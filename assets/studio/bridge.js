/* Tama: bridge between Paramix Studio (in the app's web view) and the app.
 * - navigator.serial (Web Serial) backed by the app's UART connection (BLE, USB, TCP)
 * - downloads (a[download] with blob URLs) go to the app (save, share, add to library)
 * - the app can hand a file to one of the Studio's file inputs
 * Messages to the app: TamaBridge.postMessage(JSON). Replies: window.__tamaReply(id, ok, value). */
(function () {
  'use strict';
  function post(o) { try { window.TamaBridge.postMessage(JSON.stringify(o)); } catch (e) { console.log('TamaBridge missing', e); } }
  function b64e(u8) { var s = ''; for (var i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return btoa(s); }
  function b64d(s) { var bin = atob(s), u = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u; }
  var seq = 0, pending = {};
  function call(t, extra) {
    return new Promise(function (res, rej) { var id = ++seq; pending[id] = { res: res, rej: rej }; var o = extra || {}; o.t = t; o.id = id; post(o); });
  }
  window.__tamaReply = function (id, ok, val) { var p = pending[id]; if (!p) return; delete pending[id]; if (ok) p.res(val); else p.rej(new Error(val || 'failed')); };

  // ---- Web Serial ----
  function Port() { this._open = false; this._ctrl = null; this.readable = null; this.writable = null; }
  Port.prototype._newReadable = function () {
    var self = this;
    this.readable = new ReadableStream({
      start: function (c) { self._ctrl = c; },
      cancel: function () { self._ctrl = null; if (self._open) self._newReadable(); }
    });
  };
  Port.prototype.open = async function (opts) {
    await call('open', { baud: (opts && opts.baudRate) || 460800 });
    this._open = true; this._newReadable();
    this.writable = new WritableStream({
      write: function (chunk) { var u = chunk instanceof Uint8Array ? chunk : new Uint8Array(chunk.buffer || chunk); return call('write', { b64: b64e(u) }); }
    });
  };
  Port.prototype.close = async function () {
    this._open = false;
    try { if (this._ctrl) this._ctrl.close(); } catch (e) {}
    this._ctrl = null; this.readable = null; this.writable = null;
    await call('close');
  };
  Port.prototype.setSignals = function (s) { return call('signals', s || {}); };
  Port.prototype.getSignals = async function () { return { dataCarrierDetect: false, clearToSend: true, ringIndicator: false, dataSetReady: true }; };
  Port.prototype.getInfo = function () { return {}; };
  Port.prototype.forget = async function () {};
  Port.prototype.addEventListener = function () {};
  Port.prototype.removeEventListener = function () {};
  var thePort = null;
  window.__tamaSerialRx = function (b64) { if (thePort && thePort._ctrl) { try { thePort._ctrl.enqueue(b64d(b64)); } catch (e) {} } };
  window.__tamaSerialGone = function () { if (thePort && thePort._ctrl) { try { thePort._ctrl.error(new Error('disconnected')); } catch (e) {} thePort._ctrl = null; } };
  var serial = {
    requestPort: async function () { await call('requestPort'); thePort = thePort || new Port(); return thePort; },
    getPorts: async function () { return thePort ? [thePort] : []; },
    addEventListener: function () {}, removeEventListener: function () {}
  };
  try { Object.defineProperty(navigator, 'serial', { value: serial, configurable: true }); } catch (e) { navigator.serial = serial; }

  // ---- downloads ----
  var CH = 512 * 1024;
  function sendFile(name, u8) {
    post({ t: 'fileStart', name: name, size: u8.length });
    for (var i = 0; i < u8.length; i += CH) post({ t: 'fileChunk', b64: b64e(u8.subarray(i, i + CH)) });
    post({ t: 'fileEnd', name: name });
  }
  var revoke = URL.revokeObjectURL.bind(URL);
  URL.revokeObjectURL = function (u) { setTimeout(function () { revoke(u); }, 60000); };
  document.addEventListener('click', function (ev) {
    var a = ev.target && ev.target.closest ? ev.target.closest('a[download]') : null;
    if (!a || !a.href) return;
    ev.preventDefault(); ev.stopPropagation();
    fetch(a.href).then(function (r) { return r.arrayBuffer(); }).then(function (b) { sendFile(a.download || 'download.bin', new Uint8Array(b)); })
      .catch(function (e) { post({ t: 'log', msg: 'download failed: ' + e }); });
  }, true);

  // ---- files from the app ----
  var inParts = [], inName = '';
  window.__tamaFileBegin = function (name) { inParts = []; inName = name; };
  window.__tamaFileChunk = function (b64) { inParts.push(b64d(b64)); };
  window.__tamaFileEnd = function (inputId) {
    var f = new File(inParts, inName, { type: 'application/octet-stream' }); inParts = [];
    var el = document.getElementById(inputId);
    if (!el) { post({ t: 'log', msg: 'no input ' + inputId }); return; }
    var dt = new DataTransfer(); dt.items.add(f); el.files = dt.files;
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };
  window.addEventListener('error', function (e) { post({ t: 'log', msg: 'JS error: ' + e.message }); });
  post({ t: 'ready' });
})();
