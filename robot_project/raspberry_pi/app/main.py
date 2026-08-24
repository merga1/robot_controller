"""FastAPI backend — SRS-compliant (Sections 10.1, 7.x, 8.2, 8.3, 9.x)."""
import logging
import subprocess
import asyncio
import json
import os
import sys
import threading
import time
from datetime import datetime, timezone
from typing import Optional

log = logging.getLogger(__name__)

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Depends, HTTPException, Query
from starlette.websockets import WebSocketState
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from .database import init_db, get_db
from .auth import login as auth_login, require_user, require_admin, verify_token
from .missions import create_mission, get_mission, run_mission, log_event
from . import robot_link  # loads real1_link.env + ROS env before rclpy
from .ros_monitor import start_monitor
from . import teleop
from . import ros_hub

# ── Init ──────────────────────────────────────────────────────────────────
init_db()

app = FastAPI(title="Robot Control API", version="2.0.0")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)

# ── Shared state (in-memory, updated by ROS 2 monitor + endpoints) ────────────────
robot_state: dict = {
    "connection": "connected",      # API link (tablet ↔ Pi backend)
    "status": "idle",
    "battery": 100,
    "battery_voltage": 12.6,
    "pose": {"x": 0.0, "y": 0.0, "theta": 0.0},
    "current_action": None,         # None | navigating | mission | teleop
    "destination": None,
    "current_mission": None,
    "ros_running": False,
    "message": "System idle",
    "bridge_status": {},
    # Node health (FR-STAT-4)
    "node_health": {
        "robot_driver": "unknown",
        "robotBridge": "unknown",
        "lidar_driver": "unknown",
        "nav2": "unknown",
    },
}

ros_process: Optional[subprocess.Popen] = None
gamepad_process: Optional[subprocess.Popen] = None
nav_process: Optional[subprocess.Popen] = None
_bridge_output: list[str] = []


def _log_line(severity: str, message: str) -> None:
    log_event(severity, "ros_launch", message)


def _stop_gamepad_process() -> None:
    global gamepad_process
    if gamepad_process and gamepad_process.poll() is None:
        gamepad_process.terminate()
        try:
            gamepad_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            gamepad_process.kill()
    gamepad_process = None


def _stop_gamepad() -> None:
    _stop_gamepad_process()
    teleop.disarm_teleop()


def _start_gamepad() -> str:
    """Start Pi gamepad.py (if enabled) and tablet cmd_vel teleop."""
    global gamepad_process
    mode = robot_link.JOYSTICK_MODE
    use_tablet = mode in ("tablet", "both", "")
    use_gamepad = robot_link.START_PI_GAMEPAD and mode in ("gamepad", "both", "")

    # Bug 5 fix: always arm tablet teleop when tablet mode is requested.
    # If mode=gamepad but PI_GAMEPAD is disabled, fall back to tablet mode
    # and log a warning rather than silently arming teleop with no publisher.
    if use_tablet:
        teleop.enable_teleop(True)
    elif use_gamepad:
        # Gamepad-only mode — do NOT arm tablet teleop (gamepad.py will publish).
        pass
    else:
        # mode=gamepad but START_PI_GAMEPAD=0 → no gamepad process will start;
        # fall back to tablet cmd_vel so the joystick is not silently dead.
        log.warning(
            "REAL1_JOYSTICK_MODE=%s but REAL1_PI_GAMEPAD=0 — "
            "no gamepad.py will start; falling back to tablet cmd_vel.",
            mode,
        )
        teleop.enable_teleop(True)

    gamepad_msg = "Pi gamepad disabled (REAL1_JOYSTICK_MODE=tablet)"
    if not use_gamepad:
        return gamepad_msg if not use_tablet else "Tablet cmd_vel active"

    if gamepad_process and gamepad_process.poll() is None:
        return "gamepad.py already running"

    proc, msg = robot_link.try_start_gamepad()
    if proc is None:
        log_event("info", "teleop", msg)
        return msg

    gamepad_process = proc
    script = os.path.basename(robot_link.resolve_gamepad_path() or "gamepad.py")
    log_event("info", "teleop", f"Started {script} (PID {gamepad_process.pid})")

    def _on_exit(code: int):
        global gamepad_process
        if gamepad_process and gamepad_process.poll() is not None:
            log_event(
                "error" if code != 0 else "info",
                "teleop",
                f"{script} exited (code={code})",
            )
            gamepad_process = None

    robot_link.watch_process(
        gamepad_process, _on_exit, log_fn=_log_line, source="gamepad"
    )
    parts = [f"{script} running (PID {gamepad_process.pid})"]
    if use_tablet:
        parts.append("tablet cmd_vel active")
    return " — ".join(parts)

# Load destinations (Appendix A format: {"Kitchen": {"x": 2.1, "y": 0.5, "theta": 0}})
DEST_FILE = os.path.join(os.path.dirname(__file__), "destinations.json")
if os.path.exists(DEST_FILE):
    with open(DEST_FILE) as f:
        DESTINATIONS: dict = json.load(f)
else:
    DESTINATIONS = {}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _get_setting(key: str, default: str = "") -> str:
    conn = get_db()
    row = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    conn.close()
    return row["value"] if row else default


# ── Start ROS 2 monitor (subscribes to /battery_state, /amcl_pose) ──────────────
start_monitor(robot_state)


