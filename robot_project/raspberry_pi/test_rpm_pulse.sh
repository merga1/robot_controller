#!/usr/bin/env bash
# Prove motors independently of tablet / teleop_twist_keyboard.
# robotBridge expects RPM in linear.x (NOT m/s). int(0.5) == 0 → no motion.
set -eo pipefail
RPM="${1:-10}"
DUR="${2:-3}"

if [ -f "${HOME}/Real1/install/setup.bash" ]; then
  # shellcheck disable=SC1091
  source "${HOME}/Real1/install/setup.bash"
fi

echo "Publishing linear.x=${RPM} RPM on /cmd_vel for ${DUR}s (RELIABLE)..."
echo "Watch robotBridge logs / wheels. Ctrl+C to abort early."
timeout "${DUR}" ros2 topic pub /cmd_vel geometry_msgs/msg/Twist \
  "{linear: {x: ${RPM}.0}, angular: {z: 0.0}}" \
  -r 10 --qos-reliability reliable --qos-durability volatile || true
echo "Done. If wheels did not turn, check L2JD / serial / motor enable — not QoS."
