"""
missions.py — Multi-stop mission management.

A mission is an ordered list of destination names. The server sends each
NavigateToPose goal sequentially, waiting for completion before moving to
the next waypoint.

Endpoints
---------
POST /missions   { destinations: [str, ...] }  → { id, status, destinations }
GET  /missions/{id}                             → mission record
"""

import asyncio
import threading
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from .auth import require_auth
from . import database, robot_link, ros_hub

router = APIRouter(prefix="/missions", tags=["missions"])

# ── Running mission state ─────────────────────────────────────────────────────

_lock = threading.Lock()
_running_mission: int | None = None   # current mission id


class MissionRequest(BaseModel):
    destinations: list[str]


@router.post("")
async def create_mission(body: MissionRequest, _auth=Depends(require_auth)):
    if not body.destinations:
        raise HTTPException(status_code=400, detail="destinations list is empty")

    # Resolve all names to poses before starting
    poses: list[dict] = []
    for name in body.destinations:
        dest = database.get_destination(name)
        if dest is None:
            raise HTTPException(
                status_code=404,
                detail=f"Destination '{name}' not found",
            )
        poses.append(dest)

    mission_id = database.create_mission(body.destinations)
    database.update_mission_status(mission_id, "running")

    with _lock:
        global _running_mission
        _running_mission = mission_id

    # Run mission in a background asyncio task so the HTTP response returns
    # immediately and the Flutter app can poll GET /missions/{id} for progress.
    asyncio.create_task(_run_mission(mission_id, poses))

    return {
        "id": mission_id,
        "status": "running",
        "destinations": body.destinations,
    }


@router.get("/{mission_id}")
async def get_mission(mission_id: int, _auth=Depends(require_auth)):
    record = database.get_mission(mission_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Mission not found")
    return record


# ── Background mission runner ─────────────────────────────────────────────────

async def _run_mission(mission_id: int, poses: list[dict]) -> None:
    """
    Drive through each waypoint sequentially.
    Gives up if the robot is not operational or if navigation fails.
    """
    global _running_mission
    for i, dest in enumerate(poses):
        with _lock:
            if _running_mission != mission_id:
                # Mission was cancelled externally
                database.update_mission_status(mission_id, "cancelled", completed=True)
                return

        name = dest["name"]
        x, y, theta = dest["x"], dest["y"], dest["theta"]

        # Send the goal
        ros_hub.send_nav_goal(name, x, y, theta)

        # Wait for navigation to finish (poll every 1 s, timeout 120 s)
        timeout = 120
        for _ in range(timeout):
            await asyncio.sleep(1)
            with _lock:
                cancelled = _running_mission != mission_id
            if cancelled:
                ros_hub.cancel_nav_goal()
                database.update_mission_status(mission_id, "cancelled", completed=True)
                return
            if not ros_hub.is_navigating():
                break
        else:
            # Timed out on this waypoint
            ros_hub.cancel_nav_goal()
            database.update_mission_status(mission_id, "failed", completed=True)
            return

    # All waypoints done
    with _lock:
        if _running_mission == mission_id:
            _running_mission = None
    database.update_mission_status(mission_id, "completed", completed=True)
