#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGE_NAME="${PACKAGE_NAME:-com.smile.gifmaker}"
VIDEO_URL="${VIDEO_URL:-https://v.kuaishou.com/7EsP76S3}"
PROBE_SECONDS="${PROBE_SECONDS:-75}"
mkdir -p artifacts

echo "=== Device ===" | tee artifacts/device.txt
adb wait-for-device
adb shell getprop | tee -a artifacts/device.txt
adb shell wm size | tee -a artifacts/device.txt
adb shell wm density | tee -a artifacts/device.txt

echo "=== Native bridge / ABI ===" | tee artifacts/native-bridge.txt
for prop in ro.product.cpu.abi ro.product.cpu.abilist ro.dalvik.vm.native.bridge ro.enable.native.bridge.exec; do
  printf '%s=' "$prop" | tee -a artifacts/native-bridge.txt
  adb shell getprop "$prop" | tr -d '\r' | tee -a artifacts/native-bridge.txt
done
adb shell 'find /system /vendor -iname "*ndk_translation*" -o -iname "*native_bridge*" 2>/dev/null | head -100'   | tee -a artifacts/native-bridge.txt || true
BRIDGE_SUMMARY=$(tr '\n' ';' < artifacts/native-bridge.txt)
echo "::notice title=Android ABI / native bridge::${BRIDGE_SUMMARY}"

echo "=== APK ==="
AAPT_BIN=$(command -v aapt || true)
if [ -z "$AAPT_BIN" ]; then
  SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [ -n "$SDK_ROOT" ] && [ -d "$SDK_ROOT/build-tools" ]; then
    AAPT_BIN=$(find "$SDK_ROOT/build-tools" -maxdepth 2 -type f -name aapt -perm -111 2>/dev/null | sort -V | tail -n 1)
  fi
fi
if [ -n "$AAPT_BIN" ]; then
  "$AAPT_BIN" dump badging kuaishou.apk > artifacts/apk-badging.txt 2>&1 || true
  grep -E "^package:|^sdkVersion:|^targetSdkVersion:|^native-code:" artifacts/apk-badging.txt | tee artifacts/apk.txt || true
  echo "::notice title=APK metadata::$(tr '\n' ';' < artifacts/apk.txt)"
else
  echo "aapt not found; continuing directly to adb install." | tee artifacts/apk.txt
  echo "::warning title=APK metadata::aapt not found, install test will continue"
fi

echo "=== APK deep-link strings ==="
: > artifacts/deeplink-strings.txt
for dex in $(unzip -Z1 kuaishou.apk | grep -E '^classes[0-9]*\.dex$' | head -40); do
  unzip -p kuaishou.apk "$dex" 2>/dev/null | strings 2>/dev/null | \
    grep -aEo '(kwai|kwaiopenapi|ksnebula|gifshow|kuaishou)://[^[:space:]"<>]{1,300}' >> artifacts/deeplink-strings.txt || true
done
sort -u artifacts/deeplink-strings.txt | head -500 > artifacts/deeplink-strings.tmp || true
mv artifacts/deeplink-strings.tmp artifacts/deeplink-strings.txt
head -100 artifacts/deeplink-strings.txt || true

set +e
adb install -r -g kuaishou.apk 2>&1 | tee artifacts/install.txt
INSTALL_RC=${PIPESTATUS[0]}
if [ "$INSTALL_RC" -ne 0 ]; then
  echo "Normal install failed; retrying with explicit arm64-v8a ABI." | tee -a artifacts/install.txt
  adb install --abi arm64-v8a -r -g kuaishou.apk 2>&1 | tee -a artifacts/install.txt
  INSTALL_RC=${PIPESTATUS[0]}
fi
set -e
if [ "$INSTALL_RC" -ne 0 ]; then
  INSTALL_SUMMARY=$(tr '\n' ';' < artifacts/install.txt)
  echo "::error title=Kuaishou APK installation failed::${INSTALL_SUMMARY}"
  echo "APK installation failed. See artifacts/install.txt and native-bridge.txt." >&2
  exit "$INSTALL_RC"
fi

echo "=== Package ==="
adb shell dumpsys package "$PACKAGE_NAME" > artifacts/package.txt || true
adb shell cmd package query-activities -a android.intent.action.VIEW -d "$VIDEO_URL" > artifacts/url-handlers-original.txt 2>&1 || true

RESOLVED_VIDEO_URL=$(curl -Ls --max-time 20 \
  -A 'Mozilla/5.0 (Linux; Android 15; Pixel 9 Pro) AppleWebKit/537.36 Chrome/153 Mobile Safari/537.36' \
  -o /dev/null -w '%{url_effective}' "$VIDEO_URL" || true)
if [ -z "$RESOLVED_VIDEO_URL" ]; then
  RESOLVED_VIDEO_URL="$VIDEO_URL"
fi
printf '%s\n' "$RESOLVED_VIDEO_URL" | tee artifacts/resolved-video-url.txt
adb shell cmd package query-activities -a android.intent.action.VIEW -d "$RESOLVED_VIDEO_URL" > artifacts/url-handlers-resolved.txt 2>&1 || true

