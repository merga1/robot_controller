"""
main.py — FastAPI application factory for the robot Pi backend.

All API endpoints that the Flutter app calls are wired here.

Routes registered
-----------------
  /auth/*           — login / JWT (auth.py)
  /robot/*          — lifecycle, status, bridge, motors (robot_link.py)
  /teleop/*         — joystick cmd_vel (teleop.py)
  /destinations/*   — CRUD for named map poses (database.py)
  /navigation/*     — map metadata, map image, Nav2 goal, cancel (ros_hub.py)
  /missions/*       — sequential waypoint missions (missions.py)
  /logs             — robot stdout log tail

Usage (from raspberry_pi/ directory):
    source real1_link.env
    uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
"""

import os
import io
import math
import subprocess
from pathlib import Path
from typing import Any

import yaml
from fastapi import Depends, FastAPI, HTTPException, Response, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from .auth import require_auth, require_admin, router as auth_router
from .teleop import router as teleop_router
from .missions import router as missions_router
from . import database, robot_link, ros_hub

# ── App ───────────────────────────────────────────────────────────────────────

app = FastAPI(
    title="Robot Controller API",
    version="2.0.0",
    description="REST backend for the Flutter robot controller app",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include sub-routers
app.include_router(auth_router)
app.include_router(teleop_router)
app.include_router(missions_router)


# ── Startup / shutdown ────────────────────────────────────────────────────────

@app.on_event("startup")
async def _startup():
    # Pre-start the ROS hub so amcl_pose is subscribed from the beginning.
    ros_hub.start()
    # Ensure destinations.json exists
    db_path = Path(__file__).parent / "destinations.json"
    if not db_path.exists():
        db_path.write_text("[]", encoding="utf-8")


@app.on_event("shutdown")
async def _shutdown():
    ros_hub.stop()


# ── Robot lifecycle ───────────────────────────────────────────────────────────

@app.post("/robot/start")
async def start_robot(_auth=Depends(require_auth)):
    robot_link.start_robot()
    return {"ok": True, "status": "launching"}


@app.post("/robot/stop")
async def stop_robot(_auth=Depends(require_auth)):
    robot_link.stop_robot()
    return {"ok": True, "status": "idle"}


@app.post("/robot/ready")
async def set_ready(_auth=Depends(require_auth)):
    return robot_link.set_ready()


@app.get("/robot/status")
async def get_robot_status(_auth=Depends(require_auth)):
    return robot_link.get_status()


@app.get("/robot/link-check")
async def link_check(_auth=Depends(require_auth)):
    return robot_link.get_link_check()


@app.get("/robot/bridge-status")
async def bridge_status(_auth=Depends(require_auth)):
    return robot_link.get_bridge_status()


@app.post("/robot/enable-motors")
async def enable_motors(_auth=Depends(require_auth)):
    return robot_link.enable_motors()


# ── Destinations ──────────────────────────────────────────────────────────────

class DestinationBody(BaseModel):
    name: str
    x: float = 0.0
    y: float = 0.0
    theta: float = 0.0


@app.get("/destinations")
async def list_destinations(_auth=Depends(require_auth)):
    dests = database.get_destinations()
    return {"destinations": dests}


@app.post("/destinations")
async def upsert_destination(body: DestinationBody, _auth=Depends(require_auth)):
    database.upsert_destination(body.name, body.x, body.y, body.theta)
    return {"ok": True, "name": body.name, "x": body.x, "y": body.y, "theta": body.theta}


@app.delete("/destinations/{name}")
async def delete_destination(name: str, _auth=Depends(require_auth)):
    found = database.delete_destination(name)
    if not found:
        raise HTTPException(status_code=404, detail=f"Destination '{name}' not found")
    return {"ok": True, "name": name}


# ── Navigation ────────────────────────────────────────────────────────────────

def _find_map_yaml() -> Path | None:
    """Locate the map YAML file from env or the default workspace path."""
    override = os.getenv("ROBOT_MAP_YAML", "")
    if override and Path(override).exists():
        return Path(override)
    real1_ws = os.getenv("REAL1_WS", "")
    if real1_ws:
        candidate = Path(real1_ws) / "src/articubot_one/maps/my_map.yaml"
        if candidate.exists():
            return candidate
    return None


def _parse_map_yaml(path: Path) -> dict[str, Any]:
    """Parse a ROS map_server YAML into metadata the Flutter app expects."""
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    image_file = data.get("image", "my_map.pgm")
    if not Path(image_file).is_absolute():
        image_file = str(path.parent / image_file)

    origin = data.get("origin", [0.0, 0.0, 0.0])
    resolution = float(data.get("resolution", 0.05))
    negate = int(data.get("negate", 0))

    # Read image to get pixel dimensions
    try:
        from PIL import Image
        with Image.open(image_file) as img:
            width, height = img.size
    except Exception:
        # Fall back to PGM header parsing
        width, height = _pgm_dimensions(image_file)

    return {
        "image_url": "/navigation/map/image",
        "resolution": resolution,
        "origin": {"x": float(origin[0]), "y": float(origin[1]), "yaw": float(origin[2])},
        "width": width,
        "height": height,
        "frame_id": "map",
        "negate": negate,
    }


def _pgm_dimensions(image_file: str) -> tuple[int, int]:
    """Read width/height from a PGM header without PIL."""
    try:
        with open(image_file, "rb") as f:
            magic = f.readline().decode("ascii").strip()
            if magic not in ("P5", "P2"):
                return 0, 0
            # Skip comment lines
            line = f.readline().decode("ascii").strip()
            while line.startswith("#"):
                line = f.readline().decode("ascii").strip()
            w, h = (int(v) for v in line.split())
            return w, h
    except Exception:
        return 0, 0


@app.get("/navigation/map")
async def get_map_meta(_auth=Depends(require_auth)):
    map_yaml = _find_map_yaml()
    if map_yaml is None:
        raise HTTPException(
            status_code=404,
            detail="Map YAML not found. Set REAL1_WS or ROBOT_MAP_YAML in real1_link.env",
        )
    return _parse_map_yaml(map_yaml)


@app.get("/navigation/map/image")
async def get_map_image(_auth=Depends(require_auth)):
    """Serve the map image (PGM or PNG). The Flutter client handles PGM→BMP conversion."""
    map_yaml = _find_map_yaml()
    if map_yaml is None:
        raise HTTPException(status_code=404, detail="Map not configured")

    data = yaml.safe_load(map_yaml.read_text(encoding="utf-8"))
    image_file = data.get("image", "my_map.pgm")
    if not Path(image_file).is_absolute():
        image_file = str(map_yaml.parent / image_file)

    img_path = Path(image_file)
    if not img_path.exists():
        raise HTTPException(status_code=404, detail=f"Map image not found: {image_file}")

    img_bytes = img_path.read_bytes()
    suffix = img_path.suffix.lower()
    media_map = {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".pgm": "image/x-portable-graymap",
    }
    content_type = media_map.get(suffix, "application/octet-stream")
    return Response(content=img_bytes, media_type=content_type)


class GoalBody(BaseModel):
    destination: str


@app.post("/navigation/goal")
async def send_goal(body: GoalBody, _auth=Depends(require_auth)):
    dest = database.get_destination(body.destination)
    if dest is None:
        raise HTTPException(
            status_code=404,
            detail=f"Destination '{body.destination}' not found",
        )
    ros_hub.send_nav_goal(body.destination, dest["x"], dest["y"], dest["theta"])
    return {
        "ok": True,
        "destination": body.destination,
        "x": dest["x"],
        "y": dest["y"],
        "theta": dest["theta"],
    }


@app.post("/navigation/cancel")
async def cancel_navigation(_auth=Depends(require_auth)):
    ros_hub.cancel_nav_goal()
    return {"ok": True}


# ── Logs ──────────────────────────────────────────────────────────────────────

@app.get("/logs")
async def get_logs(
    severity: str | None = None,
    limit: int = 100,
    _auth=Depends(require_auth),
):
    logs = robot_link.get_logs(severity=severity, limit=limit)
    return {"logs": logs, "count": len(logs)}


# ── Health check (no auth) ────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"ok": True, "service": "robot-api"}
