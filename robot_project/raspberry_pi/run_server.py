#!/usr/bin/env python3
"""
run_server.py — Entry point for the robot Pi backend.

Usage (from raspberry_pi/ directory):
    # Source environment first:
    set -a && source real1_link.env && set +a

    # Then start the server:
    python3 run_server.py

    # Or directly with uvicorn for hot-reload during development:
    uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

The server listens on all interfaces (0.0.0.0) so the Flutter tablet app
can reach it over Wi-Fi. The port defaults to 8000 and can be overridden
with the PORT environment variable.
"""

import os
import sys
from pathlib import Path

# Ensure the raspberry_pi/ directory is on the Python path so
# `from app.main import app` works when running as a script.
_HERE = Path(__file__).parent.resolve()
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

# Load real1_link.env if it exists and hasn't been sourced yet
_ENV_FILE = _HERE / "real1_link.env"
if _ENV_FILE.exists() and not os.getenv("REAL1_WS"):
    print(f"[run_server] Loading env from {_ENV_FILE}")
    for line in _ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        os.environ.setdefault(key.strip(), val.strip())

import uvicorn

if __name__ == "__main__":
    host = os.getenv("ROBOT_API_HOST", "0.0.0.0")
    port = int(os.getenv("PORT", os.getenv("ROBOT_API_PORT", "8000")))
    reload = os.getenv("ROBOT_API_RELOAD", "0") == "1"

    print(f"[run_server] Starting robot API on http://{host}:{port}")
    print(f"[run_server] REAL1_WS = {os.getenv('REAL1_WS', '(not set)')}")

    uvicorn.run(
        "app.main:app",
        host=host,
        port=port,
        reload=reload,
        log_level="info",
    )
