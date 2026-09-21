#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import frida

package = os.environ.get("PACKAGE_NAME", "com.smile.gifmaker")
video_url = os.environ.get("VIDEO_URL", "https://v.kuaishou.com/7EsP76S3")
resolved_video_url = os.environ.get("RESOLVED_VIDEO_URL", "").strip() or video_url
work_token = os.environ.get("WORK_TOKEN", "").strip()
work_numeric = os.environ.get("WORK_NUMERIC", "").strip()
duration = int(os.environ.get("PROBE_SECONDS", "75"))
out = Path(os.environ.get("PROBE_OUT", "artifacts"))
out.mkdir(parents=True, exist_ok=True)
log_path = out / "frida.jsonl"
js_path = Path(__file__).with_name("frida_url_probe.js")

def adb(*args, check=False):
    return subprocess.run(["adb", *args], text=True, capture_output=True, check=check)

device = frida.get_usb_device(timeout=20)
apps = {a.identifier: a for a in device.enumerate_applications()}
if package not in apps:
    raise SystemExit(f"{package} not installed/visible to Frida")

pid = None
for p in device.enumerate_processes():
    if p.name == package or getattr(p, "parameters", {}).get("identifier") == package:
        pid = p.pid
        break

if pid is None:
    pid = device.spawn([package])
    session = device.attach(pid)
else:
    session = device.attach(pid)

script = session.create_script(js_path.read_text(encoding="utf-8"))

fh = log_path.open("a", encoding="utf-8")
def on_message(message, data):
    row = {"message": message, "ts": time.time()}
    fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    fh.flush()
    if message.get("type") == "send":
        payload = message.get("payload")
        if isinstance(payload, dict) and payload.get("type") == "url":
            print(f"[URL] {payload.get('kind')}: {payload.get('url')}")

script.on("message", on_message)
script.load()

try:
    device.resume(pid)
except Exception:
    pass

time.sleep(5)

try:
    baseline = script.exports_sync.snapshot("baseline")
    print("Baseline media snapshot:", baseline)
except Exception as exc:
    print("Baseline snapshot failed:", exc)

if work_token:
    target_label = "work-token"
    target_route = f"kwai://work/{work_token}"
elif work_numeric:
    target_label = "work-numeric"
    target_route = f"kwai://work/{work_numeric}"
elif resolved_video_url:
    target_label = "resolved"
    target_route = resolved_video_url
else:
    target_label = "share"
    target_route = video_url

print(f"Opening isolated target route ({target_label}):", target_route)
subprocess.run([
    "adb", "shell", "am", "start",
    "-a", "android.intent.action.VIEW",
    "-d", target_route,
    "-p", package
], check=False)

started = time.time()
deadline = started + duration
schedule = [
    (5, "target-5s"),
    (15, "target-15s"),
    (30, "target-30s"),
    (50, "target-50s"),
]

for seconds_after_open, label in schedule:
    if seconds_after_open >= duration:
        break
    wait = started + seconds_after_open - time.time()
    if wait > 0:
        time.sleep(wait)
    try:
        snap = script.exports_sync.snapshot(label)
        print(f"Media snapshot {label}:", snap)
    except Exception as exc:
        print(f"Media snapshot {label} failed:", exc)

while time.time() < deadline:
    time.sleep(1)

fh.close()
try:
    session.detach()
except Exception:
    pass
print("Frida probe complete:", log_path)
