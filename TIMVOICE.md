# TimVoice — The Screenless Life System

**Owner:** Tim Holm (tim@holm.chat)
**Status:** Code complete, ready for device deployment

---

## The Vision

Eliminate all screens from daily life. AI captures everything 24/7 — voice, video, screen activity, health data — and delivers synthesized output on **printed paper briefs**. The phone becomes an adversarial game that punishes pickups. The Apple Watch becomes an ally that rewards staying present. Phone calls are the only acceptable digital interaction.

---

## The Roles

| Device | Role | Personality |
|--------|------|-------------|
| **iPhone** | The Enemy | Punishes every pickup. Taunts, red screen, shame. |
| **Apple Watch** | The Ally | Rewards time off-phone. Positive haptics, encouragement. |
| **MacBook** | The Spy | Silent 24/7 surveillance of screen, camera, mic, apps. |
| **Printer** | The Oracle | Synthesizes everything into paper truth. |

---

## System Architecture

```
APPLE WATCH                        iPHONE                         SERVER → PRINTER
───────────                        ──────                         ────────────────

HealthKit ──→ HealthDataCollector
  heart rate    │
  steps         │
  sleep         ├─ transferUserInfo ──→ PhoneSessionManager
  workouts      │   (health batches)     │
                │                        ├──→ ServerSync ──→ /api/ingest
WatchMicRecorder│                        │                  /api/ingest/health
  (phone far    ├─ transferFile ──────→ AudioPipeline
   away)        │   (audio chunks)       │ VAD → SpeakerID → Transcribe
                │                        │
WatchGameEngine ←── updateAppContext ───┤
  TIME ALIVE    │                        │ GameStateTransfer       Categorizer
  streak        │                        │                            │
  encouragement │                        │                       PrintJobGenerator
                │                        │                            │
  haptics ←─────┤                        │                      ┌─────┴─────┐
  (reward)      │                        │                      │  PRINTER  │
                │                        │                      │  6am/2pm  │
  "DONE" ───────┼─ sendMessage ───────→ completeChallenge()     │  Sunday   │
                │                                               └───────────┘
Complications ──┤
  TIME ALIVE    │  reads shared UserDefaults (App Group)
  streak        │
  pickups       │
```

---

## Key Technical Decisions

### Legal Compliance (California Two-Party Consent)
Only Tim's voice is transcribed and kept. All other voices are identified via speaker diarization and **hard-deleted on-device** before any data leaves the phone. Speaker identification uses MFCC-based voiceprint matching (192-dimensional embeddings, cosine similarity threshold 0.75).

### 24/7 Background Recording on iOS
iOS kills background apps aggressively. The workaround: `AVAudioSession` configured as `.playAndRecord` with a silent `AVAudioPlayer` loop (volume 0, infinite duration). This keeps the app alive indefinitely in background for continuous mic recording.

### No App Store — Direct Install via Xcode
Apple would reject a 24/7 background recording app. Solution: install directly via Xcode with a paid Apple Developer account ($99/year). The app stays permanently on the device with no review process.

### Camera Limitation on iOS
iOS hard-blocks camera access when the app is backgrounded. No workaround exists. The mic runs 24/7 via the silent audio trick; camera only captures frames when the app is in foreground (1 frame per 5 seconds). For true 24/7 video, a wearable camera would be needed.

### XcodeGen Instead of Raw pbxproj
Xcode project files (.pbxproj) are 1000+ lines of UUID references. Instead, a compact `project.yml` spec file generates the project automatically via `xcodegen generate`.

---

## iPhone App

### Entry Point
**`TimVoice/App/TimVoiceApp.swift`** — Shows `EnrollmentView` until voice profile is created, then `GameView`. Starts `AudioManager`, `AudioPipeline`, `CameraManager`, and `PhoneSessionManager` on appear.

### The Game
**`TimVoice/App/GameEngine.swift`** — Core adversarial game logic:
- Tracks phone pickups via `UIApplication.didBecomeActiveNotification`
- Calculates TIME ALIVE (seconds without touching the phone)
- Maintains streaks (consecutive days under pickup threshold)
- Escalating taunts: "Oh. You again." → "You are choosing pixels over reality."
- Issues challenges to put the phone down ("Walk outside for 5 minutes")
- Pushes game state to Watch via `PhoneSessionManager.pushGameState()`
- Uses App Group UserDefaults (`group.community.holm.timvoice`) for Watch sharing

