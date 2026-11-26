// Check of lib/paramix/doom.dart against third_party/paramix-studio/src/doom.js and its WAD converter
// doom/mcuwad.wasm (the originals).
// DUMPS=<folder with water.bin ...> node tool/paramix_check/doom.js
// Prints one line per case: "<case name> <sha256 or value>". tool/paramix_check/doom_check.dart prints the same.
// No WAD is used: the WADs, extra WADs and MIDI files are synthetic (seeded xorshift32) with the structure the
// module and the converter read (lump directory, maps, TEXTURE1/2, PNAMES, patches, flats, sprites, MUS, UMAPINFO).
'use strict';
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const PS = path.join(__dirname, '..', '..', 'third_party', 'paramix-studio');
const bin = (f) => new Uint8Array(fs.readFileSync(path.join(PS, f)));
const D = require(path.join(PS, 'src', 'doom.js')), E = require(path.join(PS, 'src', 'emu.js'));
// the embedded binaries, as build.js fills them in
const EMB = { app: bin('doom/doom_app.bin'), xip: bin('doom/doom_xip.bin'), wasm: bin('doom/mcuwad.wasm'), stub: bin('emu/stub_tpl.bin') };
const EMBF = { app: bin('doom/doomf_app.bin'), xip: bin('doom/doomf_xip.bin'), wasm: EMB.wasm, stub: EMB.stub };

const DUMPS = process.env.DUMPS;
if (!DUMPS) { console.error('DUMPS is not set'); process.exit(2); }
const EDS = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];
const lines = [];
const sha = (b) => crypto.createHash('sha256').update(Buffer.from(b.buffer, b.byteOffset, b.length)).digest('hex');
const shaS = (s) => crypto.createHash('sha256').update(Buffer.from(s, 'utf8')).digest('hex');
const H = (b) => (b === null || b === undefined ? 'null' : b.length + ':' + sha(b));
const out = (n, v) => { lines.push(n + ' ' + v); };
const errStr = (e) => 'ERR ' + (e instanceof Error && !(e instanceof TypeError) && !(e instanceof RangeError) && !(e instanceof WebAssembly.RuntimeError) ? e.message : 'INTERNAL');
const T = (n, f) => { try { out(n, f()); } catch (e) { out(n, errStr(e)); } };
const TA = async (n, f) => { try { out(n, await f()); } catch (e) { out(n, errStr(e)); } };
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

// ------------------------------------------------------------ the cases
const lumpStr = (L) => L.length + ' ' + shaS(L.map(([n, d]) => n + ':' + d.length + ':' + sha(d)).join('|'));
const keyStr = (k) => (k ? [k.fire, k.fwd, k.back, k.use, k.mod, k.run, k.invert].join(',') : 'null');
const infoStr = (i) => 'eps=' + i.eps.join('') + ' maps=' + i.maps.join(',') + ' big=' + i.big.join(',') + ' title=' + shaS(i.title) + '/' + i.title.length;
const umStr = (u) => { const ks = Object.keys(u); return ks.length + ' ' + shaS(ks.map((k) => k + '{' + Object.keys(u[k]).sort().map((q) => q + '=' + u[k][q]).join(';') + '}').join('\n')); };
/* partial WAD, extras and converted WAD of one choice */
async function chain(n, w, eps, music, only) {
  let sub = null, ex = null;
  T(n + '.sub', () => { sub = D.wadSub(w, eps, music, only); return H(sub) + ' ' + lumpStr(D.readWad(sub)); });
  if (!sub) return null;
  T(n + '.extras', () => { ex = D.gbaExtras(sub); return H(ex) + ' ' + lumpStr(D.readWad(ex)); });
  if (!ex) return null;
  let mcu = null;
  await TA(n + '.convert', async () => { mcu = await D.convert(sub, ex, EMB.wasm); return H(mcu) + ' ' + lumpStr(D.readWad(mcu)); });
  return mcu;
}

