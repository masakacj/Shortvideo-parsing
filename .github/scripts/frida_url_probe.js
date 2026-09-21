'use strict';

const seen = Object.create(null);
let targetIds = [];
let scanTimer = null;
let snapshotBaseline = Object.create(null);

function sendOnce(type, key, payload) {
  const id = type + "\n" + key;
  if (seen[id]) return;
  seen[id] = true;
  send(Object.assign({ type: type, ts: Date.now() }, payload || {}));
}

function normalizeUrl(value) {
  if (value === null || value === undefined) return "";
  const s = String(value);
  const m = s.match(/^https?:\/\/[^\x00-\x20"'<>\\]+/i);
  return m ? m[0] : "";
}

function looksInteresting(url) {
  return /\.mp4(?:$|[?&#])|\.m3u8(?:$|[?&#])|kwaicdn|kwimgs|yximgs|ndcimgs|djvod|\/upic\/|photo-video|manifest|videoresource|adaptation|representation/i.test(url);
}

function report(kind, value, extra) {
  const url = normalizeUrl(value);
  if (!url || !looksInteresting(url)) return;
  const payload = Object.assign({ kind: kind, url: url }, extra || {});
  sendOnce("url", kind + "\n" + (payload.target || "") + "\n" + url, payload);
}

function safeUse(name, fn) {
  try {
    const C = Java.use(name);
    fn(C);
    send({ type: "hook", className: name, ok: true, ts: Date.now() });
  } catch (e) {
    send({ type: "hook", className: name, ok: false, error: String(e), ts: Date.now() });
  }
}

function installJavaHooks() {
  if (typeof Java === "undefined" || !Java.available) {
    send({ type: "java", available: false, ts: Date.now() });
    return;
  }

  Java.perform(function () {
    send({ type: "java", available: true, ts: Date.now() });

    safeUse("java.net.URL", function (C) {
      const init = C.$init.overload("java.lang.String");
      init.implementation = function (s) {
        report("java.net.URL", s);
        return init.call(this, s);
      };
    });

    safeUse("java.net.URI", function (C) {
      const init = C.$init.overload("java.lang.String");
      init.implementation = function (s) {
        report("java.net.URI", s);
        return init.call(this, s);
      };
    });

    safeUse("android.net.Uri", function (C) {
      const parse = C.parse.overload("java.lang.String");
      parse.implementation = function (s) {
        report("Uri.parse", s);
        return parse.call(C, s);
      };
    });

    safeUse("android.webkit.WebView", function (C) {
      const load = C.loadUrl.overload("java.lang.String");
      load.implementation = function (s) {
        report("WebView.loadUrl", s);
        return load.call(this, s);
      };
    });

    safeUse("android.media.MediaPlayer", function (C) {
      const ds = C.setDataSource.overload("java.lang.String");
      ds.implementation = function (s) {
        report("MediaPlayer.setDataSource", s);
        return ds.call(this, s);
      };
    });

    safeUse("okhttp3.Request$Builder", function (C) {
      const u = C.url.overload("java.lang.String");
      u.implementation = function (s) {
        report("okhttp3.Request.Builder.url", s);
        return u.call(this, s);
      };
    });

    safeUse("com.android.okhttp.Request$Builder", function (C) {
      const u = C.url.overload("java.lang.String");
      u.implementation = function (s) {
        report("android.okhttp.Request.Builder.url", s);
        return u.call(this, s);
      };
    });

    safeUse("com.google.android.exoplayer2.upstream.DataSpec$Builder", function (C) {
      const u = C.setUri.overload("android.net.Uri");
      u.implementation = function (uri) {
        report("ExoPlayer.DataSpec.setUri", uri);
        return u.call(this, uri);
      };
    });

    safeUse("androidx.media3.datasource.DataSpec$Builder", function (C) {
      const u = C.setUri.overload("android.net.Uri");
      u.implementation = function (uri) {
        report("Media3.DataSpec.setUri", uri);
        return u.call(this, uri);
      };
    });

    safeUse("org.chromium.net.CronetEngine", function (C) {
      const method = C.newUrlRequestBuilder;
      if (!method) return;
      method.overloads.forEach(function (o) {
        if (o.argumentTypes.length > 0 && o.argumentTypes[0].className === "java.lang.String") {
          o.implementation = function () {
            report("CronetEngine.newUrlRequestBuilder", arguments[0]);
            return o.apply(this, arguments);
          };
        }
      });
    });

    safeUse("org.chromium.net.ExperimentalCronetEngine", function (C) {
      const method = C.newUrlRequestBuilder;
      if (!method) return;
      method.overloads.forEach(function (o) {
        if (o.argumentTypes.length > 0 && o.argumentTypes[0].className === "java.lang.String") {
          o.implementation = function () {
            report("ExperimentalCronetEngine.newUrlRequestBuilder", arguments[0]);
            return o.apply(this, arguments);
          };
        }
      });
    });

    try {
      const classes = Java.enumerateLoadedClassesSync()
        .filter(function (name) {
          return /(kwai|kuaishou|gifshow|cronet|exoplayer|media3)/i.test(name) &&
                 /(player|video|media|network|http|cdn|stream|data)/i.test(name);
        })
        .slice(0, 800);
      send({ type: "class_inventory", classes: classes, ts: Date.now() });
    } catch (e) {
      send({ type: "class_inventory", error: String(e), ts: Date.now() });
    }
  });
}

function safeReadUtf8(ptrValue, maxLen) {
  try {
    return ptrValue.readUtf8String(maxLen || 4096) || "";
  } catch (_) {
    return "";
  }
}

function stringPattern(value, utf16) {
  const bytes = [];
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code > 0x7f) return "";
    bytes.push(code.toString(16).padStart(2, "0"));
    if (utf16) bytes.push("00");
  }
  return bytes.join(" ");
}

function installGetaddrinfoHook() {
  try {
    const p = Module.findGlobalExportByName("getaddrinfo");
    if (!p) return;
    Interceptor.attach(p, {
      onEnter(args) {
        const host = safeReadUtf8(args[0], 512);
        if (/kwaicdn|kwimgs|yximgs|ndcimgs|djvod|kuaishou|gifshow|kwai/i.test(host)) {
          sendOnce("dns", host, { host: host });
        }
      }
    });
    send({ type: "native_hook", name: "getaddrinfo", ok: true, ts: Date.now() });
  } catch (e) {
    send({ type: "native_hook", name: "getaddrinfo", ok: false, error: String(e), ts: Date.now() });
  }
}

function boundedWindow(range, address, radius) {
  const rangeStart = range.base;
  const rangeEnd = range.base.add(range.size);
  let start = address.sub(radius);
  if (start.compare(rangeStart) < 0) start = rangeStart;
  let end = address.add(radius);
  if (end.compare(rangeEnd) > 0) end = rangeEnd;
  const size = end.sub(start).toUInt32();
  return { base: start, size: size };
}

function scanWindowForUrls(windowInfo, target, hitAddress) {
  let urlHits = 0;
  const patterns = [
    "68 74 74 70 73 3a 2f 2f",
    "68 74 74 70 3a 2f 2f"
  ];

  for (const pattern of patterns) {
    let matches = [];
    try {
      matches = Memory.scanSync(windowInfo.base, windowInfo.size, pattern);
    } catch (_) {
      continue;
    }

    for (const match of matches.slice(0, 120)) {
      const raw = safeReadUtf8(match.address, 4096);
      const url = normalizeUrl(raw);
      if (!url || !looksInteresting(url)) continue;
      const distance = Math.abs(match.address.sub(hitAddress).toInt32());
      urlHits += 1;
      report("target-memory", url, {
        target: target,
        distance: distance,
        address: String(match.address)
      });
    }
  }
  return urlHits;
}

function scanWindowForKeywords(windowInfo, target, hitAddress) {
  const keywords = [
    "manifest", "adaptationSet", "representation", "videoResource",
    "photoUrl", "playUrl", "H265", "HEVC", "AVC", "1080", "1440",
    "2160", "bitrate", "qualityLabel", "qualityType", "frameRate",
    "fileSize", "mainMvUrls"
  ];

  let keywordHits = 0;
  for (const keyword of keywords) {
    const pattern = stringPattern(keyword, false);
    if (!pattern) continue;
    let matches = [];
    try {
      matches = Memory.scanSync(windowInfo.base, windowInfo.size, pattern);
    } catch (_) {
      continue;
    }

    for (const match of matches.slice(0, 8)) {
      const snippet = safeReadUtf8(match.address, 1200);
      if (!snippet) continue;
      const distance = Math.abs(match.address.sub(hitAddress).toInt32());
      keywordHits += 1;
      sendOnce("target_snippet", target + "\n" + keyword + "\n" + snippet.slice(0, 700), {
        target: target,
        keyword: keyword,
        distance: distance,
        address: String(match.address),
        snippet: snippet.slice(0, 700)
      });
    }
  }
  return keywordHits;
}

function targetedMemoryScan() {
  if (!targetIds.length) {
    send({ type: "target_scan", targets: [], error: "no targets", ts: Date.now() });
    return;
  }

  const ranges = Process.enumerateRanges("rw-");
  let bytesScanned = 0;
  let targetHits = 0;
  let urlHits = 0;
  let keywordHits = 0;
  const maxRange = 96 * 1024 * 1024;
  const maxTotal = 512 * 1024 * 1024;
  const radius = 2 * 1024 * 1024;
  const windowsSeen = Object.create(null);

  for (const range of ranges) {
    if (bytesScanned >= maxTotal) break;
    if (range.size <= 0 || range.size > maxRange) continue;
    bytesScanned += range.size;

    for (const target of targetIds) {
      const patterns = [
        { encoding: "ascii", value: stringPattern(target, false) },
        { encoding: "utf16le", value: stringPattern(target, true) }
      ];

      for (const spec of patterns) {
        if (!spec.value) continue;
        let matches = [];
        try {
          matches = Memory.scanSync(range.base, range.size, spec.value);
        } catch (_) {
          continue;
        }

        for (const match of matches.slice(0, 10)) {
          targetHits += 1;
          const windowInfo = boundedWindow(range, match.address, radius);
          const windowKey = target + ":" + String(windowInfo.base) + ":" + windowInfo.size;
          if (windowsSeen[windowKey]) continue;
          windowsSeen[windowKey] = true;

          const direct = safeReadUtf8(match.address, 1400);
          sendOnce("target_hit", target + "\n" + spec.encoding + "\n" + String(match.address), {
            target: target,
            encoding: spec.encoding,
            address: String(match.address),
            range_base: String(range.base),
            range_size: range.size,
            direct: direct.slice(0, 1000)
          });

          urlHits += scanWindowForUrls(windowInfo, target, match.address);
          keywordHits += scanWindowForKeywords(windowInfo, target, match.address);
        }
      }
    }
  }

  send({
    type: "target_scan",
    targets: targetIds,
    bytes_scanned: bytesScanned,
    target_hits: targetHits,
    url_hits: urlHits,
    keyword_hits: keywordHits,
    ts: Date.now()
  });
}

function collectMediaUrlSnapshot() {
  const found = Object.create(null);
  let bytesScanned = 0;
  const maxRange = 64 * 1024 * 1024;
  const maxTotal = 256 * 1024 * 1024;
  const patterns = [
    "68 74 74 70 73 3a 2f 2f",
    "68 74 74 70 3a 2f 2f"
  ];

  const ranges = Process.enumerateRanges("rw-");
  for (const range of ranges) {
    if (bytesScanned >= maxTotal) break;
    if (range.size <= 0 || range.size > maxRange) continue;
    if (bytesScanned + range.size > maxTotal) break;
    bytesScanned += range.size;

    for (const pattern of patterns) {
      let matches = [];
      try {
        matches = Memory.scanSync(range.base, range.size, pattern);
      } catch (_) {
        continue;
      }

      for (const match of matches.slice(0, 250)) {
        const raw = safeReadUtf8(match.address, 4096);
        const url = normalizeUrl(raw);
        if (url && looksInteresting(url)) {
          found[url] = true;
        }
      }
    }
  }

  return { urls: Object.keys(found), bytesScanned: bytesScanned };
}

function temporalSnapshot(label) {
  const snap = collectMediaUrlSnapshot();
  const added = [];

  if (label === "baseline") {
    snapshotBaseline = Object.create(null);
    snap.urls.forEach(function (url) {
      snapshotBaseline[url] = true;
    });
  } else {
    snap.urls.forEach(function (url) {
      if (!snapshotBaseline[url]) {
        added.push(url);
        report("snapshot-delta", url, { snapshot: label });
        snapshotBaseline[url] = true;
      }
    });
  }

  send({
    type: "snapshot",
    label: label,
    total_urls: snap.urls.length,
    new_urls: added.length,
    bytes_scanned: snap.bytesScanned,
    ts: Date.now()
  });

  return {
    label: label,
    total_urls: snap.urls.length,
    new_urls: added.length,
    bytes_scanned: snap.bytesScanned
  };
}

function nativeInit() {
  try {
    const modules = Process.enumerateModules()
      .filter(function (m) {
        return /(kwai|kuaishou|gifshow|cronet|ssl|http|net|player|media|video)/i.test(m.name);
      })
      .slice(0, 300)
      .map(function (m) {
        return { name: m.name, base: String(m.base), size: m.size, path: m.path };
      });
    send({
      type: "native_info",
      arch: Process.arch,
      platform: Process.platform,
      pid: Process.id,
      modules: modules,
      ts: Date.now()
    });
  } catch (e) {
    send({ type: "native_info", error: String(e), ts: Date.now() });
  }

  installGetaddrinfoHook();
}

rpc.exports = {
  snapshot: function (label) {
    return temporalSnapshot(String(label || "snapshot"));
  },
  configure: function (ids) {
    targetIds = (ids || []).map(String).filter(function (x, i, a) {
      return x && a.indexOf(x) === i;
    });
    send({ type: "target_config", targets: targetIds, ts: Date.now() });

    if (scanTimer !== null) {
      clearInterval(scanTimer);
      scanTimer = null;
    }

    targetedMemoryScan();
    scanTimer = setInterval(targetedMemoryScan, 8000);
    return targetIds;
  }
};

nativeInit();
installJavaHooks();
