"""Link to the existing Real1 workspace on the Pi — no Real1 code lives in this repo."""
import logging
import os
import re
import subprocess
import threading
import time
from pathlib import Path
from typing import Callable, Optional

log = logging.getLogger(__name__)

_LINK_FILE = Path(__file__).resolve().parent.parent / "real1_link.env"


def _load_link_file() -> None:
    if not _LINK_FILE.is_file():
        return
    for line in _LINK_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_link_file()


def _candidate_real1_workspaces() -> list[str]:
    """delv and abpi share the Pi — try both homes plus current user."""
    home = os.path.expanduser("~")
    users = []
    for u in (os.environ.get("USER") or "", os.environ.get("LOGNAME") or "", "abpi", "delv"):
        if u and u not in users:
            users.append(u)
    candidates: list[str] = []
    configured = os.environ.get("REAL1_WS", "").strip()
    if configured:
        candidates.append(os.path.expanduser(configured))
    for u in users:
        candidates.append(f"/home/{u}/Real1")
    candidates.append(os.path.join(home, "Real1"))
    # De-dupe while preserving order
    seen: set[str] = set()
    out: list[str] = []
    for c in candidates:
        if c and c not in seen:
            seen.add(c)
            out.append(c)
    return out


def _scripts_dir_for_ws(ws: str) -> str:
    bridge_name = os.environ.get("REAL1_ROBOT_BRIDGE_SCRIPT", "robotBridge.py")
    configured = os.environ.get("REAL1_SCRIPTS", "").strip()
    if configured:
        conf = os.path.expanduser(configured)
        # Use configured scripts only if they belong to this workspace and contain the bridge.
        if conf.startswith(ws.rstrip("/") + "/") or conf.rstrip("/") == ws.rstrip("/"):
            if os.path.isfile(os.path.join(conf, bridge_name)):
                return conf
    for rel in (
        os.path.join("src", "Real1", "scripts"),
        os.path.join("src", "real1", "scripts"),
        "scripts",
    ):
        path = os.path.join(ws, rel)
        if os.path.isfile(os.path.join(path, bridge_name)) or os.path.isdir(path):
            return path
    return os.path.join(ws, "src", "Real1", "scripts")


def _resolve_real1_paths() -> tuple[str, str]:
    """Pick the Real1 workspace that actually contains robotBridge.py (abpi or delv)."""
    bridge_name = os.environ.get("REAL1_ROBOT_BRIDGE_SCRIPT", "robotBridge.py")
    best_ws = ""
    best_scripts = ""
    for ws in _candidate_real1_workspaces():
        if not os.path.isdir(ws):
            continue
        scripts = _scripts_dir_for_ws(ws)
        bridge = os.path.join(scripts, bridge_name)
        setup = os.path.join(ws, "install", "setup.bash")
        if os.path.isfile(bridge):
            best_ws, best_scripts = ws, scripts
            if os.path.isfile(setup):
                break
        elif not best_ws and os.path.isfile(setup):
            best_ws, best_scripts = ws, scripts
    if not best_ws:
        # Last resort: look for robotBridge.py under known Real1 trees only.
        for base in ("/home/abpi/Real1", "/home/delv/Real1", os.path.join(os.path.expanduser("~"), "Real1")):
            if not os.path.isdir(base):
                continue
            try:
                for root, dirs, files in os.walk(base):
                    # Skip heavy build dirs
                    dirs[:] = [d for d in dirs if d not in ("install", "build", "log", ".git")]
                    if bridge_name in files:
                        scripts = root
                        parts = Path(root).parts
                        ws = base
                        for i, part in enumerate(parts):
                            if part.lower() == "real1":
                                ws = str(Path(*parts[: i + 1]))
                                break
                        return ws, scripts
            except OSError:
                continue
        best_ws = os.environ.get("REAL1_WS", "/home/abpi/Real1")
        best_scripts = os.environ.get(
            "REAL1_SCRIPTS", os.path.join(best_ws, "src", "Real1", "scripts")
        )
    return best_ws, best_scripts


REAL1_WS, REAL1_SCRIPTS = _resolve_real1_paths()
os.environ["REAL1_WS"] = REAL1_WS
os.environ["REAL1_SCRIPTS"] = REAL1_SCRIPTS
log.info("Real1 paths: WS=%s SCRIPTS=%s", REAL1_WS, REAL1_SCRIPTS)

ROBOT_BRIDGE_SCRIPT = os.environ.get("REAL1_ROBOT_BRIDGE_SCRIPT", "robotBridge.py")
GAMEPAD_SCRIPT = os.environ.get("REAL1_GAMEPAD_SCRIPT", "gamepad.py")
START_COMMAND = os.environ.get("REAL1_START_CMD", "ros2 run Real1 robotBridge.py")
CMD_VEL_TOPIC = os.environ.get("REAL1_CMD_VEL_TOPIC", "/cmd_vel")
READY_COMMAND = os.environ.get("REAL1_READY_CMD", "")
ENABLE_MOTORS_COMMAND = os.environ.get("REAL1_ENABLE_MOTORS_CMD", "")
# restart_bridge | command — Real1 enables motors inside robotBridge.py on startup
ENABLE_MOTORS_MODE = os.environ.get("REAL1_ENABLE_MOTORS_MODE", "restart_bridge").strip().lower()
# Scale cmd_vel before publish (used when REAL1_CMD_VEL_UNITS=ms)
CMD_VEL_LINEAR_SCALE = float(os.environ.get("REAL1_CMD_VEL_LINEAR_SCALE", "1.0"))
CMD_VEL_ANGULAR_SCALE = float(os.environ.get("REAL1_CMD_VEL_ANGULAR_SCALE", "1.0"))
# Real1 L2JD robotBridge uses RPM — tablet sends 0.05–0.5 m/s style values → int(0.5)=0!
CMD_VEL_UNITS = os.environ.get("REAL1_CMD_VEL_UNITS", "rpm").strip().lower()
MAX_LINEAR_RPM = float(os.environ.get("REAL1_MAX_LINEAR_RPM", "10"))
MAX_ANGULAR_RPM = float(os.environ.get("REAL1_MAX_ANGULAR_RPM", "100"))
TABLET_MAX_LINEAR = float(os.environ.get("REAL1_TABLET_MAX_LINEAR", "0.5"))
TABLET_MAX_ANGULAR = float(os.environ.get("REAL1_TABLET_MAX_ANGULAR", "1.0"))
AUTO_ENABLE_ON_JOYSTICK = os.environ.get("REAL1_AUTO_ENABLE_ON_JOYSTICK", "0").strip().lower() in (
    "1", "true", "yes",
)
# gamepad|tablet|both — how JOYSTICK enables manual drive
JOYSTICK_MODE = os.environ.get("REAL1_JOYSTICK_MODE", "tablet").strip().lower()
START_PI_GAMEPAD = os.environ.get("REAL1_PI_GAMEPAD", "0").strip().lower() in ("1", "true", "yes")

