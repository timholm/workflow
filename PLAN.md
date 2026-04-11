# TimVoice System Plan: Apple Watch + Full Architecture

## The Roles

- **Watch** = The Ally. Rewards you for staying off the phone. Positive haptics, encouragement, health tracking.
- **Phone** = The Enemy. Punishes every pickup. Taunts, red screen, shame.
- **MacBook** = The Spy. Silent 24/7 surveillance of screen, camera, mic, app usage.
- **Printer** = The Oracle. Synthesizes everything into paper truth.

---

## Phase 1: Foundation (App Group + WatchConnectivity)

### Modify existing files first:

1. **`GameEngine.swift`** — Replace `UserDefaults.standard` with `UserDefaults(suiteName: "group.community.holm.timvoice")`. This is prerequisite for everything — enables Watch to read pickups, streak, TIME ALIVE.
2. **`ServerSync.swift`** — Same App Group migration for deviceId storage.
3. **`Info.plist`** — Add App Group capability and `remote-notification` background mode.

### New shared models:

4. **`ios/TimVoice/TimVoice/Models/SharedGameState.swift`** — Codable struct of full game state for Watch transfer:
   - pickupsToday, currentStreak, longestStreak, timeAliveSeconds
   - currentTaunt, activeChallenge, screenTimeThisSession

### New iPhone-side connectivity:

5. **`ios/TimVoice/TimVoice/Sync/PhoneSessionManager.swift`** — iPhone WCSession counterpart:
   - Push game state updates to Watch via `updateApplicationContext`
   - Receive health data from Watch via `didReceiveUserInfo`
   - Receive challenge completions via `sendMessage`
   - Receive Watch mic audio via `didReceive(_:)` file transfer → route to AudioPipeline

### New Watch app entry point:

6. **`ios/TimVoice/TimVoiceWatch/TimVoiceWatchApp.swift`** — @main, initializes WatchSessionManager, renders WatchGameFaceView

### New Watch connectivity:

7. **`ios/TimVoice/TimVoiceWatchExtension/Connectivity/WatchSessionManager.swift`** — Central hub:
   - Receives game state from iPhone via `updateApplicationContext`
   - Sends health data batches to iPhone via `transferUserInfo` (every 15 min)
   - Sends challenge completions via `sendMessage`
   - Sends Watch mic recordings via `transferFile`
   - Monitors `WCSession.isReachable` — when phone is far away, Watch says "PHONE IS FAR AWAY — KEEP GOING"

### New Watch game engine:

8. **`ios/TimVoice/TimVoiceWatchExtension/Game/WatchGameEngine.swift`** — NOT a copy of GameEngine. The Watch does not detect pickups. Instead:
   - Receives GameStateTransfer and publishes for SwiftUI
   - Manages **reward haptics** (inverse of phone punishment):
     - Every 30 min off-phone: gentle success tap + "30 minutes alive. Your brain is healing."
     - Streak milestones (3, 7, 14, 30 days): extended celebratory haptic
   - Tracks "phone distance" — longer the phone is unreachable, more positive the Watch becomes

### New Watch UI:

