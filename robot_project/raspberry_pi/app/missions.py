"""Mission management — FR-MISS-1 through FR-MISS-5."""
import threading
import subprocess
import os
import sys
from datetime import datetime, timezone
from .database import get_db


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def log_event(severity: str, source: str, message: str) -> None:
    """Persist a structured log entry (FR-LOG-1)."""
    conn = get_db()
    conn.execute(
        "INSERT INTO events_log (timestamp, severity, source, message) VALUES (?, ?, ?, ?)",
        (_now(), severity, source, message),
    )
    conn.commit()
    conn.close()


def create_mission(username: str, destinations: list[str]) -> dict:
    """FR-MISS-1: Create a delivery mission with an ordered list of destinations."""
    conn = get_db()
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO missions (created_by, status, created_at) VALUES (?, 'pending', ?)",
        (username, _now()),
    )
    mission_id = cur.lastrowid
    for order, dest in enumerate(destinations):
        cur.execute(
            "INSERT INTO mission_steps (mission_id, destination_label, step_order, status) "
            "VALUES (?, ?, ?, 'pending')",
            (mission_id, dest, order),
        )
    conn.commit()
    conn.close()
    log_event("info", "missions", f"Mission {mission_id} created by {username}: {destinations}")
    return get_mission(mission_id)


def get_mission(mission_id: int) -> dict:
    conn = get_db()
    mission = conn.execute(
        "SELECT * FROM missions WHERE id = ?", (mission_id,)
    ).fetchone()
    steps = conn.execute(
        "SELECT * FROM mission_steps WHERE mission_id = ? ORDER BY step_order",
        (mission_id,),
    ).fetchall()
    conn.close()
    if not mission:
        return None
    return {
        "id": mission["id"],
        "created_by": mission["created_by"],
        "status": mission["status"],
        "created_at": mission["created_at"],
        "completed_at": mission["completed_at"],
        "steps": [
            {
                "id": s["id"],
                "destination": s["destination_label"],
                "order": s["step_order"],
                "status": s["status"],
            }
            for s in steps
        ],
        "progress": f"{sum(1 for s in steps if s['status'] == 'completed')} of {len(steps)}",
    }


def run_mission(mission_id: int, destinations: dict, robot_state: dict) -> None:
    """FR-MISS-2: Execute mission steps sequentially in a background thread."""

    def _execute():
        conn = get_db()
        conn.execute(
            "UPDATE missions SET status='in_progress' WHERE id=?", (mission_id,)
        )
        conn.commit()
        conn.close()
        robot_state["current_mission"] = mission_id

        steps = get_mission(mission_id)["steps"]
        for step in steps:
            if not robot_state.get("ros_running"):
                _fail_mission(mission_id, "ROS 2 stopped during mission")
                return

            dest_name = step["destination"]
            dest = destinations.get(dest_name)
            if not dest:
                _fail_mission(mission_id, f"Unknown destination: {dest_name}")
                return

            # Mark step in_progress
            conn = get_db()
            conn.execute(
                "UPDATE mission_steps SET status='in_progress' WHERE id=?", (step["id"],)
            )
            conn.commit()
            conn.close()

            robot_state["status"] = "navigating"
            robot_state["current_goal"] = dest_name
            robot_state["message"] = f"Mission {mission_id}: navigating to {dest_name}"
            log_event("info", "missions", f"Mission {mission_id} step {step['order']}: -> {dest_name}")

            # Call the Nav2 action client
            result = subprocess.run(
                [
                    sys.executable,
                    os.path.join(
                        os.path.dirname(__file__), "..", "ros2_nodes", "navigate_client.py"
                    ),
                    str(dest["x"]),
                    str(dest["y"]),
                    str(dest.get("theta", dest.get("yaw", 0))),
                ],
                timeout=120,
            )

            if result.returncode != 0:
                # FR-MISS-5: halt mission and notify on failure
                conn = get_db()
                conn.execute(
                    "UPDATE mission_steps SET status='failed' WHERE id=?", (step["id"],)
                )
                conn.commit()
                conn.close()
                _fail_mission(mission_id, f"Navigation to {dest_name} failed")
                robot_state["status"] = "error"
                robot_state["message"] = f"Mission {mission_id} failed at step: {dest_name}"
                robot_state["current_mission"] = None
                return

            # Step succeeded
            conn = get_db()
            conn.execute(
                "UPDATE mission_steps SET status='completed' WHERE id=?", (step["id"],)
            )
            conn.commit()
            conn.close()

        # All steps done
        conn = get_db()
        conn.execute(
            "UPDATE missions SET status='completed', completed_at=? WHERE id=?",
            (_now(), mission_id),
        )
        conn.commit()
        conn.close()
        robot_state["status"] = "running"
        robot_state["current_goal"] = None
        robot_state["current_mission"] = None
        robot_state["message"] = f"Mission {mission_id} completed"
        log_event("info", "missions", f"Mission {mission_id} completed successfully")

    threading.Thread(target=_execute, daemon=True).start()


def _fail_mission(mission_id: int, reason: str) -> None:
    conn = get_db()
    conn.execute(
        "UPDATE missions SET status='failed', completed_at=? WHERE id=?",
        (_now(), mission_id),
    )
    conn.commit()
    conn.close()
    log_event("error", "missions", f"Mission {mission_id} failed: {reason}")
