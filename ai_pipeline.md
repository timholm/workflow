# holm.community AI Automation Pipeline

## Overview
You take photos. AI does everything else.

```
Phone Camera → Cloud Folder → AI Processing → Scheduled Mastodon Posts
                                    ↓
                            AI Engagement Bot
                            (boost, reply, follow)
```

## Step 1: Photo Capture (You)
- Take photos on your phone at events/groups
- Star/favorite the best 1-3 shots before you drive home
- That's it. You're done. Go to sleep.

## Step 2: Auto-Upload to Cloud
**Tool:** Syncthing, Nextcloud, or iCloud/Google Photos auto-upload

- Phone auto-syncs starred/favorited photos to a cloud folder
- Folder structure:
  ```
  /holm-content/
    /inbox/          ← new photos land here
    /scheduled/      ← AI moved them here with captions
    /posted/         ← archive after posting
    /rejected/       ← AI skipped these (blurry, duplicate)
  ```

## Step 3: AI Caption + Scheduling
**Tool:** Custom script using Claude API or local LLM

### What the AI does:
1. Scans `/inbox/` every morning at 5:00am (while you work out)
2. For each photo:
   - Reads EXIF data (location, time, date)
   - Matches location to known group/event schedule (from quarterly_schedule.csv)
   - Generates a short caption matching your voice (see content_strategy.md)
   - Picks 2-3 relevant hashtags
   - Assigns a posting time (optimal engagement windows: 7-9am, 12-1pm, 5-7pm)
3. Moves photo + caption to `/scheduled/`
4. Posts via Mastodon API at the scheduled time

### Caption Generation Prompt Template:
```
You are posting to holm.community, a Mastodon instance about real community
life in San Diego's South Bay. Write a short, authentic caption for this photo.

Context:
- Photo taken at: {location} on {date} at {time}
- Likely event: {matched_event_from_schedule}
- Content pillar: {community_group | local_culture | the_land}

Rules:
- First person, present tense
- Under 200 characters
- 2-3 hashtags max
- Tag the group/org if known
- Authentic > polished
```

### Example Output:
```
"6:29am at the fountain. @novemberprojectsd doesn't do excuses. #NPSD #BalboaPark"
Posted: 7:15am next day
```

## Step 4: AI Engagement Bot
**Tool:** Mastodon bot using Mastodon.py or custom API script

### Runs on a schedule:
| Time | Action |
|------|--------|
| 6:00am | Scan home timeline, boost 3-5 relevant posts from local SD accounts |
| 12:00pm | Reply to any mentions/replies from the morning (draft responses) |
| 5:00pm | Boost 2-3 more posts, follow any new accounts that interacted with you |
| 9:00pm | Compile daily stats, log to engagement_tracker.csv |

### Engagement Rules:
1. **Auto-boost:** Posts from accounts you follow that mention SD locations, outdoor activities, or community events
2. **Auto-reply drafts:** AI drafts replies to mentions — you approve in a weekly batch (Sunday)
3. **Auto-follow-back:** Follow anyone who follows you AND has posted about SD/outdoors in last 30 days
4. **Never auto-reply to:** DMs, controversial topics, anything political
5. **Rate limits:** Max 10 boosts/day, max 5 follows/day, max 10 replies/day (avoid looking like a bot)

## Step 5: Weekly Review (Sunday — You)
This is the only time you touch Mastodon directly. 15 minutes max.

1. Open engagement_tracker.csv — see what worked this week
2. Approve/edit AI-drafted replies (if any flagged for review)
3. Glance at follower growth and top posts
4. Adjust nothing unless something is clearly broken

## Tech Stack Options

### Minimal (Start Here):
- **Photo sync:** Google Photos auto-backup → Google Drive folder
- **Scheduling:** Buffer or Mastodon's built-in scheduled posts
- **Captions:** Manually type on phone before bed (skip AI for now)
- **Engagement:** Mastodon native notifications, check Sunday only

### Intermediate:
- **Photo sync:** Syncthing to a home server or VPS
- **Scheduling:** Mastodon API + cron job
- **Captions:** Claude API script reads photos, generates captions
- **Engagement:** Mastodon.py bot on cron schedule

### Full Automation:
- **Photo sync:** Nextcloud with auto-upload
- **Scheduling:** Custom pipeline (Python script on VPS)
- **Captions:** Claude API with vision, reads photo + EXIF + schedule context
- **Engagement:** Full Mastodon bot with boost/reply/follow logic
- **Analytics:** Auto-log to engagement_tracker.csv via Mastodon API stats

## Getting Started Checklist
- [ ] Set up holm.community Mastodon instance (done)
- [ ] Enable phone auto-upload to cloud folder
- [ ] Create Mastodon API app token (Settings → Development → New Application)
- [ ] Write initial post scheduling script (even a simple cron + curl)
- [ ] Set up engagement bot with boost-only rules (safest to start)
- [ ] Run for 2 weeks on minimal, then add caption generation
- [ ] Run for 4 weeks, then add auto-reply drafts
- [ ] Review engagement_tracker.csv monthly, adjust
