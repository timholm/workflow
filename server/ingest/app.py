"""
TimVoice Server — Ingestion & Processing Pipeline

Receives transcription segments from the iOS app (and eventually MacBook),
categorizes them using Claude, and generates print-ready briefs.

Endpoints:
    POST /api/ingest       — receive transcription segments from devices
    GET  /api/briefs/morning — get today's morning print brief
    GET  /api/briefs/afternoon — get today's afternoon print brief
    POST /api/print/morning  — trigger morning print job
    POST /api/print/afternoon — trigger afternoon print job
"""

import os
import json
from datetime import datetime, date, timedelta
from pathlib import Path

from flask import Flask, request, jsonify
from apscheduler.schedulers.background import BackgroundScheduler

from categorize.categorizer import Categorizer
from print_jobs.printer import PrintJobGenerator

app = Flask(__name__)

DATA_DIR = Path(os.environ.get("TIMVOICE_DATA_DIR", "./data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

categorizer = Categorizer()
printer = PrintJobGenerator()


# ── Ingestion ──────────────────────────────────────────────────────────

@app.route("/api/ingest", methods=["POST"])
def ingest():
    """Receive transcription segments from devices."""
    payload = request.get_json()
    if not payload or "segments" not in payload:
        return jsonify({"error": "missing segments"}), 400

    segments = payload["segments"]
    device_id = payload.get("deviceId", "unknown")

    today_file = DATA_DIR / f"raw_{date.today().isoformat()}.jsonl"

    processed = []
    for segment in segments:
        # Categorize using Claude
        segment["category"] = categorizer.categorize(segment["text"])
        segment["device"] = device_id
        segment["ingested_at"] = datetime.now().isoformat()

        # Append to daily file
        with open(today_file, "a") as f:
            f.write(json.dumps(segment) + "\n")

        processed.append(segment["id"])

    return jsonify({"status": "ok", "processed": len(processed)}), 200


# ── Health Data Ingestion ─────────────────────────────────────────────

@app.route("/api/ingest/health", methods=["POST"])
def ingest_health():
    """Receive batched health data from the iPhone (originally from Apple Watch).

    Payload matches the HealthDataTransfer struct:
        heartRateSamples, stepCount, activeEnergyBurned,
        sleepAnalysis, workoutSummary, collectionPeriod
    """
    payload = request.get_json()
    if not payload:
        return jsonify({"error": "empty payload"}), 400

    today_file = DATA_DIR / f"health_{date.today().isoformat()}.jsonl"
    payload["ingested_at"] = datetime.now().isoformat()

    with open(today_file, "a") as f:
        f.write(json.dumps(payload) + "\n")

    return jsonify({"status": "ok"}), 200


# ── Game State Ingestion ──────────────────────────────────────────────

@app.route("/api/ingest/game", methods=["POST"])
def ingest_game():
    """Receive game state snapshots (pickups, streak, TIME ALIVE).

    Payload matches the SharedGameState struct:
        pickupsToday, currentStreak, longestStreak,
        timeAliveSeconds, currentTaunt, activeChallenge,
        screenTimeThisSession, timestamp
    """
    payload = request.get_json()
    if not payload:
        return jsonify({"error": "empty payload"}), 400

    today_file = DATA_DIR / f"game_{date.today().isoformat()}.jsonl"
    payload["ingested_at"] = datetime.now().isoformat()

    with open(today_file, "a") as f:
        f.write(json.dumps(payload) + "\n")

    return jsonify({"status": "ok"}), 200


# ── Briefs ─────────────────────────────────────────────────────────────

@app.route("/api/briefs/morning", methods=["GET"])
def morning_brief():
    """Generate morning brief content."""
    brief = printer.generate_morning_brief(date.today(), DATA_DIR)
    return jsonify({"brief": brief, "date": date.today().isoformat()})


@app.route("/api/briefs/afternoon", methods=["GET"])
def afternoon_brief():
    """Generate afternoon brief content."""
    brief = printer.generate_afternoon_brief(date.today(), DATA_DIR)
    return jsonify({"brief": brief, "date": date.today().isoformat()})


# ── Print Triggers ─────────────────────────────────────────────────────

@app.route("/api/print/morning", methods=["POST"])
def trigger_morning_print():
    """Trigger the morning print job."""
    brief = printer.generate_morning_brief(date.today(), DATA_DIR)
    printer.send_to_printer(brief, job_type="morning")
    return jsonify({"status": "printed"})


@app.route("/api/print/afternoon", methods=["POST"])
def trigger_afternoon_print():
    """Trigger the afternoon print job."""
    brief = printer.generate_afternoon_brief(date.today(), DATA_DIR)
    printer.send_to_printer(brief, job_type="afternoon")
    return jsonify({"status": "printed"})


# ── Weekly Review ──────────────────────────────────────────────────────

@app.route("/api/print/weekly", methods=["POST"])
def trigger_weekly_print():
    """Generate and print weekly review."""
    end = date.today()
    start = end - timedelta(days=7)
    review = printer.generate_weekly_review(start, end, DATA_DIR)
    printer.send_to_printer(review, job_type="weekly")
    return jsonify({"status": "printed"})


# ── Scheduled Jobs ─────────────────────────────────────────────────────

def scheduled_morning_print():
    """Runs at 6:00am — prints the morning brief."""
    with app.app_context():
        brief = printer.generate_morning_brief(date.today(), DATA_DIR)
        printer.send_to_printer(brief, job_type="morning")
        print(f"[Scheduler] Morning brief printed at {datetime.now()}")


def scheduled_afternoon_print():
    """Runs at 2:00pm — prints the afternoon brief."""
    with app.app_context():
        brief = printer.generate_afternoon_brief(date.today(), DATA_DIR)
        printer.send_to_printer(brief, job_type="afternoon")
        print(f"[Scheduler] Afternoon brief printed at {datetime.now()}")


def scheduled_weekly_review():
    """Runs Sunday at 8:00am — prints the weekly review."""
    with app.app_context():
        end = date.today()
        start = end - timedelta(days=7)
        review = printer.generate_weekly_review(start, end, DATA_DIR)
        printer.send_to_printer(review, job_type="weekly")
        print(f"[Scheduler] Weekly review printed at {datetime.now()}")


# ── Startup ────────────────────────────────────────────────────────────

scheduler = BackgroundScheduler()
scheduler.add_job(scheduled_morning_print, "cron", hour=6, minute=0)
scheduler.add_job(scheduled_afternoon_print, "cron", hour=14, minute=0)
scheduler.add_job(scheduled_weekly_review, "cron", day_of_week="sun", hour=8, minute=0)
scheduler.start()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=False)
