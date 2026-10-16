"""
robot_link.py — Robot process lifecycle management.

Responsibilities
----------------
• Start / stop the ROS2 launch file (articubot_one master.launch.py)
• Track the running process (PID, alive state)
• Report bridge status (cmd_vel subscriber health)
• Enable motors (via restart or enable-motors script depending on env)
• Provide /robot/status payload for the Flutter app

Environment variables (from real1_link.env)
-------------------------------------------
REAL1_WS               — path to articubot_one1 workspace
REAL1_EXTRA_SETUP      — optional extra setup.bash to source first
REAL1_START_CMD        — launch command (default: ros2 launch articubot_one master.launch.py)
REAL1_ENABLE_MOTORS_MODE — 'restart_bridge' | 'script'
REAL1_CMD_VEL_UNITS    — 'ms' (m/s) | 'rpm'
"""

import os
import shlex
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from . import ros_hub

# ── Env config ────────────────────────────────────────────────────────────────

_REAL1_WS = os.getenv("REAL1_WS", "")
_EXTRA_SETUP = os.getenv("REAL1_EXTRA_SETUP", "")
_START_CMD = os.getenv(
    "REAL1_START_CMD", "ros2 launch articubot_one master.launch.py"
)
_ENABLE_MOTORS_MODE = os.getenv("REAL1_ENABLE_MOTORS_MODE", "restart_bridge")
_CMD_VEL_TOPIC = os.getenv("REAL1_CMD_VEL_TOPIC", "/cmd_vel")

# ── State ─────────────────────────────────────────────────────────────────────

_lock = threading.Lock()

_robot: dict[str, Any] = {
    "proc": None,         # subprocess.Popen
    "pid": None,
    "status": "idle",     # idle | launching | running | error | stopping
    "message": "Robot not started",
    "launch_command": _START_CMD,
    "logs": [],           # last 200 lines of stdout/stderr
    # ready-for-work flag (set by POST /robot/ready)
    "ready": False,
    # battery (updated externally if a sensor driver is present)
    "battery": 100,
    "battery_voltage": 12.6,
    "battery_alert": "normal",
    # node health snapshot
    "node_health": {},
}


def _append_log(line: str) -> None:
    with _lock:
        _robot["logs"].append({"text": line.rstrip(), "ts": time.time()})
        if len(_robot["logs"]) > 200:
            _robot["logs"].pop(0)


# ── Launch helpers ────────────────────────────────────────────────────────────