(async () => {
  out('const', [D.PWAD, D.WAD_OFF, D.REGION_OFF, D.REGION_END, D.CODE_OFF, D.SAVE_OFF, D.SAVE_END].join(',') + ' keys=' + keyStr(D.KEYS_DEFAULT));

  // ---- the WADs: read, write, episodes, every partial WAD with and without music, extras, converter
  const BASE = {
    sw: { seed: 0x2001, eps: '1', perEp: 3, mon: 0 },
    reg: { seed: 0x2002, eps: '123', perEp: 2, tex2: true, mon: 1, dirFirst: true },
    ult: { seed: 0x2003, eps: '1234', perEp: 2, tex2: true, mon: 1, emptyVtx: true, narrow: true },
    e2: { seed: 0x2004, eps: '2', perEp: 2, mon: 1, tall: true },
    d2: { seed: 0x2005, d2: true, perEp: 4, tex2: true, mon: 1 },
  };
  const WADS = {}, MCU = {};
  for (const n of Object.keys(BASE)) {
    const w = WADS[n] = baseWad(BASE[n]);
    out('wad.' + n, H(w));
    T('readWad.' + n, () => lumpStr(D.readWad(w)));
    T('writeWad.' + n, () => H(D.writeWad(D.readWad(w), 'PWAD')) + ' ' + H(D.writeWad(D.readWad(w).slice(3, 40).reverse(), 'IWAD')) + ' ' + H(D.writeWad([], 'IWAD')));
    let eps = [];
    T('wadEpisodes.' + n, () => { eps = D.wadEpisodes(w); return eps.join(','); });
    T('gbaExtras.' + n, () => H(D.gbaExtras(w)));
    const choices = eps.concat(eps.length > 1 ? [eps.join('')] : [], n === 'sw' ? ['2', '12', 'M'] : [], n === 'd2' ? ['1'] : [], n === 'ult' ? ['24', '31'] : []);
    for (const ep of choices) for (const m of [true, false]) { const x = await chain('wad.' + n + '.' + ep + (m ? '.music' : '.plain'), w, ep, m); if (x && !MCU[n]) MCU[n] = x; }
    const first = D.readWad(w).map((x) => x[0]).filter((x) => /^(E\dM\d|MAP\d\d)$/.test(x));
    await chain('wad.' + n + '.only', w, eps.join(''), true, new Set([first[0], first[first.length - 1], 'E9M9']));
    await chain('wad.' + n + '.onlyNone', w, eps[0] || '1', false, new Set());
  }
  // ---- many small WADs through the whole chain (converter against the WebAssembly original)
  for (let i = 0; i < 40; i++) {
    const r = rng(0x3000 + i), o = { seed: 0x4000 + i, small: true, perEp: 1 + r() % 3, tex2: r() % 2 === 0, mon: r() % 2, emptyVtx: r() % 4 === 0, narrow: r() % 3 === 0, tall: r() % 5 === 0, dirFirst: r() % 2 === 0 };
    const k = r() % 6; if (k === 0) o.d2 = true; else o.eps = ['1', '12', '3', '1234', '24'][k - 1];
    const w = baseWad(o), eps = o.d2 ? 'M' : (r() % 2 ? o.eps : o.eps[0]);
    await chain('small.' + i + '.' + eps, w, eps, r() % 2 === 0);
    // the whole WAD straight into the converter (music, sounds and GENMIDI still in it)
    let ex = null;
    T('small.' + i + '.direct.extras', () => { ex = D.gbaExtras(w); return H(ex); });
    if (ex) await TA('small.' + i + '.direct.convert', async () => { const m = await D.convert(w, ex, EMB.wasm); return H(m) + ' ' + lumpStr(D.readWad(m)); });
  }
  // ---- broken input
  T('readWad.bad', () => lumpStr(D.readWad(asc('JUNKxxxxxxxxxxxx'))));
  T('readWad.empty', () => lumpStr(D.readWad(new Uint8Array(0))));
  T('readWad.cut', () => lumpStr(D.readWad(WADS.sw.subarray(0, WADS.sw.length - 100))));
  T('readWad.cutDir', () => lumpStr(D.readWad(WADS.reg.subarray(0, 300))));
  T('wadEpisodes.none', () => D.wadEpisodes(D.writeWad([['PLAYPAL', new Uint8Array(4)]], 'IWAD')).join(','));
  T('wadEpisodes.bad', () => D.wadEpisodes(new Uint8Array(20)).join(','));
  T('wadSub.noPal', () => H(D.wadSub(D.writeWad(D.readWad(WADS.sw).filter((x) => x[0] !== 'PLAYPAL'), 'IWAD'), '1', true)));
  T('gbaExtras.missing', () => H(D.gbaExtras(D.writeWad(D.readWad(WADS.sw).filter((x) => x[0] !== 'STBAR'), 'IWAD'))));
  {
    const sub = D.wadSub(WADS.sw, '1', false), ex = D.gbaExtras(sub);
    await TA('convert.badExtras', async () => H(await D.convert(sub, asc('JUNKxxxxxxxxxxxx'), EMB.wasm)));
    await TA('convert.badSub', async () => H(await D.convert(asc('XWADxxxxxxxxxxxx'), ex, EMB.wasm)));
    await TA('convert.noMaps', async () => H(await D.convert(D.wadSub(WADS.sw, '3', false), ex, EMB.wasm)));
    await TA('convert.pwadIdent', async () => H(await D.convert(D.writeWad(D.readWad(sub), 'PWAD'), ex, EMB.wasm)));
    await TA('convert.noExtras', async () => H(await D.convert(sub, D.writeWad([], 'PWAD'), EMB.wasm)));
  }

  // ---- UMAPINFO
  const UM = [UMAP, '', 'map E1M1 {}', 'MAP MAP01 { levelname = "A" }  map map02\n{\n  levelname="B"\n  intertext = "x",\n   "y"\n next="MAP03"}', 'map X { a = 1 // c\n b = "q" // d\n c = "u" "v", "w"\n d = \t spaced out \t\n __proto__ = "p"\n constructor = "k" }',
    'map 3 { k = "three" }\nmap 1 { k = "one" }\nmap E1M1 { k = "e" }\nmap 01 { k = "zero one" }\nmap 1 { j = "again" }\nmap 4294967295 { k = "big" }', 'map A { k = v\x85 \n l = \xA0w\xA0 }', 'mapE1M1 { a = "b" }\n map\tQ\n\n{ e="\n" \r\n f = g }'];
  UM.forEach((t, i) => T('umapinfo.' + i, () => umStr(D.umapinfo(t))));

  // ---- MIDI to MUS
  for (let i = 0; i < 24; i++) T('mid2mus.' + i, () => H(D.mid2mus(midi(0x5000 + i, {}))));
  for (const [n, o] of [['smpte', { div: 0xE728 }], ['div0', { div: 0 }], ['div1', { div: 1 }], ['cut1', { cut: 1 }], ['cut2', { cut: 2 }], ['cut3', { cut: 3 }], ['cut5', { cut: 5 }], ['cut9', { cut: 9 }], ['cut40', { cut: 40 }], ['more', { ntrMore: 3 }],
    ['noEnd', { noEnd: true }], ['long', { notes: 9000 }], ['tooLong', { notes: 30000 }]]) T('mid2mus.' + n, () => H(D.mid2mus(midi(0x5100, o))));
  T('mid2mus.none', () => H(D.mid2mus(new Uint8Array(0))));
  T('mid2mus.mus', () => H(D.mid2mus(mus(rng(5), 40))));
  T('mid2mus.head', () => H(D.mid2mus(midi(0x5101, {}).subarray(0, 14))));
  T('mid2mus.short', () => H(D.mid2mus(midi(0x5101, {}).subarray(0, 9))));
  T('mid2mus.noTracks', () => { const m = midi(0x5102, {}); m[10] = 0; m[11] = 0; return H(D.mid2mus(m)); });

  // ---- extra WADs
  const PW = {
    maps1: { kind: 'maps', seed: 0x6001, maps: ['E1M2', 'E1M8', 'E3M1'] },
    mapsBig: { kind: 'maps', seed: 0x6002, maps: ['E1M1', 'E2M2'], big: true, dirFirst: true },
    maps2: { kind: 'maps', seed: 0x6003, maps: ['MAP01', 'MAP07', 'MAP31'], big: true },
    e5: { kind: 'e5', seed: 0x6004, maps: [1, 2, 9] },
    e5both: { kind: 'e5', seed: 0x6005, maps: [1, 3], both: true },
    e6: { kind: 'e6', seed: 0x6006, maps: [1, 3, 4, 9] },
  };
  const FN = [undefined, 'SIGIL_v1_21.wad', 'my_cool-map.WAD', 'Äß map.wad', 'a_very_long_file_name_for_a_wad.wad', 'pack-V2final.wad', '.wad', 'noending'];
  for (const n of Object.keys(PW)) {
    out('pwad.' + n, H(pwad(PW[n])));
    FN.forEach((fn, i) => T('pwadInfo.' + n + '.' + i, () => infoStr(D.pwadInfo(pwad(PW[n]), fn))));
  }
  T('pwadInfo.none', () => infoStr(D.pwadInfo(D.writeWad([['E0M1X', new Uint8Array(1)], ['MAP1', new Uint8Array(1)]], 'PWAD'), 'x.wad')));
  T('pwadInfo.bad', () => infoStr(D.pwadInfo(new Uint8Array(40))));
  const MERGE = [['sw+maps1', 'sw', [['maps1', false]], '1'], ['reg+maps1', 'reg', [['maps1', true]], '13'], ['ult+mapsBig', 'ult', [['mapsBig', false], ['maps1', false]], '12'], ['d2+maps2', 'd2', [['maps2', false]], 'M'], ['d2+maps1', 'd2', [['maps1', false]], 'M'],
    ['ult+e5', 'ult', [['e5', true]], '4'], ['ult+e5noslot', 'ult', [['e5', false]], '4'], ['reg+e5', 'reg', [['e5', true]], '4'], ['ult+e5both', 'ult', [['e5both', true]], '14'], ['ult+e6', 'ult', [['e6', true]], '4'], ['sw+e6', 'sw', [['e6', true]], '4'],
    ['ult+all', 'ult', [['maps1', false], ['e5', true], ['e6', true]], '1234'], ['e2+e6', 'e2', [['mapsBig', false], ['e6', true]], '24'], ['sw+none', 'sw', [], '1']];
  for (const [n, b, ps, ep] of MERGE) {
    let m = null;
    const pw = ps.map(([k, slot]) => ({ data: pwad(PW[k]), slot }));
    T('wadMerge.' + n, () => { m = D.wadMerge(WADS[b], pw); return H(m) + ' ' + lumpStr(D.readWad(m)) + ' pwads=' + pw.map((p) => sha(p.data).slice(0, 16)).join(',') + ' eps=' + D.wadEpisodes(m).join(''); });
    if (m) { await chain('merge.' + n + '.music', m, ep, true); await chain('merge.' + n + '.plain', m, ep, false); }
  }
  T('wadMerge.noMaps', () => H(D.wadMerge(WADS.sw, [{ data: D.writeWad([['FOO', new Uint8Array(3)]], 'PWAD'), slot: false }])));
  T('wadMerge.badBase', () => H(D.wadMerge(new Uint8Array(30), [])));

  // ---- keys
  {
    const bad = [];
    for (let v = 0; v < 4096; v++) { const k = { fire: 1 << (v & 3), fwd: 1 << (v >> 2 & 3), back: 1 << (v >> 4 & 3), use: 1 << (v >> 6 & 3), mod: 1 << (v >> 8 & 3), run: !!(v >> 10 & 1), invert: !!(v >> 11 & 1) }; bad.push(D.doomKeysCheck(k).length); }
    out('doomKeysCheck', shaS(bad.join(',')));
    for (const k of [D.KEYS_DEFAULT, { fire: 1, fwd: 1, back: 4, use: 8, mod: 4, run: true, invert: true }, { fire: 1, fwd: 2, back: 4, use: 2, mod: 4, run: true, invert: true }, { fire: 4, fwd: 2, back: 1, use: 16, mod: 2, run: true, invert: true }]) out('doomKeysCheck.' + keyStr(k), D.doomKeysCheck(k));
    T('doomKeysGet.none', () => keyStr(D.doomKeysGet(new Uint8Array(0x100))));
    T('doomKeysSet.none', () => H(D.doomKeysSet(new Uint8Array(0xA1000), D.KEYS_DEFAULT)));
    const fake = (ver) => { const b = new Uint8Array(0xA0500); w32(b, 0xA0010, 0x434D4450); w32(b, 0xA0014, ver); for (let i = 0; i < 28; i++) b[0xA0010 + 44 + i] = i * 9 + 1; return b; };
    for (const ver of [0, 1, 2, 3]) {
      T('doomKeysGet.fake' + ver, () => keyStr(D.doomKeysGet(fake(ver))));
      T('doomKeysSet.fake' + ver, () => { const o = D.doomKeysSet(fake(ver), { fire: 2, fwd: 4, back: 1, use: 8, mod: 2, run: false, invert: false }); return H(o) + ' ' + keyStr(D.doomKeysGet(o)); });
    }
    T('doomKeysSet.fakeBad', () => H(D.doomKeysSet(fake(2), { fire: 2, fwd: 2, back: 1, use: 8, mod: 2, run: false, invert: false })));
    T('doomKeysSet.fakeBadUse', () => H(D.doomKeysSet(fake(2), { fire: 2, fwd: 4, back: 1, use: 1, mod: 2, run: 1, invert: 0 })));
  }

  // ---- into the ROM, on every dump: both builds of the program, the keys, the whole path from the WAD
  const KEYS2 = { fire: 4, fwd: 1, back: 2, use: 8, mod: 1, run: false, invert: false };
  for (const ed of EDS) {
    const rom = new Uint8Array(fs.readFileSync(path.join(DUMPS, ed + '.bin')));
    T(ed + '.doomKeysGet.plain', () => keyStr(D.doomKeysGet(rom)));
    T(ed + '.doomKeysSet.plain', () => H(D.doomKeysSet(rom, D.KEYS_DEFAULT)));
    for (const [en, emb] of [['doom', EMB], ['doomf', EMBF]]) for (const wn of ['sw', 'd2']) {
      let r = null;
      T(ed + '.doomPatch.' + en + '.' + wn, () => { r = D.doomPatch(rom, MCU[wn], emb, E); return sha(r.rom) + ' free=' + r.free + ' keys=' + keyStr(D.doomKeysGet(r.rom)); });
      if (!r) continue;
      T(ed + '.doomKeysSet.' + en + '.' + wn, () => { const o = D.doomKeysSet(r.rom, KEYS2); return sha(o) + ' keys=' + keyStr(D.doomKeysGet(o)); });
      T(ed + '.doomKeysSet.bad.' + en + '.' + wn, () => sha(D.doomKeysSet(r.rom, { fire: 1, fwd: 2, back: 4, use: 4, mod: 4, run: true, invert: true })));
      T(ed + '.doomPatch.again.' + en + '.' + wn, () => { const q = D.doomPatch(r.rom, MCU.reg, emb, E); return sha(q.rom) + ' free=' + q.free; });
    }
    T(ed + '.doomPatch.big', () => sha(D.doomPatch(rom, new Uint8Array(D.REGION_OFF - D.WAD_OFF - 3), EMB, E).rom));
    T(ed + '.doomPatch.fits', () => { const r = D.doomPatch(rom, rnd(rng(77), D.REGION_OFF - D.WAD_OFF - 4), EMB, E); return sha(r.rom) + ' free=' + r.free; });
    T(ed + '.doomPatch.bigXip', () => sha(D.doomPatch(rom, MCU.sw, { app: EMB.app, xip: new Uint8Array(D.SAVE_OFF - D.CODE_OFF + 1), stub: EMB.stub }, E).rom));
    T(ed + '.doomPatch.bigApp', () => sha(D.doomPatch(rom, MCU.sw, { app: new Uint8Array(0x20000), xip: EMB.xip, stub: EMB.stub }, E).rom));
    T(ed + '.doomPatch.size', () => sha(D.doomPatch(rom.subarray(0, 0x800000), MCU.sw, EMB, E).rom));
    T(ed + '.doomPatch.assets', () => { const b = new Uint8Array(rom); w32(b, 0x111008, 0x800000); return sha(D.doomPatch(b, MCU.sw, EMB, E).rom); });
    for (const [n, wn, opts, emb] of [['sw.default', 'sw', {}, EMB], ['sw.keys', 'sw', { episode: '1', music: true, keys: KEYS2 }, EMBF], ['ult.e3.plain', 'ult', { episode: '3', music: false, keys: D.KEYS_DEFAULT }, EMB], ['reg.e2', 'reg', { episode: '2' }, EMB],
      ['d2.M', 'd2', { episode: 'M', music: false }, EMBF], ['e2.default', 'e2', { music: true }, EMB], ['sw.badKeys', 'sw', { keys: { fire: 1, fwd: 1, back: 1, use: 8, mod: 4, run: true, invert: true } }, EMB]]) {
      await TA(ed + '.doomBuild.' + n, async () => { const r = await D.doomBuild(rom, WADS[wn], opts, emb, E); return sha(r.rom) + ' free=' + r.free + ' keys=' + keyStr(D.doomKeysGet(r.rom)); });
    }
  }
  console.log(lines.join('\n'));
})().catch((e) => { console.error(e); process.exit(1); });
