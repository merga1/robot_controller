#!/usr/bin/env bash
# Prove motors independently of tablet.
# robotBridge calculates RPM from m/s: (mps / circ) * 60.0.
set -eo pipefail
SPEED="${1:-0.4}"
DUR="${2:-3}"

if [ -f "${HOME}/Real1/install/setup.bash" ]; then
  # shellcheck disable=SC1091
  source "${HOME}/Real1/install/setup.bash"
fi

echo "Publishing linear.x=${SPEED} m/s on /cmd_vel for ${DUR}s (RELIABLE)..."
echo "Watch robotBridge logs / wheels. Ctrl+C to abort early."
timeout "${DUR}" ros2 topic pub /cmd_vel geometry_msgs/msg/Twist \
  "{linear: {x: ${SPEED}}, angular: {z: 0.0}}" \
  -r 10 --qos-reliability reliable --qos-durability volatile || true
echo "Done."
