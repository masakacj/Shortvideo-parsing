'use strict';

const seen = Object.create(null);

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

function report(kind, value) {
  const url = normalizeUrl(value);
  if (!url || !looksInteresting(url)) return;
  sendOnce("url", kind + "\n" + url, { kind: kind, url: url });
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
    return ptrValue.readUtf8String(maxLen || 2048) || "";
  } catch (_) {
    return "";
  }
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

function scanMemoryForUrls() {
  let scanned = 0;
  let hits = 0;
  const maxTotal = 192 * 1024 * 1024;
  const maxRange = 64 * 1024 * 1024;
  const patterns = [
    "68 74 74 70 73 3a 2f 2f",
    "68 74 74 70 3a 2f 2f"
  ];

  try {
    const ranges = Process.enumerateRanges("rw-");
    for (const range of ranges) {
      if (scanned >= maxTotal) break;
      if (range.size <= 0 || range.size > maxRange) continue;
      if (scanned + range.size > maxTotal) break;
      scanned += range.size;

      for (const pattern of patterns) {
        let matches = [];
        try {
          matches = Memory.scanSync(range.base, range.size, pattern);
        } catch (_) {
          continue;
        }

        for (const match of matches.slice(0, 40)) {
          const raw = safeReadUtf8(match.address, 2048);
          const url = normalizeUrl(raw);
          if (url && looksInteresting(url)) {
            hits += 1;
            report("native-memory", url);
          }
        }
      }
    }
  } catch (e) {
    send({ type: "memory_scan", error: String(e), ts: Date.now() });
    return;
  }

  send({ type: "memory_scan", scanned_bytes: scanned, hits: hits, ts: Date.now() });
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
  scanMemoryForUrls();
  setInterval(scanMemoryForUrls, 7000);
}

nativeInit();
installJavaHooks();
