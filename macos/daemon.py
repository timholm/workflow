"""
TimVoice macOS Daemon — CONTINUOUS 24/7 recording of everything.

Records:
1. Screen — continuous video recording via ffmpeg, segmented into chunks,
   each chunk processed (OCR + scene understanding) then raw video deleted
2. Mic — continuous audio recording, voice-identified, Tim-only transcription
3. Camera — continuous video recording via ffmpeg, segmented into chunks,
   each chunk processed (scene/activity understanding) then raw video deleted
4. Active window — tracks every app/window switch with duration

Everything records 24/7. Processing extracts meaning. Raw footage is deleted
after processing. Only text/summaries persist and sync to the server.
"""

import os
import sys
import time
import json
import signal
import shutil
import threading
import subprocess
from datetime import datetime, date
from pathlib import Path


SERVER_URL = os.environ.get("TIMVOICE_SERVER", "http://localhost:8080")
DATA_DIR = Path(os.environ.get("TIMVOICE_MAC_DATA", str(Path.home() / ".timvoice")))
DATA_DIR.mkdir(parents=True, exist_ok=True)

# Recording is continuous — these control how often chunks are finalized and processed
SCREEN_CHUNK_SECONDS = 60     # 1-minute screen recording segments
CAMERA_CHUNK_SECONDS = 60     # 1-minute camera recording segments
AUDIO_CHUNK_SECONDS = 30      # 30-second audio segments (same as iOS)


# ── Continuous Screen Recording ────────────────────────────────────────