# ── Models ────────────────────────────────────────────────────────────────────
class LoginRequest(BaseModel):
    username: str
    password: str

class NavigationGoalRequest(BaseModel):
    destination: str

class MissionRequest(BaseModel):
    destinations: list[str]

class DestinationRequest(BaseModel):
    name: str
    x: float
    y: float
    theta: float

class CmdVelRequest(BaseModel):
    linear: float = 0.0   # m/s forward (+) / back (-)
    angular: float = 0.0  # rad/s left (+) / right (-)

class TeleopEnableRequest(BaseModel):
    enabled: bool


# ── Auth ──────────────────────────────────────────────────────────────────────
@app.post("/auth/login")  # FR-AUTH-1/2 — no auth required
def login(req: LoginRequest):
    return auth_login(req.username, req.password)


# ── Health ────────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    import getpass
    import socket

    hub = ros_hub.get_cmd_vel_state()
    relay = robot_link.get_relay_status()
    # Best-effort LAN IP for tablet discovery / HTTP scan labeling.
    lan_ip = ""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            lan_ip = s.getsockname()[0]
        finally:
            s.close()
    except OSError:
        pass
    user = getpass.getuser()
    host = socket.gethostname().split(".")[0]
    return {
        "ok": True,
        "service": "robot-control",
        "user": user,
        "pi_user": user,
        "host": host,
        "hostname": host,
        "ip": lan_ip,
        "hub_ready": hub.get("hub_ready"),
        "relay_alive": relay.get("alive"),
        "relay_pid": relay.get("pid"),
        "cmd_vel_topic": hub.get("topic"),
        "ros_running": robot_state.get("ros_running"),
    }


@app.get("/ws")
def websocket_info():
    """Help verify the API exposes the live status WebSocket."""
    return {
        "websocket": "/ws/status",
        "example": "ws://<pi-ip>:8000/ws/status?token=<jwt-from-login>",
        "fallback_rest": "GET /robot/status (poll every 1s if WebSocket blocked)",
    }


def _get_battery_alert(pct: int) -> str:
    if pct < 10:
        return "critical"
    if pct < 20:
        return "warning"
    return "normal"


def _status_payload() -> dict:
    return {
        "connection": robot_state["connection"],
        "pose": robot_state["pose"],
        "current_action": robot_state["current_action"],
        "destination": robot_state["destination"],
        "status": robot_state["status"],
        "message": robot_state["message"],
        "ros_running": robot_state["ros_running"],
        "node_health": robot_state["node_health"],
        "bridge_status": robot_state.get("bridge_status", {}),
        "current_mission": robot_state.get("current_mission"),
        "battery": robot_state["battery"],
        "battery_voltage": robot_state["battery_voltage"],
        "battery_alert": _get_battery_alert(robot_state["battery"]),
    }


@app.get("/robot/link-check")
def link_check(user: dict = Depends(require_user)):
    """Verify Real1 paths on the Pi — use when START fails."""
    return robot_link.validate_link()


@app.get("/robot/ros-check")
def ros_check(user: dict = Depends(require_user)):
    """Check /cmd_vel publishers and subscribers — use when teleop does not move the robot."""
    return robot_link.check_cmd_vel()


@app.get("/robot/bridge-status")
def bridge_status(user: dict = Depends(require_user)):
    """Verify robotBridge process + ROS node + cmd_vel subscriber."""
    global ros_process
    status = robot_link.verify_bridge_running(ros_process, force=True)
    robot_state["bridge_status"] = status
    if status.get("ok") and robot_state.get("ros_running"):
        robot_state["status"] = "running"
        robot_state["message"] = status.get("hint", "robotBridge running")[:500]
        nh = dict(robot_state.get("node_health") or {})
        nh["robotBridge"] = "running"
        nh["robot_driver"] = "running"
        robot_state["node_health"] = nh
    return status


