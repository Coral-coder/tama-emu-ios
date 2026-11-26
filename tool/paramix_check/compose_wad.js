// Synthetic WADs for tool/paramix_check/compose.js: the generators of tool/paramix_check/doom.js, unchanged
// (seeded xorshift32, with the structure doom.js and the converter read). compose_wad.dart has the same ones.
'use strict';
function w16(b, o, v) { b[o] = v & 255; b[o + 1] = (v >> 8) & 255; }
function w32(b, o, v) { b[o] = v & 255; b[o + 1] = (v >>> 8) & 255; b[o + 2] = (v >>> 16) & 255; b[o + 3] = (v >>> 24) & 255; }
const u32 = (b, o) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;

// ------------------------------------------------------------ synthetic inputs
function rng(seed) { let x = (seed >>> 0) || 1; return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x; }; }
function rnd(r, n) { const b = new Uint8Array(n); for (let i = 0; i < n; i++) b[i] = r() & 255; return b; }
const asc = (s) => { const b = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 255; return b; };
function name8(b, o, s) { for (let i = 0; i < 8; i++) b[o + i] = i < s.length ? s.charCodeAt(i) : 0; }
function cat(parts) { let n = 0; for (const p of parts) n += p.length; const o = new Uint8Array(n); let q = 0; for (const p of parts) { o.set(p, q); q += p.length; } return o; }
/* a WAD: header, lumps, directory (some with the directory in front of the lumps) */
function wad(L, ident, dirFirst) {
  let size = 12; for (const [, d] of L) size += d.length;
  const o = new Uint8Array(size + 16 * L.length), dir = dirFirst ? 12 : size;
  let p = dirFirst ? 12 + 16 * L.length : 12;
  o.set(asc(ident)); w32(o, 4, L.length); w32(o, 8, dir);
  L.forEach(([n, d], i) => { o.set(d, p); w32(o, dir + 16 * i, p); w32(o, dir + 16 * i + 4, d.length); name8(o, dir + 16 * i + 8, n); p += d.length; });
  return o;
}
/* a picture in the patch format: columns of posts (top, length, pad, pixels, pad), 0xFF at the end */
function patch(r, w, h, holes, lo, to) {
  const cols = [];
  for (let x = 0; x < w; x++) {
    const c = [];
    if (!holes) { c.push(0, h, r() & 255); for (let y = 0; y < h; y++) c.push(r() & 255); c.push(r() & 255); }
    else {
      let y = r() % 4;
      while (y < h) {
        const len = 1 + r() % Math.min(12, h - y);
        c.push(y, len, r() & 255); for (let k = 0; k < len; k++) c.push(r() & 255); c.push(r() & 255);
        y += len + 1 + r() % 5;
      }
    }
    c.push(255); cols.push(c);
  }
  let size = 8 + 4 * w; for (const c of cols) size += c.length;
  const o = new Uint8Array(size); w16(o, 0, w); w16(o, 2, h); w16(o, 4, lo || 0); w16(o, 6, to || 0);
  let p = 8 + 4 * w;
  cols.forEach((c, x) => { w32(o, 8 + 4 * x, p); o.set(c, p); p += c.length; });
  return o;
}
function mus(r, n) { const b = rnd(r, 16 + n); b.set([0x4D, 0x55, 0x53, 0x1A]); return b; }
const lower = (s) => s.toLowerCase();
/* the lumps of one map; tex, flats: names to draw from */
function mapLumps(r, name, tex, flats, o) {
  const s16r = () => { const v = r() % 8; return v === 0 ? [32767, -32768, 1, -1, 0][r() % 5] : ((r() % 17) - 8) * 64; };
  const pick = (a) => { const s = a[r() % a.length]; return r() % 7 === 0 ? lower(s) : s; };
  const nv = 8 + r() % 10, nsec = 2 + r() % 3, nside = 6 + r() % 8, nline = 6 + r() % 8, nseg = 8 + r() % 10, nth = 5 + r() % 10;
  const things = new Uint8Array(10 * nth), TY = [1, 3004, 9, 3001, 3002, 58, 3003, 3005, 3006, 16, 7, 2001, 2011];
  for (let i = 0; i < nth; i++) { w16(things, 10 * i, s16r()); w16(things, 10 * i + 2, s16r()); w16(things, 10 * i + 4, r() % 360); w16(things, 10 * i + 6, TY[(o.mon || 0) ? r() % TY.length : r() % 4]); w16(things, 10 * i + 8, r() & 31); }
  const lines = new Uint8Array(14 * nline);
  for (let i = 0; i < nline; i++) { w16(lines, 14 * i, r() % nv); w16(lines, 14 * i + 2, r() % nv); w16(lines, 14 * i + 4, r() & 0x1FF); w16(lines, 14 * i + 6, r() % 140); w16(lines, 14 * i + 8, r() % 20); w16(lines, 14 * i + 10, r() % nside); w16(lines, 14 * i + 12, r() % 3 === 0 ? 0xFFFF : r() % nside); }
  const sides = new Uint8Array(30 * nside);
  for (let i = 0; i < nside; i++) { w16(sides, 30 * i, r() & 0xFFFF); w16(sides, 30 * i + 2, r() & 0xFFFF); for (const q of [4, 12, 20]) name8(sides, 30 * i + q, r() % 3 === 0 ? '-' : pick(tex)); w16(sides, 30 * i + 28, r() % nsec); }
  const vtx = new Uint8Array(o.emptyVtx ? 0 : 4 * nv);
  for (let i = 0; i < nv && !o.emptyVtx; i++) { w16(vtx, 4 * i, s16r()); w16(vtx, 4 * i + 2, s16r()); }
  const segs = new Uint8Array(12 * nseg);
  for (let i = 0; i < nseg; i++) { w16(segs, 12 * i, r() % nv); w16(segs, 12 * i + 2, r() % nv); w16(segs, 12 * i + 4, r() & 0xFFFF); w16(segs, 12 * i + 6, r() % nline); w16(segs, 12 * i + 8, r() & 1); w16(segs, 12 * i + 10, r() & 0xFFFF); }
  const secs = new Uint8Array(26 * nsec);
  for (let i = 0; i < nsec; i++) { w16(secs, 26 * i, r() % 128); w16(secs, 26 * i + 2, 128 + r() % 128); name8(secs, 26 * i + 4, pick(flats)); name8(secs, 26 * i + 12, pick(flats)); w16(secs, 26 * i + 20, r() & 255); w16(secs, 26 * i + 22, r() % 17); w16(secs, 26 * i + 24, r() % 20); }
  const L = [[name, new Uint8Array(0)], ['THINGS', o.bigThings ? rnd(r, 9400) : things], ['LINEDEFS', lines], ['SIDEDEFS', sides], ['VERTEXES', vtx], ['SEGS', segs], ['SSECTORS', rnd(r, 4 * (3 + r() % 5))], ['NODES', rnd(r, 28 * (2 + r() % 4))],
    ['SECTORS', secs], ['REJECT', rnd(r, 1 + r() % 9)], ['BLOCKMAP', rnd(r, 2 * (8 + r() % 20))]];
  if (o.behavior) L.push(['BEHAVIOR', rnd(r, 16)]);
  return L;
}
const PN = ['WALL00', 'WALL01', 'WALL02', 'WALL03', 'WALL04', 'WALL05', 'WALL06', 'WALL07', 'WALL08', 'WALL09', 'WALL10', 'WALL11', 'SKYP1', 'SKYP2', 'SKYP3', 'SKYP4', 'SWP1', 'SWP2', 'NOLUMP', 'wall05'];
const TEX1 = ['AASTINKY', 'SKY1', 'SKY2', 'SKY3', 'SKY4', 'SW1BRN', 'SW2BRN', 'BLODGR1', 'BLODGR2', 'BLODGR3', 'BLODGR4', 'SLADRIP1', 'SLADRIP2', 'SLADRIP3', 'FIREWALA', 'FIREWALB', 'FIREWALL',
  'TEXA00', 'TEXA01', 'TEXA02', 'TEXA03', 'TEXA04', 'TEXA05', 'TEXA06', 'TEXA07', 'TEXA08', 'TEXA09', 'lowtex', 'HOLETEX', 'LOWPTEX'];
