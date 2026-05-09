#!/usr/bin/env bash
# Debug helper for the "VoiceKeyboard records silence / mic permission denied"
# failure mode where tccutil reset alone doesn't restore the prompt.
#
# Sequence:
#   1. Verify the Debug .app exists in DerivedData
#   2. Kill any running VoiceKeyboard process
#   3. Kick the TCC daemon (clears stale in-memory cache that survives tccutil reset)
#   4. tccutil reset Microphone for the bundle
#   5. Open System Settings -> Microphone so you can confirm the entry is gone
#   6. Launch the .app via LaunchServices (NOT Xcode/LLDB) so any prompt fires cleanly
#   7. Dump the relevant TCC + VoiceKeyboard logs from the last minute
#
# Usage: bash scripts/debug-mic-tcc.sh
# Requires sudo to kick tccd; will prompt once.

set -u

APP="$HOME/Library/Developer/Xcode/DerivedData/VoiceKeyboard-bpcwewmjvbmhtibqwbktvflmurat/Build/Products/Debug/VoiceKeyboard.app"
BUNDLE="com.voicekeyboard.app"

echo "=== 1. Verify .app exists ==="
if [ ! -d "$APP" ]; then
  echo "MISSING: $APP"
  echo "Build it first: cd mac && make build"
  exit 1
fi
echo "OK: $APP"

echo
echo "=== 2. Kill any running VoiceKeyboard ==="
pkill -x VoiceKeyboard 2>/dev/null || true
sleep 1
if pgrep -x VoiceKeyboard >/dev/null; then
  echo "WARN: VoiceKeyboard still running"
else
  echo "quit confirmed"
fi

echo
echo "=== 3. Bounce tccd (kill -> launchd respawns it fresh) ==="
echo "Will prompt for sudo. Both system and per-user tccd get killed and reloaded."
if sudo killall tccd 2>&1; then
  echo "tccd killed; launchd will respawn"
else
  echo "WARN: killall tccd returned nonzero (maybe nothing was running)"
fi
sleep 2
pgrep -x tccd >/dev/null && echo "tccd respawned (fresh state)" || echo "WARN: no tccd running yet, sleeping more"; sleep 2

echo
echo "=== 4. Reset TCC mic entry for $BUNDLE ==="
tccutil reset Microphone "$BUNDLE"
echo "reset rc=$?"

echo
echo "=== 5. Opening System Settings -> Privacy & Security -> Microphone ==="
echo "Confirm VoiceKeyboard is NOT listed there before continuing."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
read -r -p "Press ENTER once you've checked System Settings (or Ctrl-C to abort)..."

echo
echo "=== 6. Launch the .app via LaunchServices (no Xcode/LLDB) ==="
open "$APP"
echo "Watch for the macOS mic permission prompt. Click Allow if it appears."
echo "Sleeping 8s to let launch + prompt resolve..."
sleep 8

echo
echo "=== 7a. ALL VoiceKeyboard log lines from launch (last 30s, unfiltered) ==="
log show --last 30s \
  --predicate 'subsystem == "com.voicekeyboard.app"' \
  --info --debug --style compact 2>&1 \
  | tail -100

echo
echo "=== 7b. tccd activity for VoiceKeyboard (last 30s) ==="
log show --last 30s \
  --predicate 'process == "tccd"' \
  --info --debug --style compact 2>&1 \
  | grep -i "voicekeyboard\|kTCCServiceMicrophone" \
  | head -40

echo
echo "=== 7c. Did VoiceKeyboard process actually start? ==="
pgrep -x VoiceKeyboard >/dev/null && echo "yes, running PID=$(pgrep -x VoiceKeyboard)" || echo "NO — process is not running"

echo
echo "=== 8. Final TCC state check ==="
echo "Look at System Settings -> Microphone again."
echo "Is VoiceKeyboard now listed? Toggle ON or OFF?"
echo
echo "Paste back to claude:"
echo "  - Whether the prompt appeared in step 6"
echo "  - What System Settings showed in step 5 (entry present/absent before launch)"
echo "  - What step 7 logged"
echo "  - What System Settings shows after step 8"
