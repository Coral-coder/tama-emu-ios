// Check of lib/paramix/wolf.dart against third_party/paramix-studio/src/wolf.js (the original).
// node tool/paramix_check/wolf.js        (no dumps needed)
// Prints one line per case: "<case name> <value or sha256>". tool/paramix_check/wolf_check.dart prints the same.
// No game files: the sets are synthetic (seeded xorshift32) with the structure the module reads: VSWAP page table,
// MAPHEAD/GAMEMAPS, AUDIOHED/AUDIOT, a Huffman dictionary (every byte coded by its 8 bits) with VGAHEAD/VGAGRAPH.
'use strict';
const path = require('path'), crypto = require('crypto');
const W = require(path.join(__dirname, '..', '..', 'third_party', 'paramix-studio', 'src', 'wolf.js'));

const lines = [];
const sha = (b) => crypto.createHash('sha256').update(Buffer.from(b.buffer, b.byteOffset, b.length)).digest('hex');
const H = (b) => (b === null || b === undefined ? 'null' : b.length + ':' + sha(b));
const out = (n, v) => { lines.push(n + ' ' + v); };
const T = (n, f) => { try { out(n, f()); } catch (e) { out(n, 'ERR ' + (e instanceof Error && !(e instanceof TypeError) && !(e instanceof RangeError) ? e.message : 'INTERNAL')); } };
function w16(b, o, v) { b[o] = v & 255; b[o + 1] = (v >> 8) & 255; }
function w24(b, o, v) { b[o] = v & 255; b[o + 1] = (v >> 8) & 255; b[o + 2] = (v >> 16) & 255; }
function w32(b, o, v) { b[o] = v & 255; b[o + 1] = (v >>> 8) & 255; b[o + 2] = (v >>> 16) & 255; b[o + 3] = (v >>> 24) & 255; }

