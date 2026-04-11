"""
Health Insights — uses Claude to find correlations between
health metrics and phone/screen usage.

Called by the weekly review generator to produce a
"SCREENLESS CORRELATION" section for the printed brief.
"""

import json
import os
from datetime import date, timedelta
from pathlib import Path

from anthropic import Anthropic


INSIGHTS_PROMPT = """You are a health data analyst for Tim's "screenless life" system.

Tim is trying to use his phone less. He wears an Apple Watch that tracks his health,
and has a gamified system that tracks phone pickups and "TIME ALIVE" (time without
touching the phone).

You will receive a week of health data (sleep, steps, heart rate, workouts) alongside
game data (phone pickups per day, TIME ALIVE, streak).

Your job: find REAL correlations in this specific data. Do NOT make up patterns that
aren't supported by the numbers.

Return a JSON object with:
{
    "correlations": [
        {
            "finding": "One sentence describing a data-backed correlation",
            "metric_a": "the health metric",
            "metric_b": "the phone usage metric",
            "direction": "positive" or "negative" or "neutral",
            "strength": "strong" or "moderate" or "weak"
        }
    ],
    "sleep_pickup_summary": {
        "low_pickup_avg_sleep_hours": <float or null>,
        "high_pickup_avg_sleep_hours": <float or null>,
        "low_pickup_threshold": 20,
        "high_pickup_threshold": 40
    },
    "weekly_insight": "A single motivational sentence grounded in this week's actual data",
    "best_day": "Which day had the best health + lowest phone usage combo",
    "worst_day": "Which day had the worst combo"
}

Be brutally honest. If the data shows phone usage doesn't affect health, say so.
But if there IS a correlation, make it vivid and specific.

ONLY return JSON. No commentary."""


class HealthInsightsGenerator:
    def __init__(self):
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if api_key:
            self.client = Anthropic(api_key=api_key)
        else:
            self.client = None
            print("[HealthInsights] WARNING: No ANTHROPIC_API_KEY set. Insights disabled.")

    def generate_weekly_insights(
        self,
        start: date,
        end: date,
        data_dir: Path,
    ) -> dict:
        """
        Analyze a week of health + game data and return structured insights.

        Args:
            start: First day of the week (inclusive).
            end: Last day of the week (inclusive).
            data_dir: Directory containing health_{date}.jsonl and game_{date}.jsonl files.

        Returns:
            Dict with correlations, sleep_pickup_summary, weekly_insight,
            best_day, and worst_day. Returns a fallback dict if Claude is
            unavailable or the data is insufficient.
        """
        health_data = self._collect_week_health(start, end, data_dir)
        game_data = self._collect_week_game(start, end, data_dir)

        if not health_data and not game_data:
            return self._empty_insights()

        if not self.client:
            return self._fallback_insights(health_data, game_data)

        user_content = json.dumps({
            "period": {"start": start.isoformat(), "end": end.isoformat()},
            "health_by_day": health_data,
            "game_by_day": game_data,
        }, indent=2, default=str)

        try:
            response = self.client.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=1024,
                system=INSIGHTS_PROMPT,
                messages=[{"role": "user", "content": user_content}],
            )

            result_text = response.content[0].text.strip()
            return json.loads(result_text)

        except json.JSONDecodeError:
            return self._fallback_insights(health_data, game_data)
        except Exception as e:
            print(f"[HealthInsights] Claude API error: {e}")
            return self._fallback_insights(health_data, game_data)

    # ── Data Collection ───────────────────────────────────────────────

    def _collect_week_health(self, start: date, end: date, data_dir: Path) -> dict:
        """Load health data for each day in the range."""
        result = {}
        current = start
        while current <= end:
            day_data = self._load_jsonl(data_dir / f"health_{current.isoformat()}.jsonl")
            if day_data:
                result[current.isoformat()] = day_data
            current += timedelta(days=1)
        return result

    def _collect_week_game(self, start: date, end: date, data_dir: Path) -> dict:
        """Load game data for each day in the range."""
        result = {}
        current = start
        while current <= end:
            day_data = self._load_jsonl(data_dir / f"game_{current.isoformat()}.jsonl")
            if day_data:
                result[current.isoformat()] = day_data
            current += timedelta(days=1)
        return result

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

    # ── Fallback / Empty ──────────────────────────────────────────────

    def _fallback_insights(self, health_data: dict, game_data: dict) -> dict:
        """
        Compute basic insights without Claude when the API is unavailable.
        """
        low_pickup_sleep = []
        high_pickup_sleep = []

        for day_str in set(list(health_data.keys()) + list(game_data.keys())):
            h_entries = health_data.get(day_str, [])
            g_entries = game_data.get(day_str, [])

            # Extract sleep hours from health entries
            sleep_hours = None
            for entry in h_entries:
                sleep_data = entry.get("sleepAnalysis") or entry.get("sleep_analysis")
                if sleep_data:
                    total = sleep_data.get("totalSleepSeconds") or sleep_data.get("total_sleep_seconds", 0)
                    if total:
                        sleep_hours = total / 3600.0
                        break

            # Extract pickups from game entries
            pickups = None
            for entry in g_entries:
                p = entry.get("pickupsToday") or entry.get("pickups_today")
                if p is not None:
                    pickups = p
                    break

            if sleep_hours is not None and pickups is not None:
                if pickups < 20:
                    low_pickup_sleep.append(sleep_hours)
                elif pickups > 40:
                    high_pickup_sleep.append(sleep_hours)

        avg_low = round(sum(low_pickup_sleep) / len(low_pickup_sleep), 1) if low_pickup_sleep else None
        avg_high = round(sum(high_pickup_sleep) / len(high_pickup_sleep), 1) if high_pickup_sleep else None

        return {
            "correlations": [],
            "sleep_pickup_summary": {
                "low_pickup_avg_sleep_hours": avg_low,
                "high_pickup_avg_sleep_hours": avg_high,
                "low_pickup_threshold": 20,
                "high_pickup_threshold": 40,
            },
            "weekly_insight": "Keep collecting data. Patterns emerge over time.",
            "best_day": None,
            "worst_day": None,
        }

    def _empty_insights(self) -> dict:
        return {
            "correlations": [],
            "sleep_pickup_summary": {
                "low_pickup_avg_sleep_hours": None,
                "high_pickup_avg_sleep_hours": None,
                "low_pickup_threshold": 20,
                "high_pickup_threshold": 40,
            },
            "weekly_insight": "No data yet. Wear the Watch, live your life.",
            "best_day": None,
            "worst_day": None,
        }
