"""
ros_hub.py — Thin ROS2 integration layer.

Responsibilities
----------------
1. Publish geometry_msgs/Twist on /cmd_vel  (teleop)
2. Subscribe to /amcl_pose and cache the latest robot pose
3. Query node health via ros2 node list
4. Wrap the navigate_client.py subprocess for Nav2 NavigateToPose goals
5. Subscribe to /navigate_to_pose/_action/status for live goal status

Design
------
• ROS2 is optional: if rclpy is not available (dev machine without ROS)
  the hub falls back to a "sim" mode that echoes commands and returns
  fake pose data — allowing the Flutter app to be developed without a Pi.
• A single rclpy Node runs in a background daemon thread (spin_once loop)
  so the FastAPI event loop is never blocked by ROS spin calls.
• cmd_vel is published at the rate the HTTP endpoint is called (60 ms from
  the Flutter timer); no extra rate-limiting is needed here.
"""

import math
import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

# ── ROS2 optional import ──────────────────────────────────────────────────────

try:
    import rclpy
    from rclpy.node import Node
    from geometry_msgs.msg import Twist
    from nav_msgs.msg import Odometry
    from action_msgs.msg import GoalStatusArray
    _ROS_AVAILABLE = True
except ImportError:
    _ROS_AVAILABLE = False
    Node = object  # type: ignore[assignment,misc]

# ── Configuration from env ────────────────────────────────────────────────────

_CMD_VEL_TOPIC = os.getenv("REAL1_CMD_VEL_TOPIC", "/cmd_vel")
_LINEAR_SCALE = float(os.getenv("REAL1_CMD_VEL_LINEAR_SCALE", "1.0"))
_ANGULAR_SCALE = float(os.getenv("REAL1_CMD_VEL_ANGULAR_SCALE", "1.0"))

# Path to the navigate_client.py script
_NAV_CLIENT = Path(__file__).parent.parent / "ros2_nodes" / "navigate_client.py"

# ── Shared state ──────────────────────────────────────────────────────────────

_lock = threading.Lock()

_state: dict[str, Any] = {
    # Pose in map frame (x, y, theta_degrees)
    "pose_x": 0.0,
    "pose_y": 0.0,
    "pose_theta_deg": 0.0,
    # Latest published velocity
    "linear": 0.0,
    "angular": 0.0,
    # Whether rclpy node is alive
    "hub_ready": False,
    # Current navigation goal process
    "nav_proc": None,       # subprocess.Popen | None
    "nav_target": None,     # str | None
    "navigating": False,
}


def get_state() -> dict[str, Any]:
    with _lock:
        return dict(_state)


# ── ROS2 Node ─────────────────────────────────────────────────────────────────

class _RobotNode(Node):  # type: ignore[misc]
    def __init__(self) -> None:
        super().__init__("robot_api_hub")

        # Publisher: cmd_vel
        from geometry_msgs.msg import Twist
        self._pub = self.create_publisher(Twist, _CMD_VEL_TOPIC, 10)

        # Subscriber: AMCL pose (from /amcl_pose topic, PoseWithCovarianceStamped)
        try:
            from geometry_msgs.msg import PoseWithCovarianceStamped
            self.create_subscription(
                PoseWithCovarianceStamped,
                "/amcl_pose",
                self._amcl_cb,
                10,
            )
        except Exception:
            pass

        with _lock:
            _state["hub_ready"] = True

    def publish_twist(self, linear: float, angular: float) -> None:
        from geometry_msgs.msg import Twist
        msg = Twist()
        msg.linear.x = linear * _LINEAR_SCALE
        msg.angular.z = angular * _ANGULAR_SCALE
        self._pub.publish(msg)
        with _lock:
            _state["linear"] = linear
            _state["angular"] = angular

    def _amcl_cb(self, msg: Any) -> None:  # PoseWithCovarianceStamped
        p = msg.pose.pose
        # Convert quaternion to yaw (degrees)
        siny = 2.0 * (p.orientation.w * p.orientation.z + p.orientation.x * p.orientation.y)
        cosy = 1.0 - 2.0 * (p.orientation.y ** 2 + p.orientation.z ** 2)
        yaw_deg = math.degrees(math.atan2(siny, cosy))
        with _lock:
            _state["pose_x"] = p.position.x
            _state["pose_y"] = p.position.y
            _state["pose_theta_deg"] = yaw_deg


