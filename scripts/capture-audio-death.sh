#!/usr/bin/env bash
# Capture live evidence from the Ayn Thor while GoldenEye is running with dead
# audio. Run this the moment the device is plugged in, BEFORE killing the app
# or rebooting — thread states and the logcat crash buffer are perishable.
#
# Usage: scripts/capture-audio-death.sh [output-dir]
set -uo pipefail

PKG=com.sunjaycy.goldeneye
OUT=${1:-audio-death-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

echo "== waiting for device =="
adb wait-for-device
adb devices -l | tee "$OUT/device.txt"

PID=$(adb shell pidof "$PKG" | tr -d '\r')
echo "app pid: ${PID:-NOT RUNNING}" | tee -a "$OUT/device.txt"

echo "== app log files =="
adb pull "/sdcard/Android/data/$PKG/files/ge.log" "$OUT/" 2>/dev/null
adb pull "/sdcard/Android/data/$PKG/files/stderr.txt" "$OUT/" 2>/dev/null

echo "== logcat (main + crash buffers, since boot) =="
adb logcat -d > "$OUT/logcat-main.txt"
adb logcat -b crash -d > "$OUT/logcat-crash.txt"
# AAudio/audioserver-specific view (route changes, stream errors, server death)
grep -iE 'aaudio|audioserver|audio_hw|audiopolicy|AudioTrack|AudioFlinger' \
  "$OUT/logcat-main.txt" > "$OUT/logcat-audio.txt" || true

if [ -n "${PID:-}" ]; then
  echo "== thread list (look for 'Audio Worker' state + missing guest audio producer) =="
  adb shell ps -T -p "$PID" > "$OUT/threads-1.txt"
  # Second sample 3s later: a thread whose TIME advances is alive; the Audio
  # Worker stuck in a guest wait shows identical utime across samples.
  sleep 3
  adb shell ps -T -p "$PID" > "$OUT/threads-2.txt"

  echo "== per-thread kernel wait channels =="
  adb shell "for t in /proc/$PID/task/*; do
    n=\$(cat \$t/comm 2>/dev/null); w=\$(cat \$t/wchan 2>/dev/null);
    s=\$(awk '{print \$3}' \$t/stat 2>/dev/null);
    echo \"\$t \$n state=\$s wchan=\$w\"; done" > "$OUT/wchan.txt"
fi

echo "== bugreport (tombstones + ANR traces; takes a minute) =="
adb bugreport "$OUT/bugreport.zip"

echo
echo "Captured to $OUT/. Key things to look at:"
echo "  1. ge.log        : grep -E 'AAudio|REXAPU|Audio' — 'AAudio error' / 'restart failed' lines"
echo "  2. threads-*.txt : is 'Audio Worker' alive? is the guest audio producer thread present?"
echo "  3. logcat-audio  : audioserver restarts / stream disconnects around the time audio died"
echo "  4. logcat-crash  : the earlier crash (persists until reboot)"
echo "  5. bugreport.zip : FS/data/tombstones/ + FS/data/anr/ for the earlier crash"
