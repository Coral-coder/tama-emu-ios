// Reference output of Paramix Studio's core.js for core_check.dart.
// DUMPS=<folder with water.bin ...> node tool/paramix_check/core.js
// One line per case: <case name> <sha256 or value>. Only hashes, sizes and offsets are printed.
const fs = require('fs'), path = require('path'), crypto = require('crypto'), zlib = require('zlib');
const C = require(path.join(__dirname, '../../third_party/paramix-studio/src/core.js'));
const DUMPS = process.env.DUMPS;
const EDS = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];
const sha = (b) => crypto.createHash('sha256').update(typeof b === 'string' ? b : Buffer.from(b.buffer, b.byteOffset, b.byteLength)).digest('hex');
const out = (n, v) => console.log(n + ' ' + v);
const w16 = (b, o, v) => { b[o] = v & 255; b[o + 1] = (v >> 8) & 255; };
const w32 = (b, o, v) => { b[o] = v & 255; b[o + 1] = (v >>> 8) & 255; b[o + 2] = (v >>> 16) & 255; b[o + 3] = (v >>> 24) & 255; };
function rng(seed) { let s = seed >>> 0; return () => { s = (Math.imul(s, 1103515245) + 12345) >>> 0; return (s >>> 16) & 255; }; }
const err = (f) => { try { return f(); } catch (e) { return e instanceof RangeError || e instanceof TypeError ? 'err:range' : 'err:' + e.message; } };
const J = (v) => sha(JSON.stringify(v === undefined ? null : v));
class H {   // one hash over many parts
  constructor() { this.h = crypto.createHash('sha256'); }
  s(x) { this.h.update(String(x) + '\n'); return this; }
  b(x) { const t = new Uint8Array(4); w32(t, 0, x.length); this.h.update(t); this.h.update(Buffer.from(x.buffer, x.byteOffset, x.byteLength)); return this; }
  img(i) { return this.s(i.w + 'x' + i.h).b(i.data); }
  imgs(l) { this.s(l.length); for (const i of l) this.img(i); return this; }
  get hex() { return this.h.digest('hex'); }
}
const imgSha = (i) => new H().img(i).hex, imgsSha = (l) => new H().imgs(l).hex;
const img = (w, h, fn) => { const d = new Uint8ClampedArray(w * h * 4); for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) d.set(fn(x, y), (y * w + x) * 4); return { w, h, data: d }; };
// pictures with more colours and other transparent places, the same in both checks
function perturb(subs, seed) {
  const r = rng(seed);
  return subs.map((s) => { const d = new Uint8ClampedArray(s.data);
    for (let i = 0; i < d.length; i += 4) { const q = r(); if (q < 48) { d[i] = (d[i] + r()) & 255; d[i + 1] ^= r() & 31; } else if (q < 52) d[i + 3] = 0; else if (q < 56) d[i + 3] = 255; }
    return { w: s.w, h: s.h, data: d }; });
}
const decSha = (e, palSet) => err(() => { const d = C.spriteDecode(e, palSet), h = new H(); h.s(JSON.stringify(d.header)).s(JSON.stringify(d.palettes)).s(d.width + 'x' + d.height).s(d.cells.length); for (const c of d.cells) h.b(c); h.imgs(d.subs); return h.hex; });

// a fake "original" sprite in the character format (as test/unit_test.js): 4 bpp, palette, transparency
function fakeSprite(w, h, n, seed) {
  const subs = []; for (let i = 0; i < n; i++) subs.push(img(w, h, (x, y) => ((x + y + i + seed) % 7 === 0) ? [0, 0, 0, 0] : [(x * 9 + seed * 40) & 255, (y * 7) & 255, (i * 30) & 255, 255]));
  const orig = new Uint8Array(24 + 32 + 8 * n); orig[5] = 2; orig[6] = n; orig[8] = w; orig[9] = h; orig[12] = 1; orig[13] = 1; orig[14] = 0x11; orig[15] = 1; orig[4] = 0xa7; orig[18] = 24; orig[20] = 56;
  return C.spriteEncode(orig, subs, {});
}
function fakeRom() {
  const parts = []; for (let i = 0; i < 6; i++) parts.push(fakeSprite(16, 16, 2, i));
  const shapes = [[64, 64, 20], [64, 32, 20], [64, 32, 18], [32, 32, 24], [32, 16, 14], [32, 16, 14]];
  const egg = [fakeSprite(32, 32, 5, 1), fakeSprite(16, 16, 1, 2), fakeSprite(16, 16, 1, 3), fakeSprite(64, 64, 5, 4), fakeSprite(16, 16, 1, 5), fakeSprite(16, 16, 1, 6)];
  const entries = [...parts, ...egg, ...shapes.map(([w, h, n], k) => fakeSprite(w, h, n, 10 + k)), ...shapes.map(([w, h, n], k) => fakeSprite(w, h, n, 20 + k))];
  const pack = C.packJoin(entries);
  const root = C.arc2Build([new Uint8Array(64).fill(7), pack, C.arc2Build([new Uint8Array(10)])]);
  const rom = new Uint8Array(0x1000000).fill(0xff);
  rom.set([...'SONIXDEV'].map(c => c.charCodeAt(0)), 0); rom.set(root, C.ASSET_BASE);
  const verPage = (C.ASSET_BASE + root.length + 0x200000) & ~0xfff; rom.set([1, 0, 0, 0], verPage);
  return rom;
}
// ---- synthetic cards
function smaCard(seed) {
  const r = rng(seed), raw = new Uint8Array(0x100000), B = 0x1000;
  [...'BANDAINTPD'].forEach((c, i) => { raw[0x10 + i] = c.charCodeAt(0); }); [...'TAMASUMA'].forEach((c, i) => { raw[0x20 + i] = c.charCodeAt(0); });
  w16(raw, B, 0x3232); w16(raw, B + 2, 2); w32(raw, B + 8, 0x100); w32(raw, B + 24, 0x8000);
  const dp = B + 0x100, sp = B + 0x8000, nSets = 5, nGroups = 4;
  // layers and frames
  const lay = [], fr = []; let nl = 0;
  for (let f = 0; f < nGroups * 53; f++) {
    const none = r() < 40, g = (f / 53) | 0, k = f % 53;
    if (k === 1 ? g === 3 : none) { fr.push(0xFFFF, 0); continue; }
    const cnt = 1 + r() % 3; fr.push(nl, cnt);
    for (let j = 0; j < cnt; j++) {
      const a = r(), b = r();
      const m = 0x400 | (b < 230 ? 0x200 : 0) | (a & 0x07) | (a & 0x30) | ((b & 1) << 8), ws = [m];
      if (m & 1) ws.push((r() % 41 - 20) & 0xFFFF);
      if (m & 2) ws.push((r() % 41 - 20) & 0xFFFF);
      if (m & 4) ws.push(r() % 3);
      if (m & 0x10) ws.push(r()); if (m & 0x20) ws.push(r() << 8); if (m & 0x100) ws.push(r());
      if (m & 0x200) ws.push([3, 1, 1, 2][r() & 3]);
      ws.push(r() < 210 ? 0x8000 | (r() % (nSets + 1)) : r());
      lay.push(...ws); nl++;
    }
  }
  const chars = new Uint8Array(8 * 96); for (let i = 0; i < chars.length; i++) chars[i] = r();
  [1, 2, 3, 4, 5, 6, 0, 5].forEach((t, k) => { w16(chars, k * 96 + 2, t); chars[k * 96 + 28] = k % 4; });
  const tabs = []; for (let i = 0; i < 19; i++) tabs.push(new Uint8Array(0));
  tabs[11] = chars; tabs[15] = new Uint8Array(new Uint16Array(lay).buffer); tabs[18] = new Uint8Array(new Uint16Array(fr).buffer);
  let o = 80; for (let i = 0; i < 20; i++) { w32(raw, dp + 4 * i, o / 2); if (i < 19) { raw.set(tabs[i], dp + o); o += tabs[i].length; } }
  // pictures: 4 sets of 2 x 2 sprites (16 x 16, 4 bpp), 3 pictures each; a fifth of single 32 x 32 sprites (2 bpp, four times 8)
  const nSpr = 51, nCol = 96, io = 16, so = io + 6 * nSets, po = so + 8 * nSpr, xo = po + 2 * nCol;
  [io, so, po, xo].forEach((v, i) => w32(raw, sp + 4 * i, v));
  for (let i = 0; i < nSets; i++) { const q = sp + io + 6 * i; w16(raw, q, i * 12); raw[q + 2] = i < 4 ? 2 : 1; raw[q + 3] = i < 4 ? 2 : 1; w16(raw, q + 4, i < 4 ? i * 4 : 20); }
  for (let i = 0; i < nSpr; i++) { const q = sp + so + 8 * i; w16(raw, q, i < 48 ? i : 24 + (i - 48)); w16(raw, q + 2, (r() % 17 - 8) & 0xFFFF); w16(raw, q + 4, (r() % 17 - 8) & 0xFFFF); w16(raw, q + 6, i < 48 ? 0x51 : 0x8000); }
  for (let i = 0; i < nCol; i++) { let v = r() | (r() << 8); v = (i % 16 === 0 || r() < 32) ? v | 0x8000 : v & 0x7FFF; w16(raw, sp + po + 2 * i, v); }
  // pixels: blobs rather than noise, so that the poses have a shape
  for (let i = 0; i < 0x2000; i++) { const x = i & 15, y = (i >> 4) & 15; raw[sp + xo + i] = (x > 2 && x < 13 && y > 1 && y < 14) ? r() : ((r() & 3) === 0 ? r() & 0x0F : 0); }
  return raw;
}
function dimCard(seed) {
  const r = rng(seed), sizes = [], b = 0x100000;
  for (let i = 0; i < 8; i++) sizes.push(2560);
  sizes.push(2400); for (let i = 0; i < 12; i++) sizes.push(7168); sizes.push(25600);
  sizes.push(4800); for (let i = 0; i < 5; i++) sizes.push(1536);
  sizes.push(2400); for (let i = 0; i < 3; i++) sizes.push(7168);
  sizes.push(100, 2400, 3528, 2560);
  const n = sizes.length, total = sizes.reduce((a, c) => a + c, 0), first = 0x4c + 4 * (n + 1);
  const d = new Uint8Array(b + first + total);
  [...'GP_SPIFI'].forEach((c, i) => { d[b + i] = c.charCodeAt(0); }); w32(d, b + 0x48, n);
  let o = first; for (let i = 0; i <= n; i++) { w32(d, b + 0x4c + 4 * i, o); if (i < n) o += sizes[i]; }
  o = b + first;
  for (const sz of sizes) { const blob = r() & 7;
    for (let k = 0; k < sz >> 1; k++) { const q = r(); let v = q < 60 ? 0x07e0 : q < 200 ? (blob * 0x1863 + 0x4208) & 0xFFFF : r() | (r() << 8); w16(d, o + 2 * k, v); }
    o += sz; }
  return d.map((x) => x ^ 0xff);
}
// a drawn character with an eye (skin, dark outline, white eye with a dark rim)
function drawnChar(baby) {
  const W = baby ? 32 : 64, Hh = baby ? 24 : 56, cx = W >> 1, cy = Hh >> 1, rx = W * 3 >> 3, ry = Hh * 3 >> 3, ex = cx - (W >> 3), ey = cy - (Hh >> 3);
  const mk = (dx, dy, eye) => img(W, Hh, (x0, y0) => { const x = x0 - dx, y = y0 - dy;
    const q = (x - cx) * (x - cx) * ry * ry + (y - cy) * (y - cy) * rx * rx, lim = rx * rx * ry * ry;
    if (q > lim) return [0, 0, 0, 0];
    if (eye && Math.abs(x - ex) <= 1 && Math.abs(y - ey) <= 1) return x === ex && y === ey ? [10, 10, 20, 255] : [255, 255, 255, 255];
    if (eye && Math.abs(x - ex) <= 2 && Math.abs(y - ey) <= 2) return [20, 20, 30, 255];
    if (q > lim * 3 / 4) return [20, 20, 30, 255];
    return y > cy + 2 ? [230, 170, 40, 255] : [250, 200, 60, 255]; });
  return { index: 0, name: null, baby, frames: { idle1: mk(0, 0, true), idle2: mk(1, 0, true), walk1: mk(2, 1, true), happy: mk(0, -1, false), sleep: mk(-3, 2, true), attack: mk(9, 0, true) } };
}
const charSha = (ch) => { const h = new H().s(ch.index).s(ch.baby).s(ch.stage === undefined ? null : ch.stage).s(ch.name ? imgSha(ch.name) : null); for (const k in ch.frames) h.s(k).img(ch.frames[k]); return h.hex; };

