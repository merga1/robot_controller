#!/usr/bin/env python3
"""Start the Robot Control API server."""
import sys


def _preflight() -> None:
    """Fail fast if the Pi deployment is missing updated app modules."""
    required = {
        "app.robot_link": ("validate_link", "try_start_robot_bridge", "check_cmd_vel", "publish_cmd_vel"),
        "app.ros_hub": ("start", "resync_cmd_vel_topic"),
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
        print("Backend deployment incomplete. Copy ALL files from raspberry_pi/ to ~/raspberry_pi/", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    try:
        _preflight()
    except Exception as exc:
        print(f"Preflight error: {exc}", file=sys.stderr)
        sys.exit(1)
    try:
        import uvicorn
    except ImportError:
        print("Missing uvicorn. Run: pip3 install -r requirements.txt", file=sys.stderr)
        sys.exit(1)

    print("Starting Robot Control API on http://0.0.0.0:8000", flush=True)
    from app import robot_link

    robot_link.apply_ros_environment()
    try:
        import rclpy

        if not rclpy.ok():
            rclpy.init(args=None)
        print("rclpy OK — in-process cmd_vel hub will be used", flush=True)
    except ImportError:
        print(
            "rclpy not found in this Python — joystick uses cmd_vel relay subprocess",
            flush=True,
        )
    except Exception as exc:
        print(f"rclpy init warning: {exc} — using cmd_vel relay", flush=True)

    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=False)