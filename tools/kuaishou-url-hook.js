'use strict';

function emit(kind, value) {
  try {
    const s = String(value || '');
    if (/^https?:\/\//i.test(s)) {
      console.log('[KSURL][' + kind + '] ' + s);
    }
  } catch (_) {}
}

Java.perform(function () {
  try {
    const URL = Java.use('java.net.URL');
    const init = URL.$init.overload('java.lang.String');
    init.implementation = function (s) {
      emit('java.net.URL', s);
      return init.call(this, s);
    };
  } catch (e) {
    console.log('[HOOKERR][URL] ' + e);
  }

  try {
    const Uri = Java.use('android.net.Uri');
    const parse = Uri.parse.overload('java.lang.String');
    parse.implementation = function (s) {
      emit('Uri.parse', s);
      return parse.call(this, s);
    };
  } catch (e) {
    console.log('[HOOKERR][Uri] ' + e);
  }

  try {
    const Builder = Java.use('okhttp3.Request$Builder');
    const urlString = Builder.url.overload('java.lang.String');
    urlString.implementation = function (s) {
      emit('okhttp', s);
      return urlString.call(this, s);
    };
  } catch (e) {
    console.log('[HOOKINFO] okhttp3 hook unavailable: ' + e);
  }

  try {
    const HttpUrl = Java.use('okhttp3.HttpUrl');
    const get = HttpUrl.get.overload('java.lang.String');
    get.implementation = function (s) {
      emit('HttpUrl.get', s);
      return get.call(this, s);
    };
  } catch (e) {
    console.log('[HOOKINFO] HttpUrl hook unavailable: ' + e);
  }
});
