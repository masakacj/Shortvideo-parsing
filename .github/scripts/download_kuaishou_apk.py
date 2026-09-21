#!/usr/bin/env python3
import hashlib
import json
import os
import re
import sys
from pathlib import Path

import requests

PACKAGE = "com.smile.gifmaker"
HOME = "https://mobile.baidu.com/"
OUT = Path(os.environ.get("APK_OUT", "kuaishou.apk"))
URL = os.environ.get("APK_URL", "").strip()
UA = "Mozilla/5.0 (Linux; Android 15; Pixel 9 Pro) AppleWebKit/537.36 Chrome/153 Mobile Safari/537.36"

s = requests.Session()
s.headers.update({"User-Agent": UA})

if not URL:
    r = s.get(HOME, timeout=30)
    r.raise_for_status()
    text = r.text
    pos = text.find(f'"package":"{PACKAGE}"')
    if pos < 0:
        raise SystemExit("Could not find Kuaishou package entry on mobile.baidu.com")
    chunk = text[pos:pos + 12000]
    m = re.search(r'"downloadUrl":"([^"]+)"', chunk)
    if not m:
        m = re.search(r'"download_url":"([^"]+)"', chunk)
    if not m:
        raise SystemExit("Could not find Kuaishou download URL in Baidu page data")
    URL = json.loads('"' + m.group(1) + '"')
    print("Resolved APK URL from Baidu app page.")

headers = {"Referer": HOME}
with s.get(URL, headers=headers, stream=True, timeout=60, allow_redirects=True) as r:
    r.raise_for_status()
    total = int(r.headers.get("content-length") or 0)
    print("Downloading:", r.url)
    print("Expected bytes:", total)
    h_md5 = hashlib.md5()
    h_sha = hashlib.sha256()
    size = 0
    with OUT.open("wb") as f:
        for chunk in r.iter_content(1024 * 1024):
            if not chunk:
                continue
            f.write(chunk)
            h_md5.update(chunk)
            h_sha.update(chunk)
            size += len(chunk)

if size < 10 * 1024 * 1024:
    raise SystemExit(f"APK unexpectedly small: {size} bytes")
with OUT.open("rb") as f:
    if f.read(2) != b"PK":
        raise SystemExit("Downloaded file is not an APK/ZIP")

print("APK:", OUT)
print("Size:", size)
print("MD5:", h_md5.hexdigest())
print("SHA256:", h_sha.hexdigest())
