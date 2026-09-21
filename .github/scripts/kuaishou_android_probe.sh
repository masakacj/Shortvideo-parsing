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

echo "=== APK ==="
aapt dump badging kuaishou.apk | grep -E "^package:|^sdkVersion:|^targetSdkVersion:|^native-code:" | tee artifacts/apk.txt
adb install -r -g kuaishou.apk | tee artifacts/install.txt

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
python3 -m pip install --user --quiet frida-tools
FRIDA_VER=$(python3 -c 'import frida; print(frida.__version__)' 2>/dev/null)
if [ -n "$FRIDA_VER" ]; then
  curl -fL --retry 3 -o /tmp/frida-server.xz "https://github.com/frida/frida/releases/download/$FRIDA_VER/frida-server-$FRIDA_VER-android-arm64.xz"
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
