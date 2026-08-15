#!/usr/bin/env bash
# Quick backend diagnostics on the Pi — run: bash ~/raspberry_pi/check_backend.sh
set -e

APP_DIR="${HOME}/raspberry_pi"
if [ ! -d "$APP_DIR" ]; then
  APP_DIR="${HOME}/robot_project/raspberry_pi"
fi
LOG="/tmp/robot-api.log"

echo "=== Backend check ==="
echo "APP_DIR=$APP_DIR"

echo
echo "--- Port 8000 ---"
if command -v ss >/dev/null 2>&1; then
  ss -tlnp | grep ':8000' || echo "(nothing listening on 8000)"
elif command -v netstat >/dev/null 2>&1; then
  netstat -tlnp 2>/dev/null | grep ':8000' || echo "(nothing listening on 8000)"
else
  echo "(ss/netstat not available)"
fi

echo
echo "--- Processes ---"
pgrep -af 'run_server|uvicorn' || echo "(no run_server / uvicorn process)"

echo
echo "--- curl /health ---"
curl -sv --max-time 3 http://127.0.0.1:8000/health 2>&1 || true

echo
echo "--- Python deps ---"
python3 - <<'PY' || true
mods = ("fastapi", "uvicorn", "pydantic")
for m in mods:
    try:
        __import__(m)
        print(f"  OK  {m}")
    except ImportError as e:
        print(f"  MISSING  {m}: {e}")
PY

echo
echo "--- Import app.main ---"
cd "$APP_DIR" || exit 1
python3 - <<'PY' 2>&1 || true
try:
    from app.main import app
    print("  OK  app.main imported")
except Exception as exc:
    print(f"  FAIL  {exc}")
PY

echo
echo "--- Log tail ($LOG) ---"
if [ -f "$LOG" ]; then
  tail -30 "$LOG"
else
  echo "(no log file yet)"
fi

echo
echo "--- Try foreground start (5s) ---"
echo "If nothing is listening, run manually:"
echo "  cd $APP_DIR && bash run_server_ros.sh"
echo "Or install deps first:"
echo "  pip3 install -r $APP_DIR/requirements.txt"
