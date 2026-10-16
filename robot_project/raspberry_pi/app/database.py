"""
database.py — Lightweight SQLite persistence for users and missions.

Tables
------
missions (id, status, destinations_json, created_at, completed_at)

Destinations are stored as JSON in app/destinations.json (not in SQLite)
to make them easy to hand-edit and back up on the Pi.
"""

import json
import os
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ── Path config ───────────────────────────────────────────────────────────────

_APP_DIR = Path(__file__).parent
DB_PATH = _APP_DIR / "robot.db"
DESTINATIONS_PATH = _APP_DIR / "destinations.json"

# ── Thread-local SQLite connection ────────────────────────────────────────────

_local = threading.local()


def _get_conn() -> sqlite3.Connection:
    if not hasattr(_local, "conn") or _local.conn is None:
        conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        _local.conn = conn
    return _local.conn


def _init_db() -> None:
    conn = _get_conn()
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS missions (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            status        TEXT    NOT NULL DEFAULT 'pending',
            destinations  TEXT    NOT NULL DEFAULT '[]',
            created_at    TEXT    NOT NULL,
            completed_at  TEXT
        );
        """
    )
    conn.commit()


_init_db()

# ── Destinations (JSON file) ──────────────────────────────────────────────────

def _load_destinations() -> list[dict]:
    if DESTINATIONS_PATH.exists():
        try:
            raw = DESTINATIONS_PATH.read_text(encoding="utf-8").strip()
            if raw:
                return json.loads(raw)
        except Exception:
            pass
    return []


def _save_destinations(dests: list[dict]) -> None:
    DESTINATIONS_PATH.write_text(
        json.dumps(dests, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )


def get_destinations() -> list[dict]:
    """Return list of {name, x, y, theta} dicts."""
    return _load_destinations()


def upsert_destination(name: str, x: float, y: float, theta: float) -> None:
    """Insert or update a destination by name."""
    dests = _load_destinations()
    for d in dests:
        if d.get("name") == name:
            d["x"] = x
            d["y"] = y
            d["theta"] = theta
            _save_destinations(dests)
            return
    dests.append({"name": name, "x": x, "y": y, "theta": theta})
    _save_destinations(dests)


def delete_destination(name: str) -> bool:
    """Remove a destination by name. Returns True if found and removed."""
    dests = _load_destinations()
    new_dests = [d for d in dests if d.get("name") != name]
    if len(new_dests) == len(dests):
        return False
    _save_destinations(new_dests)
    return True


def get_destination(name: str) -> dict | None:
    """Look up a single destination by name."""
    for d in _load_destinations():
        if d.get("name") == name:
            return d
    return None


# ── Missions (SQLite) ─────────────────────────────────────────────────────────

def create_mission(destinations: list[str]) -> int:
    conn = _get_conn()
    cur = conn.execute(
        "INSERT INTO missions (status, destinations, created_at) VALUES (?, ?, ?)",
        ("pending", json.dumps(destinations), datetime.now(timezone.utc).isoformat()),
    )
    conn.commit()
    return cur.lastrowid  # type: ignore[return-value]


def get_mission(mission_id: int) -> dict[str, Any] | None:
    conn = _get_conn()
    row = conn.execute("SELECT * FROM missions WHERE id=?", (mission_id,)).fetchone()
    if row is None:
        return None
    d = dict(row)
    d["destinations"] = json.loads(d["destinations"])
    return d


def update_mission_status(
    mission_id: int, status: str, completed: bool = False
) -> None:
    conn = _get_conn()
    if completed:
        conn.execute(
            "UPDATE missions SET status=?, completed_at=? WHERE id=?",
            (status, datetime.now(timezone.utc).isoformat(), mission_id),
        )
    else:
        conn.execute("UPDATE missions SET status=? WHERE id=?", (status, mission_id))
    conn.commit()
