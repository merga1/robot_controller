#!/usr/bin/env bash
# Manual drive diagnostic — run on Pi after START + JOYSTICK
set -eo pipefail
# Source both workspaces required by articubot_one.
# shellcheck disable=SC1091
for setup in \
  "/home/delv/l2jd_ws/install/setup.bash" \
  "/home/delv/articubot_one1/install/setup.bash"
do
  if [ -f "$setup" ]; then
    # shellcheck source=/dev/null
    source "$setup"
  else
    echo "WARNING: ROS setup not found: $setup" >&2
  fi
done

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
echo "--- Pulse test (0.3 m/s linear.x for 2s) ---"
echo "NOTE: articubot_one expects m/s on /cmd_vel (standard ROS2). Use values like 0.3, not 150 RPM."
timeout 3 ros2 topic pub /cmd_vel geometry_msgs/msg/Twist \
  "{linear: {x: 0.3}, angular: {z: 0.0}}" \
  -r 10 --qos-reliability reliable --qos-durability volatile &
sleep 3.5
echo "If robot did not move during 0.3 m/s pulse, issue is articubot_one/motors — not tablet/QoS."
echo
echo "--- Relay QoS (grep log) ---"
grep -E 'RELIABLE|BEST_EFFORT|cmd_vel relay' /tmp/cmd_vel_relay.log 2>/dev/null | tail -5 || echo "(no relay log)"
echo
echo "--- Relay stats ---"
cat /tmp/cmd_vel_relay_stats.txt 2>/dev/null || echo "(no stats yet)"
echo
echo "--- API health ---"
curl -s http://127.0.0.1:8000/health 2>/dev/null || echo "(backend not running)"
