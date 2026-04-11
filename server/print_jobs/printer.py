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

        # Body report — aggregate health data across the week
        all_health = []
        all_game = []
        current = start
        while current <= end:
            all_health.extend(self._load_health_data(current, data_dir))
            all_game.extend(self._load_game_data(current, data_dir))
            current += timedelta(days=1)

        # Compute weekly body stats
        daily_steps = []
        daily_resting_hr = []
        total_workouts = 0
        daily_sleep_hours = []

        current = start
        while current <= end:
            day_health = self._load_health_data(current, data_dir)
            day_steps, _, day_workouts = self._extract_body_stats(day_health)
            if day_steps:
                daily_steps.append(day_steps)
            total_workouts += day_workouts

            rhr = self._extract_resting_hr(day_health)
            if rhr and rhr != "—":
                try:
                    daily_resting_hr.append(int(rhr))
                except (ValueError, TypeError):
                    pass

            sleep = self._extract_latest_sleep(day_health)
            if sleep:
                total_sec = sleep.get("totalSleepSeconds") or sleep.get("total_sleep_seconds", 0)
                if total_sec:
                    daily_sleep_hours.append(total_sec / 3600.0)

            current += timedelta(days=1)

        avg_steps = int(sum(daily_steps) / len(daily_steps)) if daily_steps else 0
        avg_hr = int(sum(daily_resting_hr) / len(daily_resting_hr)) if daily_resting_hr else 0
        avg_sleep = round(sum(daily_sleep_hours) / len(daily_sleep_hours), 1) if daily_sleep_hours else 0

        if avg_steps or avg_hr or total_workouts or avg_sleep:
            lines.append("── BODY REPORT ────────────────────────────────────")
            lines.append(f"  Avg daily steps: {avg_steps:,}")
            lines.append(f"  Avg resting HR: {avg_hr} bpm")
            lines.append(f"  Total workouts: {total_workouts}")
            lines.append(f"  Avg sleep: {avg_sleep}h")
            lines.append("")

        # Screenless correlation — compare sleep on low vs high pickup days
        from categorize.health_insights import HealthInsightsGenerator
        insights_gen = HealthInsightsGenerator()
        insights = insights_gen.generate_weekly_insights(start, end, data_dir)

        sleep_summary = insights.get("sleep_pickup_summary", {})
        good_sleep = sleep_summary.get("low_pickup_avg_sleep_hours")
        bad_sleep = sleep_summary.get("high_pickup_avg_sleep_hours")
        good_sleep_str = f"{good_sleep}h" if good_sleep else "—"
        bad_sleep_str = f"{bad_sleep}h" if bad_sleep else "—"

        lines.append("── SCREENLESS CORRELATION ─────────────────────────")
        lines.append(f"  Days with < 20 pickups: avg sleep {good_sleep_str}")
        lines.append(f"  Days with > 40 pickups: avg sleep {bad_sleep_str}")

        weekly_insight = insights.get("weekly_insight")
        if weekly_insight:
            lines.append(f"  {weekly_insight}")
        else:
            lines.append("  The data doesn't lie. Keep going.")
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

    # ── Health & Game Data Helpers ────────────────────────────────────

    def _load_health_data(self, d: date, data_dir: Path) -> list:
        """Load all health ingestion entries for a given date."""
        filepath = data_dir / f"health_{d.isoformat()}.jsonl"
        return self._load_jsonl(filepath)

    def _load_game_data(self, d: date, data_dir: Path) -> list:
        """Load all game state snapshots for a given date."""
        filepath = data_dir / f"game_{d.isoformat()}.jsonl"
        return self._load_jsonl(filepath)

    def _load_jsonl(self, filepath: Path) -> list:
        """Load all JSON lines from a file."""
        if not filepath.exists():
            return []
        entries = []
        with open(filepath) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        entries.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
        return entries

    def _extract_latest_sleep(self, health_entries: list) -> dict | None:
        """Extract the most recent sleep summary from a list of health entries."""
        for entry in reversed(health_entries):
            sleep = entry.get("sleepAnalysis") or entry.get("sleep_analysis")
            if sleep:
                return sleep
        return None

    def _extract_body_stats(self, health_entries: list) -> tuple:
        """Extract the best step count, active energy, and workout count from health entries.

        Returns (steps: int, active_energy: float, workout_count: int).
        Uses the maximum values seen (since batches are cumulative snapshots).
        """
        max_steps = 0
        max_energy = 0.0
        workout_count = 0

        for entry in health_entries:
            steps = entry.get("stepCount") or entry.get("step_count", 0)
            energy = entry.get("activeEnergyBurned") or entry.get("active_energy_burned", 0)
            if steps > max_steps:
                max_steps = steps
            if energy > max_energy:
                max_energy = energy

            workout = entry.get("workoutSummary") or entry.get("workout_summary")
            if workout:
                workout_count += 1

        return max_steps, max_energy, workout_count

    def _extract_resting_hr(self, health_entries: list) -> str:
        """Extract resting heart rate from heart rate samples.

        Looks for samples with motionContext "resting" or "sedentary".
        Returns the average as a string, or "—" if unavailable.
        """
        resting_samples = []
        for entry in health_entries:
            samples = entry.get("heartRateSamples") or entry.get("heart_rate_samples", [])
            for s in samples:
                ctx = s.get("motionContext") or s.get("motion_context", "")
                if ctx in ("resting", "sedentary"):
                    bpm = s.get("bpm", 0)
                    if bpm > 0:
                        resting_samples.append(bpm)

        if not resting_samples:
            return "—"

        return str(int(sum(resting_samples) / len(resting_samples)))

    def _extract_avg_hr(self, health_entries: list) -> str:
        """Extract overall average heart rate from all samples."""
        all_bpm = []
        for entry in health_entries:
            samples = entry.get("heartRateSamples") or entry.get("heart_rate_samples", [])
            for s in samples:
                bpm = s.get("bpm", 0)
                if bpm > 0:
                    all_bpm.append(bpm)

        if not all_bpm:
            return "—"

        return str(int(sum(all_bpm) / len(all_bpm)))

    def _extract_latest_game(self, game_entries: list) -> dict | None:
        """Get the most recent game state snapshot."""
        if not game_entries:
            return None
        return game_entries[-1]

    def _format_time_field(self, data: dict, camel_key: str, snake_key: str) -> str:
        """Format a timestamp field from health data for display."""
        raw = data.get(camel_key) or data.get(snake_key)
        if not raw:
            return "—"
        try:
            if isinstance(raw, (int, float)):
                # Seconds since 1970
                dt = datetime.fromtimestamp(raw)
            else:
                dt = datetime.fromisoformat(str(raw))
            return dt.strftime("%-I:%M %p")
        except (ValueError, TypeError, OSError):
            return str(raw)

    def _format_duration(self, seconds: float) -> str:
        """Format seconds into a human-readable 'Xh Ym' string."""
        if not seconds:
            return "0h 0m"
        hours = int(seconds // 3600)
        minutes = int((seconds % 3600) // 60)
        return f"{hours}h {minutes}m"

    # ── Segment Helpers ───────────────────────────────────────────────

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
