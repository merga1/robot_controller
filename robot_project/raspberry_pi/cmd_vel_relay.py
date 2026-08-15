#!/usr/bin/env python3
"""Persistent cmd_vel publisher — polls /tmp/robot_cmd_vel.state at 10 Hz."""

import os
import sys
import time


def _read_state(path: str) -> tuple[float, float, float]:
    """Return (timestamp, linear, angular) or (0, 0, 0) on failure."""
    try:
        parts = open(path, encoding="utf-8").read().strip().split()
        if len(parts) >= 3:
            return float(parts[0]), float(parts[1]), float(parts[2])
    except (OSError, ValueError):
        pass
    return 0.0, 0.0, 0.0


def main() -> None:
    try:
        import rclpy
        from geometry_msgs.msg import Twist
        from rclpy.node import Node
        from rclpy.qos import (
            DurabilityPolicy,
            HistoryPolicy,
            QoSProfile,
            ReliabilityPolicy,
        )
    except ImportError as exc:
        print(f"cmd_vel_relay: rclpy not available: {exc}", file=sys.stderr)
        sys.exit(1)

    topic = os.environ.get("REAL1_CMD_VEL_TOPIC", "/cmd_vel")
    state_path = os.environ.get("CMD_VEL_STATE", "/tmp/robot_cmd_vel.state")
    depth = int(os.environ.get("REAL1_CMD_VEL_QOS_DEPTH", "10"))
    stale_sec = float(os.environ.get("CMD_VEL_STALE_SEC", "0.8"))

    cmd_qos = QoSProfile(
        reliability=ReliabilityPolicy.RELIABLE,
        history=HistoryPolicy.KEEP_LAST,
        depth=depth,
        durability=DurabilityPolicy.VOLATILE,
    )

    class Relay(Node):
        def __init__(self) -> None:
            super().__init__("tablet_cmd_vel_relay")
            self._pub = self.create_publisher(Twist, topic, cmd_qos)
            self._linear = 0.0
            self._angular = 0.0
            self._publish_n = 0
            self.create_timer(0.1, self._tick)
            self.get_logger().info(
                f"cmd_vel relay on {topic} state={state_path} (RELIABLE QoS)"
            )

        def _write_stats(self) -> None:
            try:
                with open("/tmp/cmd_vel_relay_stats.txt", "w", encoding="utf-8") as fp:
                    fp.write(
                        f"publishes={self._publish_n} linear={self._linear} "
                        f"angular={self._angular} topic={topic} "
                        f"state_age={time.time() - getattr(self, '_last_ts', 0):.3f}\n"
                    )
            except OSError:
                pass

        def _tick(self) -> None:
            ts, lx, az = _read_state(state_path)
            now = time.time()
            if ts > 0 and (now - ts) <= stale_sec:
                # Fresh tablet command
                self._last_ts = ts
                self._linear = lx
                self._angular = az
            elif ts > 0 and (now - ts) > stale_sec:
                # Stale file — stop motors (safety)
                self._linear = 0.0
                self._angular = 0.0
            # else: keep last values briefly if read failed once

            msg = Twist()
            msg.linear.x = float(self._linear)
            msg.angular.z = float(self._angular)
            self._pub.publish(msg)
            self._publish_n += 1
            # Update stats every 0.5s so tablet debug is not 5s stale
            if self._publish_n % 5 == 0:
                self._write_stats()

    rclpy.init()
    node = Relay()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
