"""
holm.community Mastodon Automation Bot

Watches an inbox folder for new photos, generates captions via Claude API,
schedules posts to Mastodon, and runs an engagement bot (boost/reply/follow).
"""

import os
import json
import shutil
import logging
import base64
import csv
from datetime import datetime, timezone
from pathlib import Path

import anthropic
from mastodon import Mastodon
from apscheduler.schedulers.blocking import BlockingScheduler
from PIL import Image
from PIL.ExifTags import TAGS, GPSTAGS

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("holm-bot")

# ---------------------------------------------------------------------------
# Configuration (all from env vars / k8s secrets)
# ---------------------------------------------------------------------------
MASTODON_BASE_URL = os.environ.get("MASTODON_BASE_URL", "https://holm.community")
MASTODON_ACCESS_TOKEN = os.environ.get("MASTODON_ACCESS_TOKEN", "")
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")

CONTENT_DIR = Path(os.environ.get("CONTENT_DIR", "/holm-content"))
INBOX_DIR = CONTENT_DIR / "inbox"
SCHEDULED_DIR = CONTENT_DIR / "scheduled"
POSTED_DIR = CONTENT_DIR / "posted"
REJECTED_DIR = CONTENT_DIR / "rejected"
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))

MAX_BOOSTS_PER_DAY = int(os.environ.get("MAX_BOOSTS_PER_DAY", "10"))
MAX_FOLLOWS_PER_DAY = int(os.environ.get("MAX_FOLLOWS_PER_DAY", "5"))
MAX_REPLIES_PER_DAY = int(os.environ.get("MAX_REPLIES_PER_DAY", "10"))

PHOTO_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".heic"}

# Schedule CSV shipped with the container image
SCHEDULE_CSV = Path(os.environ.get("SCHEDULE_CSV", "/config/quarterly_schedule.csv"))
STRATEGY_MD = Path(os.environ.get("STRATEGY_MD", "/config/content_strategy.md"))
TRACKER_CSV = DATA_DIR / "engagement_tracker.csv"

# Daily counters (reset by the scheduler at midnight)
_daily_boosts = 0
_daily_follows = 0
_daily_replies = 0

# ---------------------------------------------------------------------------
# Mastodon client
# ---------------------------------------------------------------------------

def get_mastodon() -> Mastodon:
    return Mastodon(
        access_token=MASTODON_ACCESS_TOKEN,
        api_base_url=MASTODON_BASE_URL,
    )


# ---------------------------------------------------------------------------
# EXIF helpers
# ---------------------------------------------------------------------------

def _get_exif(path: Path) -> dict:
    """Return a flat dict of human-readable EXIF tags."""
    try:
        img = Image.open(path)
        raw = img._getexif()
        if raw is None:
            return {}
        return {TAGS.get(k, k): v for k, v in raw.items()}
    except Exception:
        return {}


def _decimal_from_dms(dms, ref):
    d, m, s = [float(x) for x in dms]
    dec = d + m / 60 + s / 3600
    if ref in ("S", "W"):
        dec = -dec
    return dec


def extract_location_and_time(path: Path) -> dict:
    """Return {lat, lon, datetime} from EXIF if available."""
    exif = _get_exif(path)
    result = {}

    gps_info = exif.get("GPSInfo", {})
    if gps_info:
        decoded = {}
        for k, v in gps_info.items():
            tag = GPSTAGS.get(k, k)
            decoded[tag] = v
        if "GPSLatitude" in decoded and "GPSLongitude" in decoded:
            result["lat"] = _decimal_from_dms(
                decoded["GPSLatitude"], decoded.get("GPSLatitudeRef", "N")
            )
            result["lon"] = _decimal_from_dms(
                decoded["GPSLongitude"], decoded.get("GPSLongitudeRef", "W")
            )

    dt_str = exif.get("DateTimeOriginal") or exif.get("DateTime")
    if dt_str:
        result["datetime"] = dt_str

    return result


# ---------------------------------------------------------------------------
# Claude caption generation
# ---------------------------------------------------------------------------

CAPTION_SYSTEM = """You are posting to holm.community, a Mastodon instance about real community
life in San Diego's South Bay. Write a short, authentic caption for this photo.

Rules:
- First person, present tense
- Under 200 characters
- 2-3 hashtags max
- Tag the group/org if known (use @ mentions)
- Authentic > polished
- No emojis unless they add real meaning
"""


