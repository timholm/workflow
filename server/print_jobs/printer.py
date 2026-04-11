"""
Print Job Generator — turns Tim's categorized transcriptions into
formatted print-ready briefs.

Output format is plain text optimized for a standard letter-size printer.
Could also target thermal receipt printers or e-ink displays.
"""

import json
import math
import os
import subprocess
from datetime import date, datetime, timedelta
from pathlib import Path


class PrintJobGenerator:
    def __init__(self):
        self.printer_name = os.environ.get("PRINTER_NAME", "default")
        self.print_command = os.environ.get("PRINT_CMD", "lp")  # CUPS on macOS/Linux

    # ── Morning Brief (6:00am) ─────────────────────────────────────────

    def generate_morning_brief(self, today: date, data_dir: Path) -> str:
        """
        Morning brief contains:
        - Today's date and weather placeholder
        - Today's schedule (from calendar integration)
        - Tasks captured yesterday and overnight
        - Pending items that need attention
        - Shopping list if anything was mentioned
        """
        yesterday = today - timedelta(days=1)
        yesterday_segments = self._load_segments(yesterday, data_dir)
        overnight_segments = self._load_segments(today, data_dir)

        all_segments = yesterday_segments + overnight_segments

        tasks = [s for s in all_segments if s.get("category") == "task"]
        calendar = [s for s in all_segments if s.get("category") == "calendar"]
        shopping = [s for s in all_segments if s.get("category") == "shopping"]
        emails = [s for s in all_segments if s.get("category") == "email"]
        journal = [s for s in all_segments if s.get("category") == "journal"]

        lines = []
        lines.append("=" * 60)
        lines.append(f"  MORNING BRIEF — {today.strftime('%A, %B %d, %Y')}")
        lines.append("=" * 60)
        lines.append("")

        # Tasks
        lines.append("── TASKS ──────────────────────────────────────────")
        if tasks:
            for i, t in enumerate(tasks, 1):
                summary = t.get("summary", t.get("text", "")[:80])
                priority = t.get("priority", "")
                marker = "(!)" if priority == "high" else "   "
                lines.append(f"  {marker} {i}. {summary}")
        else:
            lines.append("  No new tasks.")
        lines.append("")

        # Calendar actions
        if calendar:
            lines.append("── CALENDAR CHANGES ───────────────────────────────")
            for c in calendar:
                action = c.get("action", c.get("summary", ""))
                lines.append(f"  → {action}")
            lines.append("")

        # Emails to send
        if emails:
            lines.append("── EMAILS TO SEND ─────────────────────────────────")
            for e in emails:
                action = e.get("action", e.get("summary", ""))
                contacts = ", ".join(e.get("contacts", []))
                lines.append(f"  → {action}")
                if contacts:
                    lines.append(f"    To: {contacts}")
            lines.append("")

        # Shopping
        if shopping:
            lines.append("── SHOPPING LIST ──────────────────────────────────")
            for s in shopping:
                lines.append(f"  □ {s.get('summary', s.get('text', '')[:60])}")
            lines.append("")

        # Journal snippets
        if journal:
            lines.append("── FROM YOUR THOUGHTS ─────────────────────────────")
            for j in journal[:3]:  # max 3
                lines.append(f'  "{j.get("summary", j.get("text", "")[:80])}"')
            lines.append("")

        # Health: last night's sleep
        health_entries = self._load_health_data(yesterday, data_dir)
        # Also check today's data in case sleep was ingested after midnight
        health_entries += self._load_health_data(today, data_dir)
        sleep = self._extract_latest_sleep(health_entries)
        if sleep:
            total_sec = sleep.get("totalSleepSeconds") or sleep.get("total_sleep_seconds", 0)
            deep_sec = sleep.get("deepSleepSeconds") or sleep.get("deep_sleep_seconds", 0)
            hours = int(total_sec // 3600)
            minutes = int((total_sec % 3600) // 60)
            deep_hours = int(deep_sec // 3600)
            deep_min = int((deep_sec % 3600) // 60)
            bed_time = self._format_time_field(sleep, "sleepStart", "sleep_start")
            wake_time = self._format_time_field(sleep, "sleepEnd", "sleep_end")

            # Resting heart rate from HR samples
            resting_hr = self._extract_resting_hr(health_entries)

            lines.append("── LAST NIGHT'S SLEEP ─────────────────────────────")
            lines.append(f"  Total: {hours}h {minutes}m ({bed_time} → {wake_time})")
            lines.append(f"  Deep sleep: {deep_hours}h {deep_min}m")
            lines.append(f"  Resting heart rate: {resting_hr} bpm")
            lines.append("")

        # Health: yesterday's body stats
        yesterday_health = self._load_health_data(yesterday, data_dir)
        steps, energy, workouts = self._extract_body_stats(yesterday_health)
        if steps or energy or workouts:
            lines.append("── YESTERDAY'S BODY ───────────────────────────────")
            lines.append(f"  Steps: {steps:,}")
            lines.append(f"  Active energy: {energy:.0f} kcal")
            lines.append(f"  Workouts: {workouts}")
            lines.append("")

        # Game data
        game_entries = self._load_game_data(yesterday, data_dir)
        game = self._extract_latest_game(game_entries)
        if game:
            pickups = game.get("pickupsToday") or game.get("pickups_today", 0)
            time_alive_sec = game.get("timeAliveSeconds") or game.get("time_alive_seconds", 0)
            streak = game.get("currentStreak") or game.get("current_streak", 0)
            time_alive = self._format_duration(time_alive_sec)

            lines.append("── THE GAME ───────────────────────────────────────")
            lines.append(f"  Yesterday pickups: {pickups}")
            lines.append(f"  TIME ALIVE: {time_alive}")
            lines.append(f"  Current streak: {streak} days")
            lines.append("")

        lines.append("─" * 60)
        lines.append(f"  Generated {datetime.now().strftime('%I:%M %p')}")
        lines.append("")

        return "\n".join(lines)

    # ── Afternoon Brief (2:00pm) ───────────────────────────────────────

    def generate_afternoon_brief(self, today: date, data_dir: Path) -> str:
        """
        Afternoon brief contains:
        - New tasks from the morning
        - Email responses needed
        - Evening schedule
        - Updated shopping list
        """
        segments = self._load_segments(today, data_dir)

        tasks = [s for s in segments if s.get("category") == "task"]
        emails = [s for s in segments if s.get("category") == "email"]
        shopping = [s for s in segments if s.get("category") == "shopping"]

        lines = []
        lines.append("=" * 60)
        lines.append(f"  AFTERNOON UPDATE — {today.strftime('%A, %B %d, %Y')}")
        lines.append("=" * 60)
        lines.append("")

        lines.append("── NEW TASKS (since morning) ──────────────────────")
        morning_cutoff = datetime.combine(today, datetime.min.time()).replace(hour=6)
        afternoon_tasks = [
            t for t in tasks
            if self._parse_time(t.get("ingested_at", "")) > morning_cutoff
        ]
        if afternoon_tasks:
            for i, t in enumerate(afternoon_tasks, 1):
                lines.append(f"  {i}. {t.get('summary', t.get('text', '')[:80])}")
        else:
            lines.append("  Nothing new.")
        lines.append("")

        if emails:
            lines.append("── EMAILS PENDING ─────────────────────────────────")
            for e in emails:
                lines.append(f"  → {e.get('action', e.get('summary', ''))}")
            lines.append("")

        if shopping:
            lines.append("── SHOPPING (complete list) ────────────────────────")
            for s in shopping:
                lines.append(f"  □ {s.get('summary', s.get('text', '')[:60])}")
            lines.append("")

        # Health: today so far
        health_entries = self._load_health_data(today, data_dir)
        steps, energy, _ = self._extract_body_stats(health_entries)
        avg_hr = self._extract_avg_hr(health_entries)

        # Project steps to end of day based on current pace
        now = datetime.now()
        hours_elapsed = now.hour + now.minute / 60.0
        projected = int(steps * (16.0 / max(hours_elapsed, 1))) if steps else 0

        game_entries = self._load_game_data(today, data_dir)
        game = self._extract_latest_game(game_entries)
        pickups = 0
        time_alive = "0h 0m"
        if game:
            pickups = game.get("pickupsToday") or game.get("pickups_today", 0)
            time_alive_sec = game.get("timeAliveSeconds") or game.get("time_alive_seconds", 0)
            time_alive = self._format_duration(time_alive_sec)

        if steps or avg_hr or game:
            lines.append("── TODAY SO FAR ────────────────────────────────────")
            lines.append(f"  Steps: {steps:,} (pace for {projected:,})")
            lines.append(f"  Heart rate: avg {avg_hr} bpm")
            lines.append(f"  Phone pickups: {pickups} (TIME ALIVE: {time_alive})")
            lines.append("")

        lines.append("─" * 60)
        lines.append(f"  Generated {datetime.now().strftime('%I:%M %p')}")
        lines.append("")

        return "\n".join(lines)

    # ── Weekly Review ──────────────────────────────────────────────────

    def generate_weekly_review(self, start: date, end: date, data_dir: Path) -> str:
        """Sunday weekly review — stats, patterns, highlights."""
        all_segments = []
        current = start
        while current <= end:
            all_segments.extend(self._load_segments(current, data_dir))
            current += timedelta(days=1)

        categories = {}
        for s in all_segments:
            cat = s.get("category", "unknown")
            categories[cat] = categories.get(cat, 0) + 1

        total_words = sum(len(s.get("text", "").split()) for s in all_segments)

        lines = []
        lines.append("=" * 60)
        lines.append(f"  WEEKLY REVIEW — {start.strftime('%b %d')} to {end.strftime('%b %d, %Y')}")
        lines.append("=" * 60)
        lines.append("")

        lines.append("── STATS ──────────────────────────────────────────")
        lines.append(f"  Total segments captured: {len(all_segments)}")
        lines.append(f"  Total words spoken: {total_words:,}")
        for cat, count in sorted(categories.items(), key=lambda x: -x[1]):
            lines.append(f"    {cat:15s}: {count}")
        lines.append("")

        # People mentioned
        all_contacts = []
        for s in all_segments:
            all_contacts.extend(s.get("contacts", []))
        if all_contacts:
            from collections import Counter
            top = Counter(all_contacts).most_common(10)
            lines.append("── PEOPLE YOU MENTIONED MOST ──────────────────────")
            for name, count in top:
                lines.append(f"  {name}: {count} times")
            lines.append("")

        # Journal highlights
        journal = [s for s in all_segments if s.get("category") == "journal"]
        if journal:
            lines.append("── JOURNAL HIGHLIGHTS ─────────────────────────────")
            for j in journal[:5]:
                lines.append(f'  • "{j.get("summary", j.get("text", "")[:80])}"')
            lines.append("")

        lines.append("─" * 60)
        lines.append(f"  Generated {datetime.now().strftime('%I:%M %p')}")
        lines.append("")

        return "\n".join(lines)

    # ── Printer Output ─────────────────────────────────────────────────

    def send_to_printer(self, content: str, job_type: str = "brief"):
        """Send formatted text to the printer via CUPS (lp command)."""
        output_dir = Path("./print_output")
        output_dir.mkdir(exist_ok=True)

        # Always save to file
        filename = f"{job_type}_{date.today().isoformat()}.txt"
        filepath = output_dir / filename
        filepath.write_text(content)

        # Send to printer if configured
        if self.printer_name and self.printer_name != "file_only":
            try:
                subprocess.run(
                    [self.print_command, "-d", self.printer_name, str(filepath)],
                    check=True,
                    capture_output=True,
                )
                print(f"[Printer] Sent {job_type} to {self.printer_name}")
            except (subprocess.CalledProcessError, FileNotFoundError) as e:
                print(f"[Printer] Print failed (saved to {filepath}): {e}")
        else:
            print(f"[Printer] Saved to {filepath} (no printer configured)")

    # ── Helpers ────────────────────────────────────────────────────────

    def _load_segments(self, d: date, data_dir: Path) -> list:
        filepath = data_dir / f"raw_{d.isoformat()}.jsonl"
        if not filepath.exists():
            return []
        segments = []
        with open(filepath) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        segments.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
        return segments

    def _parse_time(self, iso_str: str) -> datetime:
        try:
            return datetime.fromisoformat(iso_str)
        except (ValueError, TypeError):
            return datetime.min
