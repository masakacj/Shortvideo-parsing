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
positive = ["同意并继续","同意并使用","同意","允许","继续","我知道了","知道了","跳过","以后再说"]
for _ in range(8):
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
                    time.sleep(2)
                    hit=True
                    break
        if hit: break
    if not hit: break
PY

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
  PACKAGE_NAME="$PACKAGE_NAME" VIDEO_URL="$VIDEO_URL" PROBE_SECONDS="$PROBE_SECONDS" PROBE_OUT=artifacts python3 .github/scripts/frida_probe.py
  FRIDA_RC=$?
else
  FRIDA_RC=1
fi
set -e

if [ "${FRIDA_RC:-1}" -ne 0 ]; then
  echo "Frida probe unavailable; opening link without instrumentation." | tee artifacts/frida-error.txt
  adb shell am start -a android.intent.action.VIEW -d "$VIDEO_URL" -p "$PACKAGE_NAME" || true
  sleep "$PROBE_SECONDS"
fi

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
