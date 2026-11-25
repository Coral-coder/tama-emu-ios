// Check of lib/paramix/feld.dart against third_party/paramix-studio/src/feld.js.
// DUMPS=<folder with water.bin, land.bin, ...> node tool/paramix_check/feld.js
// Prints one line per case: "<case name> <sha256 or value>". Same cases as feld_check.dart.
'use strict';
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const SRC = path.join(__dirname, '../../third_party/paramix-studio');
const F = require(SRC + '/src/feld.js'), E = require(SRC + '/src/emu.js');
const bin = (f) => new Uint8Array(fs.readFileSync(path.join(SRC, f)));
// the embedded binaries, as build.js fills the placeholders
const FELD = bin('feld/feld.bin'), STUB = bin('feld/stub_feld_tpl.bin'), FELDC = bin('feld/feldc.bin'), EMUSTUB = bin('emu/stub_tpl.bin');
// (feld_s.bin and feldc_s.bin: feld.js reads them itself in Node, see smallMenu)
const emb = { feld: FELD, stub: STUB }, embStrip = { stub: STUB, oldStub: EMUSTUB }, embStrip0 = { stub: STUB };
const DUMPS = process.env.DUMPS;
const EDS = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];

const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const shaS = (s) => sha(Buffer.from(s, 'latin1'));
const hex = (v) => '0x' + (v >>> 0).toString(16);
const u32 = (b, o) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;
function w32(b, o, v) { b[o] = v & 255; b[o + 1] = (v >>> 8) & 255; b[o + 2] = (v >>> 16) & 255; b[o + 3] = (v >>> 24) & 255; }
function w16(b, o, v) { b[o] = v & 255; b[o + 1] = (v >>> 8) & 255; }
const eq = (a, b) => a.length === b.length && Buffer.compare(Buffer.from(a.buffer, a.byteOffset, a.length), Buffer.from(b.buffer, b.byteOffset, b.length)) === 0;
let count = 0;
function P(name, v) { count++; console.log(name + ' ' + v); }
const err = (e) => 'ERR ' + e.message;
/** Run fn; on an error print it under `name` and return null. */
function T(name, fn) { try { return fn(); } catch (e) { P(name, err(e)); return null; } }

const fmtF = (f) => f ? [f.off, f.stubOff, f.version, f.slotOff, f.slotSize, f.nslots, f.flags, f.catOff, f.catN, f.slotOff2, f.slotN1].map(hex).join(' ') : 'null';
const opt = (v) => v === undefined ? '-' : typeof v === 'number' ? hex(v) : String(v);
function pagesStr(pages) { const h = crypto.createHash('sha256'); for (const [a, d] of pages) { h.update(Buffer.from(hex(a))); h.update(d); } return pages.size + ' ' + h.digest('hex'); }

