// Synthetic guest firmware and games for tool/paramix_check/compose.js: the generators of
// tool/paramix_check/emu.js (seeded xorshift32, with the headers the detection looks for), unchanged.
// tool/paramix_check/compose_syn.dart has the same ones for compose_check.dart.
'use strict';
const u32 = (b, o) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;
function w32(b, o, v) { b[o] = v & 255; b[o + 1] = (v >>> 8) & 255; b[o + 2] = (v >>> 16) & 255; b[o + 3] = (v >>> 24) & 255; }
const asc = (b, o, s) => { for (let i = 0; i < s.length; i++) b[o + i] = s.charCodeAt(i); };
function rng(seed) { let x = (seed >>> 0) || 1; return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x; }; }
function fillRnd(b, off, len, seed) { const r = rng(seed); for (let i = 0; i < len; i++) b[off + i] = r() & 255; }
function fillPat(b, off, len, seed) { for (let i = 0; i < len; i++) b[off + i] = ((i >> 5) * 13 + (i & 7) * seed) & 255; }
const rndBytes = (n, seed) => { const b = new Uint8Array(n); fillRnd(b, 0, n, seed); return b; };
const VEC = { idl: 0x024CAA72, ps: 0x024FDFE6, '4u': 0x024F6256, '4u-plain': 0x024C680A };
/* a colour Tama firmware: pct % of its 64 KB blocks used (random, patterns, single 8 KB parts) */
function tamaFw(dev, pct, seed) {
  const size = dev === 'pc' ? 0x400000 : 0x800000, g = new Uint8Array(size).fill(0xFF), r = rng(seed);
  for (let b = 0; b < size >> 16; b++) {
    const v = r();
    if (v % 100 >= pct) continue;
    const t = (v >>> 8) % 5, o = b << 16;
    if (t === 0) fillRnd(g, o, 0x10000, v);
    else if (t === 1) fillPat(g, o, 0x10000, v & 63);
    else if (t === 2) fillRnd(g, o + ((v >>> 12) & 7) * 0x2000, 0x2000, v);
    else if (t === 3) { fillRnd(g, o, 0x2000, v); fillPat(g, o + 0xC000, 0x1000, 5); }
    else { fillPat(g, o, 0x8000, v & 31); fillRnd(g, o + 0x8000, 0x4000, v); }
  }
  if (dev === 'pc') w32(g, 0, 0xC01234); else w32(g, 0x400000, VEC[dev]);
  return g;
}
function t7Rom(friends, seed) {
  const b = rndBytes(friends ? 0xC0000 : 0xA0000, seed);
  if (friends) { b[0x3FFC] = 0; b[0x3FFD] = 0; b[0x7FFC] = 0x34; b[0x7FFD] = 0xC1; } else { b[0x3FFC] = 0x00; b[0x3FFD] = 0xC0; }
  return b;
}
function t7Fig(len, used, seed) { const b = new Uint8Array(len); fillRnd(b, 0, used, seed); b[1] = 0xAA; b[2] = 0x55; b[0x11] = 0xAA; b[0x12] = 0x55; b[used - 1] = 0x77; return b; }
function t7FigFull(seed) { const one = t7Fig(0x100000, 0x30000, seed), b = new Uint8Array(0x400000 + 20); for (let k = 0; k < 4; k++) b.set(one, k * 0x100000); asc(b, 0x400000, 'dumped by a tool'); return b; }
function v1Rom(len, seed) { const b = rndBytes(len, seed); for (let i = 0; i < len; i += 2) b[i] &= 0x0F; return b; }
function v3Rom(seed) { const b = rndBytes(0x80000, seed); for (const o of [0x7FFA, 0x7FFC, 0x7FFE]) { b[o] = 0x10; b[o + 1] = 0xC0 + (o & 3); } return b; }
function gbRom(code, color, title, seed, trimBanks) {
  const len = 0x8000 << code, b = rndBytes(len, seed);
  if (trimBanks) b.fill(0, len - trimBanks * 0x4000);
  b.fill(0, 0x134, 0x150); asc(b, 0x134, title); b[0x143] = color; b[0x148] = code;
  let x = 0; for (let i = 0x134; i <= 0x14C; i++) x = (x - b[i] - 1) & 255;
  b[0x14D] = x;
  return b;
}
function smsRom(len, region, seed, copier) {
  const b = rndBytes(len + (copier ? 512 : 0), seed), o = (copier ? 512 : 0) + (len >= 0x8000 ? 0x7FF0 : 0x1FF0);
  if (region >= 0) { asc(b, o, 'TMR SEGA'); b[o + 15] = (region << 4) | 0x0C; }
  return b;
}
function pmRom(len, seed) { const b = rndBytes(len, seed); b[0x2100] = 0x4D; b[0x2101] = 0x4E; return b; }
function pmBios(seed) { const b = rndBytes(0x1000, seed); b[0] = 0x9A; b[1] = 0; return b; }
const hex2 = (v) => (v < 16 ? '0' : '') + v.toString(16).toUpperCase();
function abHexText(data, eol) {
  let t = '';
  for (let a = 0; a < data.length; a += 16) {
    const n = Math.min(16, data.length - a); let l = ':' + hex2(n) + hex2(a >> 8) + hex2(a & 255) + '00', s = n + (a >> 8) + (a & 255);
    for (let i = 0; i < n; i++) { l += hex2(data[a + i]); s += data[a + i]; }
    t += l + hex2((-s) & 255) + eol;
  }
  return t + ':00000001FF' + eol;
}
function wolfPack(len, flags, seed) { const b = rndBytes(len, seed); asc(b, 0, 'W3DP'); w32(b, 8, flags); w32(b, 28, 10 + (flags & 3)); w32(b, 60, 1 + flags); return b; }
/* a converted WAD: 12 bytes header (4 magic, count, directory), lumps, directory of 16 bytes (pos, size, name) */
function doomWad(lumps) {
  let len = 12; const pos = []; for (const l of lumps) { len = (len + 3) & ~3; pos.push(len); len += l[1].length; }
  len = (len + 3) & ~3; const b = new Uint8Array(len + 16 * lumps.length);
  asc(b, 0, 'MCUW'); w32(b, 4, lumps.length); w32(b, 8, len);
  lumps.forEach((l, i) => { b.set(l[1], pos[i]); w32(b, len + 16 * i, l[1].length ? pos[i] : 0); w32(b, len + 16 * i + 4, l[1].length); asc(b, len + 16 * i + 8, l[0]); });
  return b;
}
/* a TG18 firmware: "SPII", blocks used by a seeded choice, the words the address searches look for, a save */
function t18Fw(seed, sanrio, pct) {
  const g = new Uint8Array(0x800000).fill(0xFF), r = rng(seed);
  for (let b = 0; b < 128; b++) { const v = r(); if (b < 2 || b === 0x12 || b === 0x40 || v % 100 < pct) { if (v & 0x100) fillRnd(g, b << 16, 0x10000, v); else fillPat(g, b << 16, 0x10000, v & 63); } }
  g.fill(0xFF, 0x5E0000, 0x800000);
  asc(g, 0, 'SPII'); w32(g, 4, 0x2000000C);
  for (let k = 0; k < 45; k++) { const o = 0x2000 + k * 0x40; w32(g, o, 0xF8001230); w32(g, o + 8, 0xF8001231); w32(g, o + 20, 0xF8001232); }
  for (let k = 0; k < 9; k++) { const o = 0x4000 + k * 0x40; w32(g, o, 0xF8004440); w32(g, o + 4, 0xF8004441); w32(g, o + 8, 0xF8004442); }
  w32(g, 0x1000, 0xC0040000); w32(g, 0x1004, 0xF8009004);
  w32(g, 0x30000, 0xD0300000); w32(g, 0x30004, 0x3210); w32(g, 0x30008, 0xF8010020);
  g[0x120000 + 0x4F] = 0; asc(g, 0x120050, 'DispYobidashiIconInit() pYobi=%x'); g[0x120050 + 32] = 0;
  w32(g, 0x121000, sanrio ? 0xF800D8B4 : 0xF800D100); w32(g, 0x121004, 0x20120050);
  // the save: Param block, points
  fillRnd(g, 0x5E0000 + 0x21E000, 0x40, seed + 5); g[0x5E0000 + 0x21E020] = 0x39; g[0x5E0000 + 0x21E021] = 0x05; g[0x5E0000 + 0x21E070] = 8;
  for (let i = 0; i < 24; i++) g[0x5E0000 + 0x21E053 + i] = 0;
  return g;
}
/* a MyMeets record: name in the game's letters, kind, catalogue number, price, one picture of 8x8 with 4 colours */
module.exports = { u32, w32, asc, rng, fillRnd, fillPat, rndBytes, tamaFw, t7Rom, t7Fig, v1Rom, v3Rom, gbRom, smsRom, pmRom, pmBios, abHexText, wolfPack, doomWad, t18Fw };
