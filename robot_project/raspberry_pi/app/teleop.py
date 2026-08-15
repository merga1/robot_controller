"""Joystick / cmd_vel — 10 Hz keepalive prevents L2JD communication loss."""
import threading
import time

from . import robot_link
from . import ros_hub

_lock = threading.Lock()
_linear: float = 0.0
_angular: float = 0.0
_cmd_active: bool = False
_publisher_started = False
_teleop_armed: bool = False
_motor_keepalive: bool = False
_publish_count: int = 0
_last_publish_at: float = 0.0
_last_publish_ok: bool = False
_last_tablet_linear: float = 0.0
_last_tablet_angular: float = 0.0
_debug_log: list[dict] = []
_DEBUG_MAX = 30


def _log_debug(event: str, **fields) -> None:
    global _debug_log
    entry = {"t": time.time(), "event": event, **fields}
    _debug_log.append(entry)
    if len(_debug_log) > _DEBUG_MAX:
        _debug_log = _debug_log[-_DEBUG_MAX:]


def get_debug_log() -> list[dict]:
    return list(_debug_log)


def start_publisher() -> None:
    global _publisher_started
    if _publisher_started:
        return
    _publisher_started = True
    threading.Thread(target=_publish_loop, daemon=True, name="teleop_pub").start()


def is_armed() -> bool:
    return _teleop_armed and ros_hub.teleop_armed()


def motor_keepalive_active() -> bool:
    return _motor_keepalive


def start_motor_keepalive() -> None:
    """Start 10 Hz zero cmd_vel as soon as robotBridge is up — prevents comm-loss fault."""
    global _motor_keepalive
    _motor_keepalive = True
    robot_link.set_relay_allowed(True)
    robot_link.start_cmd_vel_relay()
    robot_link.publish_cmd_vel(0.0, 0.0)
    robot_link.start_shell_keepalive()
    start_publisher()
    _log_debug("motor_keepalive_started", relay=robot_link.get_relay_status())


def ensure_armed() -> None:
    """Arm cmd_vel without restarting relay (safe for 5 Hz joystick HTTP ticks)."""
    if not _teleop_armed:
        enable_teleop(True)
        return
    ros_hub.set_teleop_armed(True)
    robot_link.set_relay_allowed(True)
    robot_link.start_cmd_vel_relay()


def enable_teleop(enabled: bool) -> None:
    global _teleop_armed
    if enabled:
        first_arm = not _teleop_armed
        _teleop_armed = True
        ros_hub.set_teleop_armed(True)
        robot_link.set_relay_allowed(True)
        if first_arm:
            robot_link.restart_cmd_vel_relay()
        else:
            robot_link.start_cmd_vel_relay()
        start_publisher()
        _log_debug(
            "teleop_armed",
            first_arm=first_arm,
            relay=robot_link.get_relay_status(),
        )
    else:
        disarm_teleop()


def is_enabled() -> bool:
    with _lock:
        return _cmd_active or ros_hub.teleop_armed()


def set_velocity(linear: float, angular: float) -> None:
    start_publisher()
    global _linear, _angular, _cmd_active, _last_tablet_linear, _last_tablet_angular
    _last_tablet_linear = float(linear)
    _last_tablet_angular = float(angular)
    linear, angular = robot_link.convert_cmd_vel(linear, angular)
    linear = max(-1000.0, min(1000.0, linear))
    angular = max(-1000.0, min(1000.0, angular))
    with _lock:
        _linear = linear
        _angular = angular
        _cmd_active = linear != 0.0 or angular != 0.0
    if ros_hub.teleop_armed() or _teleop_armed or _motor_keepalive:
        _publish_once(linear, angular)