def generate_caption(photo_path: Path, meta: dict) -> str:
    """Use Claude vision to caption a photo."""
    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

    media_type = "image/jpeg"
    if photo_path.suffix.lower() == ".png":
        media_type = "image/png"
    elif photo_path.suffix.lower() == ".webp":
        media_type = "image/webp"

    image_data = base64.standard_b64encode(photo_path.read_bytes()).decode()

    context_parts = []
    if "datetime" in meta:
        context_parts.append(f"Photo taken at: {meta['datetime']}")
    if "lat" in meta:
        context_parts.append(f"GPS: {meta['lat']:.4f}, {meta['lon']:.4f}")
    context = "\n".join(context_parts) if context_parts else "No EXIF data available."

    message = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=256,
        system=CAPTION_SYSTEM,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": media_type,
                            "data": image_data,
                        },
                    },
                    {
                        "type": "text",
                        "text": f"Context:\n{context}\n\nWrite a Mastodon caption for this photo.",
                    },
                ],
            }
        ],
    )
    return message.content[0].text.strip().strip('"')


# ---------------------------------------------------------------------------
# Core jobs
# ---------------------------------------------------------------------------

def process_inbox():
    """Scan inbox for new photos, caption them, move to scheduled/."""
    INBOX_DIR.mkdir(parents=True, exist_ok=True)
    SCHEDULED_DIR.mkdir(parents=True, exist_ok=True)
    REJECTED_DIR.mkdir(parents=True, exist_ok=True)

    photos = [
        p for p in INBOX_DIR.iterdir()
        if p.suffix.lower() in PHOTO_EXTENSIONS
    ]

    if not photos:
        log.info("Inbox empty — nothing to process.")
        return

    log.info("Found %d photos in inbox.", len(photos))

    for photo in photos:
        try:
            meta = extract_location_and_time(photo)
            caption = generate_caption(photo, meta)
            log.info("Caption for %s: %s", photo.name, caption)

            # Write caption sidecar
            sidecar = SCHEDULED_DIR / f"{photo.stem}.json"
            sidecar.write_text(json.dumps({
                "photo": photo.name,
                "caption": caption,
                "meta": meta,
                "created_at": datetime.now(timezone.utc).isoformat(),
            }, indent=2, default=str))

            shutil.move(str(photo), str(SCHEDULED_DIR / photo.name))
            log.info("Moved %s to scheduled/", photo.name)

        except Exception:
            log.exception("Failed to process %s — moving to rejected/", photo.name)
            shutil.move(str(photo), str(REJECTED_DIR / photo.name))


def post_scheduled():
    """Post one scheduled photo+caption to Mastodon."""
    SCHEDULED_DIR.mkdir(parents=True, exist_ok=True)
    POSTED_DIR.mkdir(parents=True, exist_ok=True)

    sidecars = sorted(SCHEDULED_DIR.glob("*.json"))
    if not sidecars:
        log.info("Nothing scheduled to post.")
        return

    sidecar = sidecars[0]
    data = json.loads(sidecar.read_text())
    photo_path = SCHEDULED_DIR / data["photo"]

    if not photo_path.exists():
        log.warning("Photo %s missing for sidecar %s — skipping.", data["photo"], sidecar.name)
        sidecar.unlink()
        return

    masto = get_mastodon()
    media = masto.media_post(str(photo_path), description=data["caption"][:420])
    masto.status_post(data["caption"], media_ids=[media])
    log.info("Posted: %s", data["caption"][:80])

    shutil.move(str(photo_path), str(POSTED_DIR / photo_path.name))
    shutil.move(str(sidecar), str(POSTED_DIR / sidecar.name))


def run_engagement():
    """Boost relevant posts from home timeline."""
    global _daily_boosts
    if _daily_boosts >= MAX_BOOSTS_PER_DAY:
        log.info("Daily boost limit reached (%d).", MAX_BOOSTS_PER_DAY)
        return

    masto = get_mastodon()
    timeline = masto.timeline_home(limit=40)

    sd_keywords = [
        "san diego", "chula vista", "south bay", "balboa park", "coronado",
        "mission bay", "la jolla", "north park", "barrio logan", "imperial beach",
        "november project", "npsd", "surfrider", "sdbc", "hiking", "cleanup",
        "run club", "farmers market", "holm.community",
    ]

    boosted = 0
    for status in timeline:
        if _daily_boosts >= MAX_BOOSTS_PER_DAY:
            break
        if status.get("reblogged"):
            continue

        text = (status.get("content") or "").lower()
        if any(kw in text for kw in sd_keywords):
            try:
                masto.status_reblog(status["id"])
                _daily_boosts += 1
                boosted += 1
                log.info("Boosted: %s", status["id"])
            except Exception:
                log.exception("Failed to boost %s", status["id"])

    log.info("Boosted %d posts (%d/%d daily).", boosted, _daily_boosts, MAX_BOOSTS_PER_DAY)


