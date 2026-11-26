// Check of lib/paramix/visit.dart against third_party/paramix-studio/src/visit.js (the original).
// node tool/paramix_check/visit.js        (no dumps needed; VERBOSE=1 prints every transcript)
// Prints one line per case: "<case name> <value or sha256>". tool/paramix_check/visit_check.dart prints the same.
// The Paradise side is scripted with fixed bytes (test key, fixed nonces); everything the module sends and logs is
// recorded in order. The waits of the module (150 ms, 2 s, 3 s, 5 s) are shortened for the cases about them.
'use strict';
const path = require('path'), crypto = require('crypto');
let SCALE = 1;
const realTimeout = globalThis.setTimeout, realInterval = globalThis.setInterval;
globalThis.setTimeout = (f, ms, ...a) => realTimeout(f, (ms || 0) * SCALE, ...a);
globalThis.setInterval = (f, ms, ...a) => realInterval(f, (ms || 0) * SCALE, ...a);
// fixed nonces: a counter instead of random bytes
let nonceN = 0;
const fixedRandom = (n) => { nonceN++; for (let i = 0; i < n.length; i++) n[i] = (nonceN * 37 + i * 11 + (nonceN >> 8)) & 255; return n; };
try { globalThis.crypto.getRandomValues = fixedRandom; } catch (e) {}
if (globalThis.crypto.getRandomValues !== fixedRandom) Object.defineProperty(globalThis.crypto, 'getRandomValues', { value: fixedRandom, configurable: true });
const V = require(path.join(__dirname, '..', '..', 'third_party', 'paramix-studio', 'src', 'visit.js'));

const lines = [];
const sha = (b) => crypto.createHash('sha256').update(Buffer.from(b.buffer, b.byteOffset, b.length)).digest('hex');
const shaS = (s) => crypto.createHash('sha256').update(Buffer.from(s, 'utf8')).digest('hex');
const out = (n, v) => { lines.push(n + ' ' + v); };
const enc = (s) => new TextEncoder().encode(s);
const sleep = (ms) => new Promise((r) => realTimeout(r, ms));
const key = V.parseKey('TestKeyOnly-NotTheReal-0123456789');
const SID = 0xEB24098E;

async function chunk(sid, type, idx, data, o) {
  o = o || {};
  const p = new Uint8Array(12 + data.length);
  p[0] = sid & 255; p[1] = sid >> 8 & 255; p[2] = sid >> 16 & 255; p[3] = sid >>> 24;
  p[4] = 0x54; p[5] = 0x43; p[6] = 0x50; p[7] = type; p[8] = idx; p[9] = 255 - idx;
  const c = V.crc16(data) ^ (o.badCrc ? 0x0101 : 0); p[10] = c & 255; p[11] = c >> 8; p.set(data, 12);
  const n = new Uint8Array([idx, 7, 9, 11 + (o.n || 0)]), e = await V.crypt(n, o.key || key, p), all = new Uint8Array(4 + e.length);
  all.set(n); all.set(e, 4); return all;
}
function mine(seed) {
  const m = new Uint8Array(0x20014); for (let i = 0; i < m.length; i++) m[i] = (i * 31 + 7 + seed) & 255;
  m[0x20002] = 1; m[0x20004] = 0x8E; return m;
}

/* one scripted visit: tr is the transcript (sends and log events in order) */
function session(edition, scale) {
  SCALE = scale; nonceN = 0;
  const tr = [];
  const rec = (b) => {
    let txt = b.length <= 40 && b.length >= 2 && b[b.length - 2] === 13 && b[b.length - 1] === 10;
    for (let i = 0; txt && i < b.length - 2; i++) if (b[i] < 32 || b[i] > 126) txt = false;
    tr.push(txt ? 'S "' + Buffer.from(b.subarray(0, b.length - 2)).toString('latin1') + '"' : 'S ' + b.length + ':' + sha(b));
  };
  const v = V.createVisitor({ edition, key, send: async (b) => { rec(b); }, log: (e, i) => { tr.push('L ' + e + ' ' + Object.keys(i).map((k) => k + '=' + String(i[k])).join(',')); } });
  const s = { v, tr };
  /* feed, then wait until n more entries are in the transcript (or 6 s) */
  s.step = async (bytes, n) => {
    const want = tr.length + n;
    await v.feed(typeof bytes === 'string' ? enc(bytes) : bytes);
    for (let i = 0; i < 3000 && tr.length < want; i++) await sleep(2);
    if (tr.length < want) tr.push('TIMEOUT');
  };
  s.until = async (n, ms) => { const want = tr.length + n; for (let i = 0; i < ms / 2 && tr.length < want; i++) await sleep(2); if (tr.length < want) tr.push('TIMEOUT'); };
  s.packet = async (type, data, extra) => {
    await s.step('PKT ' + data.length + '\r\n', tr.length === 0 ? 2 : 1);
    const n = Math.ceil(data.length / 0x1000);
    for (let i = 0; i < n; i++) await s.step(await chunk(SID, type, i, data.subarray(i * 0x1000, (i + 1) * 0x1000)), 1 + (i === n - 1 ? extra : 0));
  };
  s.open = async (seed) => { await s.packet(0x11, new Uint8Array([0xAB, 0xAB]), 1); await s.packet(0x01, mine(seed), 2); };   // ... 'PKT 131092' is out
  s.answer = async () => { await s.step('ACK\r\n', 1); for (let i = 0; i < 33; i++) await s.step('ACK\r\n', 1); };             // 33 chunks, then 'sent'
  s.end = async (name) => { await sleep(40); v.stop(); await sleep(20); out('visit.' + name, tr.length + ' ' + shaS(tr.join('\n')) + ' ' + v.state.phase + ',' + v.state.got + ',' + (v.state.sid >>> 0).toString(16) + ',' + String(v.state.result)); if (process.env.VERBOSE) tr.forEach((x, i) => out('  ' + name + '[' + i + ']', x)); };
  return s;
}

