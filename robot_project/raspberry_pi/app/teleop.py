"""
teleop.py — Manual drive (joystick) API endpoints.

Endpoints
---------
POST /teleop/enable        { enabled: bool }   → arm or disarm the joystick
POST /teleop/cmd_vel       { linear, angular }  → publish a Twist immediately
POST /teleop/stop                               → send zero velocity + disarm
POST /teleop/test-drive                         → short forward-backward nudge
GET  /teleop/debug                              → rich diagnostics payload
GET  /teleop/connection                         → end-to-end chain check

State machine
-------------
  DISARMED: enableTeleop(false) — cmd_vel is accepted but not forwarded.
  ARMED:    enableTeleop(true)  — cmd_vel is forwarded to ROS /cmd_vel.

A watchdog timer sends zero velocity every 500 ms when armed but no
cmd_vel has been received recently, preventing runaway if the tablet
loses Wi-Fi.
"""

import os
import threading
import time
from typing import Any

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from .auth import require_auth
from . import ros_hub, robot_link

# ── Constants ─────────────────────────────────────────────────────────────────

_WATCHDOG_INTERVAL = 0.5   # seconds — send stop if no cmd_vel received
_WATCHDOG_TIMEOUT = 1.0    # seconds — how long without cmd_vel before stop

# ── Teleop state ──────────────────────────────────────────────────────────────

_lock = threading.Lock()

_teleop: dict[str, Any] = {
    "armed": False,
    "linear": 0.0,
    "angular": 0.0,
    "last_cmd_at": 0.0,
    "publish_count": 0,
}

_watchdog_thread: threading.Thread | None = None


def _watchdog_loop() -> None:
    """Send zero velocity if tablet goes silent while armed."""
    while True:
        time.sleep(_WATCHDOG_INTERVAL)
        with _lock:
            if not _teleop["armed"]:
                break
            elapsed = time.time() - _teleop["last_cmd_at"]
            if elapsed > _WATCHDOG_TIMEOUT:
                _teleop["linear"] = 0.0
                _teleop["angular"] = 0.0
        if elapsed > _WATCHDOG_TIMEOUT:  # type: ignore[possibly-undefined]
            ros_hub.publish_cmd_vel(0.0, 0.0)


def _start_watchdog() -> None:
    global _watchdog_thread
    if _watchdog_thread is not None and _watchdog_thread.is_alive():
        return
    _watchdog_thread = threading.Thread(target=_watchdog_loop, daemon=True)
    _watchdog_thread.start()


# ── Router ────────────────────────────────────────────────────────────────────

router = APIRouter(prefix="/teleop", tags=["teleop"])


class EnableBody(BaseModel):
    enabled: bool


class CmdVelBody(BaseModel):
    linear: float = 0.0
    angular: float = 0.0


@router.post("/enable")
async def enable_teleop(body: EnableBody, _auth=Depends(require_auth)):
    """Arm or disarm the joystick. Returns teleop + bridge status."""
    with _lock:
        _teleop["armed"] = body.enabled
        if body.enabled:
            _teleop["last_cmd_at"] = time.time()
        else:
            # Disarm: send a stop immediately
            _teleop["linear"] = 0.0
            _teleop["angular"] = 0.0

    if body.enabled:
        _start_watchdog()
        ros_hub.start()  # ensure hub is running
    else:
        ros_hub.publish_cmd_vel(0.0, 0.0)

    bridge = robot_link.get_bridge_status()
    return {
        "ok": True,
        "teleop_armed": body.enabled,
        "hub_ready": ros_hub.is_ready(),
        "bridge_ok": bridge.get("ok", False),
        "cmd_vel_subscriber": bridge.get("cmd_vel_subscriber", False),
        "cmd_vel_topic": bridge.get("cmd_vel_topic", "/cmd_vel"),
        "relay_alive": True,  # in this architecture the hub IS the relay
        "qos_compatible": True,
        "hint": "" if bridge.get("ok") else bridge.get("hint", ""),
    }