def disarm_teleop() -> None:
    """Joystick off — keep motor keepalive running so drivers stay enabled."""
    global _linear, _angular, _cmd_active, _teleop_armed
    _teleop_armed = False
    with _lock:
        _linear = 0.0
        _angular = 0.0
        _cmd_active = False
    ros_hub.set_teleop_armed(False)
    if _motor_keepalive:
        robot_link.set_relay_allowed(True)
        _publish_once(0.0, 0.0)
    _log_debug("teleop_disarmed", keepalive=_motor_keepalive)


def stop_all() -> None:
    """Full stop — kill relay (robot STOP or backend shutdown)."""
    global _motor_keepalive, _linear, _angular, _cmd_active, _teleop_armed
    _motor_keepalive = False
    _teleop_armed = False
    with _lock:
        _linear = 0.0
        _angular = 0.0
        _cmd_active = False
    ros_hub.set_teleop_armed(False)
    robot_link.stop_shell_keepalive()
    robot_link.set_relay_allowed(False)
    robot_link.stop_cmd_vel_relay()
    _log_debug("teleop_stop_all")


def stop() -> None:
    """Backward compatible — disarm joystick only (keepalive continues)."""
    disarm_teleop()


def _publish_once(linear: float, angular: float) -> bool:
    """Track setpoint for UI; publish via relay (RELIABLE /cmd_vel at 10 Hz)."""
    global _last_publish_ok
    ros_hub.set_cmd_vel(linear, angular)
    relay_ok = robot_link.publish_cmd_vel_if_allowed(linear, angular)
    _last_publish_ok = relay_ok
    _log_debug(
        "publish",
        linear=linear,
        angular=angular,
        via="relay" if relay_ok else "none",
        relay=robot_link.get_relay_status().get("alive"),
    )
    return _last_publish_ok


def _publish_via_label(hub: dict, relay: dict) -> str:
    if relay.get("alive"):
        return "cmd_vel relay"
    if hub.get("hub_ready"):
        return "ros_hub (pose only)"
    return "idle (no cmd_vel)"


def get_velocity() -> dict:
    hub = ros_hub.get_cmd_vel_state()
    relay = robot_link.get_relay_status()
    with _lock:
        return {
            "linear": _linear,
            "angular": _angular,
            "linear_tablet": _last_tablet_linear,
            "angular_tablet": _last_tablet_angular,
            "cmd_vel_units": robot_link.CMD_VEL_UNITS,
            "teleop_session_armed": _teleop_armed,
            "motor_keepalive": _motor_keepalive,
            "enabled": _cmd_active,
            "teleop_armed": hub.get("teleop_armed") or _motor_keepalive,
            "hub_ready": hub["hub_ready"],
            "relay_alive": relay.get("alive"),
            "relay_pid": relay.get("pid"),
            "publish_ok": _last_publish_ok,
            "publish_count": _publish_count,
            "topic": hub["topic"],
            "last_publish_at": _last_publish_at,
            "publish_via": _publish_via_label(hub, relay),
            "relay_log": relay.get("log"),
            "debug_log": get_debug_log()[-8:],
        }


def test_drive(linear: float = 0.5, angular: float = 0.0, seconds: float = 2.0) -> dict:
    """Pulse motors via relay without disarming keepalive."""
    was_armed = _teleop_armed
    if not was_armed:
        enable_teleop(True)
    set_velocity(linear, angular)
    time.sleep(max(0.2, seconds))
    set_velocity(0.0, 0.0)
    if not was_armed:
        disarm_teleop()
    return get_velocity()


def _publish_loop() -> None:
    """10 Hz keepalive — runs while motor_keepalive OR joystick armed."""
    global _publish_count, _last_publish_at
    while True:
        active = _motor_keepalive or ros_hub.teleop_armed() or _teleop_armed
        if active:
            with _lock:
                if _teleop_armed or ros_hub.teleop_armed():
                    lx, az = (_linear, _angular) if _cmd_active else (0.0, 0.0)
                else:
                    lx, az = (0.0, 0.0)
            _publish_once(lx, az)
            _publish_count += 1
            _last_publish_at = time.time()
        time.sleep(0.1)