def run_follow_back():
    """Follow back accounts that follow us and post about SD/outdoors."""
    global _daily_follows
    if _daily_follows >= MAX_FOLLOWS_PER_DAY:
        log.info("Daily follow limit reached (%d).", MAX_FOLLOWS_PER_DAY)
        return

    masto = get_mastodon()
    me = masto.me()
    followers = masto.account_followers(me["id"], limit=40)
    following_ids = {a["id"] for a in masto.account_following(me["id"], limit=80)}

    followed = 0
    for follower in followers:
        if _daily_follows >= MAX_FOLLOWS_PER_DAY:
            break
        if follower["id"] in following_ids:
            continue

        try:
            statuses = masto.account_statuses(follower["id"], limit=5)
            bio = (follower.get("note") or "").lower()
            recent_text = " ".join((s.get("content") or "") for s in statuses).lower()
            combined = bio + " " + recent_text

            sd_signals = ["san diego", "chula vista", "south bay", "outdoor", "hiking",
                          "running", "cycling", "surf", "beach", "community"]
            if any(kw in combined for kw in sd_signals):
                masto.account_follow(follower["id"])
                _daily_follows += 1
                followed += 1
                log.info("Followed back: @%s", follower["acct"])
        except Exception:
            log.exception("Failed to process follower %s", follower["acct"])

    log.info("Followed back %d accounts (%d/%d daily).", followed, _daily_follows, MAX_FOLLOWS_PER_DAY)


def log_daily_stats():
    """Append daily engagement stats to the tracker CSV."""
    masto = get_mastodon()
    me = masto.me()

    TRACKER_CSV.parent.mkdir(parents=True, exist_ok=True)

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    row = {
        "date": today,
        "followers": me.get("followers_count", 0),
        "following": me.get("following_count", 0),
        "statuses": me.get("statuses_count", 0),
        "boosts_sent": _daily_boosts,
        "follows_sent": _daily_follows,
    }

    file_exists = TRACKER_CSV.exists()
    with open(TRACKER_CSV, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=row.keys())
        if not file_exists:
            writer.writeheader()
        writer.writerow(row)

    log.info("Logged daily stats: %s", row)


def reset_daily_counters():
    """Reset rate-limit counters at midnight."""
    global _daily_boosts, _daily_follows, _daily_replies
    _daily_boosts = 0
    _daily_follows = 0
    _daily_replies = 0
    log.info("Daily counters reset.")


# ---------------------------------------------------------------------------
# Scheduler
# ---------------------------------------------------------------------------

def main():
    log.info("Starting holm.community bot")
    log.info("Mastodon: %s", MASTODON_BASE_URL)
    log.info("Content dir: %s", CONTENT_DIR)

    # Ensure directories exist
    for d in [INBOX_DIR, SCHEDULED_DIR, POSTED_DIR, REJECTED_DIR, DATA_DIR]:
        d.mkdir(parents=True, exist_ok=True)

    scheduler = BlockingScheduler(timezone="America/Los_Angeles")

    # Process inbox — every day at 5:00am PT (while you work out)
    scheduler.add_job(process_inbox, "cron", hour=5, minute=0, id="process_inbox")

    # Post scheduled — 3 times daily at optimal windows
    scheduler.add_job(post_scheduled, "cron", hour=7, minute=15, id="post_morning")
    scheduler.add_job(post_scheduled, "cron", hour=12, minute=15, id="post_noon")
    scheduler.add_job(post_scheduled, "cron", hour=17, minute=15, id="post_evening")

    # Engagement — boost relevant posts
    scheduler.add_job(run_engagement, "cron", hour=6, minute=0, id="engage_morning")
    scheduler.add_job(run_engagement, "cron", hour=17, minute=0, id="engage_evening")

    # Follow back — once daily
    scheduler.add_job(run_follow_back, "cron", hour=17, minute=30, id="follow_back")

    # Log daily stats at 9pm
    scheduler.add_job(log_daily_stats, "cron", hour=21, minute=0, id="daily_stats")

    # Reset counters at midnight
    scheduler.add_job(reset_daily_counters, "cron", hour=0, minute=0, id="reset_counters")

    log.info("Scheduler started. Jobs: %s", [j.id for j in scheduler.get_jobs()])
    scheduler.start()


if __name__ == "__main__":
    main()
