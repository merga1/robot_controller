"""SQLite database setup — Section 9.2 of the SRS."""
import sqlite3
import os

DB_PATH = os.path.join(os.path.dirname(__file__), "robot.db")


def get_db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    conn = get_db()
    cur = conn.cursor()

    cur.executescript("""
    PRAGMA journal_mode=WAL;

    CREATE TABLE IF NOT EXISTS users (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT    NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        role     TEXT    NOT NULL DEFAULT 'operator'  -- operator | administrator
    );

    CREATE TABLE IF NOT EXISTS missions (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        created_by   TEXT    NOT NULL,
        status       TEXT    NOT NULL DEFAULT 'pending',  -- pending|in_progress|completed|failed
        created_at   TEXT    NOT NULL,
        completed_at TEXT
    );

    CREATE TABLE IF NOT EXISTS mission_steps (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        mission_id        INTEGER NOT NULL REFERENCES missions(id),
        destination_label TEXT    NOT NULL,
        step_order        INTEGER NOT NULL,
        status            TEXT    NOT NULL DEFAULT 'pending'  -- pending|in_progress|completed|failed
    );

    CREATE TABLE IF NOT EXISTS events_log (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT    NOT NULL,
        severity  TEXT    NOT NULL DEFAULT 'info',  -- info|warning|error
        source    TEXT    NOT NULL DEFAULT 'system',
        message   TEXT    NOT NULL
    );

    CREATE TABLE IF NOT EXISTS settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    """
    )

    # Default settings (FR-BATT-2 / FR-BATT-3 thresholds)
    cur.executemany(
        "INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)",
        [
            ("battery_warning_threshold", "20"),
            ("battery_critical_threshold", "10"),
            ("ws_timeout_seconds", "5"),
            ("idle_timeout_minutes", "30"),
        ],
    )

    # Default admin account (password: admin — change in production)
    import hashlib
    default_hash = hashlib.sha256(b"admin").hexdigest()
    cur.execute(
        "INSERT OR IGNORE INTO users (username, password_hash, role) VALUES (?, ?, ?)",
        ("admin", default_hash, "administrator"),
    )

    conn.commit()
    conn.close()