// ------------------------------------------------------------ synthetic game files
function rng(seed) { let x = (seed >>> 0) || 1; return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x; }; }
function rnd(r, n, mask) { const b = new Uint8Array(n); for (let i = 0; i < n; i++) b[i] = r() & (mask || 255); return b; }
function cat(parts) { let n = 0; for (const p of parts) n += p.length; const o = new Uint8Array(n); let q = 0; for (const p of parts) { o.set(p, q); q += p.length; } return o; }
const rev8 = (v) => { let o = 0; for (let k = 0; k < 8; k++) if (v & (1 << k)) o |= 0x80 >> k; return o; };
/* the dictionary: a full tree, node 254 is the root, the node at heap place h (1..255) is 255 - h; a byte is its 8 bits */
function dict(extra) {
  const d = new Uint8Array(1020 + extra);
  for (let h = 1; h <= 255; h++) for (let s = 0; s < 2; s++) { const c = 2 * h + s; w16(d, 4 * (255 - h) + 2 * s, c >= 256 ? c - 256 : 256 + (255 - c)); }
  return d;
}
const huff = (d) => d.map(rev8);
/* o: ext, seed, chunks, maps, badWall, shortHead, noPal, splitTitle, ... */
function gameSet(o) {
  const r = rng(o.seed), f = {};
  // VSWAP: walls, sprites, digitized sounds
  {
    const spr = o.walls || 6, nspr = 5, nsnd = 3, nch = spr + nspr + nsnd, head = new Uint8Array(6 + 6 * nch), data = [];
    let pos = head.length + 7;
    data.push(rnd(r, 7));
    w16(head, 0, nch); w16(head, 2, spr); w16(head, 4, spr + nspr);
    for (let i = 0; i < nch; i++) {
      let len = i < spr ? 4096 : 40 + r() % 500, off = pos;
      if (i === 2) { len = 0; }                                  // an empty wall
      if (i === 3) { off = 0; }                                  // a wall without a place
      if (o.badWall && i === 1) len = o.badWall;
      if (i === spr + 1) off = 0x7FFFFF00;                       // a sprite behind the end of the file
      w32(head, 6 + 4 * i, off); w16(head, 6 + 4 * nch + 2 * i, len);
      if (off === pos && len) { data.push(rnd(r, len)); pos += len; }
    }
    f.VSWAP = cat([head].concat(data));
  }
  // GAMEMAPS and MAPHEAD
  {
    const n = o.maps, parts = [rnd(r, 8)], mh = new Uint8Array(o.shortHead ? 2 + 4 * 12 : 402 + (o.seed & 3));
    let pos = 8;
    w16(mh, 0, 0xABCD);
    for (let i = 0; i < 100 && 2 + 4 * i + 4 <= mh.length; i++) {
      if (i >= n) { w32(mh, 2 + 4 * i, i % 3 === 0 ? 0xFFFFFFFF : 0); continue; }
      if (i === 4) { w32(mh, 2 + 4 * i, 0); continue; }         // a map that is not there
      if (i === 7) { w32(mh, 2 + 4 * i, 0x7FFFFF00); continue; } // a map behind the end of the file
      const h = new Uint8Array(38);
      for (let p = 0; p < 3; p++) {
        let len = 10 + r() % 300;
        if (i === 1 && p === 2) len = 0;
        const d = rnd(r, len);
        w32(h, 4 * p, i === 2 && p === 1 ? 0 : pos); w16(h, 12 + 2 * p, len);
        parts.push(d); pos += len;
      }
      w16(h, 18, 64); w16(h, 20, 64);
      const nm = 'Wolf' + (1 + (i / 10 | 0)) + ' Map' + (1 + i % 10); for (let k = 0; k < nm.length; k++) h[22 + k] = nm.charCodeAt(k);
      w32(mh, 2 + 4 * i, pos); parts.push(h); pos += 38;
    }
    if (o.cutMaps) parts.push(rnd(r, 5));
    f.MAPHEAD = mh; f.GAMEMAPS = cat(parts);
  }
  // AUDIOHED and AUDIOT
  {
    const n = o.sounds || 100, ah = new Uint8Array(4 * (n + 1)), parts = [];
    let pos = 0;
    for (let i = 0; i < n; i++) {
      w32(ah, 4 * i, pos);
      const len = i % 9 === 5 ? 0 : 7 + r() % 120;
      if (len) { parts.push(rnd(r, len)); pos += len; }
    }
    w32(ah, 4 * n, pos);
    if (o.audioBad) w32(ah, 4 * 11, 0x7FFFFFFF);                // a start behind the end
    f.AUDIOHED = ah; f.AUDIOT = cat(parts);
  }
  // VGADICT, VGAHEAD, VGAGRAPH
  {
    const n = o.chunks, head = new Uint8Array(3 * n + (o.headExtra || 0)), parts = [], npics = n - 3 - 12;
    let pos = 0;
    const st = new Uint8Array(4 * npics), pics = [];
    for (let k = 0; k < npics; k++) {
      let w = 4 * (1 + r() % 10), h = 1 + r() % 24, len = w * h;
      const c = 3 + k;
      if (o.ext === 'SOD' && (c === 79 || c === 80)) { w = 64; h = c === 79 ? 10 : 6; if (o.splitTitle && c === 80) w = 60; len = w * h; }
      if (k % 23 === 9) w += 2;                                  // a width that is no multiple of 4
      if (k % 29 === 11) w = 0;
      if (k % 31 === 13) h = -3;
      if (k % 37 === 17) len -= 3;                               // less data than the picture needs
      if (k % 41 === 19) len += 5;
      w16(st, 4 * k, w); w16(st, 4 * k + 2, h);
      pics.push(rnd(r, Math.max(0, len)));
    }
    const put = (c, d, bare) => {
      w24(head, 3 * c, pos);
      const b = new Uint8Array((bare ? 0 : 4) + d.length); if (!bare) w32(b, 0, d.length); b.set(huff(d), bare ? 0 : 4);
      parts.push(b); pos += b.length;
    };
    for (let c = 0; c < n; c++) {
      if (c === 0) put(c, st);
      else if (c < 3) put(c, rnd(r, 30 + r() % 50));
      else if (c - 3 < npics) { if ((c - 3) % 43 === 21 || (o.noTitle2 && c === 80)) w24(head, 3 * c, 0xFFFFFF); else put(c, pics[c - 3]); }
      else if (o.ext === 'SOD' && c === 153) { if (o.noPal) w24(head, 3 * c, 0xFFFFFF); else put(c, rnd(r, o.shortPal ? 700 : 768, 63)); }
      else if (c === n - 2) put(c, rnd(r, 33), true);            // a chunk without its length in front
      else put(c, rnd(r, 5 + r() % 40));
    }
    f.VGAHEAD = head; f.VGADICT = dict(o.seed & 7); f.VGAGRAPH = cat(parts);
  }
  const res = {};
  for (const k of Object.keys(f)) res[(o.name || ((s) => s))(k + '.' + o.ext)] = f[k];
  return res;
}
const SETS = {
  wl6: { ext: 'WL6', seed: 0x1001, chunks: 150, maps: 60 },
  wl6b: { ext: 'WL6', seed: 0x1002, chunks: 150, maps: 23, shortHead: true, walls: 9, sounds: 40, audioBad: true, headExtra: 2, cutMaps: true },
  wl6apogee: { ext: 'WL6', seed: 0x1003, chunks: 157, maps: 60, name: (s) => 'C:\\games\\wolf3d\\' + s.toLowerCase() },
  wl1: { ext: 'WL1', seed: 0x1004, chunks: 157, maps: 10, name: (s) => '/home/x/wolf/' + s[0] + s.slice(1).toLowerCase() },
  wl1b: { ext: 'WL1', seed: 0x1005, chunks: 150, maps: 3 },
  sod: { ext: 'SOD', seed: 0x1006, chunks: 170, maps: 21 },
  sodNoPal: { ext: 'SOD', seed: 0x1007, chunks: 170, maps: 21, noPal: true },
  sodShortPal: { ext: 'SOD', seed: 0x1008, chunks: 170, maps: 20, shortPal: true, splitTitle: true },
  sodHalf: { ext: 'SOD', seed: 0x1009, chunks: 170, maps: 21, noTitle2: true },
  badWall: { ext: 'WL6', seed: 0x100A, chunks: 150, maps: 10, badWall: 16384 },
  badWall1: { ext: 'WL1', seed: 0x100B, chunks: 150, maps: 10, badWall: 4095 },
  badHead: { ext: 'WL6', seed: 0x100C, chunks: 149, maps: 10 },
  badHeadSod: { ext: 'SOD', seed: 0x100D, chunks: 150, maps: 10 },
  badHead1: { ext: 'WL1', seed: 0x100E, chunks: 170, maps: 10 },
};
const setStr = (s) => s.ext + ' ' + W.NEED.map((k) => k + '=' + H(s.files[k])).join(' ');
const without = (f, re) => { const o = {}; for (const k of Object.keys(f)) if (!re.test(k)) o[k] = f[k]; return o; };