# robot_bridge subscribes with RELIABLE — must match (not BEST_EFFORT).
CMD_VEL_QOS_DEPTH = int(os.environ.get("REAL1_CMD_VEL_QOS_DEPTH", "10"))

SETUP_BASH = os.path.join(REAL1_WS, "install", "setup.bash")
ROBOT_BRIDGE_PATH = os.path.join(REAL1_SCRIPTS, ROBOT_BRIDGE_SCRIPT)
GAMEPAD_PATH = os.path.join(REAL1_SCRIPTS, GAMEPAD_SCRIPT)

_ros_env_cache: Optional[dict] = None


def ros_env() -> dict:
    """Environment with Real1 workspace sourced (cached)."""
    global _ros_env_cache
    if _ros_env_cache is not None:
        return _ros_env_cache.copy()
    env = os.environ.copy()
    env.setdefault("ROS_DOMAIN_ID", "0")
    if os.path.isfile(SETUP_BASH):
        try:
            proc = subprocess.run(
                ["bash", "-lc", f"source {SETUP_BASH} && env"],
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            )
            for line in proc.stdout.splitlines():
                if "=" in line:
                    key, _, value = line.partition("=")
                    env[key] = value
        except Exception as exc:
            log.warning("Could not source %s: %s", SETUP_BASH, exc)
    _ros_env_cache = env
    return env.copy()


def apply_ros_environment() -> bool:
    """Merge Real1 ROS environment into the current process (before rclpy.init)."""
    if not os.path.isfile(SETUP_BASH):
        return False
    merged = ros_env()
    os.environ.update(merged)
    return True


apply_ros_environment()


def resolve_gamepad_path() -> Optional[str]:
    """Find gamepad script — env name first, then common variants."""
    if os.path.isfile(GAMEPAD_PATH):
        return GAMEPAD_PATH
    if os.path.isdir(REAL1_SCRIPTS):
        for name in ("gamepad.py", "gamePad.py", "Gamepad.py"):
            path = os.path.join(REAL1_SCRIPTS, name)
            if os.path.isfile(path):
                return path
    if os.path.isdir(REAL1_WS):
        for name in ("gamepad.py", "gamePad.py", "Gamepad.py"):
            path = os.path.join(REAL1_WS, name)
            if os.path.isfile(path):
                return path
    return None


def cmd_vel_publisher_qos():
    """RELIABLE QoS — must match robot_bridge subscriber (see ros2 topic info /cmd_vel -v)."""
    from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy, DurabilityPolicy

    return QoSProfile(
        reliability=ReliabilityPolicy.RELIABLE,
        history=HistoryPolicy.KEEP_LAST,
        depth=CMD_VEL_QOS_DEPTH,
        durability=DurabilityPolicy.VOLATILE,
    )


def validate_link() -> dict:
    checks = {
        "real1_link_env": str(_LINK_FILE),
        "real1_link_env_exists": _LINK_FILE.is_file(),
        "workspace": REAL1_WS,
        "workspace_exists": os.path.isdir(REAL1_WS),
        "setup_bash": SETUP_BASH,
        "setup_bash_exists": os.path.isfile(SETUP_BASH),
        "scripts_dir": REAL1_SCRIPTS,
        "scripts_dir_exists": os.path.isdir(REAL1_SCRIPTS),
        "robot_bridge_script": ROBOT_BRIDGE_PATH,
        "robot_bridge_exists": os.path.isfile(ROBOT_BRIDGE_PATH),
        "gamepad_script": resolve_gamepad_path() or GAMEPAD_PATH,
        "gamepad_exists": resolve_gamepad_path() is not None,
        "tried_homes": ["abpi", "delv", "current"],
    }
    checks["ok"] = all(
        checks[k]
        for k in (
            "workspace_exists",
            "setup_bash_exists",
            "scripts_dir_exists",
            "robot_bridge_exists",
        )
    )
    if not checks["real1_link_env_exists"]:
        checks["hint"] = f"Copy real1_link.env.example to {_LINK_FILE} on the Pi."
    elif not checks["robot_bridge_exists"]:
        checks["hint"] = (
            f"robotBridge.py not found at {ROBOT_BRIDGE_PATH}. "
            "Tried /home/abpi/Real1 and /home/delv/Real1. "
            "Set REAL1_WS and REAL1_SCRIPTS in real1_link.env to the home that has Real1."
        )
    elif not checks["setup_bash_exists"]:
        checks["hint"] = f"Run: cd {REAL1_WS} && colcon build"
    else:
        checks["hint"] = f"All Real1 paths OK ({REAL1_WS})."
    return checks


def _run_bash(body: str) -> subprocess.Popen:
    return subprocess.Popen(
        ["bash", "-lc", body],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=ros_env(),
    )


def bash_in_workspace(inner_command: str, *, cwd_scripts: bool = False) -> subprocess.Popen:
    if cwd_scripts:
        body = (
            f"cd {REAL1_WS} && source {SETUP_BASH} && "
            f"cd {REAL1_SCRIPTS} && exec {inner_command}"
        )
    else:
        body = f"cd {REAL1_WS} && source {SETUP_BASH} && exec {inner_command}"
    return _run_bash(body)