function info(tag, rom) {
  T(tag + '.info', () => {
    const e = F.edition(rom), id = F.feldId(rom);
    P(tag + '.edition', e ? e.profile.name + ' ' + e.id + ' ' + hex(e.at) : 'null');
    P(tag + '.ids', [id, F.canFields(rom), F.fieldNames(rom).join(','), F.fieldNow(rom), F.familyOf(id), F.isSix(rom), F.appKind(rom), "'" + F.emuType(rom) + "'", F.isClean(rom), F.isLaunch(rom, STUB)].join(' '));
    const ci = F.cleanInfo(rom); P(tag + '.cleanInfo', ci ? hex(ci.feld) + ' ' + hex(ci.clock) : 'null');
    P(tag + '.feldFind', fmtF(F.feldFind(rom, STUB)));
    const a = F.feldApps(rom, STUB);
    P(tag + '.feldApps', shaS(a.name0 + '|' + a.apps.map((x) => hex(x.src) + ':' + x.name).join(';')) + ' ' + a.apps.length + ' ' + [!!a.v9, opt(a.mainSrc), opt(a.auto), opt(a.noClock), opt(a.dl)].join(' '));
    const ss = F.saveSlots(rom, STUB);
    P(tag + '.saveSlots', ss ? ss.saves + ' ' + ss.live + ' ' + ss.list.map((x) => x.used ? 1 : 0).join('') : 'null');
    P(tag + '.fieldOfSettings', F.fieldOfSettings(rom, rom.subarray(0xEFE000, 0xEFF000)) + ' ' + F.fieldOfSettings(rom, rom.subarray(0xEFF000, 0xF00000)) + ' ' + F.fieldOfSettings(rom, null));
    const sl = F.feldSlots(rom, STUB);
    P(tag + '.feldSlots', sl.length);
    sl.forEach((s, k) => {
      P(tag + '.slot' + k, [s.index, s.field, s.bytes, s.pool, s.list.length, hex(s.b), sha(s.head), sha(s.stream)].join(' '));
      T(tag + '.slot' + k + '.pages', () => P(tag + '.slot' + k + '.pages', pagesStr(F.slotPages(s))));
    });
  });
}
function heavy(tag, rom) {
  T(tag + '.itemCatalog', () => {
    const c = F.itemCatalog(rom);
    P(tag + '.itemCatalog', c.length + ' ' + (c.pack === undefined ? -1 : c.pack) + ' ' + shaS(c.map((x) => [x.id, x.fixed === 2 ? 2 : x.fixed ? 1 : 0, x.pic, x.sum, x.at ? [x.at.addr, x.at.len, x.at.sum, x.at.head].join('/') : '-', x.text, x.name].join(',')).join('\n')));
  });
  T(tag + '.characters', () => { const c = F.characters(rom); P(tag + '.characters', c.length + ' ' + shaS(c.map((x) => [x.id, x.stage, x.field, x.name].join(',')).join('\n'))); });
  T(tag + '.textTabelle', () => {
    const tt = F.textTabelle(rom); P(tag + '.textTabelle', hex(tt));
    if (tt >= 0) { const l = []; for (let n = 0; n < 400; n++) l.push(F.zeichenkette(rom, tt, n)); P(tag + '.zeichenkette', shaS(l.join('\n')) + ' ' + shaS(F.FIELD_TEXT.map((n) => F.zeichenkette(rom, tt, n)).join('\n'))); }
  });
}

const APPS2 = [{ src: 0x10200000, name: 'DOOM' }, { src: 0x10300000, name: 'A VERY LONG NAME' }];
const appsN = (n) => { const l = []; for (let i = 0; i < n; i++) l.push({ src: 0x10200000 + 0x10000 * i, name: 'PROG ' + i }); return l; };
const COMBOS = [
  ['fields', { fields: true }],
  ['fieldsNoSaves', { fields: true, saves: false }],
  ['bag', { bag: true }],
  ['tama', { tama: true }],
  ['gplay', { gplay: true }],
  ['all', { fields: true, bag: true, tama: true, gplay: true, name0: 'TAMAEMU PLUS XYZ', apps: APPS2, fieldNames: ['MEADOW HILLS LONG', 'WATER', ''] }],
  ['low', { fields: true, bag: true, appsLow: 0x900000 }],
  ['lowErr', { fields: true, appsLow: 0x840000 }],
  ['launch', { launch: true, fields: true, bag: true, tama: true, apps: appsN(12), dl: 0x10400000, mainSrc: 0x10200000, auto: true }],
  ['launch0', { launch: true }],
  ['none', {}],
  ['apps13', { bag: true, apps: appsN(13) }],
];

function applyCase(tag, base, opts, saved, stripBack) {
  const r = T(tag, () => F.feldApply(base, opts, saved, emb, E));
  if (!r) return null;
  P(tag, sha(r));
  info(tag, r);
  const s = T(tag + '.strip', () => F.feldStrip(r, embStrip, E));
  if (s) { P(tag + '.strip', sha(s)); P(tag + '.strip.same', eq(s, stripBack || base)); }
  const s0 = T(tag + '.strip0', () => F.feldStrip(r, embStrip0, E));
  if (s0) P(tag + '.strip0', sha(s0));
  return r;
}

