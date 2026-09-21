#!/usr/bin/env python3
import hashlib
import json
import os
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from fractions import Fraction
from pathlib import Path
from shutil import which

OUT = Path(os.environ.get("PROBE_OUT", "artifacts"))
UA = "Mozilla/5.0 (Linux; Android 15; Pixel 9 Pro) AppleWebKit/537.36 Chrome/153 Mobile Safari/537.36"
MEDIA_HINT = re.compile(r"\.mp4(?:$|\?)|\.m3u8(?:$|\?)|kwaicdn|kwimgs|yximgs|ndcimgs|djvod|/upic/|photo-video", re.I)

def clean_url(value):
    if not isinstance(value, str):
        return ""
    value = value.replace("\\u0026", "&").replace("\\/", "/")
    value = value.strip().rstrip("),]}'\"")
    return value if value.startswith(("http://", "https://")) else ""

def collect_urls():
    urls = set()
    p = OUT / "frida.jsonl"
    if p.exists():
        for line in p.read_text(errors="ignore").splitlines():
            try:
                row = json.loads(line)
                payload = row.get("message", {}).get("payload")
                if isinstance(payload, dict) and payload.get("type") == "url":
                    u = clean_url(payload.get("url"))
                    if u and MEDIA_HINT.search(u):
                        urls.add(u)
            except Exception:
                pass

    for name in ("logcat.txt", "candidate-urls.txt", "app-cache-strings.txt"):
        p = OUT / name
        if not p.exists():
            continue
        text = p.read_text(errors="ignore")
        for raw in re.findall(r"https?://[^\s\"'<>]+", text):
            u = clean_url(raw)
            if u and MEDIA_HINT.search(u):
                urls.add(u)
    return sorted(urls)

def fraction(value):
    try:
        if not value:
            return None
        return float(Fraction(str(value)))
    except Exception:
        return None

def range_probe(url):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": UA,
            "Referer": "https://www.kuaishou.com/",
            "Range": "bytes=0-0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            cr = r.headers.get("Content-Range", "")
            total = None
            if "/" in cr:
                try:
                    total = int(cr.rsplit("/", 1)[1])
                except Exception:
                    pass
            if total is None:
                try:
                    total = int(r.headers.get("Content-Length") or 0) or None
                except Exception:
                    pass
            return {
                "status": getattr(r, "status", None),
                "content_type": r.headers.get("Content-Type"),
                "size": total,
                "final_url": r.geturl(),
            }
    except urllib.error.HTTPError as e:
        return {"status": e.code, "error": str(e)}
    except Exception as e:
        return {"error": str(e)}

def ffprobe(url):
    if not which("ffprobe"):
        return {"error": "ffprobe unavailable"}
    cmd = [
        "ffprobe",
        "-v", "error",
        "-rw_timeout", "15000000",
        "-user_agent", UA,
        "-headers", "Referer: https://www.kuaishou.com/\r\n",
        "-show_entries",
        "format=duration,size,bit_rate:stream=codec_name,codec_type,width,height,r_frame_rate,avg_frame_rate,bit_rate",
        "-of", "json",
        url,
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=25)
        if p.returncode != 0:
            return {"error": (p.stderr or p.stdout).strip()[-1500:]}
        return json.loads(p.stdout)
    except Exception as e:
        return {"error": str(e)}

def summarize(url):
    rp = range_probe(url)
    final_url = rp.get("final_url") or url
    parsed = urllib.parse.urlsplit(final_url)
    public_url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))
    probe = ffprobe(final_url)
    streams = probe.get("streams") or []
    video = next((s for s in streams if s.get("codec_type") == "video"), {})
    fmt = probe.get("format") or {}

    width = int(video.get("width") or 0) or None
    height = int(video.get("height") or 0) or None
    fps = fraction(video.get("avg_frame_rate")) or fraction(video.get("r_frame_rate"))
    vbr = int(video.get("bit_rate") or 0) or None
    fbr = int(fmt.get("bit_rate") or 0) or None
    size = rp.get("size")
    if not size:
        try:
            size = int(fmt.get("size") or 0) or None
        except Exception:
            pass

    short_edge = min(width, height) if width and height else 0
    pixels = width * height if width and height else 0
    bitrate = vbr or fbr or 0
    return {
        "url": public_url,
        "url_sha256": hashlib.sha256(url.encode()).hexdigest(),
        "host": parsed.hostname,
        "http_status": rp.get("status"),
        "content_type": rp.get("content_type"),
        "size": size,
        "width": width,
        "height": height,
        "short_edge": short_edge or None,
        "fps": round(fps, 3) if fps else None,
        "codec": video.get("codec_name"),
        "video_bitrate": vbr,
        "format_bitrate": fbr,
        "duration": float(fmt.get("duration")) if fmt.get("duration") else None,
        "_rank": [short_edge, pixels, fps or 0, bitrate, size or 0],
        "error": rp.get("error") or probe.get("error"),
    }