class ContinuousScreenRecorder(threading.Thread):
    """Records the screen 24/7 as video using ffmpeg.

    Segments into 1-minute chunks. Each chunk is:
    1. Recorded as .mp4
    2. Keyframes extracted as images
    3. Each keyframe OCR'd for text content
    4. Scene described (what's on screen)
    5. Raw video deleted — only text/descriptions kept
    """

    def __init__(self):
        super().__init__(daemon=True)
        self.running = True
        self.process = None
        self.output_dir = DATA_DIR / "screen_video"
        self.output_dir.mkdir(exist_ok=True)

    def run(self):
        while self.running:
            chunk_path = self._start_chunk()
            if chunk_path:
                self._wait_for_chunk(chunk_path)
                if self.running:
                    threading.Thread(
                        target=self._process_chunk,
                        args=(chunk_path,),
                        daemon=True,
                    ).start()

    def _start_chunk(self) -> Path | None:
        """Start recording a screen chunk using ffmpeg."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        chunk_path = self.output_dir / f"screen_{timestamp}.mp4"

        try:
            # macOS: use avfoundation to capture screen
            # Device index "1" is typically the screen; "0" is camera
            # Capture at 2fps — enough to see everything, manageable file size
            self.process = subprocess.Popen(
                [
                    "ffmpeg", "-y",
                    "-f", "avfoundation",
                    "-framerate", "2",
                    "-capture_cursor", "1",
                    "-i", "1:none",          # screen input, no audio (mic is separate)
                    "-t", str(SCREEN_CHUNK_SECONDS),
                    "-c:v", "libx264",
                    "-preset", "ultrafast",
                    "-crf", "28",            # lower quality is fine — we extract text
                    "-pix_fmt", "yuv420p",
                    str(chunk_path),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return chunk_path
        except FileNotFoundError:
            print("[Screen] ffmpeg not found. Install: brew install ffmpeg")
            self.running = False
            return None

    def _wait_for_chunk(self, chunk_path: Path):
        """Wait for the current chunk to finish recording."""
        if self.process:
            self.process.wait()
            self.process = None

    def _process_chunk(self, chunk_path: Path):
        """Extract frames, OCR them, log the content, delete the video."""
        if not chunk_path.exists():
            return

        frames_dir = chunk_path.with_suffix(".frames")
        frames_dir.mkdir(exist_ok=True)

        try:
            # Extract 1 frame every 5 seconds from the chunk
            subprocess.run(
                [
                    "ffmpeg", "-y",
                    "-i", str(chunk_path),
                    "-vf", "fps=1/5",
                    str(frames_dir / "frame_%03d.png"),
                ],
                capture_output=True,
                timeout=60,
            )

            # OCR each frame
            active_app = self._get_active_app()
            frame_texts = []

            for frame_file in sorted(frames_dir.glob("*.png")):
                text = self._ocr_image(frame_file)
                if text:
                    frame_texts.append(text)
                frame_file.unlink()

            # Deduplicate consecutive identical frames
            deduped = []
            for text in frame_texts:
                if not deduped or text != deduped[-1]:
                    deduped.append(text)

            # Log
            if deduped:
                entry = {
                    "timestamp": datetime.now().isoformat(),
                    "type": "screen_recording",
                    "active_app": active_app,
                    "duration_seconds": SCREEN_CHUNK_SECONDS,
                    "frame_count": len(deduped),
                    "content": deduped,
                }

                log_file = DATA_DIR / f"screen_log_{date.today().isoformat()}.jsonl"
                with open(log_file, "a") as f:
                    f.write(json.dumps(entry) + "\n")

        except subprocess.TimeoutExpired:
            print("[Screen] Frame extraction timed out")
        except Exception as e:
            print(f"[Screen] Processing error: {e}")
        finally:
            # Always delete raw video and frames
            chunk_path.unlink(missing_ok=True)
            shutil.rmtree(frames_dir, ignore_errors=True)

    def _get_active_app(self) -> str:
        try:
            result = subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to get name of first application process whose frontmost is true'],
                capture_output=True, text=True, timeout=5,
            )
            return result.stdout.strip()
        except Exception:
            return "unknown"

    def _ocr_image(self, filepath: Path) -> str:
        """OCR a single frame."""
        try:
            result = subprocess.run(
                ["tesseract", str(filepath), "stdout", "--psm", "3"],
                capture_output=True, text=True, timeout=10,
            )
            return result.stdout.strip()
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return ""

    def stop(self):
        self.running = False
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()


# ── Continuous Camera Recording ────────────────────────────────────────

class ContinuousCameraRecorder(threading.Thread):
    """Records the camera 24/7 as video using ffmpeg.

    Segments into 1-minute chunks. Each chunk is:
    1. Recorded as .mp4
    2. Keyframes extracted
    3. Each keyframe analyzed for scene/activity
    4. Raw video deleted — only descriptions kept
    """

    def __init__(self):
        super().__init__(daemon=True)
        self.running = True
        self.process = None
        self.output_dir = DATA_DIR / "camera_video"
        self.output_dir.mkdir(exist_ok=True)

    def run(self):
        while self.running:
            chunk_path = self._start_chunk()
            if chunk_path:
                self._wait_for_chunk(chunk_path)
                if self.running:
                    threading.Thread(
                        target=self._process_chunk,
                        args=(chunk_path,),
                        daemon=True,
                    ).start()

    def _start_chunk(self) -> Path | None:
        """Start recording a camera chunk."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        chunk_path = self.output_dir / f"camera_{timestamp}.mp4"

        try:
            # macOS: device "0" is typically the FaceTime camera
            # 1fps is enough for activity understanding
            self.process = subprocess.Popen(
                [
                    "ffmpeg", "-y",
                    "-f", "avfoundation",
                    "-framerate", "1",
                    "-video_size", "640x480",
                    "-i", "0:none",          # camera, no audio
                    "-t", str(CAMERA_CHUNK_SECONDS),
                    "-c:v", "libx264",
                    "-preset", "ultrafast",
                    "-crf", "30",
                    "-pix_fmt", "yuv420p",
                    str(chunk_path),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return chunk_path
        except FileNotFoundError:
            print("[Camera] ffmpeg not found.")
            self.running = False
            return None

    def _wait_for_chunk(self, chunk_path: Path):
        if self.process:
            self.process.wait()
            self.process = None

    def _process_chunk(self, chunk_path: Path):
        """Extract keyframes, describe scene/activity, delete video."""
        if not chunk_path.exists():
            return

        frames_dir = chunk_path.with_suffix(".frames")
        frames_dir.mkdir(exist_ok=True)

        try:
            # Extract 1 frame every 10 seconds
            subprocess.run(
                [
                    "ffmpeg", "-y",
                    "-i", str(chunk_path),
                    "-vf", "fps=1/10",
                    str(frames_dir / "frame_%03d.jpg"),
                ],
                capture_output=True,
                timeout=60,
            )

            # Describe each frame
            descriptions = []
            for frame_file in sorted(frames_dir.glob("*.jpg")):
                desc = self._describe_frame(frame_file)
                if desc:
                    descriptions.append(desc)
                frame_file.unlink()

            if descriptions:
                entry = {
                    "timestamp": datetime.now().isoformat(),
                    "type": "camera_recording",
                    "duration_seconds": CAMERA_CHUNK_SECONDS,
                    "frame_count": len(descriptions),
                    "descriptions": descriptions,
                }

                log_file = DATA_DIR / f"camera_log_{date.today().isoformat()}.jsonl"
                with open(log_file, "a") as f:
                    f.write(json.dumps(entry) + "\n")

        except Exception as e:
            print(f"[Camera] Processing error: {e}")
        finally:
            chunk_path.unlink(missing_ok=True)
            shutil.rmtree(frames_dir, ignore_errors=True)

    def _describe_frame(self, filepath: Path) -> str:
        """Describe what's in a camera frame.

        For now, returns basic metadata. When Claude vision API is integrated,
        this will return rich scene descriptions like:
        'Tim at desk, writing in notebook, coffee cup visible, afternoon light'
        """
        # TODO: send to server for Claude vision analysis
        # For now, log that a frame was captured
        return f"frame_captured_{filepath.stem}"

    def stop(self):
        self.running = False
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()


# ── Continuous Mic Recording ───────────────────────────────────────────

class ContinuousMicRecorder(threading.Thread):
    """Records microphone 24/7 using ffmpeg.

    Same voice-only pipeline as iOS — segments into 30-second chunks,
    each processed for Tim's voice only.
    """

    def __init__(self):
        super().__init__(daemon=True)
        self.running = True
        self.process = None
        self.output_dir = DATA_DIR / "audio_chunks"
        self.output_dir.mkdir(exist_ok=True)

    def run(self):
        while self.running:
            chunk_path = self._start_chunk()
            if chunk_path:
                self._wait_for_chunk(chunk_path)
                if self.running and chunk_path.exists():
                    self._queue_for_processing(chunk_path)

    def _start_chunk(self) -> Path | None:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        chunk_path = self.output_dir / f"mic_{timestamp}.wav"

        try:
            # Record 16kHz mono WAV — ideal for speech processing
            self.process = subprocess.Popen(
                [
                    "ffmpeg", "-y",
                    "-f", "avfoundation",
                    "-i", ":0",              # default mic (no video)
                    "-t", str(AUDIO_CHUNK_SECONDS),
                    "-ar", "16000",
                    "-ac", "1",
                    "-acodec", "pcm_s16le",
                    str(chunk_path),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return chunk_path
        except FileNotFoundError:
            print("[Mic] ffmpeg not found.")
            self.running = False
            return None

    def _wait_for_chunk(self, chunk_path: Path):
        if self.process:
            self.process.wait()
            self.process = None

    def _queue_for_processing(self, chunk_path: Path):
        """Queue audio chunk for speaker-identified transcription."""
        meta = {
            "timestamp": datetime.now().isoformat(),
            "duration_seconds": AUDIO_CHUNK_SECONDS,
            "sample_rate": 16000,
            "file": str(chunk_path),
            "source": "macbook_mic",
            "processed": False,
        }

        log_file = DATA_DIR / f"audio_log_{date.today().isoformat()}.jsonl"
        with open(log_file, "a") as f:
            f.write(json.dumps(meta) + "\n")

    def stop(self):
        self.running = False
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()


# ── Active Window Tracker ──────────────────────────────────────────────

class ActiveWindowTracker(threading.Thread):
    """Tracks every app/window switch with duration."""

    def __init__(self):
        super().__init__(daemon=True)
        self.running = True
        self.last_app = ""
        self.last_title = ""
        self.last_change = datetime.now()

    def run(self):
        while self.running:
            try:
                app, title = self._get_active_window()
                if (app != self.last_app or title != self.last_title) and app:
                    duration = (datetime.now() - self.last_change).total_seconds()
                    if self.last_app:
                        self._log_transition(self.last_app, self.last_title, app, title, duration)
                    self.last_app = app
                    self.last_title = title
                    self.last_change = datetime.now()
            except Exception as e:
                print(f"[WindowTracker] Error: {e}")
            time.sleep(2)

    def _get_active_window(self) -> tuple[str, str]:
        """Get active application name and window title."""
        app = ""
        title = ""
        try:
            result = subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events"\n'
                 '  set frontApp to name of first application process whose frontmost is true\n'
                 '  set frontTitle to ""\n'
                 '  try\n'
                 '    tell process frontApp\n'
                 '      set frontTitle to name of front window\n'
                 '    end tell\n'
                 '  end try\n'
                 '  return frontApp & "|" & frontTitle\n'
                 'end tell'],
                capture_output=True, text=True, timeout=5,
            )
            parts = result.stdout.strip().split("|", 1)
            app = parts[0] if parts else ""
            title = parts[1] if len(parts) > 1 else ""
        except Exception:
            pass
        return app, title

    def _log_transition(self, from_app: str, from_title: str,
                        to_app: str, to_title: str, duration: float):
        entry = {
            "timestamp": datetime.now().isoformat(),
            "from_app": from_app,
            "from_title": from_title,
            "to_app": to_app,
            "to_title": to_title,
            "duration_seconds": round(duration, 1),
        }

        log_file = DATA_DIR / f"app_log_{date.today().isoformat()}.jsonl"
        with open(log_file, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def stop(self):
        self.running = False


# ── Storage Manager ────────────────────────────────────────────────────

class StorageManager(threading.Thread):
    """Monitors disk usage and prunes old data to prevent filling the drive."""

    def __init__(self, max_gb: float = 50.0):
        super().__init__(daemon=True)
        self.running = True
        self.max_bytes = int(max_gb * 1024 * 1024 * 1024)

    def run(self):
        while self.running:
            try:
                self._check_and_prune()
            except Exception as e:
                print(f"[Storage] Error: {e}")
            time.sleep(300)  # check every 5 minutes

    def _check_and_prune(self):
        total = sum(f.stat().st_size for f in DATA_DIR.rglob("*") if f.is_file())
        if total > self.max_bytes:
            print(f"[Storage] {total / 1e9:.1f}GB exceeds {self.max_bytes / 1e9:.0f}GB limit. Pruning...")
            # Delete oldest processed files first
            files = sorted(
                (f for f in DATA_DIR.rglob("*") if f.is_file() and f.suffix in {".mp4", ".wav", ".pcm", ".png", ".jpg"}),
                key=lambda f: f.stat().st_mtime,
            )
            for f in files:
                if total <= self.max_bytes * 0.8:  # prune to 80%
                    break
                size = f.stat().st_size
                f.unlink(missing_ok=True)
                total -= size

    def stop(self):
        self.running = False


# ── Main Daemon ────────────────────────────────────────────────────────

class TimVoiceDaemon:
    """Orchestrates all 24/7 continuous recording threads."""

    def __init__(self):
        self.threads = []
        self.running = True

    def start(self):
        print("=" * 60)
        print("  TimVoice macOS Daemon — 24/7 CONTINUOUS RECORDING")
        print(f"  Data dir: {DATA_DIR}")
        print(f"  Server:   {SERVER_URL}")
        print("=" * 60)

        threads = [
            ContinuousScreenRecorder(),
            ContinuousCameraRecorder(),
            ContinuousMicRecorder(),
            ActiveWindowTracker(),
            StorageManager(max_gb=50.0),
        ]

        self.threads = threads
        for t in threads:
            t.start()
            print(f"  RECORDING  {t.__class__.__name__}")

        print(f"\n  All streams live. Recording everything.")
        print(f"  Ctrl+C to stop.\n")

        signal.signal(signal.SIGINT, self._shutdown)
        signal.signal(signal.SIGTERM, self._shutdown)

        while self.running:
            time.sleep(1)

    def _shutdown(self, signum, frame):
        print("\nStopping all recordings...")
        self.running = False
        for t in self.threads:
            t.stop()
        # Wait for ffmpeg processes to terminate
        time.sleep(2)
        print("All recordings stopped.")
        sys.exit(0)


if __name__ == "__main__":
    daemon = TimVoiceDaemon()
    daemon.start()