(async () => {
  // ---- pure functions
  out('ED', Object.keys(V.ED).map((k) => k + '=' + V.ED[k]).join(','));
  for (const [n, x] of [['text', 'TestKeyOnly-NotTheReal-0123456789'], ['short', 'short'], ['spaces', '  0123456789abcdef \r\n'], ['inner', '0123456789 abcdefghij'], ['long', 'x'.repeat(64)], ['toolong', 'x'.repeat(65)],
    ['bytes', enc('KeyFromAFile-0123456789ABCDEF\n')], ['bytes8', new Uint8Array([0x85, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51])],
    ['nbsp', new Uint8Array([0xA0, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0xA0])], ['empty', ''], ['ctl', '0123456789abcdef\x01']]) {
    const k = V.parseKey(x); out('parseKey.' + n, k ? k.length + ':' + sha(k) : 'null');
  }
  for (const n of [0, 1, 2, 255, 4096, 70000]) { const d = new Uint8Array(n); for (let i = 0; i < n; i++) d[i] = (i * 73 + n) & 255; out('crc16.' + n, V.crc16(d)); }
  for (const n of [0, 1, 31, 32, 33, 100, 4108]) {
    const d = new Uint8Array(n); for (let i = 0; i < n; i++) d[i] = (i * 5 + 3) & 255;
    const c = await V.crypt(new Uint8Array([1, 2, 3, n & 255]), key, d), b = await V.crypt(new Uint8Array([1, 2, 3, n & 255]), key, c);
    out('crypt.' + n, n + ':' + sha(c) + ' back=' + (Buffer.compare(Buffer.from(b), Buffer.from(d)) === 0 ? 1 : 0));
  }
  for (const ed of ['nowhere', 0, '', 'WATER', 6, 300]) {
    try { const v = V.createVisitor({ edition: ed, key, send: async () => {} }); out('edition.' + ed, 'ok ' + v.state.phase); v.stop(); } catch (e) { out('edition.' + ed, 'ERR ' + e.message); }
  }

  // ---- a whole visit, for every edition (names and numbers), without and with breeding
  for (const [ed, breed] of [['sky', false], ['land', false], ['water', true], ['Jade', false], ['tropics', true], ['glacier', false], [5, true], [2, false], [300, false]]) {
    const s = session(ed, 1);
    await s.open(typeof ed === 'number' ? ed : ed.length);
    await s.answer();
    await s.step('ECHO REQ\r\n', 1);
    await s.packet(0x01, new Uint8Array([4, 0]), 1);
    await s.packet(0x01, new Uint8Array([7, 1, breed ? 1 : 0, 0]), 2 + (breed ? 1 : 0));
    if (breed) { await s.step('SYNC 1\r\n', 0); await s.step('CAN\r\n', 1); }
    await s.end('visit.' + ed + (breed ? '.breed' : ''));
  }

  // ---- broken input: wrong CRC, wrong index, wrong key, other session, split and odd lines
  {
    const s = session('water', 1);
    await s.step('\r\n', 0); await s.step('FOO 1 2\r\n', 0); await s.step('PKT\r\n', 0); await s.step('PKT 0\r\n', 0); await s.step('PKT abc\r\n', 0); await s.step('PKT 9999999\r\n', 0);
    await s.step('ECHO\r\n', 0); await s.step('ECHO REP\r\n', 0); await s.step('  ACK  \r\n', 0); await s.step('NAK\r\n', 0); await s.step('ENQ 3\r\n', 0); await s.step('SYNC 1\r\n', 0);
    await s.step(new Uint8Array(300).fill(0x41), 0); await s.step('zz\r\n', 0);                       // more than 256 bytes without a line end
    await s.step('  ECHO \t REQ  \r\n', 1);
    for (const c of 'PKT 0x2\r') await s.step(c, 0);                                                    // byte by byte, the length as a hex number
    await s.step('\n', 2);
    const good = await chunk(SID, 0x11, 0, new Uint8Array([0xAB, 0xAB]));
    await s.step(await chunk(SID, 0x11, 0, new Uint8Array([0xAB, 0xAB]), { badCrc: true }), 1);       // NAK
    await s.step(await chunk(SID, 0x11, 1, new Uint8Array([0xAB, 0xAB])), 1);                         // ENQ 0
    await s.step(await chunk(SID, 0x11, 0, new Uint8Array([0xAB, 0xAB]), { key: enc('AnotherKey-0123456789-abcdefgh') }), 2);   // NAK, error key
    await s.step(await chunk(SID, 0x11, 0, new Uint8Array([0xAB, 0xAB]), { key: enc('AnotherKey-0123456789-abcdefgh'), n: 1 }), 1);   // NAK only
    await s.step(good.subarray(0, 5), 0); await s.step(good.subarray(5, 17), 0); await s.step(good.subarray(17), 2);   // in three pieces
    await s.step('PKT 6000\r\n', 1);
    const d = new Uint8Array(6000); for (let i = 0; i < d.length; i++) d[i] = (i * 7) & 255;
    await s.step(await chunk(0x12345678, 0x01, 0, d.subarray(0, 0x1000)), 1);                          // another session: NAK
    await s.step(await chunk(SID, 0x01, 0, d.subarray(0, 0x1000)), 1);
    const c1 = await chunk(SID, 0x01, 1, d.subarray(0x1000)), two = new Uint8Array(c1.length + 10); two.set(c1); two.set(enc('ECHO REQ\r\n').subarray(0, 10), c1.length);
    await s.step(two, 3); await s.step('\n', 0);                                                        // ACK, packet other, ECHO REP in one read ... the line end later
    await s.step('PKT 3\r\n', 1);
    await s.step('ECHO REQ\r\nECHO REQ\r\n', 1);                                                      // taken as the chunk (19 bytes): NAK, one byte left
    await s.step('ECHO REQ\r\nECHO REQ', 1);                                                           // 18 more: NAK again
    await s.end('broken');
  }

  // ---- our packet: NAK and ENQ from the Paradise, then CAN while playing
  {
    const s = session('glacier', 1);
    await s.open(3);
    await s.step('NAK\r\n', 0);                    // nothing sent yet
    await s.step('ACK\r\n', 1); await s.step('NAK\r\n', 1); await s.step('ACK\r\n', 1); await s.step('ENQ 5\r\n', 1); await s.step('ACK\r\n', 1);
    await s.step('ENQ 32\r\n', 1); await s.step('ENQ 40\r\n', 1); await s.step('ENQ x\r\n', 1); await s.step('ENQ 31\r\nACK\r\nACK\r\n', 3);
    await s.step('ACK\r\n', 0); await s.step('CAN\r\n', 1); await s.step('CAN\r\n', 1);
    await s.end('resend');
  }
  // ---- our packet cancelled by the Paradise
  {
    const s = session('land', 1);
    await s.open(4); await s.step('ACK\r\n', 1); await s.step('CAN\r\n', 1); await s.step('ACK\r\n', 0);
    await s.end('cancel');
  }
  // ---- nobody answers our PKT: twice again, then CAN
  {
    const s = session('sky', 0.05);
    await s.open(5); await s.until(4, 3000);
    await s.end('noAck');
  }
  // ---- a chunk is not acknowledged: twice again, then the error
  {
    const s = session('jade', 0.05);
    await s.open(6); await s.step('ACK\r\n', 1); await s.until(3, 4000);
    await s.end('noChunkAck');
  }
  // ---- while playing we ping
  {
    const s = session('tropics', 0.05);
    await s.open(7); await s.answer(); await s.until(2, 3000);
    s.v.stop(); await sleep(400);
    await s.end('echo');
  }
  // ---- stopped while the answer is being prepared
  {
    const s = session('water', 1);
    await s.packet(0x11, new Uint8Array([0xAB, 0xAB]), 1);
    await s.step('PKT 131092\r\n', 1);
    const m = mine(8);
    for (let i = 0; i < 33; i++) await s.step(await chunk(SID, 0x01, i, m.subarray(i * 0x1000, (i + 1) * 0x1000)), i === 32 ? 2 : 1);
    s.v.stop(); await s.v.feed(enc('ECHO REQ\r\n')); await sleep(400);
    await s.end('stop');
  }
  console.log(lines.join('\n'));
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