9. **`ios/TimVoice/TimVoiceWatchExtension/Views/WatchGameFaceView.swift`** — Main view:
   - Green-to-blue gradient (opposite of phone's black-to-red)
   - TIME ALIVE in large monospaced type
   - Current streak
   - Live heart rate
   - Encouragement: "You're doing it.", "This is what being present feels like."

**End of Phase 1:** Watch displays TIME ALIVE and streak, updated live from the phone. Reward haptics working.

---

## Phase 2: Game Integration (Challenges + Notifications)

10. **Modify `GameEngine.swift`** — Push state after every pickup/putdown/taunt/challenge to Watch via PhoneSessionManager.
11. **`ios/TimVoice/TimVoiceWatchExtension/Views/WatchChallengeView.swift`** — Challenge display with "I DID IT" button. For physical challenges, shows live heart rate to validate effort.
12. **`ios/TimVoice/TimVoiceWatchExtension/Notifications/WatchNotificationHandler.swift`** — Haptic notifications:
    - `pickup_taunt`: Watch buzzes with sinking-feeling haptic, shows taunt
    - `challenge_issued`: notification with START button
    - `streak_update`: celebratory haptics on milestones
    - `time_alive_milestone`: success tap at 1hr, 2hr, 4hr, 8hr
    - `morning_brief_ready`: tap when paper is printing at 6am
13. **`ios/TimVoice/TimVoiceWatchExtension/Views/WatchHealthView.swift`** — Steps, HR trend, sleep summary, workout count.

**End of Phase 2:** Watch is a fully functioning game ally with challenge completion from the wrist.

---

## Phase 3: Health Data Pipeline

14. **`ios/TimVoice/TimVoiceWatchExtension/Health/HealthDataCollector.swift`** — HealthKit queries:
    - Heart rate via `HKObserverQuery` + background delivery
    - Steps via `HKStatisticsQuery` (refreshed every 5 min)
    - Sleep analysis from `HKCategoryType.sleepAnalysis`
    - Workout detection via `HKWorkoutType` observer (auto TIME ALIVE bonus)
    - Active energy, standing hours

15. **Modify `ServerSync.swift`** — Add `syncHealthData()` method, post to new server endpoint.

16. **Modify `server/ingest/app.py`** — New `POST /api/ingest/health` endpoint.

17. **Modify `server/print_jobs/printer.py`** — Health sections in all briefs:

**Morning brief adds:**
```
── LAST NIGHT'S SLEEP ─────────────────────────────────
  Total: 7h 42m (10:48pm → 6:30am)
  Deep sleep: 2h 05m
  Resting heart rate: 56 bpm

── YESTERDAY'S BODY ───────────────────────────────────
  Steps: 8,234
  Active energy: 412 kcal
  Workouts: 1 (30min run, 287 kcal)
```

**Weekly review adds:**
```
── SCREENLESS CORRELATION ─────────────────────────────
  Days with < 20 pickups: avg sleep 7h 31m
  Days with > 40 pickups: avg sleep 5h 52m
  Resting HR since starting streak: 62 → 56 bpm
  The data doesn't lie. Keep going.
```

**End of Phase 3:** Printed briefs include sleep, steps, heart rate, and screen-health correlations.

---

## Phase 4: Watch Mic + Complications

18. **`ios/TimVoice/TimVoiceWatchExtension/Audio/WatchMicRecorder.swift`** — Records when iPhone is far away:
    - Uses `WKExtendedRuntimeSession` for background recording (~30 min sessions)
    - 16kHz mono PCM matching iPhone pipeline format
    - ~50MB local buffer, transfers to iPhone via `transferFile` for processing
    - Fills the gap when phone is in the car/another room

19. **`ios/TimVoice/TimVoiceWatchExtension/Runtime/ExtendedSessionManager.swift`** — Manages extended runtime for mic recording, HR during challenges, mindfulness timers.

20. **`ios/TimVoice/TimVoiceWatchExtension/Complications/TimVoiceComplicationProvider.swift`** — Watch face complications:
    - **TIME ALIVE**: `HH:MM` off-phone time (the centerpiece of the watch face)
    - **Streak**: current streak number with color gauge
    - **Pickup count**: the one piece of quiet shame on the wrist

21. **`server/categorize/health_insights.py`** — Claude-powered correlations between health and phone usage.

22. **`ios/TimVoice/TimVoiceWatchExtension/Info.plist`** — HealthKit entitlements, mic usage, background modes.

**End of Phase 4:** Full system operational.

---

## Data Flow

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

## Complete File Inventory

### New Watch Files (12)
1. `ios/TimVoice/TimVoiceWatch/TimVoiceWatchApp.swift`
2. `ios/TimVoice/TimVoiceWatchExtension/Connectivity/WatchSessionManager.swift`
3. `ios/TimVoice/TimVoiceWatchExtension/Game/WatchGameEngine.swift`
4. `ios/TimVoice/TimVoiceWatchExtension/Health/HealthDataCollector.swift`
5. `ios/TimVoice/TimVoiceWatchExtension/Audio/WatchMicRecorder.swift`
6. `ios/TimVoice/TimVoiceWatchExtension/Views/WatchGameFaceView.swift`
7. `ios/TimVoice/TimVoiceWatchExtension/Views/WatchHealthView.swift`
8. `ios/TimVoice/TimVoiceWatchExtension/Views/WatchChallengeView.swift`
9. `ios/TimVoice/TimVoiceWatchExtension/Complications/TimVoiceComplicationProvider.swift`
10. `ios/TimVoice/TimVoiceWatchExtension/Notifications/WatchNotificationHandler.swift`
11. `ios/TimVoice/TimVoiceWatchExtension/Runtime/ExtendedSessionManager.swift`
12. `ios/TimVoice/TimVoiceWatchExtension/Info.plist`

### New iPhone Files (2)
13. `ios/TimVoice/TimVoice/Sync/PhoneSessionManager.swift`
14. `ios/TimVoice/TimVoice/Models/SharedGameState.swift`

### Modified iPhone Files (4)
15. `ios/TimVoice/TimVoice/App/GameEngine.swift`
16. `ios/TimVoice/TimVoice/Sync/ServerSync.swift`
17. `ios/TimVoice/TimVoice/Info.plist`
18. `ios/TimVoice/TimVoice/App/TimVoiceApp.swift`

### Server Changes (3)
19. `server/ingest/app.py` (new health endpoint)
20. `server/print_jobs/printer.py` (health sections in briefs)
21. `server/categorize/health_insights.py` (new — Claude health correlations)

### New File Total: 15 | Modified: 7 | Grand Total: 22