@router.post("/cmd_vel")
async def send_cmd_vel(body: CmdVelBody, _auth=Depends(require_auth)):
    """Publish a velocity command. Only forwarded to ROS when armed."""
    with _lock:
        armed = _teleop["armed"]
        _teleop["linear"] = body.linear
        _teleop["angular"] = body.angular
        _teleop["last_cmd_at"] = time.time()
        if armed:
            _teleop["publish_count"] += 1
        count = _teleop["publish_count"]

    if armed:
        ros_hub.publish_cmd_vel(body.linear, body.angular)

    return {
        "ok": True,
        "armed": armed,
        "linear": body.linear,
        "angular": body.angular,
        "publish_count": count,
    }


@router.post("/stop")
async def stop_teleop(_auth=Depends(require_auth)):
    """Disarm and send immediate stop (preserves motor keepalive)."""
    with _lock:
        _teleop["armed"] = False
        _teleop["linear"] = 0.0
        _teleop["angular"] = 0.0
    ros_hub.publish_cmd_vel(0.0, 0.0)
    return {"ok": True, "teleop_armed": False}


@router.post("/test-drive")
async def test_drive(_auth=Depends(require_auth)):
    """
    Send a short forward-then-stop nudge so the user can verify the
    full cmd_vel chain is working (bridge → controller → wheels).
    """
    import asyncio
    bridge = robot_link.get_bridge_status()
    if not bridge.get("ok") and not bridge.get("cmd_vel_subscriber"):
        return {
            "ok": False,
            "hint": "Bridge not ready — start the robot first",
            "bridge_ok": False,
        }

    ros_hub.publish_cmd_vel(0.1, 0.0)   # nudge forward 0.1 m/s
    await asyncio.sleep(0.4)
    ros_hub.publish_cmd_vel(0.0, 0.0)   # stop

    return {
        "ok": True,
        "hint": "Test nudge sent (0.1 m/s for 400 ms). Did the robot move?",
        "bridge_ok": bridge.get("ok", False),
        "cmd_vel_subscriber": bridge.get("cmd_vel_subscriber", False),
        "teleop_armed": _teleop["armed"],
        "hub_ready": ros_hub.is_ready(),
    }


@router.get("/debug")
async def teleop_debug(_auth=Depends(require_auth)):
    """Rich diagnostics for the joystick debug dialog."""
    with _lock:
        snap = dict(_teleop)
    bridge = robot_link.get_bridge_status()
    return {
        "ok": snap["armed"] and bridge.get("ok", False),
        "teleop_armed": snap["armed"],
        "hub_ready": ros_hub.is_ready(),
        "linear": snap["linear"],
        "angular": snap["angular"],
        "publish_count": snap["publish_count"],
        "bridge_ok": bridge.get("ok", False),
        "bridge_listening": bridge.get("cmd_vel_subscriber", False),
        "cmd_vel_subscriber": bridge.get("cmd_vel_subscriber", False),
        "cmd_vel_topic": bridge.get("cmd_vel_topic", "/cmd_vel"),
        "relay_alive": True,
        "hint": bridge.get("hint", ""),
        "qos_compatible": True,
    }


@router.get("/connection")
async def teleop_connection(_auth=Depends(require_auth)):
    """End-to-end chain check for the joystick Debug button."""
    bridge = robot_link.get_bridge_status()
    hub_ok = ros_hub.is_ready()
    sub_ok = bridge.get("cmd_vel_subscriber", False)
    chain_ok = hub_ok and sub_ok

    warnings: list[str] = []
    if not hub_ok:
        warnings.append("ROS hub not ready — press START")
    if not sub_ok:
        warnings.append("No subscriber on /cmd_vel — bridge may not be running")

    return {
        "chain_ok": chain_ok,
        "hub_ready": hub_ok,
        "bridge": bridge,
        "warnings": warnings,
        "hint": "; ".join(warnings) if warnings else "All good",
    }