function lzCases(tag, rom) {
  const pages = [];
  for (let o = 0; o < 0x1000000; o += 0x100000) pages.push(['rom' + hex(o), rom.slice(o, o + 0x1000)]);
  for (const o of [0x11000, 0x111000, 0x112000, 0x234000, 0xD49000, 0xEFE000, 0xEFF000]) pages.push(['rom' + hex(o), rom.slice(o, o + 0x1000)]);
  for (const [n, p] of pages) lzOne(tag + '.lz.' + n, p);
}
function lzOne(tag, p) {
  const c = T(tag, () => F.lzPack(p)); if (!c) return;
  P(tag, c.length + ' ' + sha(c));
  T(tag + '.back', () => P(tag + '.back', eq(F.lzUnpack(c, c.length), p)));
}
function lzSynthetic() {
  const mk = (fn) => { const p = new Uint8Array(0x1000); for (let i = 0; i < 0x1000; i++) p[i] = fn(i) & 255; return p; };
  let x = 12345; const rnd = () => { x = (Math.imul(x, 1103515245) + 12345) >>> 0; return x >>> 16; };
  lzOne('lz.zero', mk(() => 0)); lzOne('lz.ff', mk(() => 0xFF));
  lzOne('lz.random', mk(() => rnd())); lzOne('lz.count', mk((i) => i)); lzOne('lz.period7', mk((i) => i % 7));
  lzOne('lz.period300', mk((i) => (i % 300) * 7 + (i % 300 >> 3)));
  lzOne('lz.mixed', mk((i) => i < 0x400 ? rnd() : i < 0x800 ? 0x55 : i < 0xC00 ? (i * 3) >> 2 : rnd() & 3));
  lzOne('lz.tail', mk((i) => i < 0xFFE ? 9 : i));
  const c = F.lzPack(mk((i) => i % 7));
  const bad = (n, inp, len) => { try { const o = F.lzUnpack(inp, len); P('lz.bad.' + n, sha(o)); } catch (e) { P('lz.bad.' + n, err(e)); } };
  bad('short', c, c.length - 1);
  { const d = new Uint8Array(c.length + 1); d.set(c); bad('long', d, d.length); }
  bad('empty', new Uint8Array(0), 0);
  bad('ref0', Uint8Array.from([0xFF, 0x00, 0x00]), 3);
  bad('lit', Uint8Array.from([0x00, 1, 2, 3]), 4);
  { const d = c.slice(); d[1] ^= 0x5A; d[2] = 0xFF; d[3] = 0xFF; bad('garbage', d, d.length); }
}
function clockCases() {
  const crc = (p) => { let c = 0; for (let i = 4; i < p.length; i++) { c ^= p[i]; for (let k = 0; k < 8; k++) c = c & 1 ? (c >>> 1) ^ 0xA001 : c >>> 1; } return c; };
  const p = new Uint8Array(4096); for (let i = 32; i < 4096; i++) p[i] = (i * 31) >> 4;
  w32(p, 12, 300); w32(p, 16, 40000);
  const c = crc(p); p[0] = c; p[1] = c >> 8; p[2] = ~c; p[3] = ~c >> 8;
  const mk = () => F.slotBuild(new Map([[0xEFE000, p.slice()], [0xEFF000, p.slice()], [0xEFD000, p.slice()]]), 0, 0xEFD000, 0xF00000);
  const stamp = (s, from, to) => { w32(s.head, 4080, 0x43544D50); w32(s.head, 4084, from); w32(s.head, 4088, to); w32(s.head, 4092, (0x43544D50 ^ from ^ to) >>> 0); };
  const run = (n, from, to, breakIt) => {
    const s = mk(); stamp(s, from, to); if (breakIt) breakIt(s);
    P('clock.' + n + '.head', sha(s.head) + ' ' + s.bytes + ' ' + sha(s.stream));
    try { P('clock.' + n, pagesStr(F.slotPages(s))); } catch (e) { P('clock.' + n, err(e)); }
    return s;
  };
  const s = run('rebase', 100, 1000); run('forward', 90000, 5); run('underflow', 0, 0xF0000000); run('sum', 100, 1000, (t) => { t.head[4092] ^= 1; });
  run('stream', 100, 1000, (t) => { t.stream[5] ^= 1; });
  const out = new Uint8Array(0x10000), f = { slotOff: 0x1000, slotSize: 0x4000, nslots: 3 }, used = new Set();
  P('clock.place', F.slotPlace(out, f, 2, s, used).map(hex).join(',') + ' ' + [...used].join(',') + ' ' + sha(out));
  const back = F.slotParse(f, 2, out.subarray(0x9000, 0xA000));
  P('clock.parse', back ? [back.field, back.bytes, back.pool, back.list.map(hex).join(','), hex(back.b)].join(' ') : 'null');
  P('clock.poolAddr', [0, 1, 2, 3, 5, 8].map((k) => hex(F.poolAddr(f, k))).join(',') + ' ' + [0, 1, 2].map((i) => hex(F.slotAddr(f, i))).join(','));
  try { F.slotPlace(out, f, 0, { head: s.head, bytes: 0x9000 + 1, stream: new Uint8Array(0x9001) }, used); P('clock.full', 'placed'); } catch (e) { P('clock.full', err(e)); }
}