# ── Background spin thread ────────────────────────────────────────────────────

_node: "_RobotNode | None" = None
_spin_thread: "threading.Thread | None" = None


def _spin_loop() -> None:
    global _node
    if not _ROS_AVAILABLE:
        return
    try:
        rclpy.init()
        _node = _RobotNode()
        while rclpy.ok():
            rclpy.spin_once(_node, timeout_sec=0.05)
    except Exception as exc:
        print(f"[ros_hub] spin loop error: {exc}")
    finally:
        with _lock:
            _state["hub_ready"] = False


def start() -> None:
    """Start the ROS2 background thread. Safe to call multiple times."""
    global _spin_thread
    if not _ROS_AVAILABLE:
        print("[ros_hub] rclpy not available — running in simulation mode")
        with _lock:
            _state["hub_ready"] = True
        return
    if _spin_thread is not None and _spin_thread.is_alive():
        return
    _spin_thread = threading.Thread(target=_spin_loop, daemon=True)
    _spin_thread.start()


def stop() -> None:
    """Request ROS2 shutdown. The daemon thread will die with the process."""
    if _ROS_AVAILABLE:
        try:
            rclpy.shutdown()
        except Exception:
            pass


# ── Public API ────────────────────────────────────────────────────────────────

def publish_cmd_vel(linear: float, angular: float) -> None:
    """Publish a Twist message on /cmd_vel. No-op in sim mode."""
    if _node is not None:
        _node.publish_twist(linear, angular)
    else:
        # Sim mode — just update state
        with _lock:
            _state["linear"] = linear
            _state["angular"] = angular


def get_pose() -> dict[str, float]:
    """Return latest AMCL pose: {x, y, theta} where theta is in degrees."""
    with _lock:
        return {
            "x": _state["pose_x"],
            "y": _state["pose_y"],
            "theta": _state["pose_theta_deg"],
        }


def is_ready() -> bool:
    with _lock:
        return bool(_state["hub_ready"])


def send_nav_goal(name: str, x: float, y: float, theta_deg: float) -> None:
    """
    Launch navigate_client.py as a subprocess to send a Nav2 goal.
    Cancels any running goal first.
    """
    cancel_nav_goal()

    cmd = ["python3", str(_NAV_CLIENT), str(x), str(y), str(theta_deg)]

    # Source ROS environment before running navigate_client.py
    real1_ws = os.getenv("REAL1_WS", "")
    env = dict(os.environ)
    if real1_ws:
        env["PYTHONPATH"] = (
            f"{real1_ws}/install/lib/python3/dist-packages:"
            + env.get("PYTHONPATH", "")
        )

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
    )

    with _lock:
        _state["nav_proc"] = proc
        _state["nav_target"] = name
        _state["navigating"] = True

    # Watch process in background thread
    def _watch():
        proc.wait()
        with _lock:
            if _state["nav_proc"] is proc:
                _state["nav_proc"] = None
                _state["nav_target"] = None
                _state["navigating"] = False

    threading.Thread(target=_watch, daemon=True).start()


def cancel_nav_goal() -> None:
    """Terminate any running navigation subprocess."""
    with _lock:
        proc = _state.get("nav_proc")
        _state["nav_proc"] = None
        _state["nav_target"] = None
        _state["navigating"] = False
    if proc is not None:
        try:
            proc.terminate()
            proc.wait(timeout=2)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass


def is_navigating() -> bool:
    with _lock:
        return bool(_state["navigating"])


def get_nav_target() -> str | None:
    with _lock:
        return _state.get("nav_target")