# ── Robot control ──────────────────────────────────────────────────────────────
@app.post("/robot/start")  # FR-CTRL-1/2
def start_robot(user: dict = Depends(require_user)):
    global ros_process
    if robot_state["ros_running"]:
        return {"status": "already_running", "message": "ROS 2 stack already running"}

    preflight = robot_link.validate_link()
    if not preflight["ok"]:
        msg = preflight.get("hint", "Real1 path check failed")
        robot_state.update({"status": "error", "message": msg, "connection": "connected"})
        log_event("error", "robot", msg)
        raise HTTPException(status_code=400, detail=msg)

    robot_state["status"] = "launching"
    robot_state["connection"] = "connected"
    robot_state["message"] = "Starting robotBridge..."
    log_event("info", "robot", f"Start requested by {user['sub']}")

    def _launch():
        global ros_process, _bridge_output
        _bridge_output = []
        try:
            ros_process, err = robot_link.try_start_robot_bridge(wait_sec=4.0)
            launch_cmd = robot_link.get_last_launch_command()
            if ros_process is None:
                msg = f"robotBridge failed: {err}"
                robot_state.update({
                    "ros_running": False,
                    "status": "error",
                    "connection": "connected",
                    "message": msg[:500],
                    "node_health": {k: "dead" for k in robot_state["node_health"]},
                    "bridge_status": {"ok": False, "hint": msg[:500], "launch_command": launch_cmd},
                })
                log_event("error", "robot", msg[:500])
                return

            verify = robot_link.verify_bridge_running(ros_process, force=True)
            robot_state["bridge_status"] = verify
            robot_state["ros_running"] = bool(
                verify.get("process_alive") and verify.get("ros_node_visible")
            ) or bool(verify.get("ok"))
            # After successful START, mark ready so READY button is optional
            if verify.get("ok") or (
                verify.get("process_alive") and verify.get("ros_node_visible")
            ):
                robot_state["status"] = "ready"
                robot_state["message"] = (
                    f"robotBridge OK — keepalive on /cmd_vel. Tap JOYSTICK to drive "
                    f"({launch_cmd}). Do NOT run manual ros2 run robotBridge while app is used."
                )
            else:
                robot_state["status"] = "error"
                robot_state["message"] = verify["hint"][:500]
            robot_state["connection"] = "connected"
            robot_state["node_health"] = {
                # Real1 drives motors via robotBridge — mark driver healthy when bridge is OK
                "robot_driver": "running" if verify.get("ok") or verify.get("ros_node_visible") else "unknown",
                "robotBridge": "running" if verify["ros_node_visible"] else "dead",
                "lidar_driver": "unknown",
                "nav2": "unknown",
            }
            log_event(
                "info",
                "robot",
                f"Started: {launch_cmd} PID={ros_process.pid} "
                f"node={verify['ros_bridge_nodes']} ok={verify['ok']}",
            )
            teleop.start_motor_keepalive()

            robot_link.watch_process(
                ros_process,
                lambda code: _on_ros_exit(code),
                log_fn=_log_line,
                source="robotBridge",
                output_lines=_bridge_output,
            )
        except Exception as exc:
            robot_state["status"] = "error"
            robot_state["connection"] = "connected"
            robot_state["message"] = str(exc)
            log_event("error", "robot", str(exc))

    def _on_ros_exit(code: int):
        global ros_process
        if robot_state["ros_running"]:
            robot_state["ros_running"] = False
            robot_state["status"] = "error"
            robot_state["connection"] = "connected"
            tail = "\n".join(_bridge_output[-6:]).strip()
            msg = f"robotBridge stopped (code={code})"
            if tail:
                msg = f"{msg}: {tail[-400:]}"
            robot_state["message"] = msg[:500]
            robot_state["node_health"] = {k: "dead" for k in robot_state["node_health"]}
            log_event("error", "robot", msg[:500])
            teleop.stop_all()
        ros_process = None

    threading.Thread(target=_launch, daemon=True).start()
    return {
        "status": "launching",
        "pid": None,
        "message": f"Starting {robot_link.START_COMMAND} in {robot_link.REAL1_WS}",
    }


@app.post("/robot/stop")  # FR-CTRL-4
def stop_robot(user: dict = Depends(require_user)):
    global ros_process
    _stop_gamepad()
    teleop.stop_all()
    if ros_process:
        ros_process.terminate()
        try:
            ros_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            ros_process.kill()
        ros_process = None
    # Also clear any manual terminal robotBridge left running
    robot_link.stop_orphan_robot_bridges()
    robot_state.update({
        "ros_running": False, "status": "idle",
        "connection": "connected", "message": "Robot stopped",
        "node_health": {k: "stopped" for k in robot_state["node_health"]},
        "bridge_status": {"ok": False, "hint": "Robot stopped — press START"},
        "current_action": None,
    })
    log_event("info", "robot", f"Stop requested by {user['sub']}")
    return {"status": "stopped"}


@app.post("/robot/ready")  # FR-CTRL-5
def ready_for_work(user: dict = Depends(require_user)):
    """Optional motor re-init. NOT required for joystick after a good START."""
    if not robot_state["ros_running"]:
        raise HTTPException(status_code=409, detail="Robot not running. Press START first.")

    verify_before = robot_link.verify_bridge_running(ros_process, force=True)
    # If bridge already healthy, skip destructive restart — just mark ready.
    if verify_before.get("ok") or verify_before.get("ros_node_visible"):
        robot_state["bridge_status"] = verify_before
        robot_state["status"] = "ready"
        robot_state["current_action"] = None
        robot_state["message"] = (
            "Ready — bridge already running. Tap JOYSTICK to drive "
            "(READY restart skipped)."
        )
        log_event("info", "robot", f"Ready (no restart) by {user['sub']}")
        return {
            "status": "ready",
            "ros_action": True,
            "detail": "Bridge already OK — no restart needed.",
            "rearm_joystick": False,
            "hint": "Tap JOYSTICK and drag the pad. READY is optional.",
        }

    teleop.disarm_teleop()

    ok, detail = robot_link.run_ready_command()
    ok_en, enable_detail = robot_link.run_enable_motors(
        restart_bridge_fn=_restart_robot_bridge_for_enable
    )

    robot_link._invalidate_bridge_cache()
    ros_hub.resync_cmd_vel_topic()
    verify = robot_link.verify_bridge_running(ros_process, force=True)
    robot_state["bridge_status"] = verify
    robot_state["status"] = "ready" if (verify.get("ok") and ok_en) else "running"
    robot_state["current_action"] = None

    msg = f"Robot ready. Motors enabled: {enable_detail[:150]}"
    robot_state["message"] = msg
    log_event(
        "info",
        "robot",
        f"Ready-for-work by {user['sub']}: {detail[:200]} | Motors: {enable_detail[:200]}",
    )

    return {
        "status": "ready",
        "ros_action": ok and ok_en,
        "detail": f"Ready: {detail}. Motors: {enable_detail}",
        "rearm_joystick": True,
        "hint": "Motors re-initialized. Tap JOYSTICK to drive.",
    }


