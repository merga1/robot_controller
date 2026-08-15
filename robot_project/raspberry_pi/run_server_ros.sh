#!/usr/bin/env bash
# Start backend with Real1 ROS sourced (required for joystick /cmd_vel).
set -eo pipefail
cd "$(dirname "$0")"

# delv and abpi are used interchangeably — try both homes.
for setup in \
  "${HOME}/Real1/install/setup.bash" \
  "/home/abpi/Real1/install/setup.bash" \
  "/home/delv/Real1/install/setup.bash"
do
  if [ -f "$setup" ]; then
    # shellcheck disable=SC1091
    # ROS setup.bash uses unset vars — do not use "set -u" here.
    # shellcheck source=/dev/null
    source "$setup"
    break
  fi
done

exec python3 run_server.py