async function slotCases(tag, base, ed) {
  const a = T(tag + '.slots.apply', () => F.feldApply(base, { fields: true, bag: true }, [], emb, E));
  if (!a) return;
  const f = F.feldFind(a, STUB);
  if (!f || f.nslots < 2) { P(tag + '.slots', 'noslots'); return; }
  const all = new Map(), two = new Map();
  for (let o = 0xD00000; o < 0xF00000; o += 0x1000) all.set(o, base.slice(o, o + 0x1000));
  for (const o of [0xEFF000, 0xEFE000]) two.set(o, base.slice(o, o + 0x1000));
  const from = ed.at + 0x1000;
  const s0 = F.slotBuild(all, 0, from, 0xF00000), s1 = F.slotBuild(two, 1, 0xEFE000, 0xF00000);
  [s0, s1].forEach((s, k) => {
    P(tag + '.slots.build' + k, [s.field, s.bytes, u32(s.head, 8), sha(s.head), sha(s.stream)].join(' '));
    T(tag + '.slots.build' + k + '.pages', () => {
      const pg = F.slotPages(s); let same = true;
      for (const [x, d] of pg) if (!eq(d, (k ? two : all).get(x))) same = false;
      P(tag + '.slots.build' + k + '.pages', pagesStr(pg) + ' ' + same);
    });
  });
  const a2 = new Uint8Array(a), used = new Set();
  const w0 = T(tag + '.slots.place0', () => F.slotPlace(a2, f, 0, s0, used)); if (w0) P(tag + '.slots.place0', w0.length + ' ' + shaS(w0.map(hex).join(',')) + ' ' + used.size);
  const w1 = T(tag + '.slots.place1', () => F.slotPlace(a2, f, 1, s1, used)); if (w1) P(tag + '.slots.place1', w1.map(hex).join(',') + ' ' + used.size);
  // an old slot (before 1.2.12): the packed data right behind the header
  if (f.nslots > 2) { const b = F.slotAddr(f, 2), h = s1.head.slice(); w32(h, 4, 3); a2.set(h, b); a2.set(s1.stream, b + 0x1000); }
  P(tag + '.slots.image', sha(a2));
  info(tag + '.slots', a2);
  const heads = []; for (let i = 0; i < f.nslots; i++) heads.push(i === 1 && f.nslots > 3 ? null : a2.subarray(F.slotAddr(f, i), F.slotAddr(f, i) + 0x1000));
  for (const skip of [-1, 0, 2]) P(tag + '.slots.poolUsed' + skip, [...F.poolUsed(f, heads, skip)].sort((x, y) => x - y).join(',').length + ' ' + shaS([...F.poolUsed(f, heads, skip)].sort((x, y) => x - y).join(',')));
  for (let i = 0; i < f.nslots; i++) {
    const p = F.slotParse(f, i, a2.subarray(F.slotAddr(f, i), F.slotAddr(f, i) + 0x1000));
    P(tag + '.slots.parse' + i, p ? [p.field, p.bytes, p.pool, p.list.length, hex(p.b)].join(' ') : 'null');
    const r = await F.slotReadAsync(async (addr, len) => a2.slice(addr, addr + len), f, i);
    P(tag + '.slots.async' + i, r ? r.bytes + ' ' + sha(r.stream) : 'null');
  }
  const saved = F.feldSlots(a2, STUB);
  const st = T(tag + '.slots.strip', () => F.feldStrip(a2, embStrip, E));
  if (!st) return;
  P(tag + '.slots.strip', sha(st) + ' ' + eq(st, base));
  applyCase(tag + '.slots.reapply', st, { fields: true, bag: true, tama: true }, saved, base);
  applyCase(tag + '.slots.reapplyLow', st, { fields: true, appsLow: 0x900000 }, saved, base);
  // a save that is too big for the room
  const big = { head: s0.head, field: 1, bytes: f.nslots * f.slotSize, stream: new Uint8Array(f.nslots * f.slotSize), index: 1 };
  applyCase(tag + '.slots.reapplyBig', st, { fields: true }, [big], base);
  applyCase(tag + '.slots.reapplyOut', st, { fields: true }, [Object.assign({}, s1, { index: 9 }), Object.assign({}, s1, { index: -1 })], base);
}

