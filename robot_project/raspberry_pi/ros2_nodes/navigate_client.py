#!/usr/bin/env python3
"""Standalone Nav2 NavigateToPose action client.
Usage: python3 navigate_client.py <x> <y> <theta_degrees>
"""
import sys
import math
import rclpy
from rclpy.node import Node
from rclpy.action import ActionClient
from nav2_msgs.action import NavigateToPose
from geometry_msgs.msg import PoseStamped, Quaternion


def yaw_to_quaternion(yaw_deg: float) -> Quaternion:
    yaw = math.radians(yaw_deg)
    q = Quaternion()
    q.w = math.cos(yaw / 2)
    q.z = math.sin(yaw / 2)
    q.x = 0.0
    q.y = 0.0
    return q


class NavClient(Node):
    def __init__(self, x: float, y: float, yaw_deg: float):
        super().__init__("robot_nav_client")
        self._client = ActionClient(self, NavigateToPose, "navigate_to_pose")
        self._x = x
        self._y = y
        self._yaw_deg = yaw_deg
        self._succeeded = False

    def send_goal(self) -> bool:
        self.get_logger().info("Waiting for Nav2 navigate_to_pose action server...")
        if not self._client.wait_for_server(timeout_sec=10.0):
            self.get_logger().error("Nav2 action server not available after 10 s")
            return False

        goal = NavigateToPose.Goal()
        goal.pose = PoseStamped()
        goal.pose.header.frame_id = "map"
        goal.pose.header.stamp = self.get_clock().now().to_msg()
        goal.pose.pose.position.x = self._x
        goal.pose.pose.position.y = self._y
        goal.pose.pose.position.z = 0.0
        goal.pose.pose.orientation = yaw_to_quaternion(self._yaw_deg)

        self.get_logger().info(
            f"Sending NavigateToPose goal: x={self._x}, y={self._y}, theta={self._yaw_deg}°"
        )
        future = self._client.send_goal_async(
            goal, feedback_callback=self._feedback_cb
        )
        rclpy.spin_until_future_complete(self, future)

        goal_handle = future.result()
        if not goal_handle.accepted:
            self.get_logger().error("Goal rejected by Nav2")
            return False

        self.get_logger().info("Goal accepted, waiting for result...")
        result_future = goal_handle.get_result_async()
        rclpy.spin_until_future_complete(self, result_future)

        status = result_future.result().status
        # action_msgs/GoalStatus: SUCCEEDED = 4
        self._succeeded = (status == 4)
        self.get_logger().info(
            f"Navigation {'succeeded' if self._succeeded else 'failed'} (status={status})"
        )
        return self._succeeded

    def _feedback_cb(self, feedback_msg):
        # Nav2 feedback: distance_remaining
        fb = feedback_msg.feedback
        self.get_logger().debug(
            f"Distance remaining: {fb.distance_remaining:.2f} m"
        )
        print(f"FEEDBACK: distance_remaining={fb.distance_remaining:.2f}", flush=True)


def main() -> int:
    if len(sys.argv) != 4:
        print("Usage: navigate_client.py <x> <y> <theta_degrees>", file=sys.stderr)
        return 1

    x = float(sys.argv[1])
    y = float(sys.argv[2])
    theta = float(sys.argv[3])

    rclpy.init()
    node = NavClient(x, y, theta)
    try:
        ok = node.send_goal()
    finally:
        node.destroy_node()
        rclpy.shutdown()

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