**`TimVoice/App/GameView.swift`** — Adversarial UI:
- Background gradient: black → red based on screen time duration
- Large TIME ALIVE counter (monospaced)
- Escalating taunt text
- Pickup shame counter
- Challenge cards with timer
- Streak display with color coding

### Voice Pipeline

**`TimVoice/Audio/AudioManager.swift`** — 24/7 background mic recording:
- `AVAudioEngine` taps raw audio at 16kHz mono 16-bit PCM
- Silent `AVAudioPlayer` loop keeps the app alive in background
- 30-second chunks written to disk
- Handles audio session interruptions (phone calls, Siri)

**`TimVoice/Voice/VoiceProfileManager.swift`** — Voice enrollment:
- 5 speech samples recorded during enrollment
- Averaged into a single voiceprint (binary file)
- Speaker verification via cosine similarity (threshold 0.75)

**`TimVoice/Voice/SpeakerEncoder.swift`** — MFCC extraction pipeline:
- Pre-emphasis → Hamming window → FFT → mel filterbank → DCT → MFCCs
- Aggregated to 192-dimensional embedding (mean + std + delta + polynomial features)
- L2 normalized for cosine similarity comparison

**`TimVoice/Transcription/TranscriptionEngine.swift`** — On-device speech-to-text:
- Apple's `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`
- No audio data leaves the device for transcription
- Converts raw PCM to WAV format for Speech framework

**`TimVoice/Pipeline/AudioPipeline.swift`** — Orchestration:
1. Audio chunk arrives (from mic or Watch)
2. VAD (energy-based RMS threshold) identifies speech segments
3. Speaker encoder creates embedding for each segment
4. Cosine similarity against Tim's voiceprint
5. Tim's segments → on-device transcription
6. Non-Tim segments → **deleted immediately**
7. Transcriptions → local JSON-lines storage
8. Server sync when connected

### Camera
**`TimVoice/Audio/CameraManager.swift`** — Foreground-only camera capture:
- `AVCaptureSession` with `AVCapturePhotoOutput`
- 1 frame every 5 seconds when app is in foreground
- iOS blocks camera in background (no workaround)

### Data & Sync
**`TimVoice/Models/AudioChunk.swift`** — Core data types: `AudioChunk`, `SpeakerSegment`, `TranscriptionSegment`, `SegmentCategory` enum (task, calendar, journal, email, shopping, note, conversation, discard)

**`TimVoice/Models/TranscriptionStore.swift`** — JSON-lines local storage organized by date, with sync tracking

**`TimVoice/Models/SharedGameState.swift`** — All Codable transfer types for Watch communication:
- `SharedGameState`, `ChallengeTransfer`, `HealthDataTransfer`
- `HeartRateSample`, `SleepSummary`, `WorkoutSummary`
- All have `toDictionary()` / `from(dictionary:)` convenience methods

**`TimVoice/Sync/ServerSync.swift`** — Syncs data to server:
- `POST /api/ingest` — transcription segments
- `POST /api/ingest/health` — Watch health data
- `POST /api/ingest/game` — game state snapshots
- Uses App Group UserDefaults with legacy migration for deviceId

**`TimVoice/Sync/PhoneSessionManager.swift`** — iPhone-side WCSession delegate:
- Pushes game state to Watch via `updateApplicationContext`
- Receives health data via `didReceiveUserInfo` → routes to ServerSync
- Receives challenge completions via `didReceiveMessage` → calls `GameEngine.completeChallenge()`
- Receives Watch audio files via `didReceive` → routes to `AudioPipeline.processWatchAudio()`

### Enrollment
**`TimVoice/App/EnrollmentView.swift`** — 5-step voice enrollment UI with recording prompts. Creates the voiceprint that the system uses to identify Tim forever after.

---

## Apple Watch App

### The Ally — Opposite of the Phone

The Watch is **not a copy of the phone's game**. It's the inverse. Where the phone punishes, the Watch rewards.

**`TimVoiceWatchExtension/Game/WatchGameEngine.swift`**:
- Receives `SharedGameState` from iPhone
- Reward haptics every 30 min off-phone: `.success` tap + "30 minutes alive. Your brain is healing."
- Streak milestones (3, 7, 14, 30 days): extended celebratory haptic
- Encouragement messages: "You're doing it.", "Phone is far away. This is freedom."
- Tracks phone distance — longer the phone is unreachable, more positive the Watch becomes

### Views