const TEX2 = ['TEXB00', 'TEXB01', 'TEXB02', 'TEXB03', 'TEXB04', 'TEXB05'];
/* a texture lump; npn: number of patch names that have a lump (0..17) */
function texLump(r, names, extra) {
  const defs = [];
  for (const n of names.concat(extra || [])) {
    const w = n.startsWith('SKY') ? 32 : 8 + r() % 41, h = n.startsWith('SKY') ? 32 : 16 + r() % 49; let ps;
    if (n === 'AASTINKY') ps = [[0, 0, 0]];
    else if (n.startsWith('SKY')) ps = [[0, 0, 12 + (n.charCodeAt(3) - 0x31) % 4]];
    else if (n === 'SW1BRN') ps = [[0, 0, 16], [8, 4, 17]];
    else if (n === 'SW2BRN') ps = [[0, -4, 17]];
    else if (n.startsWith('BLODGR') || n.startsWith('SLADRIP') || n.startsWith('FIREWAL')) ps = [[0, 0, 1 + r() % 11]];
    else if (n === 'HOLETEX') ps = [[0, 0, 2], [4, 0, 18], [8, 8, 3]];      // its second patch has no lump
    else if (n === 'LOWPTEX') ps = [[2, 2, 19], [0, 0, 4]];                 // its first patch is named in small letters
    else { ps = []; const k = 1 + r() % 4; for (let i = 0; i < k; i++) ps.push([(r() % (w + 8)) - 8, (r() % 25) - 8, r() % 12]); if (r() % 5 === 0) ps = [[0, 0, r() % 12]]; }
    const d = new Uint8Array(22 + 10 * ps.length); name8(d, 0, n); d.set(rnd(r, 4), 8); w16(d, 12, w); w16(d, 14, h); d.set(rnd(r, 4), 16); w16(d, 20, ps.length);
    ps.forEach(([x, y, p], i) => { w16(d, 22 + 10 * i, x); w16(d, 24 + 10 * i, y); w16(d, 26 + 10 * i, p); w16(d, 28 + 10 * i, r() & 0xFFFF); w16(d, 30 + 10 * i, r() & 0xFFFF); });
    defs.push(d);
  }
  const head = new Uint8Array(4 + 4 * defs.length); w32(head, 0, defs.length);
  let p = head.length; defs.forEach((d, i) => { w32(head, 4 + 4 * i, p); p += d.length; });
  return cat([head].concat(defs));
}
function pnames(names) { const b = new Uint8Array(4 + 8 * names.length); w32(b, 0, names.length); names.forEach((n, i) => name8(b, 4 + 8 * i, n)); return b; }
const FLATS = ['FLOOR4_8', 'SFLR6_1', 'MFLR8_4', 'MFLR8_3', 'NUKAGE1', 'NUKAGE2', 'NUKAGE3', 'FWATER1', 'FWATER2', 'FWATER3', 'FWATER4', 'FLAT01', 'FLAT02', 'FLAT03', 'FLAT04', 'FLAT05', 'FLAT06'];
const D2FL = ['SLIME16', 'RROCK14', 'RROCK07', 'RROCK17', 'RROCK13', 'RROCK19', 'RROCK05', 'RROCK06', 'RROCK08'];
const SPR = ['TROO', 'BAL1', 'POSS', 'SPOS', 'SARG', 'BOSS', 'BAL7', 'HEAD', 'BAL2', 'SKUL', 'CYBR', 'SPID', 'PLAY', 'MISL'];
/* o: seed, eps (e.g. '1', '1234'), d2, perEp, tex2, emptyVtx, mon, small (full pictures 32 x 20), dirFirst */
function baseWad(o) {
  const r = rng(o.seed), L = [];
  const FW = o.small ? 32 : 320, FH = o.small ? 20 : 200;
  L.push(['PLAYPAL', rnd(r, 768 * 2)], ['COLORMAP', rnd(r, 256 * 3)], ['ENDOOM', rnd(r, 200)], ['DEMO1', rnd(r, 50)], ['DEMO2', rnd(r, 50)], ['DEMO3', rnd(r, 50)]);
  const maps = [];
  if (o.d2) for (let m = 1; m <= o.perEp; m++) maps.push('MAP' + String(m).padStart(2, '0'));
  else for (const e of o.eps) for (let m = 1; m <= o.perEp; m++) maps.push('E' + e + 'M' + m);
  const tex = TEX1.concat(o.tex2 ? TEX2 : [], ['NOSUCH']), fl = FLATS.slice(4).concat(o.d2 ? D2FL.slice(6) : []);
  maps.forEach((n, i) => { for (const l of mapLumps(r, n, tex, fl, { mon: o.mon, emptyVtx: o.emptyVtx && i === 1 })) L.push(l); });
  L.push(['TEXTURE1', texLump(r, TEX1)]);
  if (o.tex2) L.push(['TEXTURE2', texLump(r, TEX2)]);
  L.push(['PNAMES', pnames(PN)], ['GENMIDI', rnd(r, 100)], ['DMXGUS', rnd(r, 60)]);
  for (const n of maps) L.push(['D_' + n, mus(r, 40 + r() % 60)]);
  for (const n of ['D_INTER', 'D_INTRO', 'D_VICTOR', 'D_INTROA'].concat(o.d2 ? ['D_RUNNIN', 'D_STALKS'] : [])) L.push([n, mus(r, 30)]);
  for (const n of ['DSPISTOL', 'DSSHOTGN', 'DPPISTOL', 'DPSHOTGN']) L.push([n, rnd(r, 40 + r() % 40)]);
  // pictures: all in the patch format from here to P_END
  const full = (holes) => patch(r, FW, FH, holes);
  if (o.d2) L.push(['HELP', full()], ['BOSSBACK', full()]); else L.push(['HELP1', full()], ['HELP2', full()]);
  L.push(['TITLEPIC', full()], ['CREDIT', full(true)], ['VICTORY2', full()], ['PFUB1', full()], ['PFUB2', patch(r, 160, 100)], ['ENDPIC', full()], ['INTERPIC', full()]);
  L.push(['END0', full()]); for (let i = 1; i <= 6; i++) L.push(['END' + i, patch(r, 24, 16, true)]);
  for (let i = 0; i < 3; i++) L.push(['WIMAP' + i, full()]);
  L.push(['AMMNUM0', patch(r, 4, 6, true)], ['STBAR', patch(r, 320, 32)], ['STARMS', patch(r, 40, 32, true)]);
  for (let i = 0; i < 10; i++) L.push(['STTNUM' + i, patch(r, o.narrow ? 10 : 14, 16, true, r() % 3, r() % 3)]);
  L.push(['STTPRCNT', patch(r, o.narrow ? 10 : 14, o.tall ? 30 : 16, true)]);
  for (let c = 65; c <= 90; c++) L.push(['STCFN0' + c, patch(r, 5 + r() % 5, 7 + r() % 2, true)]);
  L.push(['M_DOOM', patch(r, 30, 12, true)], ['M_NEWG', patch(r, 20, 8, true)], ['S_START', new Uint8Array(0)]);
  for (const s of SPR) for (const fr of ['A1', 'B1']) L.push([s + fr, patch(r, 8 + r() % 17, 8 + r() % 25, true, r() % 9, r() % 9)]);
  L.push(['S_END', new Uint8Array(0)], ['P_START', new Uint8Array(0)], ['P1_START', new Uint8Array(0)]);
  for (let i = 0; i < 18; i++) L.push([PN[i], PN[i].startsWith('SKY') ? patch(r, 32, 32) : patch(r, 8 + r() % 25, 16 + r() % 49, i % 3 === 1)]);
  L.push(['P1_END', new Uint8Array(0)], ['P_END', new Uint8Array(0)], ['F_START', new Uint8Array(0)], ['F1_START', new Uint8Array(0)]);
  for (const n of FLATS.concat(o.d2 ? D2FL : [])) L.push([n, rnd(r, 4096)]);
  L.push(['F1_END', new Uint8Array(0)], ['F_END', new Uint8Array(0)]);
  return wad(L, 'IWAD', o.dirFirst);
}
/* extra WADs. kind 'maps': maps that replace or add (names), 'e5': an episode with UMAPINFO, 'e6': one without */
const UMAP = '// made for the check\r\nMAP E5M1\r\n{\r\n\tlevelname = "Baphomet\'s Demesne"\r\n\tlabel = "E5M1"\r\n\tlevelpic = "MYLV0"\r\n\tnext = "E5M2"\r\n\tskytexture = "SKY5X"\r\n\tmusic = "D_E5M1"\r\n' +
  '\texitpic = "SIGILINT" // the picture between maps\r\n\tepisode = "M_EPI5", "Sigßil é", "s"\r\n\tpartime = 90\r\n}\r\n' +
  'map e5m2 { LevelName = "Sheol é\x80\x9E"\n music = "D_SIGMUS"\n endpic = "SIGILEND"\n intertext = "line one", "line ütwoß", "µ three"\n nointermission = true\n }\n' +
  'MAP E5M9 { levelname = "Realm of Iblis" next = "E5M7" music = D_NOQUOTE \n secret = }\n map 12 { levelname = "Twelve" }\n map 7 { levelname = "Seven"\n episode = clear }\n';
