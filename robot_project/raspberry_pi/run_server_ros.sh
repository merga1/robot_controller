#!/usr/bin/env bash
# Start backend with articubot_one ROS stack sourced (required for joystick /cmd_vel).
set -eo pipefail
cd "$(dirname "$0")"

# Source both ROS workspaces required by articubot_one.
# ROS setup.bash files use unset vars — do not use "set -u" here.
# shellcheck disable=SC1091
# shellcheck source=/dev/null
for setup in \
  "/home/delv/l2jd_ws/install/setup.bash" \
  "/home/delv/articubot_one1/install/setup.bash"
do
  if [ -f "$setup" ]; then
    source "$setup"
  else
    echo "WARNING: ROS setup not found: $setup" >&2
  fi
done

exec python3 run_server.py
