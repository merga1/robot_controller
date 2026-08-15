#!/usr/bin/env bash
# Install systemd units so pi_beacon.py (and optionally the API) start at boot.
set -euo pipefail

USER_NAME="$(whoami)"
HOME_DIR="${HOME}"
APP_DIR="${HOME_DIR}/raspberry_pi"
ENABLE_API=false

for arg in "$@"; do
  case "$arg" in
    --with-api) ENABLE_API=true ;;
    -h|--help)
      echo "Usage: $0 [--with-api]"
      echo "  Enables robot-beacon.service (pi_beacon.py) at boot."
      echo "  --with-api  Also enable robot-api.service (run_server.py)."
      exit 0
      ;;
  esac
done

if [ ! -f "${APP_DIR}/pi_beacon.py" ]; then
  echo "Missing ${APP_DIR}/pi_beacon.py — copy raspberry_pi/ to ~/raspberry_pi first." >&2
  exit 1
fi

echo "Installing Pi services for user ${USER_NAME}..."

pip3 install --user zeroconf 2>/dev/null || pip3 install zeroconf || true

install_unit() {
  local unit_name="$1"
  local template="${APP_DIR}/${unit_name}"
  if [ ! -f "$template" ]; then
    echo "Missing ${template}" >&2
    exit 1
  fi
  sed -e "s|@USER@|${USER_NAME}|g" -e "s|@HOME@|${HOME_DIR}|g" "$template" \
    | sudo tee "/etc/systemd/system/${unit_name}" >/dev/null
  echo "  installed /etc/systemd/system/${unit_name}"
}

install_unit "robot-beacon.service"

if $ENABLE_API; then
  install_unit "robot-api.service"
fi

sudo systemctl daemon-reload
sudo systemctl enable --now robot-beacon.service
echo ""
echo "robot-beacon.service is enabled and running."
systemctl is-active robot-beacon.service || true

if $ENABLE_API; then
  sudo systemctl enable --now robot-api.service
  echo "robot-api.service is enabled and running."
  systemctl is-active robot-api.service || true
fi

echo ""
echo "Done. Tablet app should discover: ${USER_NAME} @ $(hostname)"
echo "Check: systemctl status robot-beacon"
