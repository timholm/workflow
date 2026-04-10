# TimVoice macOS Daemon

Background service that continuously captures:
- Screen recordings (periodic screenshots + OCR)
- Microphone audio (same voice-only pipeline as iOS)
- Camera snapshots (periodic, for visual context)

All processing happens locally. Only Tim's voice and text summaries leave the machine.

## Setup

1. Grant permissions in System Settings → Privacy & Security:
   - Screen Recording
   - Microphone
   - Camera
   - Accessibility (for active window tracking)

2. Install dependencies:
   ```
   pip install -r requirements.txt
   ```

3. Run:
   ```
   python daemon.py
   ```

4. To install as a launch agent (runs at login):
   ```
   cp com.timvoice.daemon.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.timvoice.daemon.plist
   ```
