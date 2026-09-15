#!/usr/bin/env bash
# Start FastAPI backend if not already listening on port 8000.
set -eo pipefail

LOG="/tmp/robot-api.log"
PID_FILE="/tmp/robot-api.pid"

if [ -d "${HOME}/raspberry_pi" ]; then
  APP_DIR="${HOME}/raspberry_pi"
elif [ -d "${HOME}/robot_project/raspberry_pi" ]; then
  APP_DIR="${HOME}/robot_project/raspberry_pi"
else
  echo "Backend folder not found (~/raspberry_pi or ~/robot_project/raspberry_pi)" >&2
  exit 1
fi

# ROS optional — enables rclpy when available (robot pose / teleop).
# Source both workspaces required by articubot_one (order matters: l2jd_ws first).
for setup in \
  "/home/delv/l2jd_ws/install/setup.bash" \
  "/home/delv/articubot_one1/install/setup.bash"
do
  if [ -f "$setup" ]; then
    # shellcheck disable=SC1091
    # ROS setup.bash references unset vars (e.g. COLCON_TRACE) — no "set -u".
    # shellcheck source=/dev/null
    source "$setup"
  else
    echo "WARNING: ROS setup not found: $setup" >&2
  fi
done

health_ok() {
  python3 - <<'PY' 2>/dev/null
import urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:8000/health", timeout=2) as r:
        if r.status == 200:
            raise SystemExit(0)
except Exception:
    pass
raise SystemExit(1)
PY
}

ensure_beacon() {
  if systemctl is-active --quiet robot-beacon.service 2>/dev/null; then
    return 0
  fi
  if pgrep -f "[p]i_beacon.py" >/dev/null 2>&1; then
    return 0
  fi
  if [ -f "${APP_DIR}/pi_beacon.py" ]; then
    nohup python3 "${APP_DIR}/pi_beacon.py" >/tmp/pi-beacon.log 2>&1 &
    disown 2>/dev/null || true
  fi
  # One-time install if user has passwordless sudo (optional).
  if [ -f "${APP_DIR}/install_pi_services.sh" ] && sudo -n true 2>/dev/null; then
    bash "${APP_DIR}/install_pi_services.sh" >/tmp/install-pi-services.log 2>&1 || true
  fi
}

ensure_beacon

if health_ok; then
  exit 0
fi

pkill -f "[r]un_server.py" 2>/dev/null || true
pkill -f "[u]vicorn app.main:app" 2>/dev/null || true
sleep 1

cd "$APP_DIR" || exit 1
: >"$LOG"
nohup bash run_server_ros.sh >>"$LOG" 2>&1 &
echo $! >"$PID_FILE"

for _ in $(seq 1 90); do
  if health_ok; then
    exit 0
  fi
  sleep 1
done

# One last check — server can be slow on first import.
if health_ok; then
  exit 0
fi

echo "Backend failed to start in ${APP_DIR}" >&2
if [ -f "$LOG" ]; then
  echo "--- log tail ---" >&2
  tail -40 "$LOG" >&2
fi
exit 1
