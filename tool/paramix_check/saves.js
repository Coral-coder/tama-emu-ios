// Reference output of Paramix Studio's saves.js for saves_check.dart.
// DUMPS=<folder with water.bin ...> node tool/paramix_check/saves.js
// One line per case: <case name> <sha256 or value>. Only hashes, sizes and offsets are printed.
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const SRC = path.join(__dirname, '../../third_party/paramix-studio/src');
const C = require(path.join(SRC, 'core.js')); globalThis.ParamixCore = C;
const S = require(path.join(SRC, 'saves.js'));
const DUMPS = process.env.DUMPS;
const EDS = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];
const sha = (b) => crypto.createHash('sha256').update(Buffer.from(b)).digest('hex');
const out = (n, v) => console.log(n + ' ' + v);
const w32 = (b, o, v) => { b[o] = v & 255; b[o + 1] = (v >>> 8) & 255; b[o + 2] = (v >>> 16) & 255; b[o + 3] = (v >>> 24) & 255; };
const u16 = (b, o) => b[o] | (b[o + 1] << 8);
function rng(seed) { let s = seed >>> 0; return () => { s = (Math.imul(s, 1103515245) + 12345) >>> 0; return (s >>> 16) & 255; }; }
function fill(b, a, n, r) { for (let i = 0; i < n; i++) b[a + i] = r(); }
const err = (f) => { try { return f(); } catch (e) { return 'err:' + e.message; } };
// pages of a save as one hash: address, length and bytes of each page in the order of the map
function pagesSha(pages) { const h = crypto.createHash('sha256'); for (const [a, d] of pages) { const t = new Uint8Array(8); w32(t, 0, a); w32(t, 4, d.length); h.update(t); h.update(d); } return pages.size + ':' + h.digest('hex'); }
const saveStr = (sv) => [sv.stamp, sv.counter, sv.alarm, sv.status, JSON.stringify(sv.regs), sv.edition, pagesSha(sv.pages)].join('|');
const checkStr = (c) => JSON.stringify(c.errors) + JSON.stringify(c.warnings) + c.complete + '|' + pagesSha(c.pages);
const crcFix = (p) => { const c = S.crc16arc(p, 4, 0x1000); p[0] = c & 255; p[1] = c >> 8; p[2] = ~c & 255; p[3] = (~c >> 8) & 255; };