function pwad(o) {
  const r = rng(o.seed), L = [], e = o.kind === 'e5' ? '5' : '6';
  const tex = TEX1.concat(['SKY5X', 'SKY6']), mp = (n, x) => { for (const l of mapLumps(r, n, tex, FLATS.slice(4).concat(['NEWFLAT']), x || { mon: 1 })) L.push(l); };
  if (o.kind === 'maps') {
    L.push(['DEHACKED', rnd(r, 30)], ['TITLEPIC', patch(r, 320, 200)]);
    o.maps.forEach((n, i) => mp(n, { mon: 1, behavior: i === 0, bigThings: o.big && i === 1 }));
    L.push(['D_E1M2', mus(r, 20)], ['THING_ZD', rnd(r, 9)], ['M_DOOM', patch(r, 31, 13, true)], ['NEWLUMP', rnd(r, 77)], ['PLAYPAL', rnd(r, 768)]);
  } else {
    if (o.kind === 'e5') L.push(['UMAPINFO', asc(UMAP)]);
    for (const m of o.maps) mp('E' + e + 'M' + m);
    if (o.both) mp('E6M1');
    if (o.kind === 'e5') L.push(['MYLV0', patch(r, 40, 10, true)], ['WILV41', patch(r, 41, 10, true)], ['WILV48', patch(r, 48, 10, true)], ['D_E5M1', midi(0x900 + o.seed, {})], ['D_SIGMUS', mus(r, 50)], ['D_E5M9', midi(0x901, { div: 0xE728 })],
      ['SIGILINT', patch(r, 320, 200)], ['SIGILEND', patch(r, 320, 200)], ['SIGILTTL', patch(r, 320, 200)], ['SMALLPIC', patch(r, 64, 20)]);
    else L.push(['WILV50', patch(r, 50, 10, true)], ['WILV52', patch(r, 52, 10, true)], ['D_E6M1', mus(r, 44)], ['D_E6M3', midi(0x902, {})], ['D_E6M4', asc('junk')], ['E6TEXT', asc('You made it\r\nthrough éßµÿ\x9C\r\nthe end.')]);
    L.push(['M_EPI' + e, patch(r, 60, 12, true)], ['CREDIT', patch(r, 320, 200)], ['TEXTURE1', texLump(r, TEX1, ['SKY5X', 'SKY6'])], ['PNAMES', pnames(PN)], ['E' + e + 'TEXTX', rnd(r, 5)]);
  }
  L.push(['FF_START', new Uint8Array(0)], ['FLAT02', rnd(r, 4096)], ['NEWFLAT', rnd(r, 4096)], ['FF_END', new Uint8Array(0)], ['AFTERF', rnd(r, 11)]);
  L.push(['SS_START', new Uint8Array(0)], ['TROOA1', patch(r, 12, 12, true)], ['NEWSA0', patch(r, 9, 9, true)], ['S_END', new Uint8Array(0)]);
  L.push(['PP_START', new Uint8Array(0)], ['NEWPAT', patch(r, 16, 16)], ['PP_END', new Uint8Array(0)]);
  return wad(L, 'PWAD', o.dirFirst);
}
/* a MIDI file. o: div, cut (bytes dropped at the end), notes (a long first track), ntrMore, noEnd */
function vlq(v) { const b = [v & 127]; v >>>= 7; while (v) { b.unshift(0x80 | (v & 127)); v >>>= 7; } return b; }
function midi(seed, o) {
  const r = rng(seed), ntr = o.notes ? 1 : 1 + r() % 4, div = o.div !== undefined ? o.div : [96, 480, 120, 1024][r() % 4], parts = [];
  const CT = [0, 1, 7, 10, 11, 91, 93, 64, 67, 120, 123, 126, 127, 121, 5, 99];
  const head = new Uint8Array(14); head.set(asc('MThd')); w32(head, 4, 0x06000000); head[9] = 1; head[10] = (ntr + (o.ntrMore || 0)) >> 8; head[11] = (ntr + (o.ntrMore || 0)) & 255; head[12] = div >> 8; head[13] = div & 255;
  parts.push(head);
  for (let t = 0; t < ntr; t++) {
    const ev = [], n = o.notes || 20 + r() % 60, chans = [r() % 16, r() % 16, r() % 16, 9, (t * 5 + 1) % 16, (t * 5 + 2) % 16, (t * 5 + 3) % 16, (t * 5 + 4) % 16]; let run = -1;
    for (let i = 0; i < n; i++) {
      for (const b of vlq(r() % 4 === 0 ? r() % 3000 : r() % 60)) ev.push(b);
      const ty = o.notes ? r() % 8 : r() % 16, ch = chans[r() % chans.length];
      const st = (s) => { if (s !== run || r() % 2) ev.push(s); run = s; };
      if (ty < 6) { st(0x90 | ch); ev.push(r() & 127, r() % 5 === 0 ? 0 : r() & 127); }
      else if (ty < 8) { st(0x80 | ch); ev.push(r() & 127, r() & 127); }
      else if (ty === 8) { st(0xC0 | ch); ev.push(r() & 127); }
      else if (ty === 9) { st(0xB0 | ch); ev.push(CT[r() % CT.length], r() & 127); }
      else if (ty === 10) { st(0xE0 | ch); ev.push(r() & 127, r() & 127); }
      else if (ty === 11) { st(0xD0 | ch); ev.push(r() & 127); }
      else if (ty === 12) { st(0xA0 | ch); ev.push(r() & 127, r() & 127); }
      else if (ty === 13) { const us = 200000 + r() % 600000; ev.push(0xFF, 0x51, 3, us >> 16, (us >> 8) & 255, us & 255); }
      else if (ty === 14) { const k = r() % 9; ev.push(0xFF, 1 + r() % 5, k); for (let q = 0; q < k; q++) ev.push(0x41 + r() % 26); }
      else { const k = 1 + r() % 6; ev.push(0xF0, k); for (let q = 0; q < k - 1; q++) ev.push(r() & 127); ev.push(0xF7); }
    }
    if (!o.noEnd) ev.push(0, 0xFF, 0x2F, 0);
    const th = new Uint8Array(8); th.set(asc('MTrk')); w32(th, 4, ((ev.length & 255) << 24 | (ev.length >> 8 & 255) << 16 | (ev.length >> 16 & 255) << 8 | ev.length >>> 24) >>> 0);
    parts.push(th, Uint8Array.from(ev));
  }
  const all = cat(parts);
  return o.cut ? all.subarray(0, all.length - o.cut) : all;
}

module.exports = { baseWad, pwad };