def collect_diagnostics():
    diagnostics = {
        "ui_texts": [],
        "resumed_activity": None,
        "frida_hooks": [],
        "network_classes": [],
        "native_bridge": [],
        "install_tail": [],
        "resolved_video_url": None,
        "deeplink_strings": [],
        "native_work_deeplinks": [],
        "frida_setup": [],
        "frida_error": [],
        "frida_probe_console_tail": [],
        "frida_server_log_tail": [],
        "app_cache_hits": [],
    }

    p = OUT / "window-after.xml"
    if p.exists():
        try:
            root = ET.fromstring(p.read_text(errors="ignore"))
            seen = set()
            for node in root.iter("node"):
                for key in ("text", "content-desc"):
                    value = (node.attrib.get(key) or "").strip()
                    if value and value not in seen:
                        seen.add(value)
                        diagnostics["ui_texts"].append(value)
            diagnostics["ui_texts"] = diagnostics["ui_texts"][:200]
        except Exception:
            pass

    p = OUT / "activity.txt"
    if p.exists():
        text = p.read_text(errors="ignore")
        for pattern in (
            r"mResumedActivity:\s+[^\n]*",
            r"topResumedActivity=[^\n]*",
            r"ResumedActivity:[^\n]*",
        ):
            m = re.search(pattern, text)
            if m:
                diagnostics["resumed_activity"] = m.group(0).strip()
                break

    p = OUT / "frida.jsonl"
    if p.exists():
        hooks = []
        classes = []
        for line in p.read_text(errors="ignore").splitlines():
            try:
                row = json.loads(line)
                payload = row.get("message", {}).get("payload")
                if not isinstance(payload, dict):
                    continue
                if payload.get("type") == "hook":
                    hooks.append({
                        "class": payload.get("className"),
                        "ok": payload.get("ok"),
                        "error": payload.get("error"),
                    })
                elif payload.get("type") == "class_inventory":
                    classes.extend(payload.get("classes") or [])
            except Exception:
                pass
        diagnostics["frida_hooks"] = hooks[:100]
        diagnostics["network_classes"] = sorted(set(classes))[:800]

    for filename, key, limit in (
        ("native-bridge.txt", "native_bridge", 100),
        ("install.txt", "install_tail", 40),
        ("native-work-deeplinks.txt", "native_work_deeplinks", 20),
        ("frida-setup.txt", "frida_setup", 50),
        ("frida-error.txt", "frida_error", 50),
        ("frida-probe-console.txt", "frida_probe_console_tail", 120),
        ("frida-server.log", "frida_server_log_tail", 120),
    ):
        p = OUT / filename
        if p.exists():
            lines = [x.strip() for x in p.read_text(errors="ignore").splitlines() if x.strip()]
            diagnostics[key] = lines[-limit:] if key in {
                "install_tail", "frida_probe_console_tail", "frida_server_log_tail"
            } else lines[:limit]

    p = OUT / "deeplink-strings.txt"
    if p.exists():
        lines = [x.strip() for x in p.read_text(errors="ignore").splitlines() if x.strip()]
        diagnostics["deeplink_strings"] = [
            x for x in lines
            if re.search(r"(photo|feed|slide|detail|work|video)", x, re.I)
        ][:250]

    p = OUT / "app-cache-strings.txt"
    if p.exists():
        lines = [x.strip() for x in p.read_text(errors="ignore").splitlines() if x.strip()]
        diagnostics["app_cache_hits"] = [
            x for x in lines
            if re.search(
                r"(5190398778855289322|3xtgkud72h4jz8e|https?://|\.mp4|\.m3u8|"
                r"manifest|adaptation|representation|videoResource|photoUrl|1080|1440|2160|"
                r"H265|HEVC|AVC|bitrate|kwaicdn|kwimgs|yximgs|ndcimgs|djvod|photo-video)",
                x,
                re.I,
            )
        ][:1000]

    p = OUT / "resolved-video-url.txt"
    if p.exists():
        diagnostics["resolved_video_url"] = p.read_text(errors="ignore").strip()

    return diagnostics

urls = collect_urls()
rows = []
seen_public = set()
for url in urls:
    row = summarize(url)
    key = (row["url"], row.get("size"), row.get("codec"), row.get("fps"))
    if key in seen_public:
        continue
    seen_public.add(key)
    rows.append(row)

rows.sort(key=lambda x: tuple(x.get("_rank") or [0, 0, 0, 0, 0]), reverse=True)
for row in rows:
    row.pop("_rank", None)

result = {
    "source_url": os.environ.get("VIDEO_URL") or "https://v.kuaishou.com/7EsP76S3",
    "run_id": os.environ.get("GITHUB_RUN_ID"),
    "commit": os.environ.get("GITHUB_SHA"),
    "candidate_count": len(rows),
    "best": rows[0] if rows else None,
    "candidates": rows,
    "diagnostics": collect_diagnostics(),
}

OUT.mkdir(parents=True, exist_ok=True)
(OUT / "media-probe.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

lines = ["# Kuaishou Android Probe", "", f"Candidates: {len(rows)}", ""]
if rows:
    lines += [
        "| # | Resolution | FPS | Codec | Bitrate | Size | Host | Path |",
        "|---:|---|---:|---|---:|---:|---|---|",
    ]
    for i, r in enumerate(rows, 1):
        res = f"{r.get('width') or '?'}×{r.get('height') or '?'}"
        fps = r.get("fps") or ""
        br = r.get("video_bitrate") or r.get("format_bitrate") or ""
        size = r.get("size") or ""
        path = urllib.parse.urlsplit(r.get("url") or "").path
        lines.append(f"| {i} | {res} | {fps} | {r.get('codec') or ''} | {br} | {size} | {r.get('host') or ''} | `{path}` |")
else:
    lines.append("No media candidates were captured.")
(OUT / "media-probe.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
print(json.dumps(result, ensure_ascii=False, indent=2))