(async () => {
  // ---- plain values
  for (let e = 0; e <= 9; e++) out('ed' + e, [S.idPage(e), JSON.stringify(S.region(e)), S.family(e), JSON.stringify(S.setAddrs(e))].join('|'));
  out('KINDS', JSON.stringify(S.KINDS));
  out('T7_EE', S.T7_EE);
  { const r = rng(7), b = new Uint8Array(0x1000); fill(b, 0, 0x1000, r);
    out('crc16arc', S.crc16arc(b, 4, 0x1000) + ' ' + S.crc16arc(b, 0, 100) + ' ' + S.crc16arc(b, 9, 9));
    out('settingsOk.bad', S.settingsOk(b)); crcFix(b); out('settingsOk.good', S.settingsOk(b)); }

  // ---- every edition
  for (const name of EDS) {
    const rom = new Uint8Array(fs.readFileSync(path.join(DUMPS, name + '.bin')));
    const ed = C.openRom(rom).editionId, P = (n, v) => out(name + '.' + n, v);
    P('edition', ed);
    const pages = S.paraFromImage(rom, ed);
    P('paraFromImage', pagesSha(pages));
    const so = S.setOf(pages, ed);
    P('setOf', so ? so.at + ' ' + sha(so.p) + ' ' + S.settingsOk(so.p) : 'null');
    const file = S.paraEncode(pages, ed, { counter: 123456, ctrl: 0xE0 }, 1700000000);
    P('paraEncode', file.length + ' ' + sha(file));
    P('paraEncode.noclock', sha(S.paraEncode(pages, ed, null, 1700000000)));
    P('paraEncode.ctrl', sha(S.paraEncode(pages, ed, { counter: 0xFFFFFFFF, ctrl: 0x1E5 }, 1800000000)));
    P('paraEncode.ctrl2', sha(S.paraEncode(pages, ed, { counter: 1, ctrl: 0x61 }, 5)));
    const sv = S.paraDecode(file);
    P('paraDecode', saveStr(sv));
    P('paraDecode.noclock', saveStr(S.paraDecode(S.paraEncode(pages, ed, null, 1700000000))));
    P('paraWrite', sha(S.paraWrite(sv)));
    P('paraWrite.same', sha(S.paraWrite(sv)) === sha(file));
    for (const e2 of [1, 4, 6, 7, 8]) P('paraWrite.ed' + e2, sha(S.paraWrite(sv, e2)));
    { const f2 = file.slice(); w32(f2, 12, 0x89ABCDEF); w32(f2, 16, 0x1234); const s2 = S.paraDecode(f2); P('paraWrite.stamp', s2.stamp + ' ' + (sha(S.paraWrite(s2)) === sha(f2)) + ' ' + S.paraClock(s2, 1700000000) + ' ' + S.paraClock(s2, 0x1234 * 4294967296 + 0x89ABCDEF + 77)); }
    for (let e2 = 1; e2 <= 8; e2++) P('paraCheck.ed' + e2, checkStr(S.paraCheck(sv, e2)));
    for (let e2 = 1; e2 <= 8; e2++) P('paraCheck.notrailer.ed' + e2, checkStr(S.paraCheck(Object.assign({}, sv, { edition: 0 }), e2)));
    const part = Object.assign({}, sv, { pages: new Map([...sv.pages].filter(([a]) => a >= 0xEF0000)) });
    P('paraCheck.part', checkStr(S.paraCheck(part, ed)));
    const part2 = Object.assign({}, sv, { pages: new Map([...sv.pages].filter(([a]) => a < 0xEF0000 && (a & 0x3000) === 0)) });
    P('paraCheck.part2', checkStr(S.paraCheck(part2, ed)));
    { const m = new Map(sv.pages); m.set(0x100000, new Uint8Array(0x1000).fill(3)); m.set(0xF00000, new Uint8Array(0x1000)); m.set(S.region(ed)[0] + 0x3000, new Uint8Array(100).fill(9));
      const odd = Object.assign({}, sv, { pages: m });
      P('paraCheck.outside', checkStr(S.paraCheck(odd, ed)));
      const f3 = S.paraWrite(odd); P('paraWrite.odd', f3.length + ' ' + sha(f3)); P('paraDecode.odd', saveStr(S.paraDecode(f3))); }
    P('paraClock', [S.paraClock(sv, 1700000100), S.paraClock(sv, 1699999999), S.paraClock(sv, 1700000000 + 4294967296 + 5), S.paraClock(Object.assign({}, sv, { counter: 0 }), 1700000100), S.paraClock(Object.assign({}, sv, { stamp: 0 }), 1700000100), S.paraClock(Object.assign({}, sv, { counter: 0xFFFFFFF0 }), 1700000100)].join(' '));
    const set = S.paraSettings(sv, ed), set0 = S.paraSettings(sv);
    P('paraSettings', (set ? sha(set) : 'null') + ' ' + (set0 ? sha(set0) : 'null'));
    for (let e2 = 1; e2 <= 8; e2++) P('paraPet.ed' + e2, sha(JSON.stringify(S.paraPet(sv, e2))));
    // pet edits: exact bytes of the written save
    const petOut = (n, f) => P('paraPetSet.' + n, err(() => { const r = f(); return sha(JSON.stringify(S.paraPet(r, ed))) + ' ' + pagesSha(r.pages) + ' ' + sha(S.paraWrite(r)); }));
    for (const lv of [-3, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15]) petOut('level' + lv, () => S.paraPetSet(sv, ed, { level: lv }));
    petOut('care', () => S.paraPetSet(sv, ed, { care: true }));
    petOut('none', () => S.paraPetSet(sv, ed, {}));
    petOut('stageonly', () => S.paraPetSet(sv, ed, { stage: 5 }));
    const pet = S.paraPet(sv, ed), old = pet ? pet.id : 0;
    petOut('id.same', () => S.paraPetSet(sv, ed, { id: old, stage: 3 }));
    petOut('id.other', () => S.paraPetSet(sv, ed, { id: old + 1, stage: 5, level: 7, care: true }));
    petOut('id.big', () => S.paraPetSet(sv, ed, { id: 0x12345, stage: 13 }));
    // a save without a pet gets one, then its file (synthetic: small number at +8, the character at +12, +14 and +0x10A)
    { const m = new Map(sv.pages), so2 = S.setOf(m, ed);
      if (so2) {
        const fam = S.family(ed), t = { gen1: 0x104, jade: 0x108, gen3: 0x114, neon: 0x114 }[fam];
        const p = so2.p.slice(); p[t + 4] = 0; p[t + 5] = 0; crcFix(p);
        for (const a of S.setAddrs(ed)) if (m.has(a) && S.settingsOk(m.get(a))) m.set(a, p.slice());
        const sv0 = Object.assign({}, sv, { pages: m });
        petOut('nopet', () => sv0);
        petOut('nopet.id', () => S.paraPetSet(sv0, ed, { id: 1017, stage: 4 }));
        const sv1 = S.paraPetSet(sv0, ed, { id: 1017, stage: 4 });
        petOut('nofile', () => S.paraPetSet(sv1, ed, { id: 1020 }));
        const r = rng(ed * 31 + 5), a0 = S.region(ed)[0] + 0x20000, m2 = new Map(sv1.pages);
        const mk = (k, f) => { const d = new Uint8Array(0x1000); fill(d, 0, 0x1000, r); f(d); m2.set(a0 + k * 0x1000, d); };
        mk(0, (d) => { w32(d, 8, 1); d[14] = 1017 & 255; d[15] = 1017 >> 8; d[12] = 1; d[13] = 0; d[0x10A] = 1017 & 255; d[0x10B] = 1017 >> 8; });
        mk(1, (d) => { w32(d, 8, 200); d[12] = 1017 & 255; d[13] = 1017 >> 8; d[14] = 7; d[15] = 0; });
        mk(2, (d) => { w32(d, 8, 0); d[14] = 1017 & 255; d[15] = 1017 >> 8; });      // number 0: not a pet file
        mk(3, (d) => { w32(d, 8, 256); d[14] = 1017 & 255; d[15] = 1017 >> 8; });    // number too big
        mk(4, (d) => { w32(d, 8, 5); d[12] = 1017 & 255; d[13] = 1017 >> 8; d[14] = 1017 & 255; d[15] = 1017 >> 8; });
        m2.set(a0 + 5 * 0x1000, (() => { const d = new Uint8Array(0x800); fill(d, 0, 0x800, r); w32(d, 8, 1); d[14] = 1017 & 255; d[15] = 1017 >> 8; return d; })());
        const sv2 = Object.assign({}, sv1, { pages: m2 });
        petOut('file', () => S.paraPetSet(sv2, ed, { id: 1020, stage: 5, care: true, level: 3 }));
        petOut('file.twice', () => S.paraPetSet(S.paraPetSet(sv2, ed, { id: 1020 }), ed, { id: 2000, level: 9 }));
      } else P('paraPetSet.nopet', 'no settings');
    }
    // without a settings block
    { const m = new Map(sv.pages); for (const a of S.setAddrs(ed)) m.delete(a); const bare = Object.assign({}, sv, { pages: m });
      P('nosettings', [JSON.stringify(S.paraPet(bare, ed)), S.paraSettings(bare, ed) === null, err(() => S.paraPetSet(bare, ed, { level: 3 })), checkStr(S.paraCheck(bare, ed))].join(' ')); }
    // Neon ring made by hand on every save: several valid pages with different numbers (wrap around too)
    { const base = S.setOf(sv.pages, ed);
      if (base) {
        const mk = (seq) => { const p = base.p.slice(); w32(p, 0xAD0, seq); crcFix(p); return p; };
        const ring = S.setAddrs(8), cases = { a: [5, 9, 7], b: [0xFFFFFFFE, 2, 0xFFFFFFFF], c: [3, 3, 3], d: [0x80000000, 0, 1] };
        for (const k in cases) {
          const m = new Map(); cases[k].forEach((q, i) => m.set(ring[(i * 2) % 5], mk(q)));
          const bad = mk(100); bad[77] ^= 1; m.set(ring[1], bad);
          const s8 = Object.assign({}, sv, { pages: m, edition: 8 }), o = S.setOf(m, 8);
          P('ring.' + k, o.at + ' ' + sha(o.p) + ' ' + checkStr(S.paraCheck(s8, 8)) + ' ' + err(() => { const r = S.paraPetSet(s8, 8, { level: 6, care: true }); return pagesSha(r.pages) + ' ' + sha(JSON.stringify(S.paraPet(r, 8))); }));
        }
      } }
    // broken files
    const bads = { short: file.slice(0, 39), magic: (() => { const f = file.slice(); f[0] = 0x58; return f; })(), version: (() => { const f = file.slice(); w32(f, 8, 4); return f; })(),
      cut1: file.slice(0, 50), cut2: file.slice(0, 36 + 8 * 19 + 2), cut3: file.slice(0, 36 + 8 * 19 + 4 + 6), cut4: file.slice(0, 36 + 8 * 19 + 4 + 8 + 100), cut5: file.slice(0, file.length - 16), cut6: file.slice(0, file.length - 1),
      regs: (() => { const f = file.slice(); w32(f, 32, 0xFFFFFFFF); return f; })(), trailer: (() => { const f = file.slice(); f[f.length - 16] ^= 1; return f; })() };
    for (const k in bads) P('paraDecode.' + k, err(() => saveStr(S.paraDecode(bads[k]))));
    P('t7SaveOut', err(() => { const o = S.t7SaveOut(rom); return o ? sha(o) : 'null'; }));
  }

  // ---- TamaEmu: a synthetic image (settings block, packed blocks, LZ4 parts, spare pages, erased blocks)
  {
    const mkImg = (ver, variant) => {
      const r = rng(0xE0 + ver), img = new Uint8Array(0x1000000).fill(0xFF), c = 0xA0140;
      const guestOff = 0x400000, guestSize = 0x60000, lzOff = 0x300000, lo = (guestOff + guestSize + 0x1FFF) & ~0x1FFF, data = lo + 0x2000, n = 5;
      w32(img, c, 0x43584D50); w32(img, c + 4, ver); w32(img, c + 8, guestOff); w32(img, c + 12, guestSize); w32(img, c + 16, 0x900000); w32(img, c + 20, variant === 'pc' ? 0 : 1);
      const map = new Uint8Array(128).fill(0xFF); map[0] = 2; map[1] = 0; map[2] = 1; map[3] = 0xFE; map[5] = 4; map[40] = 5; map[70] = 3; img.set(map, c + 24);
      w32(img, c + 152, data + n * 0x2000 + (variant === 'more' ? 100 * 0x2000 : 0)); w32(img, c + 160, lzOff);
      fill(img, guestOff, guestSize, r);
      // LZ: blocks 10 and 11 (and 2, which is mapped and so not taken)
      let pos = 512;
      for (const b of [10, 11, 2]) {
        const tab = pos; pos += 65 * 4; w32(img, lzOff + 4 * b, tab);
        for (let k = 0; k < 64; k++) {
          w32(img, lzOff + tab + 4 * k, pos);
          const kind = (k + b) % 4; let part;
          if (kind === 0) part = new Uint8Array(0);
          else if (kind === 1) { part = new Uint8Array(0x400); fill(part, 0, 0x400, r); }
          else { const raw = new Uint8Array(0x400); const q = r(); for (let i = 0; i < 0x400; i++) raw[i] = kind === 2 ? (i * q) >> 3 & 255 : (i % 37 < 20 ? q : r() & 3); part = C.lz4Encode(raw); if (part.length >= 0x400) part = raw; }
          img.set(part, lzOff + pos); pos += part.length;
        }
        w32(img, lzOff + tab + 256, pos);
      }
      // spare pages
      const t = new Uint8Array(16 + 128 + 20).fill(0xFF);
      const vs = [(20 << 16 >> 13) + 1, 0xFFFF, (1 << 16 >> 13) + 2, 1024, (10 << 16 >> 13) + 3];
      vs.forEach((v, i) => { t[16 + 2 * i] = v & 255; t[17 + 2 * i] = v >> 8; });
      let x = (0x50584D50 ^ Math.imul(variant === 'more' ? 64 : n, 0x9E3779B1)) >>> 0; for (let i = 0; i < 64; i++) x = (((x << 5) | (x >>> 27)) ^ u16(t, 16 + 2 * i)) >>> 0;
      w32(t, 0, 0x50584D50); w32(t, 4, variant === 'more' ? 64 : n); w32(t, 8, variant === 'badtable' ? x ^ 1 : x); w32(t, 12, 0);
      if (variant !== 'nogone') { const g = [(1 << 11) | 1, 1 << (40 - 32), 0, 1 << 31]; let y = 0x454E4F47; g.forEach((v, i) => { w32(t, 144 + 4 * i, v); y = (y ^ v) >>> 0; }); w32(t, 160, variant === 'badgone' ? y ^ 4 : y); }
      img.set(t, lo); fill(img, data, n * 0x2000, r);
      return img;
    };
    for (const [ver, variant] of [[5, ''], [5, 'badtable'], [5, 'badgone'], [5, 'nogone'], [5, 'more'], [5, 'pc'], [4, ''], [3, ''], [2, ''], [6, '']]) {
      const img = mkImg(ver, variant), tag = 'emu.v' + ver + (variant ? '.' + variant : '');
      const cfg = S.emuCfg(img.subarray(0xA0000, 0xA1000)), cfg2 = S.emuCfg(img, 0);
      out(tag + '.cfg', [cfg.version, cfg.guestOff, cfg.guestSize, cfg.saveOff, cfg.kind, sha(cfg.map), cfg.spareEnd, cfg.lzOff, cfg.dev, cfg.size, cfg.app, cfg2.guestOff, sha(cfg2.map)].join('|'));
      const prog = []; const read = (a, n2) => img.subarray(a, a + n2);
      const g = await S.emuGuestAsync(read, cfg, (w, d, t) => prog.push(w + d + '/' + t));
      out(tag + '.guest', g.length + ' ' + sha(g) + ' ' + prog.join(','));
      const g2 = await S.emuGuestAsync(async (a, n2) => img.slice(a, a + n2), cfg);
      out(tag + '.guest.async', sha(g2));
    }
    { const sec = new Uint8Array(0x1000); out('emuCfg.none', S.emuCfg(sec)); w32(sec, 0x140, 0x43584D50); w32(sec, 0x154, 5); out('emuCfg.badkind', S.emuCfg(sec));
      for (let k = 0; k < 5; k++) { w32(sec, 0x154, k); w32(sec, 0x144, k); const c = S.emuCfg(sec); out('emuCfg.kind' + k, [c.dev, c.size, c.app, c.version, c.spareEnd, c.lzOff, c.map.length].join('|')); } }
    // lzGoneApply alone
    { const r = rng(99), g = new Uint8Array(0x400000); fill(g, 0, g.length, r); const t = new Uint8Array(64).fill(0);
      const ws = [0x80000005, 0xFFFF0000, 3, 0]; let y = 0x454E4F47; ws.forEach((v, i) => { w32(t, 8 + 4 * i, v); y = (y ^ v) >>> 0; }); w32(t, 24, y);
      const g1 = g.slice(); S.lzGoneApply(t, 8, g1, 0x400000); out('lzGoneApply', sha(g1));
      const g2 = g.slice(); S.lzGoneApply(t, 8, g2, 0x200000); out('lzGoneApply.size', sha(g2));
      const g3 = g.slice(); S.lzGoneApply(t.subarray(0, 27), 8, g3, 0x400000); out('lzGoneApply.short', sha(g3) === sha(g));
      t[24] ^= 1; const g4 = g.slice(); S.lzGoneApply(t, 8, g4, 0x400000); out('lzGoneApply.bad', sha(g4) === sha(g)); }
  }

  // ---- T7Emu
  {
    let img = new Uint8Array(16 << 20).fill(0xFF);
    out('t7.empty', S.t7SaveOut(img));
    const sv = new Uint8Array(4098); sv[0] = 0x05; for (let i = 2; i < 4098; i++) sv[i] = i * 7 & 255;
    img = S.t7SaveIn(img, sv); out('t7.in1', sha(img) + ' ' + sha(S.t7SaveOut(img)));
    const sv2 = sv.slice(); sv2[100] ^= 0x55; sv2[0] = 0x07; sv2[1] = 0x80;
    img = S.t7SaveIn(img, sv2); out('t7.in2', sha(img) + ' ' + sha(S.t7SaveOut(img)));
    img = S.t7SaveIn(img, sv); out('t7.in3', sha(img) + ' ' + sha(S.t7SaveOut(img)));
    for (let i = 0; i < 5; i++) img = S.t7SaveIn(img, i & 1 ? sv : sv2); out('t7.in8', sha(img) + ' ' + sha(S.t7SaveOut(img)));
    // sequence wrap: slot A at 0xFFFFFFFF, the next one gets 0
    { const im = img.slice(); w32(im, 0xC1004, 0xFFFFFFFF); w32(im, 0xC3004, 0xFFFFFFFE); const n = S.t7SaveIn(im, sv2); out('t7.wrap', sha(n) + ' ' + sha(S.t7SaveOut(n))); }
    { const im = img.slice(); im[0xC2000 + 50] ^= 1; out('t7.badsum', sha(S.t7SaveOut(im))); im[0xC4000 + 50] ^= 1; out('t7.badsum2', S.t7SaveOut(im)); }
    out('t7.base', sha(S.t7SaveIn(img, sv2, 0x850000)) + ' ' + sha(S.t7SaveOut(S.t7SaveIn(img, sv2, 0x850000), 0x850000)) + ' ' + S.t7SaveOut(img, 0x850000));
    out('t7.check', [S.t7SaveCheck(sv), S.t7SaveCheck(sv.subarray(1)), !!S.t7SaveCheck(null), S.t7SaveCheck(new Uint8Array(0))].join(' '));
    out('t7.err', err(() => S.t7SaveIn(img, sv.subarray(0, 100))) + ' ' + err(() => S.t7SaveIn(img, null)));
    // test27: a slot written 2 bytes off
    { const im = new Uint8Array(0x1000000).fill(0xFF), base = 0x850000, at = base + 0x1000;
      const pages = new Uint8Array(4096); for (let i = 0; i < 4094; i++) pages[i] = (i * 7 + 3) & 0xFF;
      let s = 0x7E7E; for (let i = 0; i < 4096; i++) s = (Math.imul(s, 31) + pages[i]) >>> 0;
      w32(im, at, 0x45453754); w32(im, at + 4, 5); w32(im, at + 8, 0xFFFF); w32(im, at + 12, s);
      im[at + 0x1000] = 0xAB; im[at + 0x1001] = 0xCD; im.set(pages.subarray(0, 4094), at + 0x1002);
      const o = S.t7SaveOut(im, base); out('t7.shift', sha(o)); const n = S.t7SaveIn(im, o, base); out('t7.shift.in', sha(n) + ' ' + sha(S.t7SaveOut(n, base))); }
  }
})();