**`TimVoiceWatchExtension/Views/WatchGameFaceView.swift`** — Main Watch face:
- Green-to-blue gradient (opposite of phone's black-to-red)
- TIME ALIVE in large monospaced type
- Current streak with color coding
- Encouragement text
- Challenge card with DONE button
- Pickup counter at bottom

**`TimVoiceWatchExtension/Views/WatchChallengeView.swift`**:
- Challenge display with "I DID IT" button
- Live heart rate for physical challenges
- Countdown timer for mindfulness challenges
- Skip option with shame text

**`TimVoiceWatchExtension/Views/WatchHealthView.swift`**:
- Steps progress ring (10k goal)
- Heart rate display
- Active energy
- Sleep summary
- Workout count

### Health Data Collection

**`TimVoiceWatchExtension/Health/HealthDataCollector.swift`** — HealthKit queries:
- Heart rate: `HKAnchoredObjectQuery` with background delivery
- Steps: `HKStatisticsQuery` refreshed every 5 minutes
- Sleep: `HKCategoryType.sleepAnalysis`
- Workouts: `HKObserverQuery` (auto TIME ALIVE bonus for exercise)
- Active energy, standing hours
- `collectBatch()` → `HealthDataTransfer`
- 15-minute timer flushes batches to `WatchSessionManager`

### Watch Mic Recording

**`TimVoiceWatchExtension/Audio/WatchMicRecorder.swift`**:
- Records via `AVAudioEngine` when iPhone is far away
- 16kHz mono PCM, 30-second chunks (matches iPhone format)
- 50MB local buffer with auto-prune
- Transfers to iPhone via `WatchSessionManager.sendAudioFile()`

### Watch Face Complications

**`TimVoiceWatchExtension/Complications/TimVoiceComplicationProvider.swift`** — WidgetKit (watchOS 10+):
- **TIME ALIVE**: `accessoryCircular` gauge showing hours off-phone
- **Streak**: `accessoryCorner` with color gauge (red→green)
- **Pickup Count**: `accessoryInline` showing today's pickups
- Reads from shared UserDefaults, refreshes every 5 minutes

### Notifications

**`TimVoiceWatchExtension/Notifications/WatchNotificationHandler.swift`**:
- `pickup_taunt`: `.directionDown` haptic + taunt text
- `challenge_issued`: `.notification` haptic + START action button
- `streak_update`: repeated `.success` haptics on milestones
- `time_alive_milestone`: `.success` at 1hr, 2hr, 4hr, 8hr marks
- `morning_brief_ready`: `.click` when paper is printing at 6am
- `health_insight`: health-related notifications

### Runtime Sessions

**`TimVoiceWatchExtension/Runtime/ExtendedSessionManager.swift`**:
- `WKExtendedRuntimeSession` management for mic recording, HR monitoring, mindfulness timers
- Reason-based multi-session with auto-renewal
- Keeps Watch recording even when the screen is off

### Connectivity

**`TimVoiceWatchExtension/Connectivity/WatchSessionManager.swift`** — Central Watch hub:
- Receives game state via `didReceiveApplicationContext` → pushes to `WatchGameEngine`
- Sends health data batches every 15 min via `transferUserInfo` (FIFO guaranteed)
- Sends challenge completions via `sendMessage`
- Sends audio files via `transferFile`
- Monitors `WCSession.isReachable` → publishes `isPhoneFarAway`
- Falls back to shared UserDefaults when phone is unreachable

---

## MacBook Daemon

**`macos/daemon.py`** — 24/7 continuous recording with 5 threads:

| Thread | What It Records | Details |
|--------|----------------|---------|
| `ContinuousScreenRecorder` | Screen video | ffmpeg 2fps, 1-min segments → keyframe extraction → OCR via tesseract → delete raw video |
| `ContinuousCameraRecorder` | Camera video | ffmpeg 1fps, 1-min segments → frame extraction → scene description → delete raw video |
| `ContinuousMicRecorder` | Microphone audio | ffmpeg 16kHz WAV, 30-sec chunks (same format as iOS) |
| `ActiveWindowTracker` | App/window switches | App name + window title + duration, logged every 2 seconds |
| `StorageManager` | Disk usage | Auto-prunes at 50GB, deletes oldest media files first |

**`macos/com.timvoice.daemon.plist`** — macOS Launch Agent config: `RunAtLoad`, `KeepAlive` — starts automatically at login, restarts if killed.

### macOS Permissions Required
- Screen Recording (System Settings → Privacy & Security)
- Microphone
- Camera
- Accessibility (for active window tracking)

---

## Server

### API Endpoints

**`server/ingest/app.py`** — Flask application:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/ingest` | POST | Receive transcription segments from devices |
| `/api/ingest/health` | POST | Receive batched health data from Watch (via iPhone) |
| `/api/ingest/game` | POST | Receive game state snapshots |
| `/api/briefs/morning` | GET | Generate morning brief content |
| `/api/briefs/afternoon` | GET | Generate afternoon brief content |
| `/api/print/morning` | POST | Trigger morning print job |
| `/api/print/afternoon` | POST | Trigger afternoon print job |
| `/api/print/weekly` | POST | Generate and print weekly review |

### Scheduled Print Jobs (APScheduler)
- **6:00am** — Morning brief prints automatically
- **2:00pm** — Afternoon update prints automatically
- **Sunday 8:00am** — Weekly review prints automatically

### AI Categorization

**`server/categorize/categorizer.py`** — Claude API categorization:

Every transcription segment Tim speaks gets categorized into:
| Category | Example | Action |
|----------|---------|--------|
| `task` | "Call Mike about the truck" | Added to task list on next print |
| `calendar` | "Cancel Thursday evening" | Calendar action queued |
| `journal` | "Feeling good about the garden" | Goes to journal section |
| `email` | "Reply to Sarah, tell her yes" | Draft email generated |
| `shopping` | "Buy more 5-gallon buckets" | Added to shopping list |
| `note` | General thought worth keeping | Stored for reference |
| `conversation` | Tim's side of a conversation | Context for the model |
| `discard` | Filler, background noise | Deleted |

### Health Insights

**`server/categorize/health_insights.py`** — Claude-powered correlations:
- Analyzes week of health data alongside phone usage data
- Finds real correlations (e.g., "Days with < 20 pickups: avg sleep 7h 31m")
- Falls back to local statistical computation when Claude API is unavailable
- Generates `sleep_pickup_summary`, `correlations`, `weekly_insight`, `best_day`, `worst_day`

### Printed Briefs

**`server/print_jobs/printer.py`** — Generates formatted plain text, prints via CUPS `lp` command:

**Morning Brief (6:00am):**
- Tasks captured yesterday/overnight
- Calendar changes
- Emails to send
- Shopping list
- Journal thoughts
- Last night's sleep (total, deep, resting HR)
- Yesterday's body (steps, energy, workouts)
- The Game (pickups, TIME ALIVE, streak)

**Afternoon Update (2:00pm):**
- New tasks since morning
- Pending emails
- Updated shopping list
- Today so far (steps with projected pace, avg HR, pickups)

**Weekly Review (Sunday 8:00am):**
- Segment stats by category
- People mentioned most
- Journal highlights
- Body report (avg steps, resting HR, workouts, sleep)
- Screenless correlation (sleep quality vs pickup count)
- Claude-generated weekly insight

---

## Complete File Inventory

### iPhone App (17 files)
```
ios/TimVoice/TimVoice/
├── App/
│   ├── TimVoiceApp.swift          — Entry point, app lifecycle
│   ├── GameEngine.swift           — Adversarial game logic
│   ├── GameView.swift             — Red/black adversarial UI
│   ├── EnrollmentView.swift       — 5-step voice enrollment
│   └── DashboardView.swift        — Legacy dashboard
├── Audio/
│   ├── AudioManager.swift         — 24/7 background mic recording
│   ├── AudioChunkWriter.swift     — Chunk persistence + recovery
│   └── CameraManager.swift        — Foreground camera capture
├── Voice/
│   ├── VoiceProfileManager.swift  — Enrollment + verification
│   └── SpeakerEncoder.swift       — MFCC → 192-dim embedding
├── Transcription/
│   └── TranscriptionEngine.swift  — On-device SFSpeechRecognizer
├── Pipeline/
│   └── AudioPipeline.swift        — VAD → SpeakerID → Transcribe → Store
├── Models/
│   ├── AudioChunk.swift           — Core audio data types
│   ├── SharedGameState.swift      — Watch transfer types
│   └── TranscriptionStore.swift   — JSON-lines local storage
└── Sync/
    ├── ServerSync.swift           — HTTP sync to server
    └── PhoneSessionManager.swift  — WCSession delegate (iPhone side)
```

### Watch App (1 file)
```
ios/TimVoice/TimVoiceWatch/
└── TimVoiceWatchApp.swift         — @main entry point
```

### Watch Extension (10 files)
```
ios/TimVoice/TimVoiceWatchExtension/
├── Connectivity/
│   └── WatchSessionManager.swift  — WCSession delegate (Watch side)
├── Game/
│   └── WatchGameEngine.swift      — The Ally: rewards, encouragement
├── Health/
│   └── HealthDataCollector.swift  — HealthKit queries + batching
├── Audio/
│   └── WatchMicRecorder.swift     — Records when iPhone is far away
├── Views/
│   ├── WatchGameFaceView.swift    — Green/blue ally UI
│   ├── WatchChallengeView.swift   — Challenge completion
│   └── WatchHealthView.swift      — Health dashboard
├── Complications/
│   └── TimVoiceComplicationProvider.swift — Watch face widgets
├── Notifications/
│   └── WatchNotificationHandler.swift    — Haptic notification categories
└── Runtime/
    └── ExtendedSessionManager.swift      — Background session management
```

### Configuration (6 files)
```
ios/TimVoice/
├── project.yml                                    — XcodeGen project spec
├── TimVoice/Info.plist                            — iPhone app config
├── TimVoice/TimVoice.entitlements                 — App Group entitlement
├── TimVoiceWatchExtension/Info.plist              — Watch extension config
└── TimVoiceWatchExtension/TimVoiceWatchExtension.entitlements — App Group + HealthKit
```

### Server (4 files)
```
server/
├── ingest/app.py                  — Flask API + scheduled jobs
├── categorize/categorizer.py      — Claude AI categorization
├── categorize/health_insights.py  — Claude health correlations
└── print_jobs/printer.py          — Brief generation + CUPS printing
```

### macOS Daemon (2 files)
```
macos/
├── daemon.py                      — 5-thread 24/7 recording daemon
└── com.timvoice.daemon.plist      — Launch Agent config
```

### Setup
```
setup.sh                           — One-command Mac setup script
```

**Total: 37 files** (28 Swift + 4 Python + 2 config plists + 1 YAML + 1 entitlements pair + 1 shell script)

---

## Setup Instructions

### Prerequisites
- Mac with Xcode installed
- Apple Developer account ($99/year) — required for HealthKit, background audio, Watch app
- iPhone + Apple Watch paired
- Physical printer connected to the Mac (or network printer)

### Step 1: Run Setup Script
```bash
cd /path/to/workflow
chmod +x setup.sh
./setup.sh
```

This installs XcodeGen, ffmpeg, tesseract, imagesnap, Python dependencies, generates the Xcode project, and opens it.

### Step 2: Configure Xcode Signing
1. Xcode → Settings → Accounts → Add your Apple ID
2. Click "TimVoice" project in navigator
3. For **each target** (TimVoice, TimVoiceWatch, TimVoiceWatchExtension):
   - Signing & Capabilities → Set Team to your developer account
   - Add capability: App Groups → `group.community.holm.timvoice`

### Step 3: Deploy to Devices
1. Plug in iPhone via USB
2. Select your iPhone from the device dropdown
3. Press Cmd+R (Run)
4. Watch app installs automatically via the paired Watch

### Step 4: Start Mac Daemon
```bash
python3 macos/daemon.py
```
Or install as Launch Agent for auto-start at login:
```bash
cp macos/com.timvoice.daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.timvoice.daemon.plist
```

### Step 5: Start Server
```bash
export ANTHROPIC_API_KEY='your-key'
export PRINTER_NAME=$(lpstat -d | awk '{print $NF}')
python3 server/ingest/app.py
```

---

## Data Flow Summary

1. **Tim speaks** → iPhone mic (24/7) or Watch mic (when phone is far away)
2. **VAD detects speech** → Speaker encoder creates voice embedding
3. **Voiceprint match?** → Tim's voice: transcribe on-device. Others: **delete immediately**
4. **Transcription** → Stored locally as JSON-lines, synced to server
5. **Claude categorizes** → task / calendar / journal / email / shopping / note / discard
6. **Health data flows** → Watch HealthKit → WatchSessionManager → PhoneSessionManager → Server
7. **Game state flows** → iPhone GameEngine → Watch (updateApplicationContext) + Server
8. **MacBook records** → Screen OCR + camera frames + mic + window tracking → Server
9. **Printer outputs** → Morning (6am), Afternoon (2pm), Weekly Review (Sunday 8am)
10. **Tim reads paper** → Lives life → Repeat

---

## Future Work
- Calendar API integration (Google Calendar / Apple Calendar)
- Email API integration (Gmail / Apple Mail)
- Claude Vision for camera frame analysis (macOS + iPhone foreground frames)
- Wearable camera integration for true 24/7 video
- 2TB iPhone data import pipeline
- Mastodon automation integration (see `ai_pipeline.md` and `content_strategy.md`)