function sixCases(tag, base) {
  for (const [n, ver, fl] of [['six7', 7, 4], ['six6', 6, 0]]) {
    const s = new Uint8Array(base);
    s.fill(0xFF, 0x10F000, 0x110000); w32(s, 0x10F000, 0x31584953); w32(s, 0x10F004, ver); w32(s, 0x10F020, fl);
    s[0xEFE000 + 0xF04] = 1;
    info(tag + '.' + n, s);
    T(tag + '.' + n + '.characters', () => { const c = F.characters(s); P(tag + '.' + n + '.characters', c.length + ' ' + shaS(c.map((x) => [x.id, x.stage, x.field, x.name].join(',')).join('\n'))); });
    const r = applyCase(tag + '.' + n + '.apply', s, { fields: true, bag: true, tama: true, fieldNames: ['A', 'B', 'C', 'D', 'E LONG NAME HERE', 'F'] }, []);
    if (r && n === 'six7') {
      const f = F.feldFind(r, STUB), two = new Map([[0xEFE000, s.slice(0xEFE000, 0xEFF000)], [0xEFF000, s.slice(0xEFF000, 0xF00000)]]), r2 = new Uint8Array(r), used = new Set();
      for (let i = 0; i < f.nslots; i++) T(tag + '.six7.place' + i, () => P(tag + '.six7.place' + i, F.slotPlace(r2, f, i, F.slotBuild(two, i, 0xEFE000, 0xF00000), used).map(hex).join(',')));
      info(tag + '.six7.placed', r2);
      const saved = F.feldSlots(r2, STUB), st = T(tag + '.six7.strip', () => F.feldStrip(r2, embStrip, E));
      if (st) { P(tag + '.six7.strip', sha(st) + ' ' + eq(st, s)); applyCase(tag + '.six7.reapply', st, { fields: true }, saved, s); }
    }
  }
}

function appCases(tag, base) {
  const PMXC = 0x43584D50, PDMC = 0x434D4450;
  const mkApp = (magic, fn) => { const a = new Uint8Array(0x800); for (let i = 0; i < a.length; i++) a[i] = (i * 7) & 0x7F; w32(a, 0x140, magic); for (let i = 0x144; i < 0x400; i += 4) w32(a, i, 0); if (fn) fn(a); return a; };
  const apps = [
    ['tama', mkApp(PMXC, (a) => w32(a, 0x148, 0x900000)), null],
    ['tamaBig', mkApp(PMXC, (a) => w32(a, 0x148, 0x840000)), null],
    ['doom', mkApp(PMXC, (a) => w32(a, 0x150, PDMC)), (r) => r.fill(0x00, 0xB1000, 0xD0000)],
    ['doomFull', mkApp(PMXC, (a) => w32(a, 0x150, PDMC)), (r) => r.fill(0x00, 0xB1000, 0x10E000 - 0x9000)],
    ['t18', mkApp(0x38584D50, (a) => { a.fill(0xFF, 0x140 + 16, 0x140 + 400); w32(a, 0x140 + 12, 2); w16(a, 0x140 + 16, 0xC0); w16(a, 0x140 + 20, 0xF8); w16(a, 0x140 + 272, 0xB8); w32(a, 0x140 + 400, 0); }), null],
    ['t18none', mkApp(0x38584D50, (a) => { a.fill(0xFF, 0x140 + 16, 0x140 + 400); w32(a, 0x140 + 12, 0); w32(a, 0x140 + 400, 0); }), null],
    ['t7', mkApp(0x37584D50), null],
    ['v1', mkApp(0x31584D50), null],
  ];
  for (const [n, app, after] of apps) {
    // raw: only the program at 0x0A0000 (the kind is read from it), installed: through installApp of emu.js
    const raw = new Uint8Array(base); raw.set(app, 0xA0000);
    P(tag + '.' + n + '.raw', [F.appKind(raw), "'" + F.emuType(raw) + "'", hex(E.t18Low(raw))].join(' '));
    applyCase(tag + '.' + n + '.raw.apply', raw, { fields: true, bag: true }, []);
    const inst = T(tag + '.' + n + '.inst', () => E.installApp(base, app, EMUSTUB));
    if (!inst) continue;
    if (after) after(inst);
    P(tag + '.' + n + '.inst', sha(inst));
    info(tag + '.' + n + '.inst', inst);
    applyCase(tag + '.' + n + '.inst.all', inst, { fields: true, bag: true, tama: true, name0: 'MAIN', apps: APPS2 }, []);
    applyCase(tag + '.' + n + '.inst.gplay', inst, { gplay: true }, []);
    applyCase(tag + '.' + n + '.inst.launch', inst, { launch: true, apps: APPS2, dl: 0x10400000 }, []);
  }
}

