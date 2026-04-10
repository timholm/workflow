"""
TimVoice macOS Daemon — runs in the background capturing everything.

Captures:
1. Screen — periodic screenshots + OCR to understand what Tim is doing
2. Mic — continuous audio, same voice-only pipeline as iOS
3. Camera — periodic snapshots for visual context
4. Active window — tracks what app/site Tim is using

All processing is local. Only summaries sync to the server.
"""

import os
import sys
import time
import json
import signal
import threading
import subprocess
from datetime import datetime, date
from pathlib import Path

# Screen capture
try:
    import Quartz
    from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID
    HAS_QUARTZ = True
except ImportError:
    HAS_QUARTZ = False

# Audio
try:
    import pyaudio
    import numpy as np
    HAS_AUDIO = True
except ImportError:
    HAS_AUDIO = False

# OCR
try:
    import Vision
    HAS_VISION = True
except ImportError:
    HAS_VISION = False


SERVER_URL = os.environ.get("TIMVOICE_SERVER", "http://localhost:8080")
DATA_DIR = Path(os.environ.get("TIMVOICE_MAC_DATA", str(Path.home() / ".timvoice")))
DATA_DIR.mkdir(parents=True, exist_ok=True)

SCREEN_INTERVAL = 30       # screenshot every 30 seconds
CAMERA_INTERVAL = 300      # camera snapshot every 5 minutes
AUDIO_CHUNK_SECONDS = 30   # audio chunks same as iOS


class ScreenCapture(threading.Thread):
    """Captures screenshots and extracts text via OCR."""

    def __init__(self):
        super().__init__(daemon=True)
        self.running = True
        self.output_dir = DATA_DIR / "screens"
        self.output_dir.mkdir(exist_ok=True)

    def run(self):
        while self.running:
            try:
                self.capture()
            except Exception as e:
                print(f"[Screen] Error: {e}")
            time.sleep(SCREEN_INTERVAL)

    def capture(self):
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filepath = self.output_dir / f"screen_{timestamp}.png"

        # Use macOS screencapture command (works without extra deps)
        subprocess.run(
            ["screencapture", "-x", "-C", str(filepath)],
            capture_output=True,
        )

        # Get active window info
        active_app = self._get_active_app()

        # OCR the screenshot
        text = self._ocr_image(filepath)

        # Save metadata
        meta = {
            "timestamp": datetime.now().isoformat(),
            "active_app": active_app,
            "ocr_text": text[:2000] if text else "",
            "screenshot": str(filepath),
        }

        meta_file = DATA_DIR / f"screen_log_{date.today().isoformat()}.jsonl"
        with open(meta_file, "a") as f:
            f.write(json.dumps(meta) + "\n")

        # Delete screenshot after OCR (keep only text)
        filepath.unlink(missing_ok=True)

    def _get_active_app(self) -> str:
        """Get the currently active application name."""
        try:
            result = subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to get name of first application process whose frontmost is true'],
                capture_output=True, text=True,
            )
            return result.stdout.strip()
        except Exception:
            return "unknown"

    def _ocr_image(self, filepath: Path) -> str:
        """Extract text from screenshot using macOS Vision framework or tesseract."""
        # Try macOS shortcuts (available on macOS 12+)
        try:
            result = subprocess.run(
                ["shortcuts", "run", "OCR Screenshot",
                 "-i", str(filepath)],
                capture_output=True, text=True, timeout=10,
            )
            if result.stdout.strip():
                return result.stdout.strip()
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

        # Fallback: use tesseract if installed
        try:
            result = subprocess.run(
                ["tesseract", str(filepath), "stdout"],
                capture_output=True, text=True, timeout=10,
            )
            return result.stdout.strip()
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

        return ""

    def stop(self):
        self.running = False