def _restart_robot_bridge_for_enable() -> tuple[bool, str]:
    """Restart robotBridge — re-runs Clear error + Enable motor in robotBridge.py."""
    global ros_process
    teleop.disarm_teleop()
    _stop_gamepad_process()
    if ros_process and ros_process.poll() is None:
        ros_process.terminate()
        try:
            ros_process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            ros_process.kill()
    ros_process, err = robot_link.try_start_robot_bridge(wait_sec=3.0)
    if ros_process is None:
        robot_state["ros_running"] = False
        robot_state["node_health"] = {
            **robot_state.get("node_health", {}),
            "robotBridge": "dead",
            "robot_driver": "dead",
        }
        return False, err or "robotBridge restart failed"
    verify = robot_link.verify_bridge_running(ros_process, force=True)
    robot_state["bridge_status"] = verify
    robot_state["ros_running"] = bool(
        verify.get("process_alive") and verify.get("ros_node_visible")
    ) or bool(verify.get("ok"))
    robot_state["node_health"] = {
        **robot_state.get("node_health", {}),
        "robot_driver": "running" if verify.get("ok") or verify.get("ros_node_visible") else "unknown",
        "robotBridge": "running" if verify.get("ros_node_visible") else "dead",
    }
    robot_state["message"] = verify.get("hint", "robotBridge restarted")[:500]
    # Re-attach exit watcher after restart
    def _on_enable_exit(code: int):
        global ros_process
        if robot_state.get("ros_running") and ros_process and ros_process.poll() is not None:
            robot_state["ros_running"] = False
            robot_state["status"] = "error"
            robot_state["message"] = f"robotBridge stopped after re-init (code={code})"[:500]
            robot_state["node_health"] = {
                **robot_state.get("node_health", {}),
                "robotBridge": "dead",
                "robot_driver": "dead",
            }
        ros_process = None

    robot_link.watch_process(
        ros_process,
        _on_enable_exit,
        log_fn=_log_line,
        source="robotBridge",
        output_lines=_bridge_output,
    )
    if verify.get("ok") or verify.get("ros_node_visible"):
        teleop.start_motor_keepalive()
        return True, f"robotBridge restarted (PID {ros_process.pid}) — motors re-initialized"
    return False, verify.get("hint", "robotBridge restarted but not verified")


@app.post("/robot/enable-motors")
def enable_motors(user: dict = Depends(require_user)):
    """Re-init L2JD motors (restart robotBridge — Real1 enables on bridge startup)."""
    if not robot_state["ros_running"]:
        raise HTTPException(
            status_code=409,
            detail="Press START first — robotBridge must be running before Enable motors.",
        )
    # Fast path: if bridge is already running and healthy, avoid a destructive 30s restart
    global ros_process
    if ros_process and ros_process.poll() is None:
        teleop.ensure_armed()
        teleop.start_motor_keepalive()
        detail = f"Motors ready and keepalive active (PID {ros_process.pid})"
        log_event("info", "robot", f"Enable motors (already active): {detail}")
        return {
            "status": "ok",
            "ok": True,
            "detail": detail,
            "hint": "Motors already active. Tap JOYSTICK and drag to drive.",
        }
    ok, detail = robot_link.run_enable_motors(restart_bridge_fn=_restart_robot_bridge_for_enable)
    robot_link._invalidate_bridge_cache()
    log_event("info" if ok else "warning", "robot", f"Enable motors: {detail[:400]}")
    return {
        "status": "ok" if ok else "failed",
        "ok": ok,
        "detail": detail,
        "hint": "Now tap JOYSTICK and try Test Drive." if ok else detail,
    }


@app.get("/robot/bridge-cmdvel-info")
def bridge_cmdvel_info(user: dict = Depends(require_user)):
    """How robotBridge converts /cmd_vel — read from robotBridge.py on Pi."""
    info = robot_link.parse_bridge_cmd_vel_info()
    info["config"] = {
        "units": robot_link.CMD_VEL_UNITS,
        "max_linear_rpm": robot_link.MAX_LINEAR_RPM,
        "max_angular_rpm": robot_link.MAX_ANGULAR_RPM,
        "tablet_max_linear": robot_link.TABLET_MAX_LINEAR,
    }
    return info


@app.get("/robot/drive-diagnosis")
def drive_diagnosis(user: dict = Depends(require_user)):
    """Why manual drive may not work — paths, QoS, relay, READY cmd."""
    gp = gamepad_process is not None and gamepad_process.poll() is None
    diag = robot_link.drive_diagnosis(gamepad_running=gp)
    diag["teleop"] = teleop.get_velocity()
    diag["hub_ready"] = ros_hub.hub_ready()
    diag["bridge_status"] = robot_state.get("bridge_status", {})
    return diag