out('NEED', W.NEED.join(','));
const G = {};
for (const n of Object.keys(SETS)) G[n] = gameSet(SETS[n]);
for (const n of Object.keys(SETS)) {
  out('files.' + n, Object.keys(G[n]).map((k) => k + '=' + H(G[n][k])).join(' '));
  T('pickSet.' + n, () => setStr(W.pickSet(G[n])));
  T('build.' + n, () => { const r = W.build(G[n]); return H(r.pack) + ' ' + r.ext + ' maps=' + r.maps + ' episodes=' + r.episodes + ' sod=' + r.sod; });
  T('readGraph.' + n, () => {
    const s = W.pickSet(G[n]).files, g = W.readGraph(s.VGAHEAD, s.VGADICT, s.VGAGRAPH), o = [g.nchunks];
    for (const c of [0, 1, 2, 3, 24, 46, 79, 80, 100, g.nchunks - 1, g.nchunks, g.nchunks + 5]) o.push(c + '=' + H(g.chunk(c)));
    o.push('bare=' + H(g.chunk(g.nchunks - 2, 33)), 'part=' + H(g.chunk(5, 3)), 'none=' + H(g.chunk(5, 0)));
    return o.join(' ');
  });
}
// several sets at once, incomplete sets, other files
const mix = (...xs) => Object.assign({}, ...xs);
T('pick.all', () => setStr(W.pickSet(mix(G.wl1b, G.sod, G.wl6))));
T('pick.sod+wl1', () => setStr(W.pickSet(mix(G.wl1b, G.sod))));
T('pick.wl6cut+wl1', () => setStr(W.pickSet(mix(without(G.wl6, /^VGA/), G.wl1b))));
T('pick.wl6cut+sod', () => setStr(W.pickSet(mix(without(G.wl6, /^AUDIOT/), G.sod, G.wl1b))));
T('pick.wl6cut', () => setStr(W.pickSet(without(G.wl6, /^(VGAHEAD|AUDIOT)/))));
T('pick.wl6cut+sodcut', () => setStr(W.pickSet(mix(without(G.wl6, /^MAPHEAD/), without(G.sod, /^VSWAP/)))));
T('pick.sodcut+wl1cut', () => setStr(W.pickSet(mix(without(G.sod, /^(VSWAP|GAMEMAPS)/), without(G.wl1b, /^VGADICT/)))));
T('pick.wl1cut', () => setStr(W.pickSet(without(G.wl1b, /^(VSWAP|VGADICT|VGAGRAPH|MAPHEAD|GAMEMAPS|AUDIOHED|AUDIOT)/))));
T('pick.none', () => setStr(W.pickSet({})));
T('pick.others', () => setStr(W.pickSet({ 'README.TXT': G.wl6['VSWAP.WL6'], 'VSWAP.WL2': G.wl6['VSWAP.WL6'], 'VS WAP.WL6': G.wl6['VSWAP.WL6'], 'VSWAP1.WL6': G.wl6['VSWAP.WL6'], 'VSWAP.WL6.bak': G.wl6['VSWAP.WL6'] })));
T('pick.twice', () => setStr(W.pickSet(mix(G.wl6, { 'old/vswap.wl6': G.wl6b['VSWAP.WL6'], 'x\\y/MapHead.Wl6': G.wl6b['MAPHEAD.WL6'] }))));
T('pick.extra', () => setStr(W.pickSet(mix(G.wl6, { 'CONFIG.WL6': G.wl6b['VSWAP.WL6'], 'VGAHEAD.WL1': G.wl1['/home/x/wolf/Vgahead.wl1'] }))));
T('build.all', () => H(W.build(mix(G.wl1b, G.sod, G.wl6)).pack));
T('build.none', () => H(W.build({}).pack));
T('build.cut', () => H(W.build(without(G.sod, /^VGAGRAPH/)).pack));
T('build.mixed', () => { const r = W.build(mix(G.wl6, { 'VSWAP.WL6': G.wl6b['VSWAP.WL6'], 'AUDIOT.WL6': G.wl6b['AUDIOT.WL6'] })); return H(r.pack) + ' maps=' + r.maps; });
T('build.emptyGraph', () => H(W.build(mix(G.wl6, { 'VGAGRAPH.WL6': new Uint8Array(0) })).pack));
T('build.emptyMaps', () => { const r = W.build(mix(G.wl6, { 'MAPHEAD.WL6': new Uint8Array(0), 'AUDIOHED.WL6': new Uint8Array(3) })); return H(r.pack) + ' maps=' + r.maps + ' episodes=' + r.episodes; });
T('build.emptySwap', () => H(W.build(mix(G.sod, { 'VSWAP.SOD': new Uint8Array(0) })).pack));
console.log(lines.join('\n'));
