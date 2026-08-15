#!/usr/bin/env python3
"""Start the Robot Control API server."""
import sys


def _preflight() -> None:
    """Fail fast if the Pi deployment is missing updated app modules."""
    required = {
        "app.robot_link": ("validate_link", "try_start_robot_bridge", "check_cmd_vel"),
        "app.ros_hub": ("start", "set_cmd_vel"),
        "app.teleop": ("set_velocity", "stop"),
    }
    errors = []
    for module_name, attrs in required.items():
        try:
            mod = __import__(module_name, fromlist=list(attrs))
        except ImportError as exc:
            errors.append(f"Missing module {module_name}: {exc}")
            continue
        for attr in attrs:
            if not hasattr(mod, attr):
                errors.append(f"{module_name} is outdated — missing {attr}()")
    if errors:
        print("Backend deployment incomplete. Copy ALL files from raspberry_pi/app/ to ~/raspberry_pi/app/", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    _preflight()
    import uvicorn

    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=False)