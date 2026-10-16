#!/usr/bin/env python3
"""
cmd_vel_relay.py — Standalone ROS2 cmd_vel publisher.

This process is an alternative to using ros_hub.py's embedded publisher.
It reads velocity commands written to a state file by the API server and
publishes them on /cmd_vel at a fixed rate (50 Hz).

Use case: when rclpy cannot be imported inside the FastAPI process (e.g.
because of GIL / asyncio conflicts with rclpy's executor), run this script
as a separate process and let the API server write to the state file.

State file: /tmp/robot_cmd_vel.json  → { "linear": float, "angular": float }

Usage:
    python3 cmd_vel_relay.py [--rate 50] [--topic /cmd_vel]
"""

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path

STATE_FILE = Path(os.getenv("ROBOT_CMD_VEL_STATE", "/tmp/robot_cmd_vel.json"))
WATCHDOG_TIMEOUT = 1.0   # seconds — send zero if API goes silent

# ── ROS2 ──────────────────────────────────────────────────────────────────────

try:
    import rclpy
    from rclpy.node import Node
    from geometry_msgs.msg import Twist
    _HAS_ROS = True
except ImportError:
    print("[relay] rclpy not available — running in print-only mode", file=sys.stderr)
    _HAS_ROS = False


def _read_state() -> tuple[float, float]:
    """Read (linear, angular) from the state file. Returns (0, 0) on error."""
    try:
        data = json.loads(STATE_FILE.read_text())
        return float(data.get("linear", 0)), float(data.get("angular", 0))
    except Exception:
        return 0.0, 0.0


def _state_file_age() -> float:
    """Seconds since the state file was last modified. Returns inf if missing."""
    try:
        return time.time() - STATE_FILE.stat().st_mtime
    except FileNotFoundError:
        return float("inf")


class RelayNode(Node):  # type: ignore[misc]
    def __init__(self, topic: str, rate_hz: float) -> None:
        super().__init__("cmd_vel_relay")
        self._pub = self.create_publisher(Twist, topic, 10)
        period = 1.0 / rate_hz
        self.create_timer(period, self._publish)
        self.get_logger().info(f"cmd_vel relay → {topic} @ {rate_hz} Hz")

    def _publish(self) -> None:
        age = _state_file_age()
        if age < WATCHDOG_TIMEOUT:
            linear, angular = _read_state()
        else:
            linear, angular = 0.0, 0.0

        msg = Twist()
        msg.linear.x = linear
        msg.angular.z = angular
        self._pub.publish(msg)


def main() -> None:
    parser = argparse.ArgumentParser(description="cmd_vel relay")
    parser.add_argument("--rate", type=float, default=50.0, help="Publish rate Hz")
    parser.add_argument("--topic", default="/cmd_vel", help="cmd_vel topic name")
    args = parser.parse_args()

    if not _HAS_ROS:
        # Simulation mode: just print what would be published
        print(f"[relay] Sim mode — publishing to {args.topic} @ {args.rate} Hz")
        period = 1.0 / args.rate
        while True:
            linear, angular = _read_state()
            if linear != 0 or angular != 0:
                print(f"[relay] linear={linear:.3f}  angular={angular:.3f}")
            time.sleep(period)
        return

    rclpy.init()
    node = RelayNode(args.topic, args.rate)
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