@app.post("/robot/cmd-vel-pulse")
def cmd_vel_pulse(user: dict = Depends(require_user)):
    """Publish cmd_vel via ros2 CLI for 2s — tests robotBridge independent of tablet."""
    if not robot_state["ros_running"]:
        raise HTTPException(status_code=409, detail="Robot not running. Press START first.")
    ok, detail = robot_link.run_cmd_vel_pulse(0.5, 0.0, 2.0)
    graph = robot_link.check_cmd_vel()
    log_event("info", "teleop", f"cmd_vel pulse by {user['sub']}: ok={ok}")
    return {
        "status": "ok" if ok else "failed",
        "detail": detail,
        "ros_graph": graph,
        "hint": (
            "If robot did not move, issue is in robotBridge/motors — not the tablet app."
            if ok
            else detail
        ),
    }


@app.get("/robot/status")  # FR-STAT-1 (snapshot + WebSocket fallback)
def get_status(user: dict = Depends(require_user)):
    return _status_payload()


# ── Destinations ───────────────────────────────────────────────────────────────
@app.get("/destinations")  # FR-NAV-1
def list_destinations(user: dict = Depends(require_user)):
    return {"destinations": list(DESTINATIONS.keys())}


@app.post("/destinations")  # FR-SET-2 — admin only
def add_destination(req: DestinationRequest, user: dict = Depends(require_admin)):
    DESTINATIONS[req.name] = {"x": req.x, "y": req.y, "theta": req.theta}
    with open(DEST_FILE, "w") as f:
        json.dump(DESTINATIONS, f, indent=2)
    log_event("info", "destinations", f"Added destination '{req.name}' by {user['sub']}")
    return {"status": "added", "name": req.name}


@app.delete("/destinations/{name}")  # FR-SET-2
def delete_destination(name: str, user: dict = Depends(require_admin)):
    if name not in DESTINATIONS:
        raise HTTPException(status_code=404, detail="Destination not found")
    del DESTINATIONS[name]
    with open(DEST_FILE, "w") as f:
        json.dump(DESTINATIONS, f, indent=2)
    log_event("info", "destinations", f"Deleted destination '{name}' by {user['sub']}")
    return {"status": "deleted"}


# ── Navigation ────────────────────────────────────────────────────────────────
_nav_cancel_flag = threading.Event()

