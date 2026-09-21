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

time.sleep(4)
subprocess.run([
    "adb", "shell", "am", "start",
    "-a", "android.intent.action.VIEW",
    "-d", video_url,
    "-p", package
], check=False)

routes = []
if resolved_video_url != video_url:
    routes.append(("resolved", resolved_video_url))
if work_token:
    routes.append(("work-token", f"kwai://work/{work_token}"))
if work_numeric:
    routes.append(("work-numeric", f"kwai://work/{work_numeric}"))

deadline = time.time() + duration
segments = max(1, len(routes) + 1)
segment_seconds = max(8, duration // segments)

for label, route in routes:
    time.sleep(min(segment_seconds, max(0, deadline - time.time())))
    if time.time() >= deadline:
        break
    print(f"Opening {label} route:", route)
    subprocess.run([
        "adb", "shell", "am", "start",
        "-a", "android.intent.action.VIEW",
        "-d", route,
        "-p", package
    ], check=False)

while time.time() < deadline:
    time.sleep(1)

fh.close()
try:
    session.detach()
except Exception:
    pass
print("Frida probe complete:", log_path)
