#!/usr/bin/env bash
# Manual drive diagnostic — run on Pi after START + JOYSTICK
set -eo pipefail
if [ -f "${HOME}/Real1/install/setup.bash" ]; then
  # shellcheck disable=SC1091
  source "${HOME}/Real1/install/setup.bash"
fi

echo "=== Drive diagnosis ==="
echo
echo "--- real1_link.env cmd_vel units ---"
grep -E 'CMD_VEL|RPM|ENABLE' "${HOME}/raspberry_pi/real1_link.env" 2>/dev/null || echo "(no real1_link.env)"
echo
echo "--- Nodes ---"
ros2 node list 2>/dev/null || echo "(ros2 not sourced)"
echo
echo "--- /cmd_vel QoS ---"
ros2 topic info /cmd_vel -v 2>/dev/null | head -40
echo
echo "--- State file (tablet → relay) ---"
cat /tmp/robot_cmd_vel.state 2>/dev/null || echo "(no state file — tap JOYSTICK and drag pad)"
echo
timeout 5 ros2 topic echo /cmd_vel --once 2>/dev/null || echo "(no messages in 5s)"
echo
echo "--- Pulse test (150 RPM linear.x for 2s) ---"
echo "NOTE: teleop_twist_keyboard sends m/s (e.g. 0.5) — robotBridge uses RPM and int(0.5)=0."
echo "Use RPM values like 150, not teleop_twist_keyboard, to test motors."
timeout 3 ros2 topic pub /cmd_vel geometry_msgs/msg/Twist \
  "{linear: {x: 150.0}, angular: {z: 0.0}}" \
  -r 10 --qos-reliability reliable --qos-durability volatile &
sleep 3.5
echo "If robot did not move during 150 RPM pulse, issue is robotBridge/motors — not tablet/QoS."
echo
echo "--- Relay QoS (grep log) ---"
grep -E 'RELIABLE|BEST_EFFORT|cmd_vel relay' /tmp/cmd_vel_relay.log 2>/dev/null | tail -5 || echo "(no relay log)"
echo
echo "--- Relay stats ---"
cat /tmp/cmd_vel_relay_stats.txt 2>/dev/null || echo "(no stats yet)"
echo
echo "--- API health ---"
curl -s http://127.0.0.1:8000/health 2>/dev/null || echo "(backend not running)"
