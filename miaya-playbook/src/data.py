"""SQLite persistence layer. Single writer, single replica."""
from __future__ import annotations

import os
import sqlite3
from contextlib import contextmanager
from pathlib import Path

DB_PATH = Path(os.environ.get("MIAYA_DB", "/data/playbook.db"))

SCHEMA = """
CREATE TABLE IF NOT EXISTS calls (
    contact_key TEXT PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'not_started',
    last_called_at TIMESTAMP,
    answered_by TEXT,
    notes TEXT,
    next_action TEXT,
    next_action_at DATE,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS call_log (
    id INTEGER PRIMARY KEY,
    contact_key TEXT NOT NULL,
    called_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    outcome TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS documents (
    id INTEGER PRIMARY KEY,
    filename TEXT NOT NULL,
    uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    category TEXT,
    notes TEXT,
    file_path TEXT
);

CREATE TABLE IF NOT EXISTS ask_allen (
    item TEXT PRIMARY KEY,
    amount REAL,
    included INTEGER DEFAULT 1,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS journal (
    id INTEGER PRIMARY KEY,
    entry_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    title TEXT,
    content TEXT
);

CREATE TABLE IF NOT EXISTS facts (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
"""


def init_db() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(DB_PATH) as conn:
        conn.executescript(SCHEMA)


@contextmanager
def db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def upsert_call(contact_key: str, **fields) -> None:
    with db() as conn:
        existing = conn.execute(
            "SELECT contact_key FROM calls WHERE contact_key = ?", (contact_key,)
        ).fetchone()
        if existing is None:
            conn.execute(
                "INSERT INTO calls (contact_key) VALUES (?)", (contact_key,)
            )
        if fields:
            sets = ", ".join(f"{k} = ?" for k in fields)
            values = list(fields.values()) + [contact_key]
            conn.execute(
                f"UPDATE calls SET {sets}, updated_at = CURRENT_TIMESTAMP WHERE contact_key = ?",
                values,
            )


def get_call(contact_key: str) -> sqlite3.Row | None:
    with db() as conn:
        return conn.execute(
            "SELECT * FROM calls WHERE contact_key = ?", (contact_key,)
        ).fetchone()


def all_calls() -> list[sqlite3.Row]:
    with db() as conn:
        return conn.execute("SELECT * FROM calls").fetchall()


def log_call(contact_key: str, outcome: str, notes: str = "") -> None:
    with db() as conn:
        conn.execute(
            "INSERT INTO call_log (contact_key, outcome, notes) VALUES (?, ?, ?)",
            (contact_key, outcome, notes),
        )


def call_history(contact_key: str) -> list[sqlite3.Row]:
    with db() as conn:
        return conn.execute(
            "SELECT * FROM call_log WHERE contact_key = ? ORDER BY called_at DESC",
            (contact_key,),
        ).fetchall()


def set_fact(key: str, value: str) -> None:
    with db() as conn:
        conn.execute(
            "INSERT INTO facts (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value, "
            "updated_at = CURRENT_TIMESTAMP",
            (key, value),
        )


def get_fact(key: str, default: str = "") -> str:
    with db() as conn:
        row = conn.execute("SELECT value FROM facts WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else default


def upsert_ask_item(item: str, amount: float, included: bool, notes: str = "") -> None:
    with db() as conn:
        conn.execute(
            "INSERT INTO ask_allen (item, amount, included, notes) VALUES (?, ?, ?, ?) "
            "ON CONFLICT(item) DO UPDATE SET amount = excluded.amount, "
            "included = excluded.included, notes = excluded.notes",
            (item, amount, 1 if included else 0, notes),
        )


def ask_items() -> list[sqlite3.Row]:
    with db() as conn:
        return conn.execute("SELECT * FROM ask_allen ORDER BY item").fetchall()


def add_journal_entry(title: str, content: str) -> None:
    with db() as conn:
        conn.execute(
            "INSERT INTO journal (title, content) VALUES (?, ?)", (title, content)
        )


def journal_entries() -> list[sqlite3.Row]:
    with db() as conn:
        return conn.execute(
            "SELECT * FROM journal ORDER BY entry_at DESC LIMIT 200"
        ).fetchall()