readarray -t WORK_IDS < <(python3 - "$VIDEO_URL" "$RESOLVED_VIDEO_URL" <<'PY'
import re, sys, urllib.parse
original, resolved = sys.argv[1:3]
token = ""
numeric = ""
m = re.search(r"/fw/photo/([^/?#]+)", resolved)
if m:
    token = m.group(1)
q = urllib.parse.parse_qs(urllib.parse.urlsplit(resolved).query)
numeric = (q.get("shareObjectId") or [""])[0]
if not numeric:
    m = re.search(r"/short-video/(\d+)", original)
    if m:
        numeric = m.group(1)
print(token)
print(numeric)
PY
)
WORK_TOKEN="${WORK_IDS[0]:-}"
WORK_NUMERIC="${WORK_IDS[1]:-}"
{
  [ -n "$WORK_TOKEN" ] && echo "kwai://work/$WORK_TOKEN"
  [ -n "$WORK_NUMERIC" ] && echo "kwai://work/$WORK_NUMERIC"
} | tee artifacts/native-work-deeplinks.txt
for uri in "kwai://work/$WORK_TOKEN" "kwai://work/$WORK_NUMERIC"; do
  case "$uri" in
    "kwai://work/") continue ;;
  esac
  adb shell cmd package query-activities -a android.intent.action.VIEW -d "$uri" >> artifacts/url-handlers-native.txt 2>&1 || true
done

# Default/API emulator images are rootable. Frida is best-effort; the run still
# produces logcat/UI artifacts if instrumentation is unavailable.
adb root || true
adb wait-for-device
sleep 2

echo "=== Start logcat ==="
adb logcat -c || true
adb logcat -v threadtime > artifacts/logcat.txt 2>&1 &
LOGCAT_PID=$!

echo "=== First launch ==="
adb shell monkey -p "$PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 || true
sleep 8

# Capture first-run UI before attempting the deep link.
adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
adb pull /sdcard/window.xml artifacts/window-before.xml >/dev/null 2>&1 || true
adb exec-out screencap -p > artifacts/screen-before.png || true

# Best-effort click common positive/continue buttons from the current UI.
python3 - <<'PY'
import re, subprocess, time, xml.etree.ElementTree as ET
positive = [
    "优化","立即优化","去优化","确定","确认","好的",
    "同意并继续","同意并使用","同意","允许","继续","我知道了","知道了","跳过","以后再说",
    "Agree and continue","Agree and Continue","Agree","Allow","Continue","Got it","OK","Confirm","Skip","Not now",
]
idle_rounds = 0
for _ in range(20):
    subprocess.run(["adb","shell","uiautomator","dump","/sdcard/window.xml"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    p=subprocess.run(["adb","shell","cat","/sdcard/window.xml"], text=True, capture_output=True)
    try: root=ET.fromstring(p.stdout)
    except Exception:
        time.sleep(1); continue
    hit=False
    for wanted in positive:
        for n in root.iter("node"):
            text=(n.attrib.get("text") or "").strip()
            desc=(n.attrib.get("content-desc") or "").strip()
            if text == wanted or desc == wanted:
                m=re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.attrib.get("bounds",""))
                if m:
                    x=(int(m.group(1))+int(m.group(3)))//2
                    y=(int(m.group(2))+int(m.group(4)))//2
                    subprocess.run(["adb","shell","input","tap",str(x),str(y)])
                    print("Tapped",wanted,x,y)
                    time.sleep(12 if "优化" in wanted else 5 if wanted in {"确定","确认","OK","Confirm"} else 3)
                    idle_rounds = 0
                    hit=True
                    break
        if hit: break
    if not hit:
        idle_rounds += 1
        if idle_rounds >= 5:
            break
        time.sleep(2)
PY

adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
adb pull /sdcard/window.xml artifacts/window-after-consent.xml >/dev/null 2>&1 || true
adb exec-out screencap -p > artifacts/screen-after-consent.png || true

echo "=== Frida setup ==="
set +e
python3 -m pip install --quiet frida-tools
FRIDA_VER=$(python3 -c 'import frida; print(frida.__version__)' 2>/dev/null)
DEVICE_ABI=$(adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
case "$DEVICE_ABI" in
  x86_64) FRIDA_ARCH="x86_64" ;;
  arm64-v8a|arm64) FRIDA_ARCH="arm64" ;;
  *) FRIDA_ARCH="" ;;