def _run_robot_bridge_command(inner_command: str) -> subprocess.Popen:
    """START robotBridge — always source Real1 setup.bash first (manual Pi workflow)."""
    body = (
        f"source {SETUP_BASH} && "
        f"cd {REAL1_WS} && "
        f"exec {inner_command}"
    )
    log.info("Launching robotBridge: %s", body)
    return subprocess.Popen(
        ["bash", "-lc", body],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def drain_output(proc: subprocess.Popen, limit: int = 1500) -> str:
    if not proc.stdout:
        return ""
    try:
        return (proc.stdout.read() or "").strip()[-limit:]
    except Exception:
        return ""


def _launch_candidates() -> list[tuple[str, bool]]:
    """Return (command, run_from_scripts_dir) pairs."""
    if START_COMMAND.strip():
        cmd = START_COMMAND.strip()
        if cmd.startswith("ros2 "):
            return [(cmd, False)]
        if cmd.endswith(".py") and not cmd.startswith("python3"):
            cmd = f"python3 {cmd}"
        use_scripts = ".py" in cmd and not os.path.isabs(cmd.split()[-1])
        return [(cmd, use_scripts)]
    return [
        ("ros2 run Real1 robotBridge.py", False),
        ("ros2 run Real1 robotBridge", False),
        ("ros2 run Real1 robot_bridge", False),
    ]


_last_launch_command: str = ""
_bridge_cache: dict = {"at": 0.0, "data": {}}
_GRAPH_CACHE_TTL = 5.0
_graph_cache: dict = {"at": 0.0, "nodes": [], "bridge_nodes": [], "bridge_subs": {}}
_TOPIC_CACHE_TTL = 30.0
_topic_cache: dict = {"at": 0.0, "topic": ""}
_BRIDGE_CACHE_TTL = 8.0
_CMD_VEL_RELAY = Path(__file__).resolve().parent.parent / "cmd_vel_relay.py"
_KEEPALIVE_SH = Path(__file__).resolve().parent.parent / "cmd_vel_keepalive.sh"
_cmd_vel_state_path = "/tmp/robot_cmd_vel.state"
_cmd_vel_relay_log = "/tmp/cmd_vel_relay.log"
_cmd_vel_relay_proc: Optional[subprocess.Popen] = None
_keepalive_proc: Optional[subprocess.Popen] = None
_cmd_vel_lock = threading.RLock()
_relay_allowed = False
_last_cmd_vel_write_at: float = 0.0
_last_cmd_vel_written: tuple[float, float] = (0.0, 0.0)


def _bridge_node_names(nodes: list[str]) -> list[str]:
    return [n for n in nodes if re.search(r"robot[_]?bridge", n, re.I)]


def _invalidate_bridge_cache() -> None:
    _bridge_cache["at"] = 0.0
    _bridge_cache["data"] = {}
    _graph_cache["at"] = 0.0


def _cached_ros_graph() -> tuple[list[str], list[str], dict[str, list[str]]]:
    """Node list + bridge nodes + subscriptions (cached ~5s)."""
    now = time.time()
    if _graph_cache["at"] and now - _graph_cache["at"] < _GRAPH_CACHE_TTL:
        return (
            list(_graph_cache["nodes"]),
            list(_graph_cache["bridge_nodes"]),
            dict(_graph_cache["bridge_subs"]),
        )
    nodes = _ros_node_list()
    bridge_nodes = _bridge_node_names(nodes)
    subs: dict[str, list[str]] = {}
    for node in bridge_nodes:
        subs[node] = _bridge_node_subscriptions(node)
    _graph_cache.update(
        {"at": now, "nodes": nodes, "bridge_nodes": bridge_nodes, "bridge_subs": subs}
    )
    return nodes, bridge_nodes, subs


def quick_cmd_vel_status() -> dict:
    """Fast graph check for teleop HTTP — avoids triple ros2 topic info -v."""
    global CMD_VEL_TOPIC
    nodes, bridge_nodes, subs_map = _cached_ros_graph()
    topic = CMD_VEL_TOPIC
    bridge_subs: list[str] = []
    for node in bridge_nodes:
        bridge_subs.extend(subs_map.get(node, []))
    bridge_listening = topic in bridge_subs or any(
        "cmd_vel" in t.lower() for t in bridge_subs
    )
    relay_visible = any("tablet_cmd_vel_relay" in n for n in nodes)
    has_sub = bridge_listening or bool(bridge_nodes)
    return {
        "topic": topic,
        "ok": bool(bridge_nodes) and has_sub,
        "has_subscriber": has_sub,
        "bridge_listening": bridge_listening,
        "bridge_subscriptions": bridge_subs,
        "robot_bridge_nodes": bridge_nodes,
        "relay_node_visible": relay_visible,
        "nodes": nodes,
    }


def _bridge_node_subscriptions(node_name: str) -> list[str]:
    try:
        proc = subprocess.run(
            ["bash", "-lc", f"source {SETUP_BASH} && ros2 node info {node_name}"],
            capture_output=True,
            text=True,
            timeout=15,
            env=ros_env(),
        )
        out = (proc.stdout or "") + (proc.stderr or "")
    except Exception:
        return []
    topics: list[str] = []
    in_subscribers = False
    for line in out.splitlines():
        stripped = line.strip()
        if stripped.startswith("Subscribers:"):
            in_subscribers = True
            continue
        if stripped.startswith("Publishers:") or stripped.startswith("Service Servers:"):
            in_subscribers = False
        if in_subscribers and stripped.startswith("/"):
            topic = stripped.split(":", 1)[0].strip()
            if topic:
                topics.append(topic)
    return topics


def sync_cmd_vel_topic() -> str:
    """Pick the topic robot_bridge actually subscribes to (may differ from /cmd_vel)."""
    global CMD_VEL_TOPIC
    now = time.time()
    if _topic_cache["at"] and now - _topic_cache["at"] < _TOPIC_CACHE_TTL:
        return CMD_VEL_TOPIC
    _, bridge_nodes, subs_map = _cached_ros_graph()
    candidates: list[str] = []
    for node in bridge_nodes:
        for topic in subs_map.get(node, []):
            low = topic.lower()
            if "cmd_vel" in low or low.endswith("/twist"):
                candidates.append(topic)
    if not candidates:
        _topic_cache["at"] = now
        return CMD_VEL_TOPIC
    preferred = CMD_VEL_TOPIC
    if preferred in candidates:
        _topic_cache["at"] = now
        return preferred
    chosen = candidates[0]
    if chosen != CMD_VEL_TOPIC:
        log.info("Auto-detected cmd_vel topic: %s (was %s)", chosen, CMD_VEL_TOPIC)
        CMD_VEL_TOPIC = chosen
        os.environ["REAL1_CMD_VEL_TOPIC"] = chosen
    _topic_cache["at"] = now
    return CMD_VEL_TOPIC


def _topic_has_subscriber(verbose_out: str) -> bool:
    if "Subscription count: 0" in verbose_out:
        return False
    if re.search(r"Subscription count:\s*[1-9]", verbose_out):
        return True
    return "Endpoint type: SUBSCRIPTION" in verbose_out.upper()


def _bridge_listens_on_topic(topic: str, bridge_nodes: list[str]) -> bool:
    """True if robotBridge node subscribes to this exact topic."""
    for node in bridge_nodes:
        if topic in _bridge_node_subscriptions(node):
            return True
    return False


def _ros_node_list() -> list[str]:
    try:
        proc = subprocess.run(
            ["bash", "-lc", f"source {SETUP_BASH} && ros2 node list"],
            capture_output=True,
            text=True,
            timeout=15,
            env=ros_env(),
        )
        return [line.strip() for line in (proc.stdout or "").splitlines() if line.strip()]
    except Exception:
        return []


def get_last_launch_command() -> str:
    return _last_launch_command


def verify_bridge_running(proc: Optional[subprocess.Popen] = None, *, force: bool = False) -> dict:
    """Confirm robotBridge process + ROS node + cmd_vel subscriber (cached)."""
    now = time.time()
    if not force and _bridge_cache["data"] and now - _bridge_cache["at"] < _BRIDGE_CACHE_TTL:
        cached = dict(_bridge_cache["data"])
        if proc is not None:
            alive = proc.poll() is None
            cached["process_alive"] = alive
            cached["pid"] = proc.pid if alive else None
            if not alive:
                cached["ok"] = False
                cached["hint"] = "Launch process is not running — press START again."
        return cached
    return _verify_bridge_running_now(proc)


def get_cached_bridge_status(proc: Optional[subprocess.Popen] = None) -> dict:
    return verify_bridge_running(proc, force=False)


def _verify_bridge_running_now(proc: Optional[subprocess.Popen] = None) -> dict:
    """Fresh ROS graph check — uses cached node list when possible."""
    sync_cmd_vel_topic()
    nodes, bridge_nodes, subs_map = _cached_ros_graph()
    cmd_info = quick_cmd_vel_status()
    process_alive = proc is not None and proc.poll() is None
    ros_node_visible = len(bridge_nodes) > 0
    bridge_subs: list[str] = cmd_info.get("bridge_subscriptions") or []
    for node in bridge_nodes:
        bridge_subs.extend(subs_map.get(node, []))
    bridge_subs = list(dict.fromkeys(bridge_subs))
    cmd_vel_subscriber = bool(cmd_info.get("has_subscriber"))
    bridge_listening = bool(cmd_info.get("bridge_listening"))
    launched_via_ros2 = (_last_launch_command or "").strip().startswith("ros2 run")

    # Drive is OK if the ROS node is up. Process handle may be lost after
    # Enable-motors restart — still allow teleop when the graph shows the node.
    ok = (process_alive and ros_node_visible) or (
        ros_node_visible and (cmd_vel_subscriber or bridge_listening)
    )
    if process_alive and ros_node_visible:
        ok = True

    if not process_alive and not ros_node_visible:
        hint = (
            "Launch process is not running. Set REAL1_START_CMD=ros2 run Real1 robotBridge.py "
            "in ~/raspberry_pi/real1_link.env and press START again."
        )
    elif not process_alive and ros_node_visible:
        hint = (
            "robot_bridge ROS node is visible (process handle lost) — OK to drive. "
            "Tap JOYSTICK to arm cmd_vel."
        )
        ok = True
    elif not launched_via_ros2 and process_alive:
        hint = (
            f"Wrong launch: '{_last_launch_command}'. Must use "
            "'ros2 run Real1 robotBridge.py' (not python3 robotBridge.py). "
            "Update real1_link.env and press START."
        )
    elif not ros_node_visible:
        hint = (
            f"Process PID {proc.pid if proc else '?'} is alive but ROS node robot_bridge "
            f"is missing. Command used: {_last_launch_command or 'unknown'}. "
            "Wait a few seconds or check Logs for robotBridge output."
        )
    elif not cmd_vel_subscriber and not bridge_listening:
        subs = []
        for node in bridge_nodes:
            subs.extend(_bridge_node_subscriptions(node))
        sub_hint = f" Bridge subscribes to: {subs}" if subs else ""
        hint = (
            f"robot_bridge is up but cmd_vel subscriber not confirmed yet.{sub_hint} "
            "Tap JOYSTICK and drag — or Enable motors if wheels stay stopped."
        )
        # Still allow operate when node is up (graph checks are flaky under load).
        ok = True
    else:
        hint = "robotBridge OK — ros2 run active, node visible, cmd_vel subscribed."

    result = {
        "ok": ok,
        "process_alive": process_alive,
        "pid": proc.pid if proc and process_alive else None,
        "launch_command": _last_launch_command,
        "launched_via_ros2_run": launched_via_ros2,
        "ros_node_visible": ros_node_visible,
        "ros_bridge_nodes": bridge_nodes,
        "ros_nodes": nodes,
        "cmd_vel_subscriber": cmd_vel_subscriber,
        "bridge_listening": bridge_listening,
        "cmd_vel_topic": CMD_VEL_TOPIC,
        "cmd_vel_detail": "",
        "bridge_subscriptions": bridge_subs,
        "relay_node_visible": cmd_info.get("relay_node_visible"),
        "hint": hint,
    }
    _bridge_cache["at"] = time.time()
    _bridge_cache["data"] = result
    return result


def _on_bridge_ready() -> None:
    """Sync cmd_vel topic after robotBridge is up — start keepalive immediately."""
    sync_cmd_vel_topic()
    try:
        from . import ros_hub
        from . import teleop

        ros_hub.resync_cmd_vel_topic()
        teleop.start_motor_keepalive()
    except ImportError:
        set_relay_allowed(True)
        start_cmd_vel_relay()
        publish_cmd_vel(0.0, 0.0)
        start_shell_keepalive()


def set_relay_allowed(allowed: bool) -> None:
    global _relay_allowed
    _relay_allowed = allowed
    if not allowed:
        stop_cmd_vel_relay()


def relay_allowed() -> bool:
    return _relay_allowed


def stop_cmd_vel_relay() -> None:
    _stop_cmd_vel_relay()


def start_shell_keepalive() -> None:
    """Fallback: ros2 topic pub at 10 Hz (zero RPM) for L2JD serial keepalive."""
    global _keepalive_proc
    if not _KEEPALIVE_SH.is_file():
        return
    if _keepalive_proc is not None and _keepalive_proc.poll() is None:
        return
    try:
        _keepalive_proc = subprocess.Popen(
            ["bash", str(_KEEPALIVE_SH), "start"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        log.info("shell cmd_vel keepalive started")
    except OSError as exc:
        log.warning("shell keepalive failed: %s", exc)


def stop_shell_keepalive() -> None:
    global _keepalive_proc
    if _KEEPALIVE_SH.is_file():
        try:
            subprocess.run(
                ["bash", str(_KEEPALIVE_SH), "stop"],
                capture_output=True,
                timeout=5,
            )
        except Exception:
            pass
    if _keepalive_proc is not None and _keepalive_proc.poll() is None:
        try:
            _keepalive_proc.terminate()
        except Exception:
            pass
    _keepalive_proc = None


def stop_orphan_robot_bridges() -> str:
    """Kill leftover robotBridge / relay processes so START owns the serial port.

    A manual `ros2 run Real1 robotBridge.py` left running + app START causes
    two bridges on the same L2JD bus → Communication loss + red driver LED.
    """
    cmds = [
        "pkill -f '[r]obotBridge' || true",
        "pkill -f '[r]obot_bridge' || true",
        "pkill -f '[t]ablet_cmd_vel_relay' || true",
        "pkill -f 'ros2 run Real1 robotBridge' || true",
    ]
    for c in cmds:
        try:
            subprocess.run(["bash", "-lc", c], capture_output=True, text=True, timeout=5)
        except Exception as exc:
            log.warning("stop_orphan_robot_bridges: %s", exc)
    time.sleep(1.5)
    # Confirm serial is free enough for a clean start
    left = _ros_node_list()
    leftovers = [n for n in left if re.search(r"robot[_]?bridge|tablet_cmd_vel_relay", n, re.I)]
    msg = "Cleared orphan robotBridge/relay"
    if leftovers:
        msg += f" (still visible in ROS graph: {leftovers} — wait a few seconds)"
    log.info(msg)
    return msg


def try_start_robot_bridge(wait_sec: float = 4.0) -> tuple[Optional[subprocess.Popen], str]:
    """Try each launch command; return (process, error_output)."""
    global _last_launch_command
    _invalidate_bridge_cache()
    check = validate_link()
    if not check["ok"]:
        return None, check.get("hint", "Real1 link check failed")

    # Exclusive ownership of L2JD serial — never start a second bridge.
    stop_orphan_robot_bridges()
    _stop_cmd_vel_relay()

    last_output = ""
    for cmd, _cwd_scripts in _launch_candidates():
        _last_launch_command = cmd
        proc = _run_robot_bridge_command(cmd)
        # Start keepalive ASAP once process is alive (do not wait for full verify).
        time.sleep(1.0)
        if proc.poll() is None:
            try:
                from . import teleop
                teleop.start_motor_keepalive()
            except ImportError:
                pass
        # Wait until ROS node + cmd_vel subscriber appear (up to ~20s).
        for _ in range(10):
            time.sleep(max(1.0, wait_sec / 2))
            if proc.poll() is not None:
                break
            verify = verify_bridge_running(proc, force=True)
            if verify.get("ros_node_visible") or verify.get("ok"):
                _on_bridge_ready()
                return proc, ""
        if proc.poll() is None:
            verify = verify_bridge_running(proc, force=True)
            if verify.get("ok") or verify.get("ros_node_visible"):
                _on_bridge_ready()
                return proc, ""
            out = drain_output(proc)
            last_output = verify.get("hint", "") + ("\n" + out if out else "")
            _on_bridge_ready()
            return proc, last_output
        out = drain_output(proc)
        last_output = out if out else f"{cmd} exited with code {proc.returncode}"
    return None, last_output or "All robotBridge launch commands failed"


def _stop_cmd_vel_relay() -> None:
    global _cmd_vel_relay_proc
    with _cmd_vel_lock:
        if _cmd_vel_relay_proc is not None and _cmd_vel_relay_proc.poll() is None:
            try:
                _cmd_vel_relay_proc.terminate()
            except Exception:
                pass
        _cmd_vel_relay_proc = None


def _read_relay_stats() -> str:
    try:
        return Path("/tmp/cmd_vel_relay_stats.txt").read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def get_relay_status() -> dict:
    """Return cmd_vel relay subprocess health (fallback when ros_hub is off)."""
    with _cmd_vel_lock:
        alive = _cmd_vel_relay_proc is not None and _cmd_vel_relay_proc.poll() is None
        exit_code = None if alive else (
            _cmd_vel_relay_proc.poll() if _cmd_vel_relay_proc else None
        )
        stats = _parse_relay_stats()
        ts, lx, az = _read_cmd_vel_state()
        return {
            "alive": alive,
            "writer_ok": True,
            "pid": _cmd_vel_relay_proc.pid if alive else None,
            "exit_code": exit_code,
            "topic": CMD_VEL_TOPIC,
            "state_file": _cmd_vel_state_path,
            "state_ts": ts,
            "state_linear": lx,
            "state_angular": az,
            "last_write_at": _last_cmd_vel_write_at,
            "last_written": {"linear": _last_cmd_vel_written[0], "angular": _last_cmd_vel_written[1]},
            "log": _cmd_vel_relay_log,
            "stats": stats.get("raw", ""),
            "stats_linear": stats.get("linear_f"),
            "stats_angular": stats.get("angular_f"),
        }


def _write_cmd_vel_state(linear: float, angular: float) -> bool:
    """Atomic write — relay subprocess polls this file (FIFO was unreliable on Pi)."""
    global _last_cmd_vel_write_at, _last_cmd_vel_written
    line = f"{time.time():.3f} {float(linear)} {float(angular)}\n"
    tmp = f"{_cmd_vel_state_path}.tmp"
    try:
        Path(tmp).write_text(line, encoding="utf-8")
        os.replace(tmp, _cmd_vel_state_path)
        _last_cmd_vel_write_at = time.time()
        _last_cmd_vel_written = (float(linear), float(angular))
        return True
    except OSError as exc:
        log.warning("cmd_vel state write failed: %s", exc)
        return False


def _read_cmd_vel_state() -> tuple[float, float, float]:
    try:
        parts = Path(_cmd_vel_state_path).read_text(encoding="utf-8").strip().split()
        if len(parts) >= 3:
            return float(parts[0]), float(parts[1]), float(parts[2])
    except OSError:
        pass
    return 0.0, 0.0, 0.0


def _parse_relay_stats() -> dict:
    raw = _read_relay_stats()
    out: dict = {"raw": raw}
    if not raw:
        return out
    for token in raw.split():
        if "=" in token:
            k, _, v = token.partition("=")
            out[k.strip()] = v.strip()
    try:
        out["linear_f"] = float(out.get("linear", 0))
        out["angular_f"] = float(out.get("angular", 0))
    except (TypeError, ValueError):
        out["linear_f"] = 0.0
        out["angular_f"] = 0.0
    return out


def restart_cmd_vel_relay() -> dict:
    """Stop and restart relay — call when enabling joystick."""
    _stop_cmd_vel_relay()
    start_cmd_vel_relay()
    return get_relay_status()


def start_cmd_vel_relay() -> None:
    """One persistent ROS publisher — reads /tmp/robot_cmd_vel.state at 10 Hz."""
    global _cmd_vel_relay_proc
    with _cmd_vel_lock:
        if _cmd_vel_relay_proc is not None and _cmd_vel_relay_proc.poll() is None:
            return
        _stop_cmd_vel_relay()
        # Do NOT wipe state file here — that raced with publish_cmd_vel and
        # caused "state=10 but relay publishes 0".

        topic = sync_cmd_vel_topic()
        relay = _CMD_VEL_RELAY
        if not relay.is_file():
            log.error("cmd_vel relay script missing: %s", relay)
            return

        reader = (
            f"source {SETUP_BASH} && "
            f"export REAL1_CMD_VEL_TOPIC={topic} && "
            f"export CMD_VEL_STATE={_cmd_vel_state_path} && "
            f"export REAL1_CMD_VEL_QOS_DEPTH={CMD_VEL_QOS_DEPTH} && "
            f"python3 {relay}"
        )
        log_fp = open(_cmd_vel_relay_log, "a", encoding="utf-8")
        log_fp.write(f"\n--- relay start topic={topic} state={_cmd_vel_state_path} ---\n")
        log_fp.flush()
        _cmd_vel_relay_proc = subprocess.Popen(
            ["bash", "-lc", reader],
            env=ros_env(),
            stdout=log_fp,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        time.sleep(0.4)
        if _cmd_vel_relay_proc.poll() is not None:
            log.error(
                "cmd_vel relay exited immediately (code=%s) — see %s",
                _cmd_vel_relay_proc.returncode,
                _cmd_vel_relay_log,
            )
            _cmd_vel_relay_proc = None
            return
        log.info("cmd_vel relay OK pid=%s → %s", _cmd_vel_relay_proc.pid, topic)


def publish_cmd_vel_if_allowed(linear: float, angular: float) -> bool:
    """Send velocity via relay only while joystick mode is active."""
    if not _relay_allowed:
        return False
    return publish_cmd_vel(linear, angular)


def publish_cmd_vel(linear: float, angular: float) -> bool:
    """Ensure relay is up, then write velocity (order matters — never zero after write)."""
    if not _relay_allowed:
        return False
    start_cmd_vel_relay()
    ok = _write_cmd_vel_state(linear, angular)
    if not ok:
        return False
    with _cmd_vel_lock:
        alive = _cmd_vel_relay_proc is not None and _cmd_vel_relay_proc.poll() is None
    return alive


def check_cmd_vel() -> dict:
    """Report cmd_vel publishers/subscribers and active ROS nodes."""
    topic = sync_cmd_vel_topic()
    result: dict = {"topic": topic, "ok": False}
    try:
        info = subprocess.run(
            [
                "bash",
                "-lc",
                f"source {SETUP_BASH} && ros2 topic info {topic} -v",
            ],
            capture_output=True,
            text=True,
            timeout=15,
            env=ros_env(),
        )
        nodes = subprocess.run(
            ["bash", "-lc", f"source {SETUP_BASH} && ros2 node list"],
            capture_output=True,
            text=True,
            timeout=15,
            env=ros_env(),
        )
        node_lines = [n.strip() for n in (nodes.stdout or "").splitlines() if n.strip()]
        bridge_nodes = _bridge_node_names(node_lines)
        out = (info.stdout or "") + (info.stderr or "")
        bridge_subs = []
        for node in bridge_nodes:
            bridge_subs.extend(_bridge_node_subscriptions(node))
        bridge_listening = _bridge_listens_on_topic(topic, bridge_nodes)
        has_sub = bridge_listening or _topic_has_subscriber(out)
        out_lower = out.lower()
        qos_ok = (
            "incompatible qos" not in out_lower
            and "offering incompatible" not in out_lower
        )
        relay_best_effort = (
            "tablet_cmd_vel_relay" in out
            and "best_effort" in out_lower.split("tablet_cmd_vel_relay")[-1][:400].lower()
        )
        if relay_best_effort:
            qos_ok = False
        hub_publisher = "robot_api_hub" in out
        if not qos_ok:
            qos_hint = (
                "tablet_cmd_vel_relay publishes BEST_EFFORT but robot_bridge needs RELIABLE. "
                "On the Pi: copy updated ~/raspberry_pi/cmd_vel_relay.py, restart backend "
                "(bash run_server_ros.sh)."
                if relay_best_effort
                else (
                    "QoS mismatch on /cmd_vel — publisher must use RELIABLE. "
                    "Redeploy cmd_vel_relay.py and restart backend."
                )
            )
        elif not has_sub:
            qos_hint = (
                f"robotBridge does not subscribe to {topic} — "
                f"bridge listens on: {bridge_subs or 'unknown'}. "
                "Set REAL1_CMD_VEL_TOPIC in real1_link.env."
            )
        else:
            qos_hint = (
                f"robotBridge listens on {topic} with matching QoS "
                f"(relay={ 'tablet_cmd_vel_relay' in out })."
            )
        result.update(
            {
                "ok": info.returncode == 0 and has_sub and qos_ok,
                "detail": out.strip(),
                "nodes": "\n".join(node_lines),
                "robot_bridge_nodes": bridge_nodes,
                "bridge_subscriptions": bridge_subs,
                "bridge_listening": bridge_listening,
                "has_subscriber": has_sub,
                "qos_compatible": qos_ok,
                "relay_best_effort": relay_best_effort,
                "hub_publisher_visible": hub_publisher,
                "hint": qos_hint,
            }
        )
    except Exception as exc:
        result["error"] = str(exc)
    return result


def convert_cmd_vel(linear: float, angular: float) -> tuple[float, float]:
    """Convert tablet cmd_vel to units robotBridge expects (RPM for L2JD)."""
    linear = float(linear)
    angular = float(angular)
    if CMD_VEL_UNITS == "rpm":
        linear = linear * (MAX_LINEAR_RPM / max(TABLET_MAX_LINEAR, 0.01))
        angular = angular * (MAX_ANGULAR_RPM / max(TABLET_MAX_ANGULAR, 0.01))
    else:
        linear *= CMD_VEL_LINEAR_SCALE
        angular *= CMD_VEL_ANGULAR_SCALE
    return round(linear, 3), round(angular, 3)


def parse_bridge_cmd_vel_info() -> dict:
    """Read robotBridge.py _cmd_vel_cb for debugging (runs on Pi)."""
    info: dict = {"path": ROBOT_BRIDGE_PATH, "units": CMD_VEL_UNITS}
    try:
        text = Path(ROBOT_BRIDGE_PATH).read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        info["error"] = str(exc)
        return info
    m = re.search(r"def _cmd_vel_cb\(.*?(?=\n    def |\Z)", text, re.S)
    if m:
        snippet = m.group(0)
        info["callback_lines"] = snippet[:2500]
        if "RPM" in snippet.upper() or "rpm" in snippet:
            info["likely_units"] = "rpm"
        if re.search(r"int\s*\(\s*msg\.linear", snippet):
            info["warning"] = (
                "robotBridge casts linear.x to int — values below 1.0 become ZERO. "
                "Use REAL1_CMD_VEL_UNITS=rpm (default) so tablet sends ~10 not 0.5."
            )
    for name, pat in (
        ("max_rpm", r"MAX.*?RPM\s*=\s*([\d.]+)"),
        ("wheel_base", r"WHEEL.*?BASE\s*=\s*([\d.]+)"),
    ):
        hit = re.search(pat, text, re.I)
        if hit:
            info[name] = hit.group(1)
    info["publish_example"] = (
        f"ros2 topic pub /cmd_vel geometry_msgs/msg/Twist "
        f'"{{linear: {{x: {MAX_LINEAR_RPM:.0f}}}, angular: {{z: 0.0}}}}" -r 10'
    )
    return info


def run_enable_motors(
    restart_bridge_fn: Optional[Callable[[], tuple[bool, str]]] = None,
) -> tuple[bool, str]:
    """Enable motors — restart robotBridge (default) or REAL1_ENABLE_MOTORS_CMD only."""
    cmd = ENABLE_MOTORS_COMMAND.strip()

    if not cmd and ENABLE_MOTORS_MODE == "restart_bridge" and restart_bridge_fn is not None:
        return restart_bridge_fn()

    if cmd:
        timeout = 120 if "BridgeTest" in cmd else 45
        try:
            proc = subprocess.run(
                ["bash", "-lc", f"cd {REAL1_WS} && source {SETUP_BASH} && {cmd}"],
                capture_output=True,
                text=True,
                timeout=timeout,
                env=ros_env(),
            )
            out = ((proc.stdout or "") + (proc.stderr or "")).strip()
            if proc.returncode == 0:
                return True, out or "Enable motors command OK"
            return False, out or f"Enable motors failed (code={proc.returncode})"
        except subprocess.TimeoutExpired:
            return False, (
                f"Command timed out after {timeout}s: {cmd}. "
                "Remove REAL1_ENABLE_MOTORS_CMD from real1_link.env and use "
                "REAL1_ENABLE_MOTORS_MODE=restart_bridge instead."
            )
        except Exception as exc:
            return False, str(exc)

    if ENABLE_MOTORS_MODE == "restart_bridge" and restart_bridge_fn is not None:
        return restart_bridge_fn()

    return False, (
        "Set REAL1_ENABLE_MOTORS_MODE=restart_bridge in ~/raspberry_pi/real1_link.env "
        "(Real1 enables motors inside robotBridge.py on startup)."
    )


def list_ros_services(filter_sub: str = "") -> list[str]:
    try:
        proc = subprocess.run(
            ["bash", "-lc", f"source {SETUP_BASH} && ros2 service list"],
            capture_output=True,
            text=True,
            timeout=15,
            env=ros_env(),
        )
        lines = [ln.strip() for ln in (proc.stdout or "").splitlines() if ln.strip()]
        if filter_sub:
            low = filter_sub.lower()
            lines = [ln for ln in lines if low in ln.lower()]
        return lines[:20]
    except Exception:
        return []


def sample_cmd_vel_traffic(seconds: float = 2.0) -> dict:
    """Check if anything is publishing on cmd_vel (Hz + one message)."""
    topic = sync_cmd_vel_topic()
    result: dict = {"topic": topic, "hz": None, "sample": None}
    try:
        hz_proc = subprocess.run(
            [
                "bash",
                "-lc",
                f"source {SETUP_BASH} && timeout {max(1, int(seconds))} "
                f"ros2 topic hz {topic} 2>&1 | tail -3",
            ],
            capture_output=True,
            text=True,
            timeout=int(seconds) + 5,
            env=ros_env(),
        )
        result["hz_output"] = (hz_proc.stdout or hz_proc.stderr or "").strip()
        echo_proc = subprocess.run(
            [
                "bash",
                "-lc",
                f"source {SETUP_BASH} && timeout {max(1, int(seconds))} "
                f"ros2 topic echo {topic} --once 2>&1",
            ],
            capture_output=True,
            text=True,
            timeout=int(seconds) + 5,
            env=ros_env(),
        )
        result["echo_output"] = (echo_proc.stdout or echo_proc.stderr or "").strip()[:800]
    except Exception as exc:
        result["error"] = str(exc)
    return result


def run_ready_command() -> tuple[bool, str]:
    """Optional Real1 hook when operator presses READY FOR WORK."""
    cmd = READY_COMMAND.strip()
    if not cmd:
        return False, "No REAL1_READY_CMD configured (UI state only)."
    try:
        proc = subprocess.run(
            ["bash", "-lc", f"cd {REAL1_WS} && source {SETUP_BASH} && {cmd}"],
            capture_output=True,
            text=True,
            timeout=30,
            env=ros_env(),
        )
        out = ((proc.stdout or "") + (proc.stderr or "")).strip()
        if proc.returncode != 0:
            return False, out or f"Ready command failed (code={proc.returncode})"
        return True, out or "Ready command OK"
    except Exception as exc:
        return False, str(exc)


def run_cmd_vel_pulse(
    linear: float = 0.5, angular: float = 0.0, seconds: float = 2.0
) -> tuple[bool, str]:
    """Direct ros2 topic pub test — linear is tablet-normalized unless units=ms."""
    topic = sync_cmd_vel_topic()
    lx, az = convert_cmd_vel(linear, angular)
    duration = max(0.5, float(seconds))
    inner = (
        f"source {SETUP_BASH} && "
        f"timeout {duration} ros2 topic pub {topic} geometry_msgs/msg/Twist "
        f"\"{{linear: {{x: {lx}}}, angular: {{z: {az}}}}}\" -r 10"
    )
    try:
        proc = subprocess.run(
            ["bash", "-lc", inner],
            capture_output=True,
            text=True,
            timeout=int(duration) + 15,
            env=ros_env(),
        )
        out = ((proc.stdout or "") + (proc.stderr or "")).strip()
        ok = proc.returncode in (0, 124)  # 124 = timeout from `timeout` cmd (expected)
        return ok, f"Published linear.x={lx} angular.z={az} on {topic} for {duration}s"
    except Exception as exc:
        return False, str(exc)


def drive_diagnosis(gamepad_running: bool = False) -> dict:
    """Full manual-drive diagnostic — run when nothing moves."""
    link = validate_link()
    cmd = check_cmd_vel()
    relay = get_relay_status()
    return {
        "real1_paths_ok": link.get("ok"),
        "real1_hint": link.get("hint"),
        "gamepad_script": resolve_gamepad_path(),
        "gamepad_running": gamepad_running,
        "joystick_mode": JOYSTICK_MODE,
        "ready_command_configured": bool(READY_COMMAND.strip()),
        "enable_motors_configured": bool(ENABLE_MOTORS_COMMAND.strip()),
        "ready_command": READY_COMMAND.strip() or None,
        "enable_motors_command": ENABLE_MOTORS_COMMAND.strip() or None,
        "ros_enable_services": list_ros_services("enable"),
        "cmd_vel_traffic": sample_cmd_vel_traffic(2.0),
        "cmd_vel_topic": CMD_VEL_TOPIC,
        "cmd_vel_check": cmd,
        "relay": relay,
        "likely_causes": _drive_failure_causes(link, cmd, relay, gamepad_running),
    }


def _drive_failure_causes(
    link: dict, cmd: dict, relay: dict, gamepad_running: bool
) -> list[str]:
    causes: list[str] = []
    if not link.get("ok"):
        causes.append("Real1 paths missing — check real1_link.env on Pi.")
    if not cmd.get("qos_compatible", True):
        if cmd.get("relay_best_effort"):
            causes.append(
                "tablet_cmd_vel_relay uses BEST_EFFORT — redeploy cmd_vel_relay.py "
                "and restart backend; or use in-process ros_hub (run_server_ros.sh)."
            )
        else:
            causes.append("QoS mismatch on /cmd_vel — publisher must be RELIABLE.")
    if not cmd.get("bridge_listening"):
        causes.append("robotBridge is not subscribed to /cmd_vel — check REAL1_CMD_VEL_TOPIC.")
    if not READY_COMMAND.strip() and not ENABLE_MOTORS_COMMAND.strip():
        causes.append(
            "REAL1_ENABLE_MOTORS_CMD not set — motors may stay disabled. "
            "Tap Enable Motors in app or add command to real1_link.env."
        )
    if not relay.get("alive") and not gamepad_running:
        causes.append("cmd_vel relay not running — tap JOYSTICK after READY.")
    if cmd.get("bridge_listening") and relay.get("alive"):
        causes.append(
            "L2JD driver RED blink = motor fault / not enabled. Tap RE-INIT MOTORS on tablet, "
            "or on Pi: pkill -f robotBridge; ros2 run Real1 robotBridge.py"
        )
        causes.append(
            f"robotBridge uses RPM in linear.x (int cast). "
            f"ros2 topic pub with 0.2 → int(0.2)=0 (no move). Test at 10 Hz: "
            f"bash ~/raspberry_pi/test_rpm_pulse.sh {int(MAX_LINEAR_RPM)} 3"
        )
        causes.append(
            "Single --once cmd_vel often fails — L2JD needs ~10 Hz stream (tablet relay does this)."
        )
    if not causes:
        causes.append(
            "Software path looks OK. teleop_twist_keyboard sends m/s — robotBridge uses RPM; "
            f"test with: ros2 topic pub /cmd_vel geometry_msgs/msg/Twist "
            f"'{{linear: {{x: {MAX_LINEAR_RPM:.0f}}}, angular: {{z: 0.0}}}}' -r 10. "
            "If that pulse does not move the robot, check robotBridge/L2JD (communication loss, "
            "fault latched, wiring)."
        )
    return causes


def start_gamepad() -> subprocess.Popen:
    path = resolve_gamepad_path()
    if not path:
        raise FileNotFoundError(
            f"No gamepad script in {REAL1_SCRIPTS} or {REAL1_WS} "
            f"(tried gamepad.py, gamePad.py — set REAL1_GAMEPAD_SCRIPT in real1_link.env)"
        )
    in_scripts = path.startswith(REAL1_SCRIPTS)
    script = os.path.basename(path) if in_scripts else path
    return bash_in_workspace(f"python3 {script}", cwd_scripts=in_scripts)


def try_start_gamepad() -> tuple[Optional[subprocess.Popen], str]:
    """Start Pi gamepad script if present; return (process or None, message)."""
    path = resolve_gamepad_path()
    if not path:
        return None, "No gamepad script on Pi — using tablet joystick (/cmd_vel)"
    proc = start_gamepad()
    return proc, f"Started {os.path.basename(path)} (PID {proc.pid})"


def stream_process_output(
    proc: subprocess.Popen,
    on_line: Callable[[str, str], None],
    source: str = "process",
) -> None:
    if not proc.stdout:
        return
    for line in proc.stdout:
        line = line.rstrip()
        if not line:
            continue
        sev = (
            "error"
            if any(w in line.lower() for w in ("error", "fatal", "failed", "exception"))
            else "info"
        )
        on_line(sev, f"[{source}] {line[:500]}")


def watch_process(
    proc: subprocess.Popen,
    on_exit: Callable[[int], None],
    log_fn: Optional[Callable[[str, str], None]] = None,
    source: str = "process",
    output_lines: Optional[list[str]] = None,
) -> None:
    def _run():
        if log_fn or output_lines is not None:
            if not proc.stdout:
                code = proc.wait()
                on_exit(code)
                return
            for line in proc.stdout:
                line = line.rstrip()
                if not line:
                    continue
                if output_lines is not None:
                    output_lines.append(line)
                if log_fn:
                    sev = (
                        "error"
                        if any(
                            w in line.lower()
                            for w in ("error", "fatal", "failed", "exception")
                        )
                        else "info"
                    )
                    log_fn(sev, f"[{source}] {line[:500]}")
            on_exit(proc.wait())
        else:
            on_exit(proc.wait())

    threading.Thread(target=_run, daemon=True).start()
