"""ROS hub — pose + battery monitor (cmd_vel uses relay subprocess)."""
import logging
import math
import threading

from . import robot_link
from .ros_context import ensure_rclpy

log = logging.getLogger(__name__)

_started = False
_hub_ready = False
_teleop_armed = False
_zero_burst = 0
_cmd_lock = threading.Lock()
_cmd_linear = 0.0
_cmd_angular = 0.0
_publish_count = 0


def start(robot_state: dict) -> None:
    global _started
    if _started:
        return
    _started = True
    threading.Thread(target=_run, args=(robot_state,), daemon=True, name="ros_hub").start()


def hub_ready() -> bool:
    return _hub_ready


def teleop_armed() -> bool:
    return _teleop_armed


def set_teleop_armed(active: bool) -> None:
    """Only publish cmd_vel while joystick mode is active."""
    global _teleop_armed, _zero_burst
    _teleop_armed = active
    if active:
        _zero_burst = 0
    else:
        with _cmd_lock:
            _cmd_linear = 0.0
            _cmd_angular = 0.0
        _zero_burst = 8  # ~0.8s of explicit zero after stop


def resync_cmd_vel_topic() -> str:
    return robot_link.sync_cmd_vel_topic()


def set_cmd_vel(linear: float, angular: float) -> bool:
    global _cmd_linear, _cmd_angular, _publish_count
    with _cmd_lock:
        _cmd_linear = float(linear)
        _cmd_angular = float(angular)
        if _teleop_armed:
            _publish_count += 1
    return _hub_ready and _teleop_armed


def get_cmd_vel_state() -> dict:
    with _cmd_lock:
        return {
            "linear": _cmd_linear,
            "angular": _cmd_angular,
            "publish_count": _publish_count,
            "hub_ready": _hub_ready,
            "teleop_armed": _teleop_armed,
            "topic": robot_link.CMD_VEL_TOPIC,
        }


def _run(robot_state: dict) -> None:
    global _hub_ready
    robot_link.apply_ros_environment()
    if not ensure_rclpy():
        log.warning("ROS hub skipped — rclpy not available (using cmd_vel relay)")
        return
    try:
        import rclpy
        from geometry_msgs.msg import PoseWithCovarianceStamped
        from rclpy.node import Node
        try:
            from sensor_msgs.msg import BatteryState
        except ImportError:
            BatteryState = None

        class RobotHub(Node):
            def __init__(self):
                super().__init__("robot_api_hub")
                self.create_subscription(
                    PoseWithCovarianceStamped, "/amcl_pose", self._pose_cb, 10
                )
                if BatteryState is not None:
                    self.create_subscription(
                        BatteryState, "/battery_state", self._battery_cb, 10
                    )

            def _battery_cb(self, msg) -> None:
                pct = msg.percentage
                # ROS standard is 0.0 to 1.0, but some drivers publish 0 to 100.
                if pct <= 1.0:
                    pct = pct * 100.0
                robot_state["battery"] = int(round(pct))
                robot_state["battery_voltage"] = float(round(msg.voltage, 2))

            def _pose_cb(self, msg: PoseWithCovarianceStamped) -> None:
                p = msg.pose.pose
                siny = 2.0 * (
                    p.orientation.w * p.orientation.z
                    + p.orientation.x * p.orientation.y
                )
                cosy = 1.0 - 2.0 * (p.orientation.y ** 2 + p.orientation.z ** 2)
                theta_deg = round(math.degrees(math.atan2(siny, cosy)), 1)
                robot_state["pose"] = {
                    "x": round(p.position.x, 3),
                    "y": round(p.position.y, 3),
                    "theta": theta_deg,
                }

        node = RobotHub()
        _hub_ready = True
        log.info("ROS hub started (pose/battery only — cmd_vel via relay)")
        while rclpy.ok():
            rclpy.spin_once(node, timeout_sec=0.1)
    except Exception as exc:
        log.error("ROS hub stopped: %s", exc, exc_info=True)
    finally:
        _hub_ready = False