(async () => {
  // ================================================================ without a dump
  out('consts', [C.ASSET_BASE, JSON.stringify(C.EDITIONS), JSON.stringify(C.GROUP_PARTS), C.GROUP_SHEET_W, C.GROUP_SHEET_H, JSON.stringify(C.FIELD_NAMES), JSON.stringify(C.TXT_ENC), C.EYE_V2].join('|'));
  out('DIM_EYE_PRESETS', JSON.stringify(Object.keys(C.DIM_EYE_PRESETS).sort((a, b) => a - b).map((k) => [k, C.DIM_EYE_PRESETS[k]])));
  { const r = rng(1), b = new Uint8Array(5000); for (let i = 0; i < b.length; i++) b[i] = r(); out('crc32', C.crc32(b) + ' ' + C.crc32(b.subarray(0, 0)) + ' ' + C.crc32(new TextEncoder().encode('123456789'))); }
  // RLE and LZ4
  for (let t = 0; t < 12; t++) {
    const r = rng(100 + t), n = [0, 1, 5, 13, 64, 300, 1024, 4096, 127, 128, 4000, 9000][t], b = new Uint8Array(n);
    for (let i = 0; i < n;) { const q = r(); if (t % 3 === 0) b[i++] = q; else { const run = 1 + (r() % (t % 3 === 1 ? 9 : 400)); for (let k = 0; k < run && i < n; k++) b[i++] = q & (t & 1 ? 255 : 3); } }
    const re = C.rleEncode(b), le = C.lz4Encode(b);
    out('rle' + t, sha(re) + ' ' + sha(C.rleDecode(re, false)) + ' ' + (sha(C.rleDecode(re)) === sha(b)));
    out('lz4' + t, sha(le) + ' ' + sha(C.lz4Decode(le)) + ' ' + (sha(C.lz4Decode(le)) === sha(b)));
    // cut and damaged streams
    out('rle' + t + '.cut', sha(C.rleDecode(re.subarray(0, re.length >> 1))) + ' ' + sha(C.rleDecode(b)));
    out('lz4' + t + '.cut', sha(C.lz4Decode(le.subarray(0, le.length >> 1))) + ' ' + sha(C.lz4Decode(b)) + ' ' + sha(C.lz4Decode(le.subarray(0, le.length - 1))));
  }
  { const ws = [3, 0x11223344, 0x80000002, 1, 2, 3, 4, 5, 6, 7, 8, 2, 0xAABBCCDD, 0x80000003, 9, 9, 0, 77, 77]; const b = new Uint8Array(ws.length * 4); ws.forEach((v, i) => w32(b, 4 * i, v));
    out('rle.word', sha(C.rleDecode(b, true)) + ' ' + sha(C.rleDecode(b.subarray(0, 58), true)) + ' ' + C.rleDecode(b, true).length); }
  { const b = new Uint8Array([0xF0, 255, 255, 3]), b2 = new Uint8Array([0x1F, 65, 1, 0, 255, 255]), b3 = new Uint8Array([0x10, 65, 9, 0, 0x10, 66]), b4 = new Uint8Array([0x20, 65]);
    out('lz4.odd', [b, b2, b3, b4].map((x) => C.lz4Decode(x).length + ':' + sha(C.lz4Decode(x))).join(' ')); }
  // quantize
  for (let t = 0; t < 14; t++) {
    const r = rng(200 + t), n = [1, 5, 40, 300, 2000, 6000, 20000, 500, 500, 3000, 64, 1000, 4000, 12000][t], nc = [4, 4, 15, 16, 16, 255, 256, 1, 3, 8, 64, 2, 15, 31][t], px = [];
    for (let i = 0; i < n; i++) { const m = t % 4; px.push(m === 0 ? [r(), r(), r()] : m === 1 ? [r() & 0xF8, r() & 0xE0, r() & 0xC0] : m === 2 ? [r() >> 3, 200 + (r() & 31), r() & 1 ? 255 : 0] : [(r() % 6) * 51, (r() % 3) * 100, r() % 40]); }
    out('quantize' + t, C.quantize(px, nc).length + ' ' + J(C.quantize(px, nc)));
  }
  out('textClean', JSON.stringify(['Mametchi', '  hello   world  ', 'straße', 'ünïcödé', "it's a.b&c!?/", '###', '', null, undefined, 'a\tb\nc', 'ﬁne ﬂow ﬀ ﬃ ﬄ ﬅ ﬆ', 'ı ſ ŉ ǰ ẖ ẗ ẘ ẙ ẚ', 'KK åéî', 'x  y', 'abc123xyz', 'TAMA-GOTCHI_42', 'µ ÿ ǆ ǅ ΐ ա և', 12345].map((s) => C.textClean(s))));
  out('sheetLayout', JSON.stringify([[64, 64, 20], [32, 16, 14], [512, 512, 7], [1281, 5, 3], [1280, 2, 3], [640, 2, 3], [1, 1, 5000], [100, 7, 13], [16, 16, 0], [8, 8, 1]].map((a) => C.sheetLayout(...a))));
  out('partOptions', JSON.stringify([0, 1, 2, 3, 4, 5].map((k) => C.partOptions(k))) + JSON.stringify(C.partOptions(1, { keepPalette: true })) + JSON.stringify(C.partOptions(4, { keepLength: false, figure: false })));
  for (const a of [['0123456789', 100, 20, 2], ['42', 32, 32, 3], ['7', 8, 8, 1], ['1000', 64, 64, 5], ['', 5, 5, 1], ['88', 4, 3, 2]]) out('numberImage.' + a[0], imgSha(C.numberImage(...a)));
  out('numberImage.err', err(() => imgSha(C.numberImage('1a', 30, 30, 1))));
  // pictures
  { const a = img(40, 30, (x, y) => (x + y) % 5 === 0 ? [0, 0, 0, 0] : [x * 6, y * 8, (x * y) & 255, 255]), e = C.emptyImage(40, 30);
    const b = { w: 40, h: 30, data: a.data.map((v, i) => i % 4 === 3 ? v : Math.min(255, v + (i % 7 === 0 ? 4 : 0))) }, c = { w: 40, h: 30, data: a.data.map((v, i) => i === 4 * 43 ? v ^ 0x20 : v) };
    out('emptyImage', imgSha(e) + ' ' + imgSha(C.emptyImage(0, 0)));
    out('sameImage', [C.sameImage(a, a), C.sameImage(a, e), C.sameImage(a, b), C.sameImage(a, c), C.sameImage(e, C.emptyImage(40, 31)), C.sameImage(e, C.emptyImage(40, 30))].join(' '));
    out('crop', [imgSha(C.crop(a, 0, 0, 40, 30)), imgSha(C.crop(a, 5, 7, 11, 13)), imgSha(C.crop(a, 39, 29, 1, 1)), imgSha(C.crop(a, 30, 20, 20, 5)), err(() => imgSha(C.crop(a, 0, 28, 8, 4)))].join(' '));
    const pl = [[64, 64, 1], [64, 64, 2], [32, 32, 0.5], [32, 32, 0.625, 28], [64, 64, 1.25, 54], [64, 64, 1.5], [20, 20, 1], [20, 20, 3], [64, 64, 0.3], [41, 31, 1.01], [128, 128, 2.7, 100], [64, 64, 0.01], [16, 64, 1, 40], [64, 64, 1 / 3], [64, 64, 0.7, 60]];
    pl.forEach((p, i) => out('place' + i, err(() => imgSha(C.place(a, ...p)))));
    const soft = img(33, 27, (x, y) => [(x * 37 + y * 11) & 255, (x * 5 + y * 91) & 255, (x * y * 3) & 255, (x * 29 + y * 53) & 255]);
    pl.forEach((p, i) => out('place.soft' + i, err(() => imgSha(C.place(soft, ...p)))));
    // sheets
    const subs = []; for (let i = 0; i < 45; i++) subs.push(img(32, 16, (x, y) => [x * 8, y * 16, i * 5, (x + i) % 3 ? 255 : 0]));
    const sh = C.sheetFromSubs(subs); out('sheetFromSubs', imgSha(sh)); out('subsFromSheet', imgsSha(C.subsFromSheet(sh, 32, 16, 45)));
    out('subsFromSheet.err', err(() => imgsSha(C.subsFromSheet(sh, 32, 16, 44))) + ' ' + err(() => imgsSha(C.subsFromSheet(sh, 16, 16, 45))));
    const parts = C.GROUP_PARTS.map((p, k) => { const l = []; for (let i = 0; i < p.n; i++) l.push(img(p.w, p.h, (x, y) => [(x * 4 + k * 40) & 255, (y * 4 + i * 9) & 255, (x ^ y) * 3 & 255, (x + y + i) % 4 ? 255 : 0])); return l; });
    const gs = C.groupSheet(parts); out('groupSheet', imgSha(gs)); out('groupFromSheet', C.groupFromSheet(gs).map(imgsSha).join(' '));
    out('groupFromSheet.err', err(() => C.groupFromSheet(a).length));
  }
  // ZIP
  { const def = (d) => new Uint8Array([1, d.length & 255, d.length >> 8, ~d.length & 255, (~d.length >> 8) & 255, ...d]);   // a stored deflate block
    const files = [{ name: 'figur_0012.png', data: new Uint8Array([1, 2, 3]) }, { name: 'a/b.txt', data: new TextEncoder().encode('hallo') }, { name: 'dir/', data: new Uint8Array(0) }, { name: 'größe ü.bin', data: new Uint8Array(1000).map((_, i) => i * 7) }, { name: 'packed.bin', data: def(new TextEncoder().encode('deflated text')) }, { name: 'empty', data: new Uint8Array(0) }];
    const z = C.zipBuild(files); out('zipBuild', z.length + ' ' + sha(z) + ' ' + sha(C.zipBuild([])));
    const inf = async (b) => new Uint8Array(zlib.inflateRawSync(b));
    const show = (l) => l.map((f) => f.name + ':' + f.data.length + ':' + sha(f.data)).join(',');
    out('zipRead', show(await C.zipRead(z, inf)));
    // the fifth entry marked as deflated in the central directory
    const z2 = z.slice(); let p = (z2[z2.length - 6] | z2[z2.length - 5] << 8 | z2[z2.length - 4] << 16 | z2[z2.length - 3] << 24) >>> 0;
    for (let k = 0; k < 4; k++) p += 46 + (z2[p + 28] | z2[p + 29] << 8); z2[p + 10] = 8;
    out('zipRead.deflate', show(await C.zipRead(z2, inf)));
    z2[p + 10] = 9; out('zipRead.method', await C.zipRead(z2, inf).then(show, (e) => 'err:' + e.message));
    out('zipRead.nozip', await C.zipRead(new Uint8Array(100), inf).then(show, (e) => 'err:' + e.message) + ' ' + await C.zipRead(new Uint8Array(5), inf).then(show, (e) => 'err:' + e.message));
    const z3 = new Uint8Array(z.length + 300); z3.set(z, 0); out('zipRead.tail', await C.zipRead(z3, inf).then(show, (e) => 'err:' + e.message)); }
  // the synthetic ROM of the Studio's own unit test
  let fake;
  { const rom = fakeRom(), ctx = C.openRom(rom); fake = ctx;
    out('fake.rom', sha(rom));
    out('fake.open', [ctx.editionId, ctx.edition, ctx.assetEnd, ctx.limit, ctx.entries.length, JSON.stringify(ctx.groups), ctx.adult, ctx.egg, C.isNeon(rom)].join('|'));
    out('fake.findGroups', JSON.stringify(C.findGroups(ctx.entries)) + ' ' + C.findEgg(ctx.entries) + ' ' + C.findEgg(ctx.entries.slice(7)) + ' ' + JSON.stringify(C.findGroups(ctx.entries.slice(0, 15))));
    out('fake.rebuild', sha(C.buildRom(ctx, new Map()).rom) === sha(rom));
    ctx.entries.forEach((e, i) => out('fake.decode' + i, decSha(e)));
    const g = ctx.groups[0];
    const red = img(64, 64, (x, y) => (x > 10 && x < 50 && y > 10) ? [250, 30, 40, 255] : (x === 10 ? [0, 0, 0, 255] : [0, 0, 0, 0]));
    const body = C.spriteEncode(ctx.entries[g], Array(20).fill(red), C.partOptions(0)); out('fake.body', sha(body) + ' ' + decSha(body));
    const eyesBlank = C.spriteBlank(ctx.entries[g + 1], C.partOptions(1)); out('fake.eyesBlank', sha(eyesBlank));
    out('fake.eyes.err', err(() => sha(C.spriteEncode(ctx.entries[g + 1], Array(20).fill(img(64, 32, (x, y) => [(x * 37 + y * 91) & 255, (x * 13) & 255, (y * 71) & 255, 255])), C.partOptions(1)))));
    out('fake.encode.err', err(() => sha(C.spriteEncode(ctx.entries[g], Array(19).fill(red), {}))) + ' ' + err(() => sha(C.spriteEncode(ctx.entries[g + 1], Array(20).fill(red), {}))));
    const b = C.buildRom(ctx, new Map([[g, body], [g + 1, eyesBlank]])); out('fake.buildRom', sha(b.rom) + ' ' + b.assetEnd + ' ' + b.free);
    const dpNew = new Uint8Array(3000).fill(9), b2 = C.buildRom(ctx, new Map([[3, C.spriteTiny(ctx.entries[3])]]), dpNew); out('fake.buildRom.dp', sha(b2.rom) + ' ' + b2.assetEnd + ' ' + b2.free + ' ' + sha(C.openRom(b2.rom).files[0]));
    out('fake.buildRom.big', err(() => sha(C.buildRom(ctx, new Map(), new Uint8Array(0x300000)).rom)));
    out('fake.verifyRom', C.verifyRom(rom, [0, 5, 20]) + ' ' + err(() => { const r2 = rom.slice(); r2[C.ASSET_BASE + 40]++; return C.verifyRom(r2, []); }) + ' ' + err(() => { const r2 = rom.slice(); r2[C.ASSET_BASE] = 0; return C.verifyRom(r2, []); }));
    out('fake.open.err', err(() => C.openRom(rom.subarray(0, 1000)).limit) + ' ' + err(() => { const r2 = rom.slice(); r2[0] = 0x58; return C.openRom(r2).limit; }) + ' ' + err(() => { const r2 = rom.slice(); r2.set(C.arc2Build([new Uint8Array(4), new Uint8Array(8)]), C.ASSET_BASE); return C.openRom(r2).limit; }) + ' ' + err(() => { const r2 = rom.slice(); r2[C.ASSET_BASE + 1] = 0; return C.openRom(r2).limit; }));
    out('fake.launcher', JSON.stringify([...C.launcherKeep(ctx)]) + ' ' + C.isLauncher(ctx) + ' ' + JSON.stringify([...C.launcherChanges(ctx).keys()]));
    out('fake.texts', C.textTablesOf(rom) === null ? 'null' : 'tables'); out('fake.textGet', JSON.stringify(C.textGet(rom, 3)) + ' ' + err(() => sha(C.textApply(rom, new Map([[1, 'X']])))) + ' ' + (C.textApply(rom, new Map()) === rom) + ' ' + (C.textApply(rom, null) === rom));
    out('fake.fields', JSON.stringify(C.charTable(ctx.files[0])) + JSON.stringify(C.charGroups(ctx)) + JSON.stringify(C.fieldSets(ctx)));
    // edition pages written by hand (footer k with k + id = constant, then its inverse)
    const idp = (r2, p, id, c) => { w32(r2, p, id); const k = (c - id) >>> 0; w32(r2, p + 0xFF8, k); w32(r2, p + 0xFFC, ~k >>> 0); };
    const eds = [[0xD49000, 2, 0x70169E2C], [0xD49000, 4, 0x849633DB], [0xD29000, 6, 0x96CB83B8], [0xD29000, 4, 0x96CB83B8], [0xD85000, 7, 0x99431749], [0xEFD000, 7, 0x99431749], [0xEFD000, 3, 0x70169E2C], [0xEFD000, 4, 0x96CB83B8], [0xD49000, 5, 0x96CB83B8], [0xD29000, 2, 0x70169E2C], [0xD49000, 3, 0x12345678], [0xD29000, 5, 0x12345678], [0xD49000, 9, 0x70169E2C]];
    out('fake.editions', eds.map(([p, id, c]) => { const r2 = rom.slice(); idp(r2, p, id, c); const x = C.openRom(r2); return x.editionId + ':' + x.edition + ':' + C.isNeon(r2); }).join(' '));
    { const r2 = rom.slice(); r2.fill(0xFF, ctx.limit, ctx.limit + 4); r2[ctx.limit + 0x1000] = 77; const x = C.openRom(r2); out('fake.edition.other', x.editionId + ':' + x.edition + ':' + x.limit); }
    // sprites of every kind made by hand: 1, 2, 8 bpp, plain, word RLE, LZ4, direct colour, palette sets, grids
    const r = rng(77);
    const mk = (o) => { const bits = { 0: 1, 1: 2, 2: 4, 3: 8 }[o.bpp], ncol = o.bpp >= 0x10 ? 0 : 1 << bits, npx = o.w * o.h, np = o.numPal || 1;
      const palLen = 2 * ncol * np, cells = [];
      for (let s = 0; s < o.n; s++) { let raw;
        if (o.bpp >= 0x10) { raw = new Uint8Array(npx * 2); for (let i = 0; i < raw.length; i++) raw[i] = r(); }
        else { raw = new Uint8Array(Math.ceil(npx * bits / 8)); const q = r(); for (let i = 0; i < raw.length; i++) raw[i] = (i % 9 < 5) ? q : r(); }
        cells.push(raw); }
      let body, tbl = null;
      if (o.bpp >= 0x10 || o.pack === 'plain') body = cells.map((c) => o.xor ? c.map((x) => x ^ 0x53) : c);
      else { tbl = []; body = cells.map((c, s) => { let d, unc = 0;
          if (o.pack === 'rle') d = C.rleEncode(c); else if (o.pack === 'lz4') d = C.lz4Encode(c);
          else { const wds = []; for (let i = 0; i + 4 <= c.length; i += 4) wds.push(0x80000001, (c[i] | c[i + 1] << 8 | c[i + 2] << 16 | c[i + 3] << 24) >>> 0); wds.push(3, 0x01020304, 0); d = new Uint8Array(wds.length * 4); wds.forEach((v, i) => w32(d, 4 * i, v)); }
          if (o.unc && s % 2) { d = c; unc = 0x80000000; }
          tbl.push(unc); return o.xor ? d.map((x) => x ^ 0x53) : d; }); }
      const pixOff = 24 + palLen; let len = pixOff + (tbl ? 8 * o.n : 0); const offs = []; for (const d of body) { offs.push(len - pixOff); len += d.length; }
      const e = new Uint8Array(len + (o.extra || 0)); w32(e, 0, len); e[4] = (o.transp ? 4 : 0) | (o.pack === 'rle' ? 0x20 : o.pack === 'rlew' ? 0x40 : o.pack === 'lz4' ? 0x08 : 0) | (o.xor ? 0x80 : 0) | 3;
      e[5] = o.bpp; w16(e, 6, o.n); e[8] = o.w; e[9] = o.h; e[10] = o.ox || 0; e[11] = o.oy || 0; e[12] = o.iw === undefined ? 1 : o.iw; e[13] = o.ih === undefined ? 1 : o.ih; e[14] = 0x11; e[15] = o.bpp >= 0x10 ? 0 : (o.numPal === undefined ? 1 : o.numPal);
      w16(e, 16, o.tr || 0); w16(e, 18, 24); w16(e, 20, pixOff);
      for (let i = 0; i < palLen; i++) e[24 + i] = r();
      body.forEach((d, s) => { if (tbl) { w32(e, pixOff + 8 * s, (offs[s] | tbl[s]) >>> 0); w32(e, pixOff + 8 * s + 4, d.length); } e.set(d, pixOff + offs[s]); });
      return e; };
    const kinds = [
      { bpp: 0, w: 16, h: 16, n: 3, pack: 'rle', xor: 1, transp: 1 }, { bpp: 1, w: 12, h: 10, n: 4, pack: 'plain', xor: 1 }, { bpp: 1, w: 12, h: 10, n: 4, pack: 'plain', transp: 1, tr: 2 },
      { bpp: 2, w: 32, h: 32, n: 6, pack: 'rle', xor: 1, transp: 1, numPal: 3 }, { bpp: 2, w: 16, h: 16, n: 8, pack: 'lz4', xor: 1, transp: 1, iw: 2, ih: 2 }, { bpp: 3, w: 24, h: 24, n: 4, pack: 'lz4', xor: 1, unc: 1 },
      { bpp: 3, w: 20, h: 12, n: 5, pack: 'rle', unc: 1, transp: 1, tr: 200 }, { bpp: 2, w: 16, h: 8, n: 3, pack: 'rlew', xor: 1 }, { bpp: 3, w: 8, h: 8, n: 6, pack: 'rlew', iw: 3, ih: 2, transp: 1, tr: 5, numPal: 2 },
      { bpp: 0x11, w: 16, h: 16, n: 4, transp: 1, tr: 0x07e0, iw: 2, ih: 1 }, { bpp: 0x11, w: 10, h: 6, n: 3 }, { bpp: 0x10, w: 8, h: 8, n: 2, transp: 1, tr: 0x1234, ox: 250, oy: 7 },
      { bpp: 2, w: 16, h: 16, n: 5, pack: 'rle', xor: 1, transp: 1, iw: 2, ih: 2 }, { bpp: 1, w: 9, h: 7, n: 2, pack: 'rle', xor: 1, iw: 0, ih: 0, numPal: 0, ox: 128, oy: 255 }, { bpp: 2, w: 64, h: 32, n: 20, pack: 'rle', xor: 1, transp: 1, extra: 4000 },
      { bpp: 3, w: 16, h: 16, n: 2, pack: 'lz4', xor: 1, transp: 1, tr: 0, numPal: 2 }, { bpp: 5, w: 4, h: 4, n: 1, pack: 'plain' },
    ];
    kinds.forEach((o, i) => {
      const e = o.bpp === 5 ? (() => { const x = mk(Object.assign({}, o, { bpp: 2 })); x[5] = 5; return x; })() : mk(o), P = (n, v) => out('kind' + i + '.' + n, v);
      P('entry', e.length + ' ' + sha(e)); P('header', JSON.stringify(C.spriteHeader(e))); P('decode', decSha(e)); P('decode.pal1', decSha(e, 1)); P('decode.cut', decSha(e.subarray(0, e.length - 9)) + ' ' + decSha(e.subarray(0, 30)) + ' ' + decSha(e.subarray(0, 10)));
      P('tiny', err(() => { const t = C.spriteTiny(e); return sha(t) + ' ' + decSha(t); }));
      for (const [k, v] of [[0, e], [1, (() => { const x = e.slice(0, e.length - 1); w32(x, 0, x.length); return x; })()], [2, (() => { const x = new Uint8Array(e.length + 2); x.set(e); w32(x, 0, e.length + 1); return x; })()], [3, e.subarray(0, 20)], [4, (() => { const x = e.slice(); w32(x, 0, e.length + 6); return x; })()], [5, (() => { const x = e.slice(); w32(x, 0, 21); return x; })()]]) P('align' + k, err(() => { const a = C.spriteAlign(v); return a ? a.length + ':' + sha(a) : 'null'; }));
      let subs; try { subs = C.spriteDecode(e).subs; } catch (x) { return; }
      const enc = (n, s, opts) => P('encode.' + n, err(() => { const x = C.spriteEncode(e, s, opts); return x.length + ' ' + sha(x) + ' ' + decSha(x); }));
      const ps = perturb(subs, 500 + i);
      enc('same', subs, {}); enc('keep', subs, { keepPalette: true }); enc('more', ps, { allowMoreColors: true }); enc('quant', ps, {}); enc('keepq', ps, { keepPalette: true }); enc('len', subs, { keepLength: true }); enc('lenq', ps, { keepLength: true, allowMoreColors: true });
      for (let k = 0; k < 6; k++) { enc('part' + k, subs, C.partOptions(k)); enc('partq' + k, ps, C.partOptions(k)); }
      enc('partkeep', ps, C.partOptions(0, { keepPalette: true })); enc('nofig', ps, C.partOptions(1, { figure: false, keepLength: false }));
      P('blank', err(() => sha(C.spriteBlank(e)))); P('blank.part', err(() => sha(C.spriteBlank(e, C.partOptions(1)))));
      const blank = subs.map((s) => C.emptyImage(s.w, s.h)), solid = subs.map((s) => ({ w: s.w, h: s.h, data: new Uint8ClampedArray(s.data.length).fill(255) })), dark = subs.map((s) => ({ w: s.w, h: s.h, data: s.data.map((v, j) => j % 4 === 3 ? 255 : j % 4 === 2 ? 100 : 5) }));
      enc('blank', blank, {}); enc('solid', solid, {}); enc('solid.fig', solid, C.partOptions(0)); enc('dark.fig', dark, C.partOptions(0)); enc('blank.fig', blank, C.partOptions(3));
    });
  }
  // eye layers of a data pack without a layer table (the old scan), and of a small one with a table
  { const dp = new Uint8Array(new Uint16Array([0, 10, 1027, 5, 65516, 1, 11, 1539, 0, 65520, 15, 12, 1031, 0, 0, 0, 0, 0, 10, 1100, 65530, 40, 3, 7, 7, 11, 1600, 3, 9, 2, 0, 0, 0, 0, 0, 0, 10, 1027, 5, 65516, 1, 11, 1539, 0, 65520, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).buffer);
    const mv = (m) => m.count + ':' + sha(m.dataPack);
    out('scan.paraLayers', C.paraLayers(dp) === null ? 'null' : 'table');
    out('scan', [mv(C.hideEyes(dp, 10, 11)), mv(C.hideEyes(dp, 10, 11, 300)), mv(C.setEyeOffset(dp, 10, 11, 64, 32, 3, 9)), mv(C.shiftEyes(dp, 10, 11, -4, 6)), mv(C.shiftEyes(dp, 10, 12, 1, 1)), JSON.stringify(C.eyeFirst(dp, 10, 11)), JSON.stringify(C.eyeFirst(dp, 11, 12)), JSON.stringify(C.eyeRelGet(dp, 10, 11, 64, 32)), JSON.stringify(C.eyeRelGet(dp, 3, 4, 64, 32)), JSON.stringify(C.faceFirst(dp, 10, 11, 12)), JSON.stringify(C.facePoses(dp, 10, 11, 12))].join(' '));
    out('layersMove.raw', sha(C.layersMove(dp, [{ ox: 6, oy: 8, d: [3, -2] }, { ox: -1, oy: 8, d: [9, 9] }, { ox: 20, oy: -1, d: [9, 9] }, { ox: 118, oy: 300, d: [70000, -70000] }])));
    // a table: 20 offsets, layers at 15, frames at 18
    const r = rng(31), lay = [], fr = []; let nl = 0;
    for (let f = 0; f < 60; f++) { if (r() < 30) { fr.push(0xFFFF, 0); continue; } const cnt = 1 + r() % 4; fr.push(f === 7 ? 5000 : nl, cnt);
      for (let j = 0; j < cnt; j++) { const a = r(), m = 0x400 | (a & 0x3FF), ws = [m]; for (let b = 0; b < 10; b++) if (m & (1 << b)) ws.push(b < 2 ? (r() % 61 - 30) & 0xFFFF : b === 2 ? r() % 4 : r()); ws.push(100 + r() % 6); lay.push(...ws); nl++; } }
    const t = new Uint8Array(80 + 2 * lay.length + 2 * fr.length + 6); for (let i = 0; i < 20; i++) w32(t, 4 * i, i <= 15 ? 40 : i <= 17 ? 40 + lay.length : i === 18 ? 40 + lay.length : 40 + lay.length + fr.length);
    w32(t, 4 * 18, 40 + lay.length); w32(t, 4 * 19, 40 + lay.length + fr.length);
    lay.forEach((v, i) => w16(t, 80 + 2 * i, v)); fr.forEach((v, i) => w16(t, 80 + 2 * lay.length + 2 * i, v));
    const P = C.paraLayers(t), idx = new Map(P.layers.map((l, i) => [l, i]));
    out('table.paraLayers', P.layers.length + ' ' + P.frames.length + ' ' + J(P.layers) + ' ' + J(P.frames.map((f) => f.map((l) => idx.get(l)))));
    for (const [b, e, m] of [[100, 101, 102], [101, 100, 105], [103, 104, 100], [105, 105, 105], [100, 200, 101], [300, 100, 101]]) {
      const fp = C.facePoses(t, b, e, m);
      out('table.' + b + '.' + e + '.' + m, [JSON.stringify(C.eyeFirst(t, b, e)), JSON.stringify(C.faceFirst(t, b, e, m)), J(fp), fp.length, JSON.stringify(C.eyeRelGet(t, b, e, 64, 32)), JSON.stringify(C.eyeRelGet(t, b, e, 32, 16)), mv(C.shiftEyes(t, b, e, 3, -2)), mv(C.hideEyes(t, b, e)), mv(C.hideEyes(t, b, e, 77)), mv(C.setEyeOffset(t, b, e, 64, 32, -5, 11)), mv(C.setEyeOffset(t, b, e, 32, 16, 2, 3)),
        sha(C.layersMove(t, fp.flatMap((p, i) => [p.eye, p.mouth].filter((x) => x).map((x) => ({ ox: x.ox, oy: x.oy, d: [i - 3, 2 * i + 1] })))))].join(' '));
    }
    const bad = t.slice(); w16(bad, 80, 0x8000); out('table.badmask', C.paraLayers(bad) === null ? 'null' : 'table');
    out('table.short', [C.paraLayers(t.subarray(0, 60)), C.paraLayers(new Uint8Array(0)), C.paraLayers(t.subarray(0, t.length - 7))].map((x) => x === null ? 'null' : x.layers.length + '/' + x.frames.length).join(' '));
    // character table and fields on a made data pack
    const mkDp = (recs, shift) => { const d = new Uint8Array(40 + 30 * recs.length + 8); w32(d, 0, 4); w32(d, 4, 12); w32(d, 8, 20 + shift); w32(d, 12, (40 + 30 * recs.length) / 2 + shift); w32(d, 16, 9999); recs.forEach((rc, i) => rc.forEach((v, k) => w16(d, 40 + 2 * shift + 30 * i + 2 * k, v))); return d; };
    const recs = [[0xFFFF, 0, 0, 0, 0, 0, 0, 0], [1000, 50, 7, 0, 0, 0, 0, 0], [1001, 51, 8, 1, 2, 0, 0, 1], [1002, 52, 9, 2, 2, 0, 0, 2], [1003, 51, 10, 3, 1, 0, 0, 9], [1004, 53, 11, 3, 1, 0, 0, 7], [9000, 60, 12, 0, 0, 0, 0, 3], [1005, 99, 13, 3, 0, 0, 0, 8], [1006, 52, 14, 3, 0, 0, 0, 9]];
    out('charTable.made', JSON.stringify(C.charTable(mkDp(recs, 0))) + ' ' + JSON.stringify(C.charTable(mkDp(recs.slice(1), 0))) + ' ' + JSON.stringify(C.charTable(mkDp(recs, 0).subarray(0, 100))) + ' ' + JSON.stringify(C.charTable(new Uint8Array(0))));
    const fctx = (rs, groups) => ({ files: [mkDp(rs, 0)], groups, entries: fake.entries });
    out('charGroups.made', [fctx(recs, [12, 18, 24, 30, 36, 42, 48]), fctx(recs, [12, 18, 24, 30]), fctx(recs, [12, 18]), fctx(recs.filter((x) => x[0] !== 1000), [12, 18, 24]), fctx(recs.map((x) => x[0] === 1001 ? [1001, 55, 8, 1, 2, 0, 0, 1] : x), [12, 18, 24]), fctx(recs.map((x) => [x[0], x[1], x[2], x[3], x[4], 0, 0, x[7] > 6 ? 2 : x[7]]), [12, 18, 24, 12, 18, 24, 12])].map((c) => JSON.stringify(C.charGroups(c)) + JSON.stringify(C.fieldSets(c))).join(' '));
  }
  // cards
  for (const [kind, raw] of [['sma', smaCard(11)], ['sma2', smaCard(12)], ['dim', dimCard(21)], ['drawn', null], ['drawn.baby', null]]) {
    const P = (n, v) => out(kind + '.' + n, v);
    let card;
    if (raw) { P('card', raw.length + ' ' + sha(raw)); P('detect', C.smaDetect(raw) + ' ' + C.smaDetect(raw.subarray(0, 0x10FF)));
      P('load.err', err(() => (kind === 'dim' ? C.smaLoad : C.dimLoad)(raw).chars.length) + ' ' + err(() => { const x = raw.slice(); if (kind === 'dim') x[0x100000] ^= 1; else x[0x1000] ^= 1; return (kind === 'dim' ? C.dimLoad : C.smaLoad)(x).chars.length; }) + ' ' + err(() => C.dimLoad(raw.subarray(0, 5000)).chars.length));
      card = kind === 'dim' ? C.dimLoad(raw) : C.smaLoad(raw); P('load', card.chars.length + ' ' + card.eggs.length + ' ' + (card.kind || '') + ' ' + imgsSha(card.eggs) + ' ' + card.eggs.map((e) => e.w + 'x' + e.h).join(','));
      if (card.eggs.length) { const es = C.dimEggSubs(card.eggs); P('dimEggSubs', imgsSha(es.small) + ' ' + imgsSha(es.big)); const e1 = C.dimEggSubs(card.eggs.slice(0, 2)); P('dimEggSubs.two', imgsSha(e1.small) + ' ' + imgsSha(e1.big)); }
      P('dimEggSubs.none', err(() => imgsSha(C.dimEggSubs([]).small)));
    } else card = { chars: [drawnChar(kind !== 'drawn')], eggs: [] };
    card.chars.forEach((ch, ci) => {
      const Q = (n, v) => P('ch' + ci + '.' + n, v), im = ch.frames.idle1;
      Q('char', im.w + 'x' + im.h + ' ' + Object.keys(ch.frames).join(',') + ' ' + charSha(ch));
      Q('dimCharParts', C.dimCharParts(ch).map(imgsSha).join(' ')); Q('dimCharParts.scale', C.dimCharParts(ch, 1.5, 0.75).map(imgsSha).join(' ') + ' ' + C.dimCharParts(ch, 0.4, 3).map(imgsSha).join(' '));
      const guess = C.dimGuessEye(ch), pre = C.dimEyePreset(ch); Q('dimGuessEye', JSON.stringify(guess)); Q('dimEyePreset', pre === undefined ? 'undefined' : JSON.stringify(pre));
      const cx = im.w >> 1, cy = im.h >> 1; Q('eyeRectAt', [[cx, cy], [0, 0], [im.w - 1, im.h - 1], [cx - 5, cy - 4], [3, cy]].map(([x, y]) => JSON.stringify(C.eyeRectAt(ch, x, y))).join(' '));
      const rects = [guess || [cx - 3, cy - 3, cx + 3, cy + 3], [cx - 2, cy - 6, cx + 4, cy - 1], [1, 1, 4, 3], [cx, cy, cx, cy]];
      rects.forEach((rect, ri) => Q('eyes' + ri, err(() => {
        const ep = C.dimCharPartsWithEyes(ch, rect); if (!ep) return 'null';
        const lay = (l) => new H().imgs(l.body).imgs(l.eyes).img(l.lo).img(l.lc).img(l.em).s(JSON.stringify(l.off)).hex;
        const r1 = [ep.parts.map(imgsSha).join(','), JSON.stringify(ep.eyeBig), JSON.stringify(ep.eyeSmall), lay(ep.big), lay(ep.small), C.eyeVariants(ep.big, true).map(imgsSha).join(','), C.eyeVariants(ep.small, false).map(imgsSha).join(',')].join(' ');
        // the parts into the character group of the synthetic ROM, as the Studio does
        const g = fake.groups[1], encs = ep.parts.map((subs, k) => err(() => sha(C.spriteEncode(fake.entries[g + k], subs, C.partOptions(k)))));
        const fit = [1, 4].map((k) => { let res = 'none'; C.eyeVariants(k === 1 ? ep.big : ep.small, k === 1).some((v, vi) => { try { res = vi + ':' + sha(C.spriteEncode(fake.entries[g + k], v, C.partOptions(k))); return true; } catch (x) { return false; } }); return res; });
        return sha(r1 + ' ' + encs.join(',') + ' ' + fit.join(','));
      })));
      Q('eyes.scale', err(() => { const ep = C.dimCharPartsWithEyes(ch, rects[0], 0.8, 0.4); return ep ? ep.parts.map(imgsSha).join(',') + JSON.stringify(ep.eyeBig) + JSON.stringify(ep.eyeSmall) : 'null'; }));
      Q('eyes.outside', err(() => { const ep = C.dimCharPartsWithEyes(ch, [im.w - 2, im.h - 2, im.w + 3, im.h + 3]); return ep ? 'parts' : 'null'; }));
      Q('encode', C.dimCharParts(ch).map((subs, k) => err(() => sha(C.spriteEncode(fake.entries[fake.groups[0] + k], subs, C.partOptions(k))))).join(' '));
    });
  }

  // ================================================================ every edition
  for (const name of EDS) {
    const rom = new Uint8Array(fs.readFileSync(path.join(DUMPS, name + '.bin'))), P = (n, v) => out(name + '.' + n, v);
    const ctx = C.openRom(rom), dp = ctx.files[0], n = ctx.entries.length;
    P('open', [ctx.editionId, ctx.edition, ctx.assetEnd, ctx.limit, n, ctx.groups.length, J(ctx.groups), ctx.adult, ctx.egg, C.isNeon(rom)].join('|'));
    P('root', ctx.root.chk + ' ' + ctx.root.length + ' ' + JSON.stringify(ctx.root.ents));
    P('files', ctx.files.map((f) => f.length + ':' + sha(f)).join(' '));
    P('arc2', C.arc2Checksum(rom, C.ASSET_BASE, ctx.root.length) + ' ' + C.arc2Files(rom, C.ASSET_BASE).map(sha).join(',') + ' ' + sha(C.arc2Build(ctx.files)) + ' ' + (sha(C.arc2Build(ctx.files)) === sha(rom.subarray(C.ASSET_BASE, ctx.assetEnd))));
    P('pack', C.packSplit(ctx.files[1]).length + ' ' + sha(C.packJoin(ctx.entries)) + ' ' + (sha(C.packJoin(ctx.entries)) === sha(ctx.files[1])) + ' ' + new H().imgs(ctx.entries.map((e) => ({ w: 0, h: 0, data: e }))).hex);
    P('find', J(C.findGroups(ctx.entries)) + ' ' + C.findEgg(ctx.entries) + ' ' + (ctx.groups.length ? C.findFirstAdult(ctx.entries, ctx.groups) : -1) + ' ' + (ctx.groups.length > 3 ? C.findFirstAdult(ctx.entries, ctx.groups.slice(0, 3)) : -1));
    P('headers', J(ctx.entries.map((e) => C.spriteHeader(e))));
    { const h = new H(); let bad = 0; for (const e of ctx.entries) { const s = decSha(e); if (s.startsWith('err')) bad++; h.s(s); } P('decode.all', h.hex + ' errors ' + bad); }
    { const h = new H(); let k = 0; ctx.entries.forEach((e) => { if (C.spriteHeader(e).numPal > 1) { k++; h.s(decSha(e, 1)).s(decSha(e, 7)); } }); P('decode.palsets', k + ' ' + h.hex); }
    P('verifyRom', err(() => C.verifyRom(rom, ctx.entries.map((_, i) => i))) + ' ' + err(() => { const r2 = rom.slice(); r2[C.ASSET_BASE + ctx.root.ents[2].offset + 20] ^= 1; return C.verifyRom(r2, []); }) + ' ' + err(() => { const r2 = rom.slice(); r2[C.ASSET_BASE + ctx.root.ents[1].offset + 5000] ^= 1; return C.verifyRom(r2, []); }));
    P('rebuild', (() => { const b = C.buildRom(ctx, new Map()); return sha(b.rom) + ' ' + (sha(b.rom) === sha(rom)) + ' ' + b.assetEnd + ' ' + b.free; })());
    // tiny, blank, align on every entry
    { const ht = new H(), ha = new H(); let na = 0; for (const e of ctx.entries) { ht.s(err(() => sha(C.spriteTiny(e)))); const a = C.spriteAlign(e); if (a) na++; ha.s(a ? sha(a) : 'null'); const x = e.slice(0, e.length - 1); w32(x, 0, x.length); const a2 = C.spriteAlign(x); ha.s(a2 ? sha(a2) : 'null'); } P('tiny.all', ht.hex); P('align.all', na + ' ' + ha.hex); }
    // encode: a spread of entries, the first direct colour ones, the egg and two character groups
    { const step = Math.ceil(n / 40), pick = new Map();   // index -> part number or -1
      for (let i = 0; i < n; i += step) pick.set(i, -1);
      let nd = 0; for (let i = 0; i < n && nd < 3; i++) { const h = C.spriteHeader(ctx.entries[i]); if (h.bpp >= 0x10 && h.sw * h.sh * h.numSprites < 100000) { pick.set(i, -1); nd++; } }
      if (ctx.egg >= 0) { pick.set(ctx.egg, -1); pick.set(ctx.egg + 3, -1); }
      for (const g of [ctx.groups[1], ctx.adult, ctx.groups[ctx.groups.length - 1]]) if (g !== undefined && g >= 0) for (let k = 0; k < 6; k++) pick.set(g + k, k);
      const list = [...pick.keys()].sort((a, b) => a - b); P('encode.picked', list.length + ' ' + J(list));
      for (const i of list) {
        const e = ctx.entries[i], h = C.spriteHeader(e), k = pick.get(i), px = h.sw * h.sh * h.numSprites;
        let subs; try { subs = C.spriteDecode(e).subs; } catch (x) { P('encode' + i, 'err'); continue; }
        const res = []; const enc = (s, opts) => res.push(err(() => { const x = C.spriteEncode(e, s, opts); return x.length + ':' + sha(x); }));
        const ps = perturb(subs, i);
        enc(subs, { keepPalette: true }); enc(ps, { keepPalette: true }); enc(subs, { keepLength: true }); res.push(err(() => sha(C.spriteBlank(e))));
        if (px <= 150000) { enc(subs, {}); enc(ps, {}); enc(ps, { allowMoreColors: true }); }
        if (k >= 0) { enc(subs, C.partOptions(k)); enc(ps, C.partOptions(k)); enc(ps, C.partOptions(k, { keepPalette: true })); res.push(err(() => sha(C.spriteBlank(e, C.partOptions(k))))); }
        P('encode' + i, sha(res.join(' ')));
      }
    }
    // sheets of a character group
    if (ctx.groups.length) { const g = ctx.adult, parts6 = [0, 1, 2, 3, 4, 5].map((k) => C.spriteDecode(ctx.entries[g + k]).subs), sheet = C.groupSheet(parts6), back = C.groupFromSheet(sheet);
      P('groupSheet', imgSha(sheet) + ' ' + back.map(imgsSha).join(',') + ' ' + back.every((p, k) => p.every((s, i) => C.sameImage(s, parts6[k][i]))));
      const ss = C.sheetFromSubs(parts6[3]); P('sheet', imgSha(ss) + ' ' + imgsSha(C.subsFromSheet(ss, 32, 32, 24))); }
    // launcher ROM
    { const keep = C.launcherKeep(ctx), ch = C.launcherChanges(ctx), h = new H(); for (const [i, e] of ch) h.s(i).b(e);
      P('launcher', keep.size + ' ' + J([...keep]) + ' ' + C.isLauncher(ctx) + ' ' + ch.size + ' ' + h.hex);
      const b = C.buildRom(ctx, ch), c2 = C.openRom(b.rom); P('launcher.rom', sha(b.rom) + ' ' + b.assetEnd + ' ' + b.free + ' ' + C.isLauncher(c2) + ' ' + c2.groups.length + ' ' + c2.adult + ' ' + c2.egg + ' ' + c2.limit + ' ' + c2.editionId); }
    // fields
    { const ct = C.charTable(dp), cg = C.charGroups(ctx), fsets = C.fieldSets(ctx);
      P('charTable', ct.length + ' ' + J(ct)); P('charGroups', cg.length + ' ' + J(cg));
      P('fieldSets', fsets.length + ' ' + J(fsets) + ' ' + fsets.map((f) => f.type + ':' + f.chars.length + ':' + f.maps.length + ':' + f.overlays.length + ':' + f.closeups.length).join(','));
      const few = { files: ctx.files, entries: ctx.entries, groups: ctx.groups.slice(0, ctx.groups.length - 2) }; P('fields.fewer', J(C.charGroups(few)) + ' ' + J(C.fieldSets(few))); }
    // texts
    { const x = C.textTablesOf(rom), h = new H(); for (const t of x.tabs) h.s(t.n).b(t.b).s(JSON.stringify(t.offs));
      P('textTablesOf', x.off + ' ' + x.tabs.length + ' ' + x.tabs.map((t) => t.n).join(',') + ' ' + h.hex);
      const nmax = Math.max(...x.tabs.map((t) => t.n)), all = []; for (let i = 0; i < nmax + 3; i++) all.push(C.textGet(rom, i));
      const full = all.map((s, i) => s ? i : -1).filter((i) => i >= 0); P('textGet', all.length + ' ' + full.length + ' ' + J(all));
      const names = C.charGroups(ctx).map((c) => c.name), ids = [...new Set([0, 1, 2, ...full.slice(0, 4), ...names.slice(0, 6), names[names.length - 1], full[full.length - 1], nmax - 1, nmax + 5])].filter((v) => v !== undefined);
      const texts = ['Test name 1', 'a much longer name than before, with ünïcödé & more!?', '###', 'x', "it's/9.", 'Straße', '', 'Paramix', 'ZZ TOP', 'q', 'W W', '0'];
      const edits = new Map(ids.map((id, k) => [id, texts[k % texts.length]]));
      const r2 = C.textApply(rom, edits); P('textApply', J(ids) + ' ' + sha(r2) + ' ' + J(ids.map((id) => C.textGet(r2, id))) + ' ' + J(all.map((_, i) => C.textGet(r2, i))) + ' ' + C.openRom(r2).assetEnd);
      const r3 = C.textApply(r2, new Map(ids.map((id) => [id, all[id]]))); P('textApply.back', sha(r3) + ' ' + (sha(r3) === sha(rom)) + ' ' + J(all.map((_, i) => C.textGet(r3, i))));
      P('textApply.none', (C.textApply(rom, new Map()) === rom) + ' ' + (sha(C.textApply(rom, new Map([[full[0], '###']]))) === sha(rom)) + ' ' + sha(C.textApply(rom, new Map([[full[1], 'solo']]))));
      P('textApply.long', err(() => sha(C.textApply(rom, new Map([[full[0], 'A'.repeat(70000)]])))) + ' ' + err(() => sha(C.textApply(rom, new Map([[full[2], 'AB '.repeat(3000)]])))));
      P('textApply.big', err(() => { const m = new Map(); for (const i of full) m.set(i, ('NAME ' + i + ' ').repeat(400)); return sha(C.textApply(rom, m)); })); }
    // figures: layers, faces, eyes
    { const L = C.paraLayers(dp), idx = new Map(L.layers.map((l, i) => [l, i]));
      P('paraLayers', L.layers.length + ' ' + L.frames.length + ' ' + J(L.layers) + ' ' + J(L.frames.map((f) => f.map((l) => idx.get(l)))));
      const hs = {}, add = (k, v) => { (hs[k] = hs[k] || new H()).s(v); }, mv = (m) => m.count + ':' + sha(m.dataPack);
      let cur = dp;
      ctx.groups.forEach((g, gi) => {
        add('eyeFirst', JSON.stringify(C.eyeFirst(dp, g, g + 1)) + JSON.stringify(C.eyeFirst(dp, g + 3, g + 4)) + JSON.stringify(C.eyeFirst(dp, g, g + 2)));
        add('faceFirst', JSON.stringify(C.faceFirst(dp, g, g + 1, g + 2)) + JSON.stringify(C.faceFirst(dp, g + 3, g + 4, g + 5)));
        const fp = C.facePoses(dp, g, g + 1, g + 2), fps = C.facePoses(dp, g + 3, g + 4, g + 5);
        add('facePoses', fp.length + ' ' + fps.length + JSON.stringify(fp) + JSON.stringify(fps));
        add('eyeRelGet', JSON.stringify(C.eyeRelGet(dp, g, g + 1, 64, 32)) + JSON.stringify(C.eyeRelGet(dp, g, g + 2, 64, 32)) + JSON.stringify(C.eyeRelGet(dp, g + 3, g + 4, 32, 16)) + JSON.stringify(C.eyeRelGet(dp, g + 3, g + 5, 32, 16)));
        if (gi % 4 === 0) {   // the changing ones on every fourth figure (each copies the data pack)
          add('shiftEyes', mv(C.shiftEyes(dp, g, g + 1, 2, -1)) + mv(C.shiftEyes(dp, g, g + 2, -3, 4)) + mv(C.shiftEyes(dp, g + 3, g + 4, 1, 1)) + mv(C.shiftEyes(dp, g + 3, g + 5, -40000, 40000)));
          add('hideEyes', mv(C.hideEyes(dp, g, g + 1)) + mv(C.hideEyes(dp, g + 3, g + 4, 500)));
          add('setEyeOffset', mv(C.setEyeOffset(dp, g, g + 1, 64, 32, 3, 5)) + mv(C.setEyeOffset(dp, g + 3, g + 4, 32, 16, -2, 1)));
          add('layersMove', sha(C.layersMove(dp, [...fp, ...fps].flatMap((p, i) => [p.eye, p.mouth].filter((x) => x).map((x) => ({ ox: x.ox, oy: x.oy, d: [(i % 5) - 2, 3 - (i % 7)] }))))));
          cur = C.shiftEyes(cur, g, g + 1, 1 + gi % 3, -2).dataPack; cur = C.shiftEyes(cur, g + 3, g + 5, -1, gi % 2).dataPack;
        }
      });
      for (const k of ['eyeFirst', 'faceFirst', 'facePoses', 'eyeRelGet', 'shiftEyes', 'hideEyes', 'setEyeOffset', 'layersMove']) P(k, hs[k] ? hs[k].hex : 'none');
      // the moved eyes and mouths in a ROM
      const b = C.buildRom(ctx, new Map(), cur), c2 = C.openRom(b.rom), h2 = new H();
      for (const g of ctx.groups) h2.s(JSON.stringify(C.eyeRelGet(c2.files[0], g, g + 1, 64, 32)) + JSON.stringify(C.eyeRelGet(c2.files[0], g + 3, g + 5, 32, 16)));
      P('eyes.rom', sha(cur) + ' ' + sha(b.rom) + ' ' + b.free + ' ' + h2.hex);
    }
  }
})();
