'use strict';

const seen = Object.create(null);
function report(kind, value) {
  if (value === null || value === undefined) return;
  const s = String(value);
  if (!/^https?:\/\//i.test(s)) return;
  const key = kind + "\n" + s;
  if (seen[key]) return;
  seen[key] = true;
  send({ type: "url", kind: kind, url: s, ts: Date.now() });
}

function safeUse(name, fn) {
  try {
    const C = Java.use(name);
    fn(C);
    send({ type: "hook", className: name, ok: true });
  } catch (e) {
    send({ type: "hook", className: name, ok: false, error: String(e) });
  }
}

Java.perform(function () {
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

  safeUse("com.google.android.exoplayer2.upstream.DefaultHttpDataSource", function (C) {
    const open = C.open.overload("com.google.android.exoplayer2.upstream.DataSpec");
    open.implementation = function (spec) {
      try { report("ExoPlayer.DefaultHttpDataSource.open", spec.uri.value.toString()); } catch (_) {}
      return open.call(this, spec);
    };
  });

  safeUse("androidx.media3.datasource.DefaultHttpDataSource", function (C) {
    const open = C.open.overload("androidx.media3.datasource.DataSpec");
    open.implementation = function (spec) {
      try { report("Media3.DefaultHttpDataSource.open", spec.uri.value.toString()); } catch (_) {}
      return open.call(this, spec);
    };
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