esac
echo "Frida version: ${FRIDA_VER:-unknown}, device ABI: ${DEVICE_ABI:-unknown}, server arch: ${FRIDA_ARCH:-unknown}"   | tee artifacts/frida-setup.txt
if [ -n "$FRIDA_VER" ] && [ -n "$FRIDA_ARCH" ]; then
  curl -fL --retry 3 -o /tmp/frida-server.xz "https://github.com/frida/frida/releases/download/$FRIDA_VER/frida-server-$FRIDA_VER-android-$FRIDA_ARCH.xz"
  xz -df /tmp/frida-server.xz
  adb push /tmp/frida-server /data/local/tmp/frida-server
  adb shell chmod 755 /data/local/tmp/frida-server
  adb shell '/data/local/tmp/frida-server >/data/local/tmp/frida-server.log 2>&1 &' || true
  sleep 3
  set -o pipefail
  PACKAGE_NAME="$PACKAGE_NAME" VIDEO_URL="$VIDEO_URL" RESOLVED_VIDEO_URL="$RESOLVED_VIDEO_URL" \
    WORK_TOKEN="$WORK_TOKEN" WORK_NUMERIC="$WORK_NUMERIC" PROBE_SECONDS="$PROBE_SECONDS" PROBE_OUT=artifacts \
    python3 .github/scripts/frida_probe.py 2>&1 | tee artifacts/frida-probe-console.txt
  FRIDA_RC=${PIPESTATUS[0]}
  set +o pipefail
  adb shell cat /data/local/tmp/frida-server.log > artifacts/frida-server.log 2>&1 || true
else
  FRIDA_RC=1
fi
set -e

if [ "${FRIDA_RC:-1}" -ne 0 ]; then
  echo "Frida probe unavailable; opening all routes without instrumentation." | tee artifacts/frida-error.txt
  adb shell am start -a android.intent.action.VIEW -d "$VIDEO_URL" -p "$PACKAGE_NAME" || true
  sleep 15
  if [ "$RESOLVED_VIDEO_URL" != "$VIDEO_URL" ]; then
    adb shell am start -a android.intent.action.VIEW -d "$RESOLVED_VIDEO_URL" -p "$PACKAGE_NAME" || true
    sleep 15
  fi
  if [ -n "$WORK_TOKEN" ]; then
    adb shell am start -a android.intent.action.VIEW -d "kwai://work/$WORK_TOKEN" -p "$PACKAGE_NAME" || true
    sleep 15
  fi
  if [ -n "$WORK_NUMERIC" ]; then
    adb shell am start -a android.intent.action.VIEW -d "kwai://work/$WORK_NUMERIC" -p "$PACKAGE_NAME" || true
    sleep 15
  fi
fi

echo "=== Scan fresh app data for media metadata ==="
APP_ROOT="/data/user/0/$PACKAGE_NAME"
adb shell "find '$APP_ROOT/cache' '$APP_ROOT/files' '$APP_ROOT/databases' -type f 2>/dev/null" \
  | tr -d '\r' | head -400 > artifacts/app-data-files.txt || true
: > artifacts/app-cache-strings.txt
while IFS= read -r remote_file; do
  [ -n "$remote_file" ] || continue
  size=$(adb shell "stat -c %s '$remote_file' 2>/dev/null" | tr -d '\r' || true)
  case "$size" in
    ''|*[!0-9]*) continue ;;
  esac
  [ "$size" -le 33554432 ] || continue
  {
    echo "===== $remote_file ($size bytes) ====="
    timeout 8s adb exec-out cat "$remote_file" 2>/dev/null | strings -n 6 | \
      grep -aEi 'https?://|\.mp4|\.m3u8|manifest|adaptation(Set)?|representation|videoResource|photoUrl|H265|HEVC|AVC|1080|1440|2160|bitrate|kwaicdn|kwimgs|yximgs|ndcimgs|djvod|photo-video|5190398778855289322|3xtgkud72h4jz8e' \
      | head -300 || true
  } >> artifacts/app-cache-strings.txt
done < artifacts/app-data-files.txt

adb shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true
adb pull /sdcard/window.xml artifacts/window-after.xml >/dev/null 2>&1 || true
adb exec-out screencap -p > artifacts/screen-after.png || true
adb shell dumpsys activity activities > artifacts/activity.txt || true
adb shell dumpsys media_session > artifacts/media-session.txt || true

kill "$LOGCAT_PID" 2>/dev/null || true
sleep 1

python3 - <<'PY'
from pathlib import Path
import re, json
urls=set()
patterns=[
    re.compile(r'https?://[^\s"\\<>]+',re.I),
]
for name in ["artifacts/logcat.txt","artifacts/frida.jsonl"]:
    p=Path(name)
    if not p.exists(): continue
    text=p.read_text(errors="ignore")
    for pat in patterns:
        for u in pat.findall(text):
            u=u.rstrip("),]}'")
            if any(x in u.lower() for x in [".mp4","m3u8","kwaicdn","yximgs","ndcimgs","gifshow","kuaishou","ksapisrv"]):
                urls.add(u)
Path("artifacts/candidate-urls.txt").write_text("\n".join(sorted(urls))+"\n",encoding="utf-8")
print("Candidate URLs:",len(urls))
for u in sorted(urls):
    print(u)
PY

echo "=== Candidate URLs ==="
cat artifacts/candidate-urls.txt || true

echo "=== Probe media candidates ==="
if ! command -v ffprobe >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq ffmpeg
fi
PROBE_OUT=artifacts VIDEO_URL="$VIDEO_URL" python3 .github/scripts/analyze_probe_urls.py