function cleanCases(tag, rom, base) {
  P(tag + '.cleanReserved', F.cleanReserved().map((x) => x.map(hex).join('-')).join(','));
  const cb = T(tag + '.cleanBase', () => F.cleanBase(rom)); if (!cb) return;
  P(tag + '.cleanBase', sha(cb));
  info(tag + '.cleanBase', cb);
  const ce = { feld: FELDC, stub: STUB };
  const one = (n, src, opts, e) => {
    const r = T(tag + '.clean.' + n, () => F.cleanApply(src, opts, e || ce)); if (!r) return null;
    P(tag + '.clean.' + n, sha(r)); info(tag + '.clean.' + n, r);
    return r;
  };
  const c = one('apps', cb, { apps: appsN(12), dl: 0x10400000, mainSrc: 0x10210000, auto: true, noClock: true });
  one('plain', cb, {});
  one('app', cb, { app: 0x10200001, name0: 'TAMAEMU PLUS XYZ', apps: APPS2, auto: true });
  one('name0NoApp', cb, { name0: 'IGNORED', noClock: true });
  one('spot', cb, { apps: APPS2, spot: { feld: 0xC8000, clock: 0xD8000 } });
  one('apps13', cb, { apps: appsN(13) });
  one('paradise', base, { apps: APPS2 });
  one('oldMenu', cb, {}, { feld: FELD, stub: STUB });
  { const big = new Uint8Array(0xE000 + 4); big.set(FELDC); one('small', cb, { apps: APPS2 }, { feld: big, stub: STUB }); }
  { const bad = new Uint8Array(cb); bad[0] = 0x58; one('noTable', bad, {}); }
  { const bad = new Uint8Array(cb); bad.fill(0xFF, 0xEFD000, 0xEFE000); one('noEdition', bad, {}); }
  T(tag + '.cleanBase.none', () => { const z = new Uint8Array(0x1000000); P(tag + '.cleanBase.none', sha(F.cleanBase(z))); });
  if (c) {
    const again = one('again', c, { apps: F.feldApps(c, STUB).apps, dl: F.feldApps(c, STUB).dl, mainSrc: F.feldApps(c, STUB).mainSrc, auto: F.feldApps(c, STUB).auto, noClock: F.feldApps(c, STUB).noClock, spot: F.cleanInfo(c) });
    if (again) P(tag + '.clean.again.same', eq(again, c));
    T(tag + '.clean.strip', () => P(tag + '.clean.strip', sha(F.feldStrip(c, embStrip, E))));
    T(tag + '.clean.feldApply', () => P(tag + '.clean.feldApply', sha(F.feldApply(c, { bag: true }, [], emb, E))));
  }
}

async function main() {
  lzSynthetic();
  clockCases();
  for (const name of EDS) {
    const file = path.join(DUMPS, name + '.bin');
    if (!fs.existsSync(file)) { P(name, 'missing'); continue; }
    const rom = new Uint8Array(fs.readFileSync(file));
    P(name + '.size', rom.length);
    info(name + '.orig', rom);
    heavy(name + '.orig', rom);
    lzCases(name, rom);
    const base = T(name + '.base', () => F.feldStrip(rom, embStrip, E));
    if (!base) continue;
    P(name + '.base', sha(base) + ' ' + eq(base, rom));
    const ed = F.edition(base);
    const done = {};
    for (const [n, opts] of COMBOS) done[n] = applyCase(name + '.apply.' + n, base, opts, []);
    if (done.fields) T(name + '.apply.twice', () => P(name + '.apply.twice', sha(F.feldApply(done.fields, { bag: true }, [], emb, E))));
    T(name + '.apply.half', () => P(name + '.apply.half', sha(F.feldApply(base.subarray(0, 0x800000), { bag: true }, [], emb, E))));
    for (const k of ['launch', 'launch0']) if (done[k]) {
      const c = new Uint8Array(done[k]), f = F.feldFind(c, STUB);
      P(name + '.launchRestore.' + k, F.launchRestore(c, f.stubOff) + ' ' + sha(c) + ' ' + F.launchRestore(c, f.stubOff) + ' ' + F.launchRestore(c, 0x90000));
    }
    if (ed) await slotCases(name, base, ed);
    sixCases(name, base);
    appCases(name, base);
    cleanCases(name, rom, base);
  }
  console.error('cases: ' + count);
}
main();
