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
});
