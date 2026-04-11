#!/bin/bash
# TimVoice Setup Script
# Run this on your Mac to set up everything.
# Usage: ./setup.sh

set -e

echo "============================================"
echo "  TimVoice — Screenless Life System Setup"
echo "============================================"
echo ""

# ── Step 1: Check prerequisites ──────────────────────────────────────

echo "Checking prerequisites..."

# Check for Xcode
if ! xcode-select -p &>/dev/null; then
    echo ""
    echo "ERROR: Xcode is not installed."
    echo "  1. Open the App Store"
    echo "  2. Search for 'Xcode'"
    echo "  3. Click 'Get' (it's free, ~12GB)"
    echo "  4. After install, run: sudo xcode-select --switch /Applications/Xcode.app"
    echo "  5. Then re-run this script."
    echo ""
    exit 1
fi
echo "  ✓ Xcode found"

# Check for Homebrew
if ! command -v brew &>/dev/null; then
    echo "  Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
echo "  ✓ Homebrew found"

# ── Step 2: Install tools ────────────────────────────────────────────

echo ""
echo "Installing tools..."

# XcodeGen — generates Xcode project from project.yml
if ! command -v xcodegen &>/dev/null; then
    echo "  Installing XcodeGen..."
    brew install xcodegen
fi
echo "  ✓ XcodeGen"

# ffmpeg — for macOS screen/camera/mic recording
if ! command -v ffmpeg &>/dev/null; then
    echo "  Installing ffmpeg..."
    brew install ffmpeg
fi
echo "  ✓ ffmpeg"

# tesseract — for OCR on screen captures
if ! command -v tesseract &>/dev/null; then
    echo "  Installing tesseract..."
    brew install tesseract
fi
echo "  ✓ tesseract"

# imagesnap — for macOS camera snapshots
if ! command -v imagesnap &>/dev/null; then
    echo "  Installing imagesnap..."
    brew install imagesnap
fi
echo "  ✓ imagesnap"

# Python dependencies for server
echo "  Installing Python dependencies..."
pip3 install -r server/requirements.txt --quiet 2>/dev/null || true
pip3 install -r macos/requirements.txt --quiet 2>/dev/null || true
echo "  ✓ Python packages"

# ── Step 3: Generate Xcode project ───────────────────────────────────

echo ""
echo "Generating Xcode project..."
cd ios/TimVoice
xcodegen generate
cd ../..
echo "  ✓ TimVoice.xcodeproj generated"

# ── Step 4: Open Xcode ───────────────────────────────────────────────

echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo ""
echo "  1. ENROLL AS APPLE DEVELOPER (if you haven't):"
echo "     → Open: https://developer.apple.com/enroll"
echo "     → Pay \$99/year"
echo "     → This gives you: background audio, HealthKit, Watch app"
echo ""
echo "  2. OPEN THE PROJECT:"
echo "     → Opening Xcode now..."
echo ""
echo "  3. IN XCODE:"
echo "     → Xcode menu → Settings → Accounts → '+' → Add your Apple ID"
echo "     → In the project navigator, click 'TimVoice' (top)"
echo "     → For EACH target (TimVoice, TimVoiceWatch, TimVoiceWatchExtension):"
echo "       → Signing & Capabilities tab"
echo "       → Set 'Team' to your developer account"
echo "       → Click '+ Capability' → Add 'App Groups'"
echo "       → Add group: group.community.holm.timvoice"
echo ""
echo "  4. DEPLOY TO YOUR PHONE:"
echo "     → Plug in your iPhone via USB"
echo "     → Select your iPhone from the device dropdown (top bar)"
echo "     → Press Cmd+R (Run)"
echo "     → The Watch app installs automatically"
echo ""
echo "  5. START THE MAC DAEMON:"
echo "     → In a terminal: cd $(pwd) && python3 macos/daemon.py"
echo ""
echo "  6. START THE SERVER:"
echo "     → In another terminal:"
echo "     → export ANTHROPIC_API_KEY='your-key'"
echo "     → export PRINTER_NAME=\$(lpstat -d | awk '{print \$NF}')"
echo "     → cd $(pwd) && python3 server/ingest/app.py"
echo ""

# Open Xcode
open ios/TimVoice/TimVoice.xcodeproj