class ActiveWindowTracker(threading.Thread):
    """Tracks which app and window Tim is using, logging transitions."""

    def __init__(self):
        super().__init__(daemon=True)
        self.running = True
        self.last_app = ""
        self.last_change = datetime.now()

    def run(self):
        while self.running:
            try:
                current = self._get_active_app()
                if current != self.last_app and current:
                    duration = (datetime.now() - self.last_change).total_seconds()
                    self._log_transition(self.last_app, current, duration)
                    self.last_app = current
                    self.last_change = datetime.now()
            except Exception as e:
                print(f"[WindowTracker] Error: {e}")
            time.sleep(2)  # check every 2 seconds

    def _get_active_app(self) -> str:
        try:
            result = subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to get name of first application process whose frontmost is true'],
                capture_output=True, text=True, timeout=5,
            )
            return result.stdout.strip()
        except Exception:
            return ""

    def _log_transition(self, from_app: str, to_app: str, duration: float):
        entry = {
            "timestamp": datetime.now().isoformat(),
            "from_app": from_app,
            "to_app": to_app,
            "duration_seconds": round(duration, 1),
        }

        log_file = DATA_DIR / f"app_log_{date.today().isoformat()}.jsonl"
        with open(log_file, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def stop(self):
        self.running = False


class MicCapture(threading.Thread):
    """Continuous microphone recording with the same voice-only pipeline as iOS."""

    def __init__(self):
        super().__init__(daemon=True)
        self.running = True
        self.sample_rate = 16000
        self.chunk_size = 1024

    def run(self):
        if not HAS_AUDIO:
            print("[Mic] pyaudio not installed. Mic capture disabled.")
            return

        pa = pyaudio.PyAudio()
        stream = pa.open(
            format=pyaudio.paInt16,
            channels=1,
            rate=self.sample_rate,
            input=True,
            frames_per_buffer=self.chunk_size,
        )

        print("[Mic] Recording started")
        frames = []
        chunk_start = datetime.now()

        while self.running:
            try:
                data = stream.read(self.chunk_size, exception_on_overflow=False)
                frames.append(data)

                elapsed = (datetime.now() - chunk_start).total_seconds()
                if elapsed >= AUDIO_CHUNK_SECONDS:
                    audio_data = b"".join(frames)
                    self._process_chunk(audio_data, chunk_start)
                    frames = []
                    chunk_start = datetime.now()

            except Exception as e:
                print(f"[Mic] Error: {e}")
                time.sleep(1)

        stream.stop_stream()
        stream.close()
        pa.terminate()

    def _process_chunk(self, audio_data: bytes, start_time: datetime):
        """Process audio chunk — same pipeline as iOS.
        TODO: integrate speaker identification from the iOS voiceprint."""
        chunk_file = DATA_DIR / "audio_chunks" / f"chunk_{start_time.strftime('%Y%m%d_%H%M%S')}.pcm"
        chunk_file.parent.mkdir(exist_ok=True)
        chunk_file.write_bytes(audio_data)

        # For now, queue for server-side processing
        # Once speaker ID is ported to Python, it runs locally
        meta = {
            "timestamp": start_time.isoformat(),
            "duration_seconds": AUDIO_CHUNK_SECONDS,
            "sample_rate": self.sample_rate,
            "file": str(chunk_file),
            "source": "macbook_mic",
        }

        log_file = DATA_DIR / f"audio_log_{date.today().isoformat()}.jsonl"
        with open(log_file, "a") as f:
            f.write(json.dumps(meta) + "\n")

    def stop(self):
        self.running = False


class CameraCapture(threading.Thread):
    """Periodic camera snapshots for visual context."""

    def __init__(self):
        super().__init__(daemon=True)
        self.running = True
        self.output_dir = DATA_DIR / "camera"
        self.output_dir.mkdir(exist_ok=True)

    def run(self):
        while self.running:
            try:
                self.capture()
            except Exception as e:
                print(f"[Camera] Error: {e}")
            time.sleep(CAMERA_INTERVAL)

    def capture(self):
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filepath = self.output_dir / f"cam_{timestamp}.jpg"

        # Use imagesnap (brew install imagesnap) or ffmpeg
        try:
            subprocess.run(
                ["imagesnap", "-q", str(filepath)],
                capture_output=True, timeout=10,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            # Fallback to ffmpeg
            try:
                subprocess.run(
                    ["ffmpeg", "-f", "avfoundation", "-framerate", "1",
                     "-i", "0", "-frames:v", "1", "-y", str(filepath)],
                    capture_output=True, timeout=10,
                )
            except (FileNotFoundError, subprocess.TimeoutExpired):
                return

        if filepath.exists():
            meta = {
                "timestamp": datetime.now().isoformat(),
                "file": str(filepath),
                "source": "macbook_camera",
            }
            log_file = DATA_DIR / f"camera_log_{date.today().isoformat()}.jsonl"
            with open(log_file, "a") as f:
                f.write(json.dumps(meta) + "\n")

    def stop(self):
        self.running = False


class TimVoiceDaemon:
    """Main daemon that orchestrates all capture threads."""

    def __init__(self):
        self.threads = []
        self.running = True

    def start(self):
        print("=" * 50)
        print("  TimVoice macOS Daemon")
        print(f"  Data: {DATA_DIR}")
        print(f"  Server: {SERVER_URL}")
        print("=" * 50)

        # Start all capture threads
        screen = ScreenCapture()
        window = ActiveWindowTracker()
        mic = MicCapture()
        camera = CameraCapture()

        self.threads = [screen, window, mic, camera]
        for t in self.threads:
            t.start()
            print(f"  ✓ {t.__class__.__name__} started")

        print("\nDaemon running. Ctrl+C to stop.\n")

        # Handle graceful shutdown
        signal.signal(signal.SIGINT, self._shutdown)
        signal.signal(signal.SIGTERM, self._shutdown)

        # Keep main thread alive
        while self.running:
            time.sleep(1)

    def _shutdown(self, signum, frame):
        print("\nShutting down...")
        self.running = False
        for t in self.threads:
            t.stop()
        print("Done.")
        sys.exit(0)


if __name__ == "__main__":
    daemon = TimVoiceDaemon()
    daemon.start()