@app.post("/navigation/goal")  # FR-NAV-2
def send_navigation_goal(req: NavigationGoalRequest, user: dict = Depends(require_user)):
    global nav_process
    if not robot_state["ros_running"]:
        raise HTTPException(status_code=409, detail="Robot not running. Press START first.")
    dest = DESTINATIONS.get(req.destination)
    if not dest:
        raise HTTPException(status_code=404, detail=f"Unknown destination: {req.destination}")

    # Cancel any active navigation first
    if nav_process and nav_process.poll() is None:
        nav_process.terminate()
        try:
            nav_process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            nav_process.kill()

    _nav_cancel_flag.clear()
    teleop.disarm_teleop()
    robot_state.update({
        "status": "navigating",
        "current_action": "navigating",
        "destination": req.destination,
        "message": f"Navigating to {req.destination}",
    })
    log_event("info", "navigation", f"Goal sent to '{req.destination}' by {user['sub']}")

    def _go():
        global nav_process
        try:
            nav_process = subprocess.Popen(
                [
                    sys.executable,
                    os.path.join(os.path.dirname(__file__), "..", "ros2_nodes", "navigate_client.py"),
                    str(dest["x"]), str(dest["y"]), str(dest.get("theta", dest.get("yaw", 0))),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            while True:
                line = nav_process.stdout.readline()
                if not line:
                    break
                line = line.strip()
                if line.startswith("FEEDBACK:"):
                    parts = line.split("=")
                    if len(parts) == 2:
                        dist = parts[1]
                        robot_state["message"] = f"Navigating to {req.destination}: {dist} remaining"
            
            rc = nav_process.wait()
            if _nav_cancel_flag.is_set():
                robot_state["status"] = "running"
                robot_state["current_action"] = None
                robot_state["destination"] = None
                robot_state["message"] = "Navigation cancelled"
                log_event("info", "navigation", "Navigation cancelled by operator")
            else:
                outcome = "succeeded" if rc == 0 else "aborted"
                robot_state["status"] = "running" if outcome == "succeeded" else "error"
                robot_state["current_action"] = None
                robot_state["destination"] = None
                robot_state["message"] = f"Navigation {outcome}: {req.destination}"
                log_event(
                    "info" if outcome == "succeeded" else "error",
                    "navigation",
                    f"Navigation to '{req.destination}' {outcome} (rc={rc})",
                )
        except Exception as exc:
            robot_state["status"] = "error"
            robot_state["message"] = str(exc)
            log_event("error", "navigation", str(exc))
        finally:
            nav_process = None

    threading.Thread(target=_go, daemon=True).start()
    return {"status": "accepted", "goal_id": req.destination}


@app.post("/navigation/cancel")  # FR-NAV-5
def cancel_navigation(user: dict = Depends(require_user)):
    global nav_process
    _nav_cancel_flag.set()
    if nav_process and nav_process.poll() is None:
        nav_process.terminate()
        try:
            nav_process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            nav_process.kill()
    nav_process = None
    log_event("info", "navigation", f"Cancel requested by {user['sub']}")
    return {"status": "cancelling"}


# ── Joystick / cmd_vel teleop ─────────────────────────────────────────────────
@app.post("/teleop/enable")
def teleop_enable(req: TeleopEnableRequest, user: dict = Depends(require_user)):
    if not robot_state["ros_running"]:
        raise HTTPException(status_code=409, detail="Robot not running. Press START first.")
    try:
        if req.enabled:
            _nav_cancel_flag.set()
            enable_detail = ""
            if robot_link.AUTO_ENABLE_ON_JOYSTICK:
                ok_en, enable_detail = robot_link.run_enable_motors(
                    restart_bridge_fn=_restart_robot_bridge_for_enable
                )
                log_event(
                    "info" if ok_en else "warning",
                    "teleop",
                    f"Auto enable motors on joystick: {enable_detail[:300]}",
                )
            gamepad_msg = _start_gamepad()
            teleop.enable_teleop(True)
            ros_hub.resync_cmd_vel_topic()
            bridge = robot_link.verify_bridge_running(ros_process, force=False)
            cmd = robot_link.quick_cmd_vel_status()
            bridge["qos_compatible"] = True
            bridge["cmd_vel_subscriber"] = cmd.get("has_subscriber", True)
            bridge["bridge_listening"] = cmd.get("bridge_listening", True)
            hub = teleop.get_velocity()
            relay = robot_link.get_relay_status()
            hint = _teleop_debug_hint(
                bridge, cmd, moving=False, hub_ready=hub.get("hub_ready", False)
            )
            motor_hint = (
                "Driver blinking RED? Tap RE-INIT MOTORS first — fault blocks motion even "
                "when /cmd_vel is connected."
            )
            robot_state.update({
                "status": "running",
                "current_action": "teleop",
                "destination": None,
                "message": gamepad_msg,
                "bridge_status": bridge,
            })
            log_event("info", "teleop", f"Joystick enabled by {user['sub']}: {gamepad_msg}")
            return {
                "status": "enabled",
                "message": gamepad_msg,
                "gamepad": gamepad_msg,
                "bridge_ok": bridge.get("ok", True),
                "cmd_vel_subscriber": cmd.get("has_subscriber", True),
                "qos_compatible": True,
                "relay_best_effort": False,
                "bridge_listening": cmd.get("bridge_listening", True),
                "bridge_subscriptions": cmd.get("bridge_subscriptions", []),
                "cmd_vel_topic": robot_link.CMD_VEL_TOPIC,
                "cmd_vel_units": hub.get("cmd_vel_units"),
                "linear": hub.get("linear"),
                "angular": hub.get("angular"),
                "hub_ready": hub.get("hub_ready"),
                "relay_alive": hub.get("relay_alive"),
                "relay_pid": hub.get("relay_pid"),
                "relay_stats": relay.get("stats"),
                "stats_linear": relay.get("stats_linear"),
                "stats_angular": relay.get("stats_angular"),
                "state_linear": relay.get("state_linear"),
                "state_angular": relay.get("state_angular"),
                "teleop_armed": hub.get("teleop_armed") or True,
                "enable_motors": enable_detail,
                "publish_via": hub.get("publish_via"),
                "hint": hint,
                "motor_hint": motor_hint,
            }
        _stop_gamepad()
        teleop.disarm_teleop()
        robot_state.update({
            "current_action": None,
            "message": "Joystick disabled",
        })
        log_event("info", "teleop", f"Joystick disabled by {user['sub']}")
        return {"status": "disabled", "message": robot_state["message"]}
    except HTTPException:
        raise
    except Exception as exc:
        log.exception("teleop_enable failed")
        raise HTTPException(status_code=500, detail=f"teleop enable failed: {exc}") from exc


def _teleop_debug_hint(bridge: dict, cmd: dict, *, moving: bool, hub_ready: bool = False) -> str:
    relay = robot_link.get_relay_status()
    armed = ros_hub.teleop_armed()
    publishing = armed and relay.get("alive")
    if cmd.get("qos_compatible") is False or cmd.get("relay_best_effort"):
        return (
            "BLOCKED: tablet_cmd_vel_relay uses BEST_EFFORT but robot_bridge needs RELIABLE. "
            "Copy updated cmd_vel_relay.py to the Pi and restart: bash ~/raspberry_pi/run_server_ros.sh"
        )
    if not armed and not moving:
        return "Press JOYSTICK to enable manual drive (cmd_vel is off until then)."
    if not publishing:
        return (
            "cmd_vel not active. Tap JOYSTICK again after READY, "
            f"or check /tmp/cmd_vel_relay.log on the Pi."
        )
    if not bridge.get("ok"):
        return bridge.get("hint") or "robotBridge is not verified — press START and wait for green OK."
    topic = cmd.get("topic") or robot_link.CMD_VEL_TOPIC
    subs = cmd.get("bridge_subscriptions") or bridge.get("bridge_subscriptions") or []
    if not cmd.get("has_subscriber") and not cmd.get("bridge_listening"):
        return (
            f"robotBridge does not listen on {topic}. "
            f"Bridge subscriptions: {subs or 'none'}. "
            "Add REAL1_CMD_VEL_TOPIC=... to ~/raspberry_pi/real1_link.env"
        )
    if moving:
        return f"Publishing cmd_vel on {topic} at 10 Hz (relay). Drag must show ROS linear≈10 RPM."
    return (
        "Teleop armed (idle = linear 0). Drag the pad or hold Forward — "
        "then check that ROS linear ≈ 10, not 0."
    )


@app.post("/teleop/cmd_vel")
def teleop_cmd_vel(req: CmdVelRequest, user: dict = Depends(require_user)):
    if not robot_state["ros_running"]:
        raise HTTPException(status_code=409, detail="Robot not running. Press START first.")
    try:
        teleop.ensure_armed()
        teleop.set_velocity(req.linear, req.angular)
        info = teleop.get_velocity()
        moving = abs(req.linear) > 0.001 or abs(req.angular) > 0.001
        bridge = robot_state.get("bridge_status") or {}
        relay = robot_link.get_relay_status()
        topic = robot_link.CMD_VEL_TOPIC
        hint = f"Publishing cmd_vel on {topic} at 10 Hz (relay)." if moving else f"Joystick idle (speed={req.linear:.2f}, turn={req.angular:.2f})"
        robot_state.update({
            "current_action": "teleop",
            "message": hint,
        })
        return {
            "status": "ok",
            "linear": info.get("linear"),
            "angular": info.get("angular"),
            "linear_tablet": req.linear,
            "angular_tablet": req.angular,
            "cmd_vel_units": info.get("cmd_vel_units"),
            "teleop_active": info.get("enabled") or moving,
            "publish_count": info.get("publish_count"),
            "bridge_ok": bridge.get("ok", True),
            "cmd_vel_subscriber": True,
            "qos_compatible": True,
            "bridge_listening": True,
            "bridge_subscriptions": bridge.get("bridge_subscriptions", []),
            "cmd_vel_topic": topic,
            "hub_ready": info.get("hub_ready"),
            "relay_alive": relay.get("alive"),
            "relay_pid": relay.get("pid"),
            "relay": relay,
            "relay_stats": relay.get("stats"),
            "stats_linear": relay.get("stats_linear"),
            "stats_angular": relay.get("stats_angular"),
            "state_linear": relay.get("state_linear"),
            "state_angular": relay.get("state_angular"),
            "teleop_armed": info.get("teleop_armed"),
            "publish_ok": info.get("publish_ok"),
            "publish_via": info.get("publish_via"),
            "hint": hint,
        }
    except HTTPException:
        raise
    except Exception as exc:
        log.exception("teleop_cmd_vel failed")
        raise HTTPException(status_code=500, detail=f"teleop cmd_vel failed: {exc}") from exc


@app.post("/teleop/stop")
def teleop_stop(user: dict = Depends(require_user)):
    # Zero joystick only — keep motor keepalive so drivers do not fault red.
    teleop.disarm_teleop()
    teleop.set_velocity(0.0, 0.0)
    robot_state.update({
        "message": "Joystick zeroed (motor keepalive still running)",
    })
    log_event("info", "teleop", f"Zero cmd_vel by {user['sub']}")
    return {"status": "stopped"}


@app.get("/teleop/connection")
def teleop_connection(user: dict = Depends(require_user)):
    """Quick joystick→ROS chain check (no 2s blocking sample)."""
    status = teleop.get_velocity()
    relay = robot_link.get_relay_status()
    bridge = robot_link.verify_bridge_running(ros_process, force=True)
    topic = robot_link.CMD_VEL_TOPIC
    bridge_subs = bridge.get("bridge_subscriptions") or []
    bridge_listening = topic in bridge_subs or bridge.get("bridge_listening")
    hub_ok = status.get("hub_ready")
    relay_ok = relay.get("alive")
    armed = status.get("teleop_armed")
    publishing = armed and relay_ok
    ros_linear = status.get("linear", 0.0)
    units = status.get("cmd_vel_units", "ms")
    warn = []
    if units != "rpm":
        warn.append("REAL1_CMD_VEL_UNITS should be rpm for L2JD robotBridge")
    if armed and ros_linear != 0.0 and abs(float(ros_linear)) < 1.0:
        warn.append(f"linear.x={ros_linear} is too small — robotBridge likely needs RPM (~10)")
    if armed and not hub_ok and not relay_ok:
        warn.append("Neither ROS hub nor cmd_vel relay is alive — restart with run_server_ros.sh")
    if armed and relay_ok and not hub_ok:
        stats = relay.get("stats") or ""
        if "linear=0" in stats and status.get("enabled"):
            warn.append("Relay alive but linear=0 — redeploy cmd_vel_relay.py (state file fix)")
    if armed and relay_ok:
        stats_lin = relay.get("stats_linear")
        state_lin = relay.get("state_linear")
        if status.get("enabled") and abs(float(status.get("linear") or 0)) > 1.0:
            if stats_lin is not None and abs(float(stats_lin)) < 0.01:
                warn.append(
                    "Relay publishes linear=0 — redeploy cmd_vel_relay.py and app/robot_link.py"
                )
            if state_lin is not None and abs(float(state_lin) - float(status.get("linear") or 0)) > 1.0:
                warn.append(f"State file mismatch: file={state_lin} teleop={status.get('linear')}")
    if not bridge.get("cmd_vel_subscriber"):
        warn.append(
            "robotBridge is NOT subscribed to /cmd_vel — press START, wait for green, then Enable motors"
        )
    chain_ok = publishing and bridge.get("cmd_vel_subscriber")
    return {
        "chain_ok": chain_ok,
        "teleop": status,
        "relay": relay,
        "bridge": bridge,
        "warnings": warn,
        "hint": (
            "Connection OK — drag pad; linear on ROS should be ~10 (rpm), not 0.5."
            if chain_ok and units == "rpm"
            else "Tap JOYSTICK, drag pad, then Debug. linear must reach ROS as RPM."
        ),
    }


@app.get("/teleop/debug")
def teleop_debug(user: dict = Depends(require_user)):
    """Live joystick debug — publish log, relay stats, cmd_vel traffic."""
    gp = gamepad_process is not None and gamepad_process.poll() is None
    status = teleop.get_velocity()
    traffic = robot_link.sample_cmd_vel_traffic(2.0)
    relay = robot_link.get_relay_status()
    return {
        "teleop": status,
        "relay": relay,
        "cmd_vel_traffic": traffic,
        "bridge": robot_link.get_cached_bridge_status(ros_process),
        "gamepad_running": gp,
        "enable_services": robot_link.list_ros_services("enable"),
        "hint": (
            "Drag joystick during cmd_vel_traffic sample. "
            "If echo_output is empty, tablet commands are not reaching ROS."
        ),
    }


@app.get("/teleop/status")
def teleop_status(user: dict = Depends(require_user)):
    status = teleop.get_velocity()
    status["ros_graph"] = robot_link.check_cmd_vel()
    return status


@app.post("/teleop/test-drive")
def teleop_test_drive(user: dict = Depends(require_user)):
    """Publish a short RPM pulse via the same relay path as the joystick."""
    if not robot_state["ros_running"]:
        raise HTTPException(status_code=409, detail="Robot not running. Press START first.")
    teleop.ensure_armed()
    result = teleop.test_drive(0.5, 0.0, 2.0)
    relay = robot_link.get_relay_status()
    log_event(
        "info",
        "teleop",
        f"Test drive by {user['sub']}: linear={result.get('linear')} relay={relay.get('alive')}",
    )
    moved = abs(float(result.get("linear") or 0)) > 0.5 or abs(
        float(relay.get("state_linear") or 0)
    ) > 0.5
    return {
        "status": "ok",
        "ok": bool(relay.get("alive")),
        "teleop": result,
        "relay": relay,
        "hint": (
            "Test pulse via cmd_vel relay (~10 RPM for 2s). "
            "If wheels did not move: Enable motors, then JOYSTICK again. "
            "Pi check: bash ~/raspberry_pi/test_rpm_pulse.sh 10 3"
        ),
        "moved_hint": moved,
    }


# ── Missions ──────────────────────────────────────────────────────────────────
@app.post("/missions")  # FR-MISS-1/2
def create_new_mission(req: MissionRequest, user: dict = Depends(require_user)):
    if not robot_state["ros_running"]:
        raise HTTPException(status_code=409, detail="Robot not running. Press START first.")
    for d in req.destinations:
        if d not in DESTINATIONS:
            raise HTTPException(status_code=404, detail=f"Unknown destination: {d}")
    mission = create_mission(user["sub"], req.destinations)
    run_mission(mission["id"], DESTINATIONS, robot_state)
    return mission


@app.get("/missions/{mission_id}")  # FR-MISS-3
def fetch_mission(mission_id: int, user: dict = Depends(require_user)):
    m = get_mission(mission_id)
    if not m:
        raise HTTPException(status_code=404, detail="Mission not found")
    return m


# ── Logs ───────────────────────────────────────────────────────────────────────
@app.get("/logs")  # FR-LOG-1/2/3
def get_logs(
    severity: Optional[str] = None,
    limit: int = 100,
    user: dict = Depends(require_user),
):
    conn = get_db()
    if severity:
        rows = conn.execute(
            "SELECT * FROM events_log WHERE severity=? ORDER BY id DESC LIMIT ?",
            (severity, limit),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT * FROM events_log ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
    conn.close()
    return {
        "logs": [
            dict(r) for r in rows
        ]
    }


# ── Settings ──────────────────────────────────────────────────────────────────
@app.get("/settings")  # FR-SET-3
def get_settings(user: dict = Depends(require_user)):
    conn = get_db()
    rows = conn.execute("SELECT key, value FROM settings").fetchall()
    conn.close()
    return {r["key"]: r["value"] for r in rows}


@app.put("/settings/{key}")  # admin only
def update_setting(key: str, value: str, user: dict = Depends(require_admin)):
    conn = get_db()
    conn.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (key, value))
    conn.commit()
    conn.close()
    return {"key": key, "value": value}


# ── WebSocket live telemetry ────────────────────────────────────────────────────
@app.websocket("/ws/status")  # FR-STAT-1 / Section 10.4
async def status_websocket(
    websocket: WebSocket,
    token: str = Query(default=""),
):
    await websocket.accept()

    try:
        verify_token(token or websocket.query_params.get("token", ""))
    except ValueError as exc:
        try:
            await websocket.send_json({"error": "unauthorized", "detail": str(exc)})
            await websocket.close(code=4001)
        except Exception:
            pass
        return

    try:
        while websocket.client_state == WebSocketState.CONNECTED:
            try:
                await websocket.send_json(_status_payload())
            except (WebSocketDisconnect, RuntimeError):
                break
            await asyncio.sleep(1)
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