def _build_launch_env() -> dict[str, str]:
    """Build an environment that has the ROS workspaces sourced."""
    env = dict(os.environ)
    # Source is a bash built-in, so we run it through bash -c
    # We cannot source in Python directly, so we pre-compute the variables
    # via a subprocess that echoes the env after sourcing.
    setup_files = []
    if _EXTRA_SETUP and Path(_EXTRA_SETUP).exists():
        setup_files.append(_EXTRA_SETUP)
    ws_setup = f"{_REAL1_WS}/install/setup.bash"
    if _REAL1_WS and Path(ws_setup).exists():
        setup_files.append(ws_setup)

    if not setup_files:
        return env

    source_cmds = " && ".join(f"source {p}" for p in setup_files)
    try:
        result = subprocess.run(
            ["bash", "-c", f"{source_cmds} && env"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        for line in result.stdout.splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                env[k] = v
    except Exception:
        pass
    return env


def _read_output(proc: "subprocess.Popen[str]") -> None:
    assert proc.stdout is not None
    for line in proc.stdout:
        _append_log(line)
        # Detect bridge ready signal (ros2 node starts printing)
        if "robot_bridge" in line.lower() or "nav2" in line.lower():
            with _lock:
                if _robot["status"] == "launching":
                    _robot["status"] = "running"
                    _robot["message"] = "Robot running"


def start_robot() -> None:
    with _lock:
        if _robot["proc"] is not None and _robot["proc"].poll() is None:
            return  # already running
        _robot["status"] = "launching"
        _robot["message"] = "Starting robot..."
        _robot["ready"] = False

    env = _build_launch_env()
    cmd = shlex.split(_START_CMD)
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
        )
    except FileNotFoundError as exc:
        with _lock:
            _robot["status"] = "error"
            _robot["message"] = f"Cannot start: {exc}"
        return

    with _lock:
        _robot["proc"] = proc
        _robot["pid"] = proc.pid
        _robot["launch_command"] = _START_CMD

    # Read stdout in background
    threading.Thread(target=_read_output, args=(proc,), daemon=True).start()

    # Poll for process death in background
    def _watch():
        proc.wait()
        with _lock:
            if _robot["proc"] is proc:
                _robot["proc"] = None
                _robot["pid"] = None
                _robot["status"] = "idle"
                _robot["message"] = "Robot stopped"
                _robot["ready"] = False
    threading.Thread(target=_watch, daemon=True).start()

    # Start the ROS hub node (subscribes amcl, publishes cmd_vel)
    ros_hub.start()


def stop_robot() -> None:
    with _lock:
        proc = _robot.get("proc")
        _robot["status"] = "idle"
        _robot["message"] = "Robot stopped"
        _robot["ready"] = False
        _robot["proc"] = None
        _robot["pid"] = None

    ros_hub.cancel_nav_goal()
    if proc is not None:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass


def set_ready() -> dict[str, Any]:
    with _lock:
        _robot["ready"] = True
        _robot["status"] = "running"
        _robot["message"] = "Ready for work"
    return get_status()


def enable_motors() -> dict[str, Any]:
    """
    Enable motors. Mode 'restart_bridge' restarts the launch process which
    re-initialises the motor controller on startup.
    """
    if _ENABLE_MOTORS_MODE == "restart_bridge":
        stop_robot()
        time.sleep(1)
        start_robot()
        return {"ok": True, "mode": "restart_bridge", "hint": "Bridge restarted — motors re-initialized"}
    return {"ok": False, "hint": f"Unknown enable_motors mode: {_ENABLE_MOTORS_MODE}"}


# ── Status helpers ────────────────────────────────────────────────────────────

def _proc_alive() -> bool:
    with _lock:
        proc = _robot.get("proc")
    return proc is not None and proc.poll() is None


def _node_list() -> list[str]:
    """Return running ROS2 node names (best-effort, empty on error)."""
    try:
        result = subprocess.run(
            ["ros2", "node", "list"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        return [n.strip() for n in result.stdout.splitlines() if n.strip()]
    except Exception:
        return []


def _build_node_health() -> dict[str, str]:
    nodes = _node_list()
    health: dict[str, str] = {}
    expected = ["robot_bridge", "controller_manager", "amcl", "bt_navigator", "map_server"]
    for name in expected:
        matched = any(name in n for n in nodes)
        health[name] = "running" if matched else "stopped"
    return health


def _cmd_vel_has_subscriber() -> bool:
    """Check if anything is subscribed to /cmd_vel via ros2 topic info."""
    try:
        result = subprocess.run(
            ["ros2", "topic", "info", _CMD_VEL_TOPIC],
            capture_output=True, text=True, timeout=3,
        )
        return "Subscription count: 0" not in result.stdout
    except Exception:
        return False


def get_bridge_status() -> dict[str, Any]:
    alive = _proc_alive()
    ros_visible = any("robot_bridge" in n for n in _node_list())
    has_sub = _cmd_vel_has_subscriber()
    ok = alive and (ros_visible or has_sub)
    with _lock:
        pid = _robot.get("pid")
        cmd = _robot.get("launch_command", _START_CMD)
    return {
        "ok": ok,
        "process_alive": alive,
        "ros_node_visible": ros_visible,
        "cmd_vel_subscriber": has_sub,
        "cmd_vel_topic": _CMD_VEL_TOPIC,
        "pid": pid,
        "launch_command": cmd,
        "hint": "" if ok else "Bridge not ready — press START and wait",
        "warming_up": alive and not ros_visible,
    }


def get_status() -> dict[str, Any]:
    with _lock:
        s = dict(_robot)
        s.pop("proc", None)  # not serialisable
        s.pop("logs", None)

    node_health = _build_node_health()
    is_alive = _proc_alive()
    navigating = ros_hub.is_navigating()
    nav_target = ros_hub.get_nav_target()
    pose = ros_hub.get_pose()

    # Infer status from live state
    if navigating:
        status = "navigating"
        message = f"Navigating to {nav_target}" if nav_target else "Navigating..."
    elif is_alive and s.get("ready"):
        status = "ready"
        message = "Ready for work"
    elif is_alive:
        status = s.get("status", "running")
        message = s.get("message", "Robot running")
    else:
        status = "idle"
        message = "Robot not started"

    bridge = get_bridge_status()

    return {
        "connection": "connected",
        "status": status,
        "ros_running": is_alive,
        "message": message,
        "pose": pose,
        "destination": nav_target,
        "is_navigating": navigating,
        "node_health": node_health,
        "bridge_status": bridge,
        "battery": s.get("battery", 100),
        "battery_voltage": s.get("battery_voltage", 12.6),
        "battery_alert": s.get("battery_alert", "normal"),
        "current_mission": None,
    }


def get_link_check() -> dict[str, Any]:
    """Check that required env variables are set for the robot to start."""
    ws_ok = bool(_REAL1_WS) and Path(f"{_REAL1_WS}/install/setup.bash").exists()
    return {
        "ok": ws_ok,
        "REAL1_WS": _REAL1_WS or "(not set)",
        "hint": None if ws_ok else (
            "REAL1_WS is not set or workspace not built. "
            "Set it in real1_link.env and restart the server."
        ),
    }


def get_logs(severity: str | None = None, limit: int = 100) -> list[dict]:
    with _lock:
        logs = list(_robot["logs"])
    logs = logs[-limit:]
    if severity:
        level = severity.upper()
        logs = [l for l in logs if level in l.get("text", "").upper()]
    return [{"severity": "INFO", "message": l["text"], "ts": l["ts"]} for l in logs]
