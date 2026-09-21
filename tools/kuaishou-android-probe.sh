#!/usr/bin/env bash
set -Eeuo pipefail

VIDEO_URL="${1:-https://v.kuaishou.com/7EsP76S3}"
APK_PATH="${2:-kuaishou.apk}"
PACKAGE="com.smile.gifmaker"
OUT="${GITHUB_WORKSPACE:-$PWD}/artifacts/kuaishou-android-probe"
mkdir -p "$OUT"

exec > >(tee "$OUT/probe-console.log") 2>&1

echo "video_url=$VIDEO_URL"
echo "apk_path=$APK_PATH"
date -Is

adb wait-for-device
adb shell getprop > "$OUT/getprop.txt" || true
adb shell wm size > "$OUT/wm-size.txt" || true
adb shell wm density > "$OUT/wm-density.txt" || true
adb shell getprop ro.product.cpu.abilist > "$OUT/emulator-abilist.txt" || true

echo "=== emulator ABI ==="
cat "$OUT/emulator-abilist.txt" || true

echo "=== APK install ==="
set +e
adb install -r -g "$APK_PATH" 2>&1 | tee "$OUT/adb-install.txt"
INSTALL_RC=${PIPESTATUS[0]}
set -e
if [[ "$INSTALL_RC" -ne 0 ]] || ! adb shell pm path "$PACKAGE" > "$OUT/package-path.txt" 2>/dev/null; then
  echo "APK installation failed; preserving emulator diagnostics."
  adb shell pm list packages -f > "$OUT/packages.txt" || true
  exit 20
fi

adb shell dumpsys package "$PACKAGE" > "$OUT/package-dumpsys.txt" || true
adb shell cmd package resolve-activity --brief -a android.intent.action.VIEW -d "$VIDEO_URL" > "$OUT/url-resolver.txt" 2>&1 || true

# Fresh emulator only; root is used for diagnostics if the Google APIs image permits it.
adb root > "$OUT/adb-root.txt" 2>&1 || true
sleep 2
adb wait-for-device

adb logcat -c || true
adb shell am force-stop "$PACKAGE" || true

echo "=== initial app launch ==="
adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 > "$OUT/monkey.txt" 2>&1 || true
sleep 8
adb exec-out screencap -p > "$OUT/01-app-launch.png" || true
adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
adb pull /sdcard/window.xml "$OUT/01-window.xml" >/dev/null 2>&1 || true

# Try lightweight Java URL instrumentation. Failure must not abort the base probe.
echo "=== optional Frida URL instrumentation ==="
set +e
python3 -m pip install --quiet --disable-pip-version-check frida-tools
FRIDA_PIP_RC=$?
if [[ "$FRIDA_PIP_RC" -eq 0 ]]; then
  FRIDA_VERSION="$(python3 - <<'PY'
import frida
print(frida.__version__)
PY
)"
  echo "frida_version=$FRIDA_VERSION"
  curl -L --fail --retry 2 \
    "https://github.com/frida/frida/releases/download/${FRIDA_VERSION}/frida-server-${FRIDA_VERSION}-android-x86_64.xz" \
    -o "$OUT/frida-server.xz"
  if [[ "$?" -eq 0 ]]; then
    xz -d -f "$OUT/frida-server.xz"
    adb push "$OUT/frida-server" /data/local/tmp/frida-server >/dev/null
    adb shell chmod 755 /data/local/tmp/frida-server
    adb shell 'pkill -f frida-server || true'
    adb shell '/data/local/tmp/frida-server >/dev/null 2>&1 &' || true
    sleep 2
    frida-ps -U > "$OUT/frida-ps.txt" 2>&1 || true
    timeout 45s frida -U -f "$PACKAGE" -l "$GITHUB_WORKSPACE/tools/kuaishou-url-hook.js" -o "$OUT/frida-url.log" > "$OUT/frida-console.txt" 2>&1 &
    FRIDA_CLI_PID=$!
    sleep 8
  fi
fi
set -e

echo "=== open target URL ==="
adb shell am start -W -a android.intent.action.VIEW -d "$VIDEO_URL" "$PACKAGE" > "$OUT/open-url.txt" 2>&1 || \
  adb shell am start -W -a android.intent.action.VIEW -d "$VIDEO_URL" >> "$OUT/open-url.txt" 2>&1 || true

for n in 1 2 3; do
  sleep 10
  adb exec-out screencap -p > "$OUT/0$((n+1))-after-url.png" || true
  adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
  adb pull /sdcard/window.xml "$OUT/0$((n+1))-window.xml" >/dev/null 2>&1 || true
done

adb logcat -d -v threadtime > "$OUT/logcat.txt" || true
adb shell dumpsys activity activities > "$OUT/activity.txt" || true
adb shell dumpsys media.metrics > "$OUT/media-metrics.txt" 2>&1 || true
adb shell dumpsys media_session > "$OUT/media-session.txt" 2>&1 || true
adb shell dumpsys connectivity > "$OUT/connectivity.txt" 2>&1 || true
adb shell dumpsys netstats > "$OUT/netstats.txt" 2>&1 || true
adb shell ss -tpn > "$OUT/ss-tcp.txt" 2>&1 || true

PID="$(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
echo "$PID" > "$OUT/app-pid.txt"
if [[ -n "$PID" ]]; then
  adb shell "cat /proc/$PID/maps" > "$OUT/app-maps.txt" 2>&1 || true
  adb shell "cat /proc/$PID/net/tcp" > "$OUT/app-net-tcp.txt" 2>&1 || true
  adb shell "cat /proc/$PID/net/tcp6" > "$OUT/app-net-tcp6.txt" 2>&1 || true
fi

# Pull out anything that already looks like a media/CDN URL or quality descriptor.
python3 - "$OUT" <<'PY'
from pathlib import Path
import re, sys
out = Path(sys.argv[1])
texts = []
for name in ("logcat.txt", "frida-url.log", "frida-console.txt", "probe-console.log"):
    p = out / name
    if p.exists():
        texts.append(p.read_text(errors="ignore"))
text = "\n".join(texts)
urls = sorted(set(re.findall(r'https?://[^\s\"\'<>]+', text)))
interesting = [
    u for u in urls
    if re.search(r'\.mp4|\.m3u8|kwaicdn|kwimgs|yximgs|ndcimgs|gifshow|kuaishou|video', u, re.I)
]
(out / "interesting-urls.txt").write_text("\n".join(interesting) + ("\n" if interesting else ""))
quality_lines = []
for line in text.splitlines():
    if re.search(r'1080|1440|2160|720p|1080p|bitrate|manifest|representation|videoResource|H265|HEVC|AVC', line, re.I):
        quality_lines.append(line)
(out / "quality-lines.txt").write_text("\n".join(quality_lines[-5000:]) + ("\n" if quality_lines else ""))
print(f"interesting_urls={len(interesting)} quality_lines={len(quality_lines)}")
PY

echo "=== summary ==="
cat "$OUT/interesting-urls.txt" || true
