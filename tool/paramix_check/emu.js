// Check of lib/paramix/emu_build.dart against third_party/paramix-studio/src/emu.js (the original).
// DUMPS=<folder with water.bin ...> node tool/paramix_check/emu.js
// Prints one line per case: "<case name> <sha256 or value>". tool/paramix_check/emu_check.dart prints the same.
// The guest firmware and the games are synthetic (seeded xorshift32, with the headers the detection looks for).
'use strict';
const fs = require('fs'), path = require('path'), crypto = require('crypto'), vm = require('vm');
const PS = path.join(__dirname, '..', '..', 'third_party', 'paramix-studio');
const bin = (f) => new Uint8Array(fs.readFileSync(path.join(PS, f)));
// the embedded binaries, filled in as build.js does it
let src = fs.readFileSync(path.join(PS, 'src', 'emu.js'), 'utf8');
const B = { emu: bin('emu/emu.bin'), stub: bin('emu/stub_tpl.bin'), t7: bin('t7/t7.bin'), t7x: bin('t7/t7x.bin'), t18: bin('t18/t18.bin'), t18x: bin('t18/t18x.bin'), v1: bin('v1/v1.bin'), v3: bin('v3/v3.bin'),
  gb: bin('gb/gb.bin'), gbc: bin('gb/gbc.bin'), sms: bin('sms/sms.bin'), pm: bin('pm/pm.bin'), ab: bin('ab/ab.bin'), wolf: bin('wolf/wolf.bin'), wolfsod: bin('wolf/wolfsod.bin'),
  doomApp: bin('doom/doomf_app.bin'), doomXip: bin('doom/doomf_xip.bin') };
for (const [ph, k] of [['__EMU_APP_B64__', 'emu'], ['__EMU_STUB_B64__', 'stub'], ['__T7_APP_B64__', 't7'], ['__T7X_APP_B64__', 't7x'], ['__V1_APP_B64__', 'v1'], ['__V3_APP_B64__', 'v3'], ['__GB_APP_B64__', 'gb'],
  ['__GBC_APP_B64__', 'gbc'], ['__AB_APP_B64__', 'ab'], ['__PM_APP_B64__', 'pm'], ['__SMS_APP_B64__', 'sms'], ['__WOLF_APP_B64__', 'wolf'], ['__WOLFSOD_APP_B64__', 'wolfsod'], ['__T18_APP_B64__', 't18'], ['__T18_XIP_B64__', 't18x']])
  src = src.replace(ph, Buffer.from(B[k]).toString('base64'));
const mod = { exports: {} };
vm.runInThisContext('(function (module) {' + src + '\n})', { filename: 'emu.js' })(mod);
const E = mod.exports;

const DUMPS = process.env.DUMPS;
if (!DUMPS) { console.error('DUMPS is not set'); process.exit(2); }
const EDS = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];
const lines = [];
const sha = (b) => crypto.createHash('sha256').update(Buffer.from(b.buffer, b.byteOffset, b.length)).digest('hex');
const H = (b) => (b === null || b === undefined ? 'null' : b.length + ':' + sha(b));
const out = (n, v) => { lines.push(n + ' ' + v); };
const T = (n, f) => { try { out(n, f()); } catch (e) { out(n, 'ERR ' + (e instanceof Error && !(e instanceof TypeError) && !(e instanceof RangeError) ? e.message : 'INTERNAL') + (e.needPack ? ' needPack' : '') + (e.room ? ' room' + (e.frag ? ' frag' : '') : '') + (e.packHint ? ' packHint' : '') + (e.prog ? ' prog=' + e.prog : '')); } };
const bo = (v) => (v === null || v === undefined ? '-' : v ? '1' : '0');
const hx = (v) => (v === null || v === undefined ? '-' : (v >>> 0).toString(16));
const u32 = (b, o) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;
function w32(b, o, v) { b[o] = v & 255; b[o + 1] = (v >>> 8) & 255; b[o + 2] = (v >>> 16) & 255; b[o + 3] = (v >>> 24) & 255; }
const asc = (b, o, s) => { for (let i = 0; i < s.length; i++) b[o + i] = s.charCodeAt(i); };

// ------------------------------------------------------------ synthetic inputs
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
function utf16(b, o, s) { for (let i = 0; i < s.length; i++) { b[o + 2 * i] = s.charCodeAt(i); b[o + 2 * i + 1] = 0; } }
/* a download record of the colour Tamas ("TAMAGO", name UTF-16 BE at 6, file name at 0x34, length at 0x48, sum at the end) */
function dlcRec(len, t, c, f, fam, name, file, seed, tail) {
  const b = rndBytes(len + (tail || 0), seed);
  asc(b, 0, 'TAMAGO'); b.fill(0, 6, 0x4C);
  for (let i = 0; i < name.length; i++) { b[6 + 2 * i] = 0; b[7 + 2 * i] = name.charCodeAt(i); }
  asc(b, 0x34, file);
  b[0x48] = (len >>> 24) & 255; b[0x49] = (len >>> 16) & 255; b[0x4A] = (len >>> 8) & 255; b[0x4B] = len & 255;
  b[0x4E] = t; b[0x50] = c; b[0x51] = f; if (len > 0x100) b[0xFF] = fam;
  let s = 0; for (let i = 0; i < len - 2; i++) s += b[i];
  b[len - 2] = (s >> 8) & 255; b[len - 1] = s & 255;
  return b;
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
function t18Rec(len, target, cat, price, name, file, seed, pic) {
  const b = rndBytes(len, seed);
  asc(b, 0, 'TAMAGO'); b.fill(0, 6, 0x100); asc(b, 52, file);
  b[0x48] = 0; b[0x49] = (len >>> 16) & 255; b[0x4A] = (len >>> 8) & 255; b[0x4B] = len & 255;
  b[78] = (target >>> 24) & 255; b[79] = (target >>> 16) & 255; b[80] = (target >>> 8) & 255; b[81] = target & 255;
  b[90] = cat >> 8; b[91] = cat & 255; b[118] = price >> 8; b[119] = price & 255;
  for (let i = 0; i < name.length && i < 12; i++) { const ch = name.charCodeAt(i); b[94 + 2 * i] = 0; b[95 + 2 * i] = ch === 32 ? 0x6C : ch === 42 ? 0x63 : ch >= 65 && ch <= 90 ? 0xE0 + ch - 65 : ch >= 48 && ch <= 57 ? 0xC6 + ch - 48 : 0x11; }
  if (pic && len >= 0x240) {
    const p = 0x202; b[0x200] = 0; b[0x201] = 1; b[p] = 0; b[p + 1] = 46; b[p + 2] = 8; b[p + 3] = 8; b[p + 4] = 4; b[p + 5] = 0; b[p + 6] = 0; b[p + 7] = 0;
    const pal = [0x07E0, 0xF800, 0x001F, 0x8410]; for (let i = 0; i < 4; i++) { b[p + 8 + 2 * i] = pal[i] >> 8; b[p + 9 + 2 * i] = pal[i] & 255; }
    for (let i = 0; i < 32; i++) b[p + 16 + i] = ((i * 7 + seed) & 3) | ((((i >> 2) + seed) & 3) << 4);
  }
  if ((target >>> 24) === 0x94) { b[0xB0] = 0x02; b[0xB1] = 0x40; }
  let s = 0; for (let i = 0; i < len - 2; i++) s = (s + b[i]) & 0xFFFF;
  b[len - 2] = s >> 8; b[len - 1] = s & 255;
  return b;
}
function image(w, h, mode, seed) {
  const rgba = new Uint8ClampedArray(w * h * 4), r = rng(seed);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const o = (y * w + x) * 4, v = r();
    if (mode === 0) { rgba[o] = (x >> 3) * 40 & 255; rgba[o + 1] = (y >> 3) * 30 & 255; rgba[o + 2] = 128; }
    else if (mode === 1) { rgba[o] = v & 255; rgba[o + 1] = (v >> 8) & 0xF0; rgba[o + 2] = (v >> 16) & 0xC0; }
    else { rgba[o] = v & 255; rgba[o + 1] = (v >> 8) & 255; rgba[o + 2] = (v >> 16) & 255; }
    rgba[o + 3] = 255; }
  return { w, h, rgba };
}

// ------------------------------------------------------------ what a result looks like
const pkStr = (p) => 'blocks=' + p.blocks + ' big=' + bo(p.big) + ' lzOff=' + hx(p.lzOff) + ' lzBlocks=' + (p.lzBlocks === undefined ? '-' : p.lzBlocks) + ' raw=' + bo(!!p.raw) + ' few=' + (p.few === undefined ? '-' : p.few) + ' pages=' + p.pages.map((x) => x.v.toString(16) + ':' + sha(x.data).slice(0, 8)).join(',') + ' map=' + sha(p.map) + ' blob=' + H(p.blob);
const cfgStr = (c) => (!c ? 'null' : c.kind + ' rom=' + hx(c.romOff) + '+' + hx(c.romLen) + ' save=' + hx(c.saveOff) + (c.kind === 'doom' ? ' cfg=' + hx(c.cfg) + ' region=' + hx(c.regionOff) + '+' + hx(c.regionLen) + ' code=' + hx(c.codeOff) : '')
  + (c.kind === 't18' ? ' v=' + c.version + ' flags=' + hx(c.flags) + ' map=' + c.map.map((v) => v.toString(16)).join('.') + ' spare=' + c.spare.map((v) => v.toString(16)).join('.') : '')
  + (c.kind === 'tama' ? ' dev=' + c.dev + ' guest=' + hx(c.guestOff) + '+' + hx(c.guestSize) + ' spareEnd=' + hx(c.spareEnd) + ' lzOff=' + hx(c.lzOff) + ' map=' + sha(c.map) : ''));
const optStr = (o) => (!o ? '-' : o.vol + '/' + o.dim + '/' + o.off);
const keysStr = (k) => (!k ? '-' : Array.isArray(k) ? k.join('.') : Object.keys(k).sort().map((n) => n + '=' + (typeof k[n] === 'boolean' ? bo(k[n]) : k[n])).join(','));
const xStr = (x) => 'kind=' + E.extraKind(x) + ' name=' + x.name + ' off=' + hx(x.off) + ' saveOff=' + hx(x.saveOff) + ' clock=' + bo(x.clock) + ' nfc=' + bo(x.nfc) + ' sess=' + bo(x.sess) + ' opt=' + optStr(x.opt) + ' dev=' + (x.dev || '-') + ' pack=' + bo(x.kind === 'tama' ? x.pack : undefined)
  + ' title=' + (x.title || '-') + ' gg=' + bo(x.gg) + ' inv=' + bo(x.inv) + ' keys=' + keysStr(x.keys) + ' region=' + hx(x.region) + ' figs=' + (x.figs ? x.figs.map((f) => f.name + ':' + H(f.data)).join(',') : '-')
  + ' data=' + H(x.rom || x.guest || x.fw || (x.kind === 'wolf' ? x.pack : null) || x.mcu) + ' save=' + H(x.save) + ' bios=' + H(x.bios);
const placedStr = (r) => 'low=' + hx(r.low) + ' dl=' + hx(r.dl) + ' freeKB=' + r.freeKB + ' list=' + r.list.map((l) => l.name + '@' + hx(l.off) + '/' + hx(l.src)).join(',') + ' rom=' + sha(r.rom);
const recStr = (r) => (!r ? 'null' : 'file=' + r.file + ' name=' + r.name + ' readable=' + bo(r.readable) + ' art=' + r.art + ' target=' + hx(r.target) + ' cat=' + r.cat + ' price=' + r.price + ' model=' + r.model + ' pic=' + (r.pic ? r.pic.w + 'x' + r.pic.h + ':' + sha(new Uint8Array(r.pic.rgba.buffer)) : '-') + ' bytes=' + H(r.bytes));
const itemsStr = (it) => 'save=' + bo(it.save) + ' points=' + it.points + ' room=' + (it.room ? it.room.name : '-') + ' ' + it.areas.map((a) => a.key + '(free=' + a.free + ' noCount=' + bo(!!a.noCount) + ':' + a.slots.map((s) => s.n + (s.rec ? '=' + s.rec.name : '') + 'x' + s.count + (s.basic ? 'b' : '')).join(',') + ')').join(' ');
const resStr = (r) => r.map((x) => hx(x[0]) + '-' + hx(x[1])).join(',');

const stubs = [[0xB0000, B.stub]];
const t7app = () => { const a = new Uint8Array(B.t7); a.x = B.t7x; return a; };
const t18app = () => { const a = new Uint8Array(B.t18); a.xip = B.t18x; return a; };
const v1app = () => { const a = new Uint8Array(B.v1); a.v3 = B.v3; return a; };
const APPS = () => ({ t7: t7app(), tama: B.emu, t18: t18app(), v1: v1app(), doom: { app: B.doomApp, xip: B.doomXip } });

// ------------------------------------------------------------ cases without a dump
function pure() {
  out('const', [E.MENU_ROOM, E.MENU_ROOM_LEN, E.PACK_OPT, E.PACK_ASK, E.PACK_FEW, E.DETECT_TAG, E.DOOM_LINK, E.GUEST_LZ, E.SMS_MAGIC, E.AB_MAGIC, E.AB_SAVE, E.AB_MAX, E.PM_MAGIC, E.PM_SAVE, E.PM_BIOS_AT, E.WOLF_MAGIC, E.GB_MAGIC, E.V1_MAGIC, E.T7X_SAVE, E.APPX_MAX, E.T7_MAGIC, E.T18_MAGIC, E.T18_XIP_OFF, E.T18_SAVE_LEN, E.STUB_OFF, E.GUEST_OFF, E.BIG_OFF].map((v) => (typeof v === 'boolean' ? bo(v) : v)).join(','));
  out('const.keys', [E.SMS_KEYS_DEFAULT, E.AB_KEYS_DEFAULT, E.PM_KEYS_DEFAULT, E.GB_KEYS_DEFAULT, E.OPT_LV, E.PS_STAMP].map((k) => k.join('.')).join(' ') + ' ' + keysStr(E.WOLF_KEYS_DEFAULT));
  out('const.devices', Object.keys(E.DEVICES).map((d) => d + ':' + E.DEVICES[d].kind + ':' + E.DEVICES[d].size + ':' + E.DEVICES[d].label + ':' + E.DEVICES[d].par).join(','));
  out('const.saveFlag', Object.keys(E.SAVE_FLAG).map((d) => { const f = E.SAVE_FLAG[d]; return d + ':' + f.kind + ':' + f.at.join('.') + ':' + f.off + ':' + f.on + ':' + f.len; }).join(','));
  out('const.adults', E.T18_ADULTS.map((a) => a[0] + a[1]).join(','));
  out('embedded', [E.embedded().app, E.embedded().stub, E.t7Embedded(), E.t7Embedded().x, E.t18Embedded(), E.t18Embedded().xip, E.v1Embedded(), E.v3Embedded(), E.gbEmbedded(), E.gbcEmbedded(), E.smsEmbedded(), E.pmEmbedded(), E.abEmbedded(), E.wolfEmbedded(), E.wolfSodEmbedded()].map(H).join(' '));
  // LZ
  const lzIn = [['empty', new Uint8Array(0)], ['3', rndBytes(3, 1)], ['rnd1k', rndBytes(1024, 2)], ['zero1k', new Uint8Array(1024)], ['ff5', new Uint8Array(5).fill(0xFF)]];
  { const p = new Uint8Array(1024); fillPat(p, 0, 1024, 9); lzIn.push(['pat1k', p]); const q = rndBytes(4096, 3); q.set(q.subarray(100, 900), 2000); q.fill(7, 3000, 3600); lzIn.push(['mix4k', q]);
    const z = new Uint8Array(70000); fillPat(z, 0, 70000, 3); z.set(rndBytes(300, 4), 40000); lzIn.push(['long70k', z]); const hi = rndBytes(2048, 5); for (let i = 0; i < 2048; i++) hi[i] |= 0x80; hi.set(hi.subarray(0, 600), 1200); lzIn.push(['high2k', hi]); }
  for (const [n, d] of lzIn) { T('lzEnc.' + n, () => H(E.lzEnc(d))); T('lzDec.' + n, () => { const c = E.lzEnc(d), b = E.lzDec(c, d.length); return H(b) + ' same=' + bo(Buffer.from(b).equals(Buffer.from(d))); }); }
  T('lzDec.short', () => H(E.lzDec(E.lzEnc(lzIn[6][1]), 1000)));
  T('lzDec.long', () => H(E.lzDec(E.lzEnc(lzIn[5][1]), 2000)));
  { const g = tamaFw('idl', 40, 77), bl = [3, 5, 0x20, 0x41, 0x7F];
    T('lzPack', () => H(E.lzPack(g, bl)));
    T('lzPack.none', () => H(E.lzPack(g, [])));
    T('lzUnpack', () => { const z = E.lzPack(g, bl), g2 = new Uint8Array(g); for (const b of bl) g2.fill(0x11, b << 16, (b + 1) << 16); E.lzUnpack((a, n) => z.subarray(a, a + n), g2); return H(g2) + ' same=' + bo(Buffer.from(g2).equals(Buffer.from(g))); });
    T('lzCount', () => { const z = E.lzPack(g, bl), r = new Uint8Array(0x2000 + z.length); r.set(z, 0x2000); return E.lzCount(r, 0x2000) + ',' + E.lzCount(r, 0) + ',' + E.lzCount(r, r.length - 100); }); }
  T('tamaLzCan', () => [B.emu, B.t7, null, new Uint8Array(8), B.doomApp].map((a) => bo(E.tamaLzCan(a))).join(''));
  // detection of the colour Tamas
  const fws = {};
  for (const [dev, pct, seed] of [['pc', 50, 11], ['pc', 100, 12], ['idl', 40, 13], ['idl', 62, 14], ['idl', 85, 15], ['ps', 45, 16], ['ps', 70, 17], ['4u', 45, 18], ['4u', 95, 19], ['4u-plain', 42, 20], ['4u-plain', 66, 21]]) fws[dev + '.' + pct] = tamaFw(dev, pct, seed);
  { const g = tamaFw('pc', 50, 22); asc(g, 0x123456, 'TAMAGO'); g[0x123456 + 6] = 0; fws['id.50'] = g; }
  { const g = tamaFw('idl', 30, 23); w32(g, 0x400000, 0x02400010); for (let k = 0; k < 12; k++) utf16(g, 0x500000 + k * 0x100, 'DL_iDN_x'); utf16(g, 0x510000, 'DL_iDL_x'); fws['tagps.30'] = g; }
  { const g = tamaFw('idl', 30, 24); w32(g, 0x400000, 0x02400020); for (let k = 0; k < 10; k++) utf16(g, 0x500000 + k * 0x100, 'DL_T4U_x'); fws['tag4u.30'] = g; }
  { const g = tamaFw('idl', 30, 25); w32(g, 0x400000, 0x02400030); for (let k = 0; k < 9; k++) utf16(g, 0x500000 + k * 0x100, 'DL_iDL_x'); for (let k = 0; k < 9; k++) utf16(g, 0x520000 + k * 0x100, 'DL_iDN_x'); fws['tagidl.30'] = g; }
  { const g = tamaFw('idl', 30, 26); w32(g, 0x400000, 0x024CA8FE); fws['idljp.30'] = g; }
  for (const k of Object.keys(fws)) { T('emuDetect.' + k, () => E.emuDetect(fws[k])); const d = k.split('.')[0]; T('tamaName.' + k, () => { let dv; try { dv = E.emuDetect(fws[k]); } catch (e) { dv = '?'; } return E.tamaName(fws[k], dv) + ',' + E.tamaName(fws[k], d) + ',' + E.tamaName(null, 'pc') + ',' + E.tamaName(fws[k], 'zz'); }); }
  for (const [n, g] of [['short', new Uint8Array(0x80)], ['zero4', new Uint8Array(0x400000)], ['zero8', new Uint8Array(0x800000)], ['big', new Uint8Array(0x800001)], ['edge', (() => { const g = new Uint8Array(0x400002); g[0x400000] = 0xFF; return g; })()], ['t7', t7Rom(false, 1)]]) T('emuDetect.' + n, () => E.emuDetect(g));
  // packing
  const devOf = (k) => { const d = k.split('.')[0]; return d === 'id' ? 'pc' : d.startsWith('tag') || d === 'idljp' ? 'idl' : d; };
  for (const k of Object.keys(fws)) {
    const g = fws[k], dev = devOf(k);
    for (const [on, o] of [['plain', {}], ['sparse', { sparse: true }], ['lz', { lz: true }], ['sparse.room', { sparse: true, room: E.MENU_ROOM_LEN }], ['lz.room', { lz: true, room: E.MENU_ROOM_LEN }], ['lz.sparse.small', { lz: true, sparse: true, room: 0x300000 }], ['lzAll', { lz: true, lzAll: true, room: E.MENU_ROOM_LEN }], ['lzExtra', { lz: true, lzExtra: [0x40, 0x0b, 1, 2, 3], room: E.MENU_ROOM_LEN }], ['lzOnly', { lz: true, lzOnly: [1, 2, 3, 0x30, 0x60] }]]) {
      if ((on === 'lzAll' || on === 'lzExtra' || on === 'lz.sparse.small') && !/^(pc\.50|idl\.62|ps\.70|4u\.95|id\.50)$/.test(k)) continue;
      T('packGuest.' + k + '.' + on, () => pkStr(E.packGuest(g, dev, o)));
    }
    T('packMain.' + k, () => pkStr(E.packMain(g, dev)));
    T('packMain.' + k + '.pack', () => pkStr(E.packMain(g, dev, B.emu, true)));
    T('packMain.' + k + '.t7app', () => pkStr(E.packMain(g, dev, B.t7, false)));
    T('mainNeedsPack.' + k, () => bo(E.mainNeedsPack(g, dev)) + bo(E.mainNeedsPack(g, dev, B.t7)));
    T('tamaNeedsLz.' + k, () => bo(E.tamaNeedsLz(g, dev)) + bo(E.tamaNeedsLz(g, dev, E.MENU_ROOM_LEN)) + bo(E.tamaNeedsLz(g, dev, 0x200000)));
    T('extraSize.tama.' + k, () => [E.extraSize({ kind: 'tama', guest: g, dev }), E.extraSize({ kind: 'tama', guest: g, dev, pack: true }), E.extraSize({ kind: 'tama', guest: g, dev }, 0x40000), E.extraSize({ kind: 'tama', guest: g, dev })].join(','));
    T('extraName.tama.' + k, () => E.extraName({ kind: 'tama', guest: g, dev }));
  }
  T('packGuest.short', () => pkStr(E.packGuest(fws['idl.40'].subarray(0, 0x123456), 'idl', {})));
  T('packGuest.t7dev', () => pkStr(E.packGuest(fws['pc.50'], 't7', {})));
  T('packGuest.nodev', () => pkStr(E.packGuest(fws['pc.50'], 'zz', {})));
  T('extraSize.tama.nodev', () => E.extraSize({ kind: 'tama', guest: fws['pc.50'], dev: 'zz' }));
  // download content
  const dlcFw = (dev, seed, save) => { const g = tamaFw(dev, 40, seed); g.fill(0xFF, 0x590000, 0x7E0000); g.fill(0xFF, 0xE000, 0xF000); if (save) { fillRnd(g, 0xE000, 0x4E4, seed + 1); fillRnd(g, 0xE4E4, 0x4E4, seed + 2); g[0xE000] = 1; g[0xE4E4] = 2; } return g; };
  const recs = [['meal', 0x400, 0x81, 0x02, 0x01, 1, 'DL_iDL_Meal.jpg', 'idl_meal01'], ['snackC', 0x300, 0x81, 0x0C, 0x02, 3, 'DL_iDN_Cake', 'idn_cake'], ['snackD', 0x280, 0x81, 0x0D, 0x02, 2, 'DL_T4U_Snack.JPG', 't4u_snack0123'],
    ['wall', 0x1F00, 0x81, 0x1F, 0x00, 1, 'Wall', 'idl_wall'], ['daily', 0x7000, 0x81, 0x29, 0x00, 2, 'DL_iDN_Recipe', 'idn_rec01'], ['item', 0x1800, 0x81, 0x2A, 0x01, 3, 'DL_x_Item', 't4u_item0650'], ['item2', 0x1800, 0x81, 0x2A, 0x01, 1, 'Item two', 't4u_item0850'],
    ['item3', 0x1000, 0x81, 0x2A, 0x01, 1, 'Item three', 't4u_item0012'], ['itemNoId', 0x1000, 0x81, 0x2A, 0x01, 2, 'Item none', 'noid'], ['bingo', 0x6000, 0x81, 0x29, 0x00, 1, 'Bingo', 't4u_b1350'], ['gasha', 0x6000, 0x81, 0x29, 0x00, 2, 'Gasha', 't4u_g99700'],
    ['cloth', 0x3F00, 0x81, 0x33, 0x00, 2, 'Cloth', 'cloth77'], ['acc', 0x1F00, 0x81, 0x34, 0x00, 3, 'Acc', 'acc'], ['acc2', 0x2100, 0x81, 0x35, 0x00, 1, 'TooBig', 'acc2'], ['dest', 0x7F00, 0x94, 0x47, 0x02, 2, 'Dest', 'dest'], ['game', 0x7F00, 0x94, 0x5B, 0x01, 1, 'DL_iDL_Game.jpg', 'game'],
    ['game2', 0x5000, 0x94, 0x5B, 0x02, 3, 'Game2', 'game2'], ['char', 0x7000, 0x94, 0x48, 0x03, 1, 'Char', 'char'], ['letter', 0x600, 0x81, 0x51, 0x00, 2, 'Letter', 'let'], ['letterIdl', 0x600, 0x81, 0x51, 0x00, 1, 'Letter iD L', 'let2'], ['stamp', 0x9000, 0x81, 0x52, 0x03, 2, 'Stamp', 'stamp'],
    ['happy', 0x9000, 0x81, 0x52, 0x02, 1, 'Happy', 'happy'], ['happyPs', 0x9000, 0x81, 0x52, 0x02, 2, 'HappyPs', 'happyps'], ['meal4u', 0x500, 0x81, 0x01, 0x01, 2, 'Meal 4U', 'm4u'], ['snack4u', 0x500, 0x81, 0x01, 0x02, 3, 'Snack 4U', 's4u'], ['small', 0x80, 0x81, 0x02, 0x01, 9, 'Small', 'small'], ['none', 0x400, 0x77, 0x02, 0x01, 1, 'None', 'none']]
    .map(([n, len, t, c, f, fam, name, file], i) => [n, dlcRec(len, t, c, f, fam, name, file, 100 + i)]);
  const recOf = (n) => recs.find((r) => r[0] === n)[1];
  for (const [n, r] of recs) {
    T('dlcName.' + n, () => JSON.stringify(E.dlcName(r)));
    T('dlcRoute.' + n, () => ['idl', 'ps', '4u', '4u-plain', 'pc', undefined].map((d) => { const s = d === undefined ? E.dlcRoute(r) : E.dlcRoute(r, d); return s ? s.kind + ':' + s.label + ':' + hx(s.base) + ':' + s.size + ':' + s.n + ':' + bo(!!s.one) : 'null'; }).join(' '));
    for (const d of ['idl', 'ps', '4u', '4u-plain']) T('dlcRecord.' + n + '.' + d, () => H(E.dlcRecord(r, d)));
  }
  T('dlcName.short', () => JSON.stringify(E.dlcName(recOf('meal').subarray(0, 0x15))));
  T('dlcRoute.short', () => bo(!!E.dlcRoute(new Uint8Array(0x20))) + bo(!!E.dlcRoute(new Uint8Array(0x20), 'ps')) + bo(!!E.dlcRoute(new Uint8Array(0x20), '4u')));
  { const jpg = (r, extra) => { const b = new Uint8Array(300 + r.length + extra); fillRnd(b, 0, 300, 5); for (let i = 0; i + 1 < 300; i++) if (b[i] === 0xFF && b[i + 1] === 0xD9) b[i] = 0; b[200] = 0xFF; b[201] = 0xD9; b.set(r, 300); return b; };
    T('dlcRecord.jpg', () => H(E.dlcRecord(jpg(recOf('meal'), 0))));
    T('dlcRecord.jpg.tail', () => H(E.dlcRecord(jpg(recOf('meal'), 3))));
    T('dlcRecord.jpg.ps.tail', () => H(E.dlcRecord(jpg(recOf('snackD'), 3), 'ps')));
    T('dlcRecord.ps.tail1', () => { const r = recOf('snackD'), b = new Uint8Array(r.length + 1); b.set(r); b[r.length] = 9; return H(E.dlcRecord(b, 'ps')); });
    T('dlcRecord.nodecl', () => { const r = new Uint8Array(recOf('wall')); r[0x49] = 0x77; return H(E.dlcRecord(r)); });
    T('dlcRecord.badsum', () => { const r = new Uint8Array(recOf('wall')); r[0x100] ^= 1; return H(E.dlcRecord(r)); });
    T('dlcRecord.none', () => H(E.dlcRecord(rndBytes(500, 6))));
    T('dlcRecord.tiny', () => H(E.dlcRecord(recOf('meal').subarray(0, 0x40)))); }
  for (const [dev, seed] of [['idl', 31], ['ps', 32], ['4u', 33], ['4u-plain', 34]]) {
    let g = dlcFw(dev, seed, true);
    T('dlcStores.' + dev + '.empty', () => E.dlcStores(g).map((s) => s.kind + ':' + s.label + ':' + s.slots.map((x) => x.slot + (x.name === null ? '' : '=' + x.name)).join('|')).join(' '));
    T('dlcAreas.' + dev, () => E.dlcAreas(dev).map((a) => hx(a[0]) + '-' + hx(a[1])).join(','));
    for (const [n, r0] of recs) {
      T('dlcAdd.' + dev + '.' + n, () => { const r = E.dlcRecord(r0, dev), a = E.dlcAdd(g, r); g = a.guest; return a.store.kind + ':' + a.slot + ':' + bo(!!a.stamp) + ' ' + H(g) + ' flag=' + E.saveFlagGet(g, dev) + '/' + E.psStampGet(g); });
    }
    T('dlcAdd.' + dev + '.again', () => H(E.dlcAdd(g, E.dlcRecord(recOf('meal'), dev)).guest));
    T('dlcAdd.' + dev + '.raw', () => { const a = E.dlcAdd(g, recOf('cloth')); return a.store.kind + ':' + a.slot; });
    T('dlcStores.' + dev, () => E.dlcStores(g).map((s) => s.kind + ':' + s.slots.map((x) => (x.name === null ? '' : x.name)).join('|')).join(' '));
    T('dlcSlots.' + dev, () => E.dlcSlots(g).map((x) => x.slot + '=' + x.name).join(','));
    T('dlcPut.' + dev, () => H(E.dlcPut(g, recOf('game2'), 1)));
    for (const [kind, slot] of [[0, 0], [7, 1], [11, 0], [12, 0], [9, 0], [5, 9], [99, 0], [0, -1]]) T('dlcFree.' + dev + '.' + kind + '.' + slot, () => { const o = E.dlcFree(g, kind, slot); return H(o) + ' flag=' + E.saveFlagGet(o, dev); });
    T('dlcAdd.' + dev + '.full', () => { let x = g, n = 0; for (let i = 0; i < 30; i++) { const r = dlcRec(0x200, 0x81, 0x02, 0x01, 9, 'M' + i, 'm' + i, 300 + i); x = E.dlcAdd(x, r).guest; n++; } return n; });
    T('saveFlag.' + dev, () => { const x = new Uint8Array(g); E.saveFlag(x, dev, 0x55); E.psStamp(x, 0x66); return H(x.subarray(0xE000, 0xF000)) + ' ' + E.saveFlagGet(x, dev) + ' ' + E.psStampGet(x) + ' ' + E.saveFlagGet(x, 'pc'); });
  }
  T('dlc.nosave', () => { const g = dlcFw('ps', 35, false); const a = E.dlcAdd(g, E.dlcRecord(recOf('stamp'), 'ps')); return a.slot + ' ' + E.psStampGet(a.guest) + ' ' + H(a.guest); });
  T('dlc.pc', () => E.dlcStores(fws['pc.50']).length + ',' + E.dlcSlots(fws['pc.50']).length + ',' + E.dlcAreas('pc').length);
  T('dlcAdd.pc', () => H(E.dlcAdd(fws['pc.50'], recOf('meal')).guest));
  T('dlcPut.pc', () => H(E.dlcPut(fws['pc.50'], recOf('game'), 0)));
  T('dlcFree.pc', () => H(E.dlcFree(fws['pc.50'], 7, 0)));
  T('dlc.unknown8', () => { const g = new Uint8Array(0x7C0000).fill(0xFF); const a = E.dlcAdd(g, recOf('game')); return E.dlcStores(g).length + ' ' + a.store.kind + ':' + a.slot + ' ' + H(a.guest) + ' ' + H(E.dlcFree(a.guest, 7, 0)); });
  // the run state of TamaEmu with the stamp byte
  { const mk = (dev, len, at, hit) => {
      const save = rndBytes(len, 40), emu = rndBytes(0x3000, 41), gram = new Uint8Array(32768); fillPat(gram, 0, 32768, 3);
      if (hit) emu.set(save, at); const raw = new Uint8Array(emu.length + gram.length); raw.set(emu); raw.set(gram, emu.length);
      const enc = []; for (let i = 0; i < raw.length; i += 128) { const n = Math.min(128, raw.length - i); enc.push(n - 1); for (let k = 0; k < n; k++) enc.push(raw[i + k]); }
      const img = new Uint8Array(0x60000).fill(0xFF), so = 0x10000;
      w32(img, so, 0x53584D50); w32(img, so + 4, 3); w32(img, so + 8, 0x1234); w32(img, so + 12, 0x5678); w32(img, so + 16, enc.length); w32(img, so + 20, Math.ceil(enc.length / 0x1000) + 2); img.set(enc, so + 0x1000);
      return { img, so, save, dev };
    };
    const run = (n, m, v, f) => T('psSessStamp.' + n, () => { if (f) f(m); const r = m.dev ? E.psSessStamp(m.img, m.so, m.save, v, m.dev) : E.psSessStamp(m.img, m.so, m.save, v); return bo(r) + ' ' + H(m.img); });
    run('ps', mk('ps', 0x4E4, 0x1000, true), 0x0C); run('ps.default', Object.assign(mk('ps', 0x4E4, 0x804, true), { dev: undefined }), 0);
    run('idl', mk('idl', 0x400, 0x2000, true), 3); run('nohit', mk('ps', 0x4E4, 0, false), 0x0C); run('pc', mk('pc', 0x4E4, 0, true), 1);
    run('same', mk('ps', 0x4E4, 0x1000, true), 0x0C, (m) => { E.psSessStamp(m.img, m.so, m.save, 0x0C, 'ps'); });
    run('nomagic', mk('ps', 0x4E4, 0x1000, true), 1, (m) => { m.img[m.so] = 0; });
    run('version', mk('ps', 0x4E4, 0x1000, true), 1, (m) => { m.img[m.so + 4] = 2; });
    run('bytes', mk('ps', 0x4E4, 0x1000, true), 1, (m) => { w32(m.img, m.so + 16, 0x50000); });
    run('shortsave', mk('ps', 0x200, 0x1000, true), 7); }
  // T7
  const go = t7Rom(false, 51), fr = t7Rom(true, 52);
  T('t7Kind', () => [go, fr, null, go.subarray(0, 100), rndBytes(0xA0000, 53), (() => { const b = t7Rom(true, 54); b[0x3FFC] = 1; return b; })(), new Uint8Array(0xC0000)].map((b) => String(E.t7Kind(b)) + bo(E.t7Detect(b))).join(','));
  const figA = t7Fig(0x40000, 0x12345, 55), figB = t7Fig(0x100000, 0x80000, 56), figFull = t7FigFull(57), figZero = new Uint8Array(0x1000);
  T('t7FigDetect', () => [figA, figFull, figZero, null, figA.subarray(0, 0x30), go].map((b) => bo(E.t7FigDetect(b))).join(''));
  for (const [n, f] of [['a', figA], ['b', figB], ['full', figFull], ['zero', figZero], ['tiny', new Uint8Array(8).fill(1)], ['pow', rndBytes(0x80000, 58)], ['dbl', (() => { const b = new Uint8Array(0x100000); b.set(rndBytes(0x80000, 59)); b.set(b.subarray(0, 0x80000), 0x80000); b[0x80000] ^= 0xFF; return b; })()]]) T('t7FigData.' + n, () => H(E.t7FigData(f)));
  T('t7FigName', () => ['(03)_Tama-Go_Mametchi.bin', 'C:\\x\\TamaGo-Kuchipatchi Figure.bin', '/a/b/tama go_memetchi_figure', '', undefined, 'A very long name of a figure that goes on.bin', 'Näme_ü.bin', '(12) - tama_go__X', '...', 'noext', 'tama-go.bin'].map((s) => JSON.stringify(E.t7FigName(s))).join(','));
  T('t7Room', () => [E.t7Room([]), E.t7Room([{ data: figA }, { data: figB }]), E.t7Room([{ data: figA }], 0xC0000)].join(','));
  T('t7XName', () => E.t7XName(go) + ',' + E.t7XName(fr) + ',' + E.t7XName(null));
  // V1, V3
  const v46 = v1Rom(0x3000, 61), v48 = v1Rom(0x4000, 62), v3 = v3Rom(63);
  T('v1Detect', () => [v46, v48, v3, null, rndBytes(0x3000, 64), v46.subarray(0, 0x2000), rndBytes(0x80000, 65)].map((b) => bo(E.v1Detect(b)) + bo(E.v3Detect(b))).join(','));
  T('v1Name', () => [v46, v48, v3, new Uint8Array(0x3000), new Uint8Array(0)].map((b) => E.v1Name(b) + bo(E.v1Clock(b))).join(','));
  // Game Boy
  const gb32 = gbRom(0, 0x00, 'TETRIS', 71), gb256 = gbRom(3, 0x00, 'Zelda dx\x7Fx', 72), gbTrim = gbRom(5, 0x00, 'POKEMON RED', 73, 18), gbc1m = gbRom(5, 0x80, 'GOLD', 74), gbc2m = gbRom(6, 0xC0, 'CRYSTAL', 75), gbTrim3 = gbRom(4, 0x00, '', 76, 3), gbcTrim = gbRom(4, 0x80, '  spaced  ', 77, 6);
  const gbs = [['32', gb32], ['256', gb256], ['trim', gbTrim], ['c1m', gbc1m], ['c2m', gbc2m], ['trim3', gbTrim3], ['ctrim', gbcTrim]];
  T('gbDetect', () => gbs.map((x) => x[1]).concat([null, gb32.subarray(0, 0x4000), rndBytes(0x8000, 78), (() => { const b = new Uint8Array(gb32); b[0x148] = 1; return b; })(), rndBytes(0x400000, 79), rndBytes(0x9000, 80)]).map((b) => bo(E.gbDetect(b))).join(''));
  for (const [n, r] of gbs) T('gb.' + n, () => { const t = E.gbTrim(r); return bo(E.gbIsColor(r)) + bo(E.gbColorOnly(r)) + ' ' + JSON.stringify(E.gbTitle(r)) + ' trim=' + t.banks + ':' + H(t.rom) + ' untrim=' + H(E.gbUntrim(t.rom, (t.banks << 16) | 5)) + ' size=' + E.extraSize({ kind: 'gb', rom: r }) + ' name=' + E.extraName({ kind: 'gb', rom: r }); });
  T('gbTrim.odd', () => { const t = E.gbTrim(rndBytes(0x21000, 81)), t2 = E.gbTrim(rndBytes(0x10000, 82)); return t.banks + ':' + t.rom.length + ',' + t2.banks + ':' + t2.rom.length; });
  T('gbUntrim.edge', () => [E.gbUntrim(gb32, 0), E.gbUntrim(gb32, 1 << 16), E.gbUntrim(gb32.subarray(0, 0x4100), 9 << 16), E.gbUntrim(new Uint8Array(0), 9 << 16), E.gbUntrim(gb32, 300 << 16), E.gbUntrim(gb32, 4 << 16)].map((b) => b.length).join(','));
  T('gbTitle.short', () => JSON.stringify(E.gbTitle(new Uint8Array(0x138))) + bo(E.gbIsColor(new Uint8Array(0x100))) + bo(E.gbColorOnly(new Uint8Array(0x100))));
  // Master System, Game Gear
  const sms1 = smsRom(0x20000, 4, 91), smsJ = smsRom(0x8000, 3, 92), gg = smsRom(0x40000, 6, 93), smsNo = smsRom(0x10000, -1, 94), smsCop = smsRom(0x20000, 4, 95, true), sms8 = smsRom(0x2000, 7, 96), smsBad = smsRom(0x20000, 2, 97);
  T('smsDetect', () => [sms1, smsJ, gg, smsNo, smsCop, sms8, smsBad, null, rndBytes(0x1000, 98), rndBytes(0x20100, 99), rndBytes(0x200000, 90)].map((b) => bo(E.smsDetect(b)) + bo(E.smsDetect(b, 'game.SMS')) + bo(E.smsDetect(b, 'x.gg')) + bo(E.smsDetect(b, 'x.bin'))).join(','));
  T('smsGameGear', () => [sms1, smsJ, gg, smsNo, smsCop, sms8].map((b) => bo(E.smsGameGear(b)) + bo(E.smsGameGear(b, 'a.GG')) + bo(E.smsGameGear(b, 'a.sms'))).join(','));
  const names = ['Sonic the Hedgehog (USA, Europe).sms', 'Alex Kidd in Miracle World [!].sms', 'Castle of Illusion Starring Mickey Mouse.sms', 'the.of.and.sms', '', undefined, 'Pokemon Pinball mini (Europe).min', 'POKEMON the of', 'ünïcödé gäme.gg', "It's a 'test' & more!.bin", 'a   b\tc\nd.x', '(only brackets).sms', 'Arduboy_Game-v1.2.hex', 'x'.repeat(40) + '.sms', 'Fifteen letters  and more', 'line1\n(two).sms'];
  T('smsTitle', () => names.map((s) => JSON.stringify(E.smsTitle(s))).join(','));
  T('pmTitle', () => names.map((s) => JSON.stringify(E.pmTitle(s))).join(','));
  T('abTitle', () => names.map((s) => JSON.stringify(E.abTitle(s))).join(','));
  // Pokemon mini
  const pm1 = pmRom(0x80000, 101), pmS = pmRom(0x2200, 102), pmBig = pmRom(0x180000, 103), bios = pmBios(104);
  T('pmDetect', () => [pm1, pmS, pmBig, null, rndBytes(0x2200, 105), pm1.subarray(0, 0x2100), bios].map((b) => bo(E.pmDetect(b)) + bo(E.pmTooBig(b)) + bo(E.pmBiosDetect(b))).join(','));
  // Arduboy
  const abData = rndBytes(0x3456, 111), abOdd = rndBytes(0x1235, 112), abFull = rndBytes(0x8000, 113);
  const hexes = [['crlf', abHexText(abData, '\r\n')], ['lf', abHexText(abOdd, '\n')], ['full', abHexText(abFull, '\n')], ['bytes', Buffer.from(abHexText(abData, '\n'), 'latin1')], ['toobig', abHexText(rndBytes(0x8010, 114), '\n')], ['nohex', 'hello'], ['empty', ''],
    ['badsum', abHexText(abData, '\n').replace(':10001000', ':10001001')], ['noeof', abHexText(abData, '\n').replace(':00000001FF\n', '')], ['onlyeof', ':00000001FF\n'], ['seg', ':020000020000FC\n' + abHexText(abOdd, '\n')], ['segbad', ':020000021000EC\n' + abHexText(abOdd, '\n')], ['lin', ':020000040000FA\n:0400100001020304E2\n:00000001FF'],
    ['junk', abHexText(abOdd, '\n').replace('\n', '\nrubbish\n')], ['short', ':0000000000\n:10'], ['blank', '\n\n  ' + abHexText(abOdd, '\n\n')], ['nan', ':0000000000\n:zz00000000\n:02zzzz00AABB\n:00000001FF'], ['nan2', ':0000000000\n:0200zz00AABB99\n:00000001FF'], ['lower', abHexText(abOdd, '\n').toLowerCase()]];
  for (const [n, t] of hexes) T('abHex.' + n, () => H(E.abHex(typeof t === 'string' ? t : new Uint8Array(t))));
  // Wolf3D
  const wolf = wolfPack(0x123456, 0, 121), wolfSh = wolfPack(0x60000, 1, 122), sod = wolfPack(0x90000, 2, 123);
  T('wolf', () => [wolf, wolfSh, sod, null, new Uint8Array(100), wolf.subarray(0, 60), rndBytes(200, 124)].map((p) => { const i = E.wolfInfo(p); return bo(E.wolfPackOk(p)) + bo(E.wolfSod(p)) + (i ? bo(i.shareware) + bo(i.sod) + ':' + i.episodes + ':' + i.maps : '-'); }).join(','));
  // T18
  const fw18 = t18Fw(131, false, 38), fw18s = t18Fw(132, true, 30), fw18big = t18Fw(133, false, 80);
  T('t18Detect', () => [fw18, fw18s, null, fw18.subarray(0, 0x700000), new Uint8Array(0x800000), fws['idl.40']].map((b) => bo(E.t18Detect(b))).join(''));
  for (const [n, f] of [['a', fw18], ['sanrio', fw18s], ['big', fw18big], ['none', fws['idl.40']], ['small', fw18.subarray(0, 0x3000)], ['range', (() => { const g = new Uint8Array(fw18); w32(g, 0x121000, 0xF8001000); return g; })()], ['unaligned', fw18.subarray(1, 0x200001)]]) T('t18Addrs.' + n, () => { const a = E.t18Addrs(f); return hx(a.idle) + ',' + hx(a.soft) + ',' + hx(a.dma) + ',' + hx(a.param); });
  const trecs = [['meal', t18Rec(0x400, 0x81010101, 15003, 120, 'OMURICE 2', 'tg18_as15003_1.txt', 141, true)], ['snack', t18Rec(0x300, 0x81010102, 15010, 80, 'CAKE*', 'TG18_bs15010', 142, true)], ['item', t18Rec(0x1800, 0x81042A01, 16001, 300, 'BALL', 'tg18_it', 143, true)], ['item3', t18Rec(0x1000, 0x81042A03, 16002, 310, 'TOY 77', 'tg18_i3', 144, false)],
    ['acc', t18Rec(0x1F00, 0x81023400, 17001, 500, 'RIBBON', 'tg18_ac', 145, true)], ['acc5', t18Rec(0x400, 0x81023500, 17002, 510, 'HAT', 'tg18_a5', 146, true)], ['room', t18Rec(0x3F00, 0x81071F00, 18001, 900, 'PINK ROOM', 'tg18_rm', 147, true)], ['game', t18Rec(0x8000, 0x94005B01, 19001, 0, 'MAGIC HUT', 'tg18_gm', 148, false)],
    ['place', t18Rec(0x4000, 0x94004702, 19002, 0, 'TOWN', 'tg18_pl', 149, false)], ['derived', t18Rec(0x200, 0x81019901, 15020, 5, 'SOUP', 'x', 150, false)], ['derived2', t18Rec(0x200, 0x81019902, 15021, 5, 'TEA', 'y_z', 151, false)], ['unknown', t18Rec(0x200, 0x81990000, 1, 2, 'abc', 'unk_file', 152, false)], ['basic', t18Rec(0x300, 0x81010101, 12000, 0, 'RICE', 'tg18_basic', 153, true)],
    ['big', t18Rec(0x2100, 0x81042A01, 16009, 1, 'BIG', 'big', 154, true)], ['unread', t18Rec(0x200, 0x81010101, 15030, 1, 'a?b!', 'unread_file', 155, false)]];
  const trec = (n) => trecs.find((r) => r[0] === n)[1];
  const scanFile = (() => { const parts = [rndBytes(77, 160)]; for (const [, r] of trecs) { parts.push(r); parts.push(rndBytes(13, 161)); } { const r = new Uint8Array(trec('game')); r[0x300] ^= 1; parts.push(r); parts.push(new Uint8Array([0x12, 0x34, 0, 0])); } { const r = new Uint8Array(trec('meal')); r[0x300] ^= 1; parts.push(r); }
    let n = 0; for (const p of parts) n += p.length; const b = new Uint8Array(n); let o = 0; for (const p of parts) { for (let i = 0; i + 6 < p.length && p.length < 100; i++) if (p[i] === 0x54) p[i] = 0x55; b.set(p, o); o += p.length; } return b; })();
  let scanned = [];
  T('t18iScan', () => { scanned = E.t18iScan(scanFile); return scanned.length + ' ' + scanned.map(recStr).join(' | '); });
  T('t18iScan.none', () => E.t18iScan(rndBytes(5000, 162)).length + ',' + E.t18iScan(new Uint8Array(10)).length + ',' + E.t18iScan(trec('meal').subarray(0, 0x200)).length);
  const sc = (n) => E.t18iScan(trec(n))[0];
  { const f = new Uint8Array(fw18);
    T('t18Items.empty', () => itemsStr(E.t18Items(f)));
    T('t18ItemAdd.nosave', () => { const e = new Uint8Array(0x800000).fill(0xFF); return E.t18ItemAdd(e, sc('meal')).slot; });
    for (const [n, cnt] of [['basic', 1], ['meal', 2], ['snack', 0], ['item', 3], ['item3', 9], ['acc', 1], ['acc5', undefined], ['room', 1], ['game', 1], ['place', 1], ['game', 1], ['derived', 1], ['derived2', 2], ['unknown', 1], ['big', 1], ['unread', 1]])
      T('t18ItemAdd.' + n, () => { const r = sc(n); const a = cnt === undefined ? E.t18ItemAdd(f, r) : E.t18ItemAdd(f, r, cnt); return a.area + ':' + a.slot + ' ' + H(f.subarray(0x5E0000)); });
    T('t18ItemAdd.dlfull', () => { const r = E.t18iScan(t18Rec(0x1000, 0x94004702, 19009, 0, 'ISLE', 'tg18_p2', 156, false))[0]; const a = E.t18ItemAdd(f, r); return a.area + ':' + a.slot; });
    T('t18Items.filled', () => itemsStr(E.t18Items(f)));
    T('t18ItemCount', () => { E.t18ItemCount(f, 'food', 1, 3); E.t18ItemCount(f, 'food', 20, 2); E.t18ItemCount(f, 'item', 0, 7); E.t18ItemCount(f, 'acc', 1, -2); return itemsStr(E.t18Items(f)); });
    T('t18Points', () => [0, 1234, 65535, 70000, -5, 4660].map((v) => { E.t18Points(f, v); return E.t18Items(f).points; }).join(','));
    T('t18ItemDel', () => { E.t18ItemDel(f, 'food', 1); E.t18ItemDel(f, 'acc', 0); E.t18ItemDel(f, 'dl', 1); return itemsStr(E.t18Items(f)) + ' ' + H(f.subarray(0x5E0000)); });
    T('t18RoomReset', () => { E.t18RoomReset(f); return itemsStr(E.t18Items(f)) + ' ' + H(f.subarray(0x5E0000)); });
    T('t18ItemAdd.fill', () => { let n = 0; try { for (let i = 0; i < 40; i++) { E.t18ItemAdd(f, E.t18iScan(t18Rec(0x200, 0x81010101, 15100 + i, 1, 'F' + i, 'f' + i, 170 + i, false))[0]); n++; } } catch (e) { return n + ' ' + e.message + ' ' + itemsStr(E.t18Items(f)); } return n; }); }
  T('t18AdultFind', () => ['Mametchi.png', '16', '016.PNG', 'my_kuchipatchi-adult.jpg', 'LOVELITCHI', 'x', '', '99', '21.gif', 'pompom tchi.bmp', 'Kuro-Mametchi', '1e1', '35'].map((s) => E.t18AdultFind(s)).join(','));
  const pics = new Map();
  for (const [n, w, h, mode, seed] of [['blocks', 100, 80, 0, 181], ['small', 16, 16, 0, 182], ['64', 64, 64, 1, 183], ['noise', 200, 200, 1, 184], ['noise64', 64, 64, 2, 185], ['wide', 640, 10, 2, 186], ['one', 1, 1, 2, 187]])
    T('t18PicMake.' + n, () => { const p = E.t18PicMake(image(w, h, mode, seed)); pics.set(n, p); return H(p) + ' rgba=' + sha(new Uint8Array(E.t18PicRgba(p).rgba.buffer)); });
  // DOOM
  const lump = (n, seed) => rndBytes(n, seed), cmapL = lump(34 * 256, 191), big1 = lump(0x30000, 192), big2 = lump(0x25000, 193);
  const wadA = doomWad([['PLAYPAL', lump(768, 194)], ['COLORMAP', cmapL], ['E1M1', new Uint8Array(0)], ['THINGS', lump(300, 195)], ['TEX1', big1], ['SND', big2], ['SMALL', lump(100, 196)], ['FLAT', lump(4096, 197)]]);
  const wadB = doomWad([['PLAYPAL', lump(768, 194)], ['COLORMAP', cmapL], ['E5M1', new Uint8Array(0)], ['THINGS', lump(700, 198)], ['TEX1', big1], ['SND', big2], ['SMALL', lump(100, 196)], ['NEW', lump(0x9000, 199)], ['FLAT', lump(4096, 197)]]);
  const wadC = doomWad([['COLORMAP', lump(100, 200)], ['X', lump(5000, 201)]]);
  const dx = (mcu, o) => Object.assign({ kind: 'doom', mcu }, o || {});
  T('doomLinks', () => { const xa = dx(wadA), xb = dx(wadB), xc = dx(wadC), xt = { rom: go }, l = E.doomLinks([xb, xt, xc, xa, dx(null)]); return l.size + ' ' + [xa, xb, xc].map((x) => { const k = l.get(x); return k ? 'saved=' + k.saved + ' mcu=' + H(k.mcu) + ' refs=' + k.refs.map((r) => r[0] + '>' + (r[1] === xa ? 'a' : r[1] === xb ? 'b' : 'c') + '+' + r[2]).join(',') : '-'; }).join(' | '); });
  T('doomLinks.same', () => { const xa = dx(wadA), xb = dx(new Uint8Array(wadA)), l = E.doomLinks([xa, xb]); return l.size + ' ' + (l.get(xb) ? 'b:' + l.get(xb).saved + ':' + H(l.get(xb).mcu) : l.get(xa) ? 'a:' + l.get(xa).saved : '-'); });
  T('doomUnlink.whole', () => bo(E.doomUnlink(new Uint8Array(100), 4, wadA) === wadA));
  T('doomParts', () => [E.doomParts(dx(wadA)), E.doomParts(dx(wadA), 0x12345), E.doomParts({ kind: 'doom' }), E.doomParts({ kind: 'doom', size: 0x123456 }, 1), E.doomParts(dx(wadB, { region: 0x150000 }), B.doomXip.length)].map((p) => hx(p.prog) + '+' + hx(p.wad)).join(','));
  T('extraName', () => [dx(wadA), dx(wadA, { title: 'SIGIL' }), dx(wadA, { ep: 2 }), dx(wadA, { ep: 'all', d2: true }), dx(wadA, { name: 'MY WAD 1.9!' }), dx(wadA, { name: 'lower' }), dx(wadA, { name: 'THIS NAME IS TOO LONG' }), { kind: 't18' }, { rom: go }, { rom: fr }, { rom: v46 }, { rom: v3 }, { kind: 'v1', rom: v48 }, { kind: 'sms' }, { kind: 'sms', title: 'SONIC' }, { kind: 'pm' }, { kind: 'pm', title: 'PINBALL' }, { kind: 'ab' }, { kind: 'ab', title: 'A' }, { kind: 'wolf', pack: wolf }, { kind: 'wolf', pack: sod }, { kind: 'tama', dev: 'ps' }]
    .map((x) => E.extraKind(x) + '=' + E.extraName(x)).join(','));
  T('extraSize', () => [{ rom: go }, { rom: fr, figs: [{ name: 'a', data: figA }] }, { rom: go, figs: [{ name: 'a', data: figA }, { name: 'b', data: figB }] }, { rom: v46 }, { rom: v48 }, { rom: v3 }, { kind: 'sms', rom: sms1 }, { kind: 'sms', rom: smsCop }, { kind: 'pm', rom: pm1 }, { kind: 'pm', rom: pmS }, { kind: 'ab', rom: abData }, { kind: 'wolf', pack: wolf }, dx(wadA), dx(wadB, { region: 0x200000 }), { kind: 'doom' }, { kind: 't18', fw: fw18 }, { kind: 't18', fw: fw18big }]
    .map((x) => E.extraSize(x)).join(','));
  return { fws, go, fr, figA, figB, figFull, v46, v48, v3, gb32, gb256, gbTrim, gbc1m, gbc2m, gbcTrim, sms1, gg, smsNo, smsCop, pm1, pmS, bios, abData, abOdd, wolf, sod, wolfSh, fw18, fw18s, fw18big, wadA, wadB, wadC, pics, trec, sc, recOf, dlcFw };
}

// ------------------------------------------------------------ cases on a ROM image
function settings(n, rom) {
  T(n + '.clock', () => { const g = E.emuClockGet(rom), a = E.emuClockSet(rom, true), b = E.emuClockSet(rom, false); return bo(g) + ' ' + bo(a === rom) + sha(a) + ' ' + bo(b === rom) + sha(b) + ' ' + bo(E.emuClockGet(b)); });
  T(n + '.t18clock', () => { const g = E.t18ClockGet(rom), a = E.t18ClockSet(rom, true), b = E.t18ClockSet(rom, false); return bo(g) + ' ' + bo(a === rom) + sha(a) + ' ' + bo(b === rom) + sha(b) + ' ' + bo(E.t18ClockGet(b)); });
  T(n + '.nfc', () => { const g = E.emuNfcGet(rom), a = E.emuNfcSet(rom, true), b = E.emuNfcSet(rom, false); return bo(g) + ' ' + bo(a === rom) + sha(a) + ' ' + bo(b === rom) + sha(b) + ' ' + bo(E.emuNfcGet(b)); });
  T(n + '.sess', () => { const g = E.emuSessGet(rom), a = E.emuSessSet(rom, true), b = E.emuSessSet(rom, false); return bo(g) + ' ' + bo(a === rom) + sha(a) + ' ' + bo(b === rom) + sha(b) + ' ' + bo(E.emuSessGet(b)); });
  T(n + '.opt', () => { const g = E.emuOptGet(rom); return optStr(g) + ' ' + [{ vol: 1, dim: 0, off: 0 }, { vol: 3, dim: 10, off: 7 }, { vol: 2, dim: 5, off: 3 }, { vol: 0, dim: 11, off: 1 }, { vol: 7, dim: 23, off: 9 }, null].map((o) => { const r = E.emuOptSet(rom, o); return bo(r === rom) + sha(r).slice(0, 16) + '=' + optStr(E.emuOptGet(r)); }).join(' '); });
  T(n + '.opt.old', () => { const a = 0xA0140 + (u32(rom, 0xA0140) === E.T18_MAGIC ? 400 : 156), r = new Uint8Array(rom); return [0x00040000, 0x00080000, 0x000C0000, 0x0C000000, 0x0F350000].map((f) => { w32(r, a, f); return optStr(E.emuOptGet(r)); }).join(' '); });
  T(n + '.auto', () => { const g = E.autoGet(rom, stubs), a = E.autoSet(rom, stubs, true), b = a && E.autoSet(a, stubs, false); return bo(g) + ' ' + (a ? sha(a) + bo(E.autoGet(a, stubs)) : 'null') + ' ' + (b ? sha(b) + bo(E.autoGet(b, stubs)) : 'null') + ' old=' + bo(E.autoGetOld(rom, stubs)) + bo(a ? E.autoGetOld(a, stubs) : null) + ' off=' + bo(E.autoGet(rom, [[0xB1000, B.stub], [-5, B.stub], [0xFFFFFF, B.stub]])) + bo(E.autoGet(rom, [])); });
  T(n + '.reserved', () => resStr(E.appReserved(rom)));
  T(n + '.cfg', () => cfgStr(E.extraCfg(rom, 0xA0000)) + ' t18Low=' + hx(E.t18Low(rom)) + ' doomCfg=' + cfgStr(E.doomCfg(rom, 0xA0000)));
  T(n + '.read', () => E.appsRead(rom, [{ src: 0x10000000 + 0xA0000 - 0x11000, name: 'MAIN' }]).map(xStr).join(' | '));
  T(n + '.packed', () => E.appsPacked(rom, [{ src: 0x10000000 + 0xA0000 - 0x11000, name: '' }, { src: 0x10000000 + 0xA0000 - 0x11000, name: 'NAMED' }, { src: 5 }, { src: 0x20000000 }]).join(','));
  T(n + '.hiFree', () => { const dirty = new Uint8Array(rom); let did = 0; for (let b = 0xF0; b < 0x100; b++) if (dirty.subarray(b << 16, (b + 1) << 16).every((v) => v === 0xFF)) { dirty[(b << 16) + 5] = 1; did++; } const a = E.hiFree(rom, []), c = E.hiFree(dirty, null, 0xF30000), d = E.hiFree(dirty, [0x200000]); return bo(a === rom) + ' ' + did + ' ' + bo(c === dirty) + sha(c) + ' ' + bo(d === dirty) + sha(d); });
  T(n + '.t7', () => { const c = E.t7Cfg(rom), f = E.t7FromRom(rom); return (c ? 'v=' + c.version + ' rom=' + hx(c.romOff) + '+' + hx(c.romLen) + ' save=' + hx(c.saveOff) + ' flags=' + hx(c.flags) + ' figs=' + c.figs.map((x) => x.name + '@' + hx(x.off) + '+' + hx(x.len)).join(',') : 'null') + ' from=' + (f ? H(f.rom) + '/' + f.figs.map((x) => x.name + ':' + H(x.data)).join(',') : 'null') + ' outdated=' + bo(E.t7Outdated(rom)); });
  T(n + '.t18', () => { const c = E.t18Cfg(rom); return (c ? 'v=' + c.version + ' save=' + hx(c.saveOff) + ' flags=' + hx(c.flags) + ' map=' + c.map.map((v) => v.toString(16)).join('.') + ' spare=' + c.spare.map((v) => v.toString(16)).join('.') : 'null') + ' from=' + H(E.t18FromRom(rom)); });
  T(n + '.v1', () => H(E.v1FromRom(rom)) + ' ' + H(E.v1FromRom(rom, 0x200000)));
  T(n + '.wall', () => { const d = new Date(2024, 1, 29, 23, 59, 58), a = E.t7Wall(rom, 0x123456789, d), b = E.t18Wall(rom, -1, d); return bo(a === rom) + sha(a) + ' ' + bo(b === rom) + sha(b); });
  T(n + '.origs', () => { const t = E.sceneTable(rom), o = E.installedOrigs(rom, t); return o ? o.map(hx).join(',') : 'null'; });
  T(n + '.upgrade', () => { const a = E.emuUpgrade(rom, B.emu), b = E.t7Upgrade(rom, t7app()), c = E.t18Upgrade(rom, t18app()), d = E.t18Upgrade(rom, t18app(), B.stub), e = E.v1Upgrade(rom, v1app()); return [a, b, c, d, e].map((x) => (x ? sha(x) : 'null')).join(' '); });
  T(n + '.upgrade.old', () => { const r = new Uint8Array(rom); r[0xA0000 + 0x900] ^= 0x55; r[0xC8000 + 5] ^= 1; r[0xF0000 + 0x40] ^= 1; const a = E.emuUpgrade(r, B.emu), b = E.t7Upgrade(r, t7app()), c = E.t18Upgrade(r, t18app()), d = E.t18Upgrade(r, t18app(), B.stub), e = E.v1Upgrade(r, v1app()), f = E.t7Upgrade(r, new Uint8Array(B.t7)), g = E.emuUpgrade(r, B.t7), h = E.v1Upgrade(r, new Uint8Array(B.v1)); return [a, b, c, d, e, f, g, h].map((x) => (x ? sha(x) : 'null')).join(' '); });
  T(n + '.remove', () => sha(E.emuRemove(rom)));
}
function onRom(ed, rom, S) {
  const gen1 = ed === 'water' || ed === 'land' || ed === 'sky', first = ed === 'water' || ed === 'jade' || ed === 'tropical' || ed === 'neon';
  T(ed + '.sceneTable', () => { const t = E.sceneTable(rom); return Object.keys(t).length + ' home=' + hx(t.PSID_HOME) + ' ' + crypto.createHash('sha256').update(Object.keys(t).sort().map((k) => k + '=' + t[k]).join(',')).digest('hex'); });
  T(ed + '.neonRom', () => bo(E.neonRom(rom)) + bo(E.neonRom(null)) + bo(E.neonRom(rom.subarray(0, 0xD85000))));
  T(ed + '.t18Free', () => E.t18Free(rom).map((v) => v.toString(16)).join('.') + ' / ' + E.t18Free(rom, true).map((v) => v.toString(16)).join('.'));
  settings(ed + '.plain', rom);
  // TamaEmu as the main program
  const tamaCases = gen1 ? [['pc.50', {}], ['pc.100', { clock: false }], ['id.50', { lang: 'en' }], ['idl.40', {}], ['idl.62', { pack: true }], ['idl.62', {}], ['idl.85', {}], ['idl.85', { pack: true }], ['ps.45', { lang: 'en', clock: false }], ['ps.70', { pack: true }], ['4u.45', {}], ['4u.95', { pack: true }], ['4u-plain.42', { device: '4u-plain' }], ['4u-plain.66', {}], ['tagps.30', {}], ['idl.40', { device: 'ps' }]]
    : [['pc.50', {}], ['idl.62', { pack: true }], ['ps.45', {}]];
  let tamaRom = null, tamaBig = null, nfcRom = null;
  for (const [k, o] of tamaCases) {
    if (!first && !/^(pc\.50|idl\.62|ps\.45|4u\.45)$/.test(k)) continue;
    const n = ed + '.emuPatch.' + k + (o.pack ? '.pack' : '') + (o.device ? '.' + o.device : '');
    T(n, () => { const r = E.emuPatch(rom, S.fws[k], B.emu, B.stub, o); if (k === 'pc.50') tamaRom = r.rom; if (k === 'idl.62' && o.pack) tamaBig = r.rom; if (k === '4u.45') nfcRom = r.rom; return r.device + ' blocks=' + r.blocks + ' big=' + bo(r.big) + ' ' + sha(r.rom); });
  }
  T(ed + '.emuPatch.short', () => sha(E.emuPatch(rom.subarray(0, 0x800000), S.fws['pc.50'], B.emu, B.stub).rom));
  T(ed + '.emuPatch.badfw', () => sha(E.emuPatch(rom, S.go, B.emu, B.stub).rom));
  T(ed + '.emuPatch.noblock', () => sha(E.emuPatch(rom, S.fws['pc.50'], B.t7, B.stub).rom));
  T(ed + '.emuPatch.badstub', () => sha(E.emuPatch(rom, S.fws['pc.50'], B.emu, B.emu).rom));
  if (tamaRom) {
    settings(ed + '.tama', tamaRom);
    T(ed + '.tama.again', () => { const r = E.emuPatch(tamaRom, S.fws['ps.45'], B.emu, B.stub, { lang: 'en' }); return r.device + ' ' + bo(r.big) + ' ' + sha(r.rom); });
    T(ed + '.tama.v1', () => sha(E.v1Patch(tamaRom, S.v46, v1app(), B.stub)));
    T(ed + '.tama.t7', () => sha(E.t7Patch(tamaRom, S.fr, [], t7app(), B.stub)));
    T(ed + '.tama.t18', () => { const r = E.t18Patch(tamaRom, S.fw18, t18app(), B.stub); return r.blocks + ',' + r.spares + ',' + bo(r.hot) + ' ' + sha(r.rom); });
    T(ed + '.tama.installApp', () => sha(E.installApp(tamaRom, B.gb, B.stub)) + ' ' + sha(E.installApp(tamaRom, B.gb, B.stub, { keep: true })));
    T(ed + '.tama.upgrade.v2', () => { const r = new Uint8Array(tamaRom); return [1, 2, 3, 4, 5, 6].map((v) => { w32(r, 0xA0144, v); const u = E.emuUpgrade(r, B.emu); return u ? sha(u).slice(0, 16) : 'null'; }).join(' '); });
  }
  if (tamaBig) {
    settings(ed + '.tamaBig', tamaBig);
    T(ed + '.tamaBig.again', () => { const r = E.emuPatch(tamaBig, S.fws['pc.50'], B.emu, B.stub); return bo(r.big) + ' ' + sha(r.rom); });
    T(ed + '.tamaBig.t7', () => sha(E.t7Patch(tamaBig, S.go, [], t7app(), B.stub)));
    T(ed + '.tamaBig.v1', () => sha(E.v1Patch(tamaBig, S.v3, v1app(), B.stub)));
    T(ed + '.tamaBig.t18', () => sha(E.t18Patch(tamaBig, S.fw18, t18app(), B.stub).rom));
  }
  if (nfcRom) settings(ed + '.tama4u', nfcRom);
  // T7Emu as the main program
  const figs = [{ name: '(03)_Tama-Go_Mametchi.bin', data: S.figA }, { name: 'Full figure.bin', data: S.figFull }];
  let t7Rom_ = null;
  T(ed + '.t7Patch.go', () => { t7Rom_ = E.t7Patch(rom, S.go, figs, t7app(), B.stub, { lang: 'en' }); return sha(t7Rom_); });
  T(ed + '.t7Patch.friends', () => sha(E.t7Patch(rom, S.fr, figs, t7app(), B.stub, { clock: false })));
  T(ed + '.t7Patch.nox', () => sha(E.t7Patch(rom, S.go, [], new Uint8Array(B.t7), B.stub)));
  T(ed + '.t7Patch.bad', () => sha(E.t7Patch(rom, S.v46, [], t7app(), B.stub)));
  T(ed + '.t7Patch.many', () => sha(E.t7Patch(rom, S.go, new Array(17).fill(figs[0]), t7app(), B.stub)));
  T(ed + '.t7Patch.noroom', () => sha(E.t7Patch(rom, S.go, [figs[0], { name: 'b1', data: S.figB }, { name: 'b2', data: S.figB }, { name: 'b3', data: S.figB }, { name: 'b4', data: S.figB }, { name: 'b5', data: S.figB }, { name: 'b6', data: S.figB }, { name: 'b7', data: S.figB }], t7app(), B.stub)));
  T(ed + '.t7Patch.wrongapp', () => sha(E.t7Patch(rom, S.go, [], B.gb, B.stub)));
  if (t7Rom_) {
    settings(ed + '.t7', t7Rom_);
    const used = new Uint8Array(t7Rom_); fillRnd(used, 0xC0000, 0x8000, 7); w32(used, 0xC1000, 0x45453754);
    T(ed + '.t7.again.same', () => sha(E.t7Patch(used, S.go, figs, t7app(), B.stub, { lang: 'en' })));
    T(ed + '.t7.again.figs', () => sha(E.t7Patch(used, S.go, [figs[0]], t7app(), B.stub)));
    T(ed + '.t7.again.rom', () => sha(E.t7Patch(used, S.fr, [], t7app(), B.stub)));
    T(ed + '.t7.outdated', () => { const r = new Uint8Array(used); let s2 = 0x7E7E; for (let i = 2; i < 4096; i++) s2 = (Math.imul(s2, 31) + r[0xC2000 + i]) >>> 0; w32(r, 0xC100C, Math.imul(Math.imul(s2, 31), 31) >>> 0); const a = E.t7Outdated(r); r[0xA0900] ^= 1; const b = E.t7Outdated(r); let s = 0x7E7E; for (let i = 0; i < 4096; i++) s = (Math.imul(s, 31) + r[0xC2000 + i]) >>> 0; w32(r, 0xC100C, s); return bo(a) + bo(b) + bo(E.t7Outdated(r)) + bo(E.t7Outdated(r, 0x200000)); });
    T(ed + '.t7.tama', () => sha(E.emuPatch(t7Rom_, S.fws['pc.50'], B.emu, B.stub).rom));
    T(ed + '.t7.t18', () => sha(E.t18Patch(t7Rom_, S.fw18, t18app(), B.stub).rom));
    T(ed + '.t7.apps', () => placedStr(E.appsPlace(t7Rom_, [{ rom: S.fr }, { rom: S.v46 }], APPS(), {})));
  }
  // V1Emu, V3Emu as the main program
  let v1Rom_ = null, v3Rom_ = null;
  T(ed + '.v1Patch.46', () => { v1Rom_ = E.v1Patch(rom, S.v46, v1app(), B.stub, { lang: 'en' }); return sha(v1Rom_); });
  T(ed + '.v1Patch.48', () => sha(E.v1Patch(rom, S.v48, v1app(), B.stub, { clock: false })));
  T(ed + '.v1Patch.v3', () => { v3Rom_ = E.v1Patch(rom, S.v3, v1app(), B.stub); return sha(v3Rom_); });
  T(ed + '.v1Patch.v3.none', () => sha(E.v1Patch(rom, S.v3, new Uint8Array(B.v1), B.stub)));
  T(ed + '.v1Patch.bad', () => sha(E.v1Patch(rom, S.go, v1app(), B.stub)));
  if (v1Rom_) { settings(ed + '.v1', v1Rom_); const used = new Uint8Array(v1Rom_); fillRnd(used, 0xC0000, 0x3000, 8);
    T(ed + '.v1.again', () => sha(E.v1Patch(used, S.v46, v1app(), B.stub)) + ' ' + sha(E.v1Patch(used, S.v48, v1app(), B.stub)));
    T(ed + '.v1.upgrade.flags', () => { const r = new Uint8Array(used); w32(r, 0xA0140 + 20, 1); const u = E.v1Upgrade(r, v1app()); return u ? sha(u) : 'null'; }); }
  if (v3Rom_) settings(ed + '.v3', v3Rom_);
  // T18Emu as the main program
  let t18Rom_ = null;
  for (const [n, f, o] of [['a', 'fw18', {}], ['en', 'fw18s', { lang: 'en', clock: false, opt: { vol: 2, dim: 4, off: 5 }, nosess: true }], ['nohot', 'fw18', { hotWindow: false }], ['holes', 'fw18', { holes: true, spares: 7 }], ['holes.nohot', 'fw18s', { holes: true, hotWindow: false, noResv: true }], ['launch', 'fw18', { launch: true, spares: 12 }], ['noResv', 'fw18', { noResv: true }], ['big', 'fw18big', {}], ['big.launch', 'fw18big', { launch: true }]]) {
    if (!first && !/^(a|en|big)$/.test(n)) continue;
    T(ed + '.t18Patch.' + n, () => { const r = E.t18Patch(rom, S[f], t18app(), B.stub, o); if (n === 'a') t18Rom_ = r.rom; return r.blocks + ',' + r.spares + ',' + bo(r.hot) + ' ' + sha(r.rom); });
  }
  T(ed + '.t18Patch.bad', () => sha(E.t18Patch(rom, S.fws['idl.40'], t18app(), B.stub).rom));
  T(ed + '.t18Patch.noxip', () => sha(E.t18Patch(rom, S.fw18, new Uint8Array(B.t18), B.stub).rom));
  T(ed + '.t18Patch.short', () => sha(E.t18Patch(rom.subarray(0, 100), S.fw18, t18app(), B.stub).rom));
  if (t18Rom_) {
    settings(ed + '.t18', t18Rom_);
    T(ed + '.t18.again', () => { const used = new Uint8Array(t18Rom_); fillRnd(used, 0xC0000, 0x24000, 9); w32(used, 0xC0000, 0); const r = E.t18Patch(used, S.fw18, t18app(), B.stub); return bo(r.hot) + ' ' + sha(r.rom) + ' ' + sha(E.t18Patch(used, S.fw18s, t18app(), B.stub).rom); });
    T(ed + '.t18.tama', () => sha(E.emuPatch(t18Rom_, S.fws['pc.50'], B.emu, B.stub).rom));
    T(ed + '.t18.t7', () => sha(E.t7Patch(t18Rom_, S.go, [], t7app(), B.stub)));
    T(ed + '.t18.installApp', () => sha(E.installApp(t18Rom_, B.gb, B.stub)) + ' ' + sha(E.installApp(t18Rom_, B.gb, B.stub, { keep: true })));
    T(ed + '.t18.pics', () => { const m = new Map([[16, S.pics.get('blocks')], [21, S.pics.get('small')], [35, S.pics.get('64')], [99, S.pics.get('noise')], [18, S.pics.get('noise')]]); const r = E.t18PicsWrite(t18Rom_, m), back = E.t18PicsRead(r), e = E.t18PicsWrite(r, new Map()); return sha(r) + ' ' + [...back.keys()].map((k) => k + ':' + sha(back.get(k)).slice(0, 12)).join(',') + ' ' + sha(e) + ' ' + E.t18PicsRead(e).size + ' ' + resStr(E.appReserved(r)); });
    T(ed + '.t18.pics.none', () => bo(E.t18PicsWrite(rom, new Map()) === rom) + E.t18PicsRead(rom).size);
    // items into the installed T18Emu
    let g1 = null;
    T(ed + '.t18.write', () => { const fw = E.t18FromRom(t18Rom_); E.t18ItemAdd(fw, S.sc('meal'), 2); E.t18ItemAdd(fw, S.sc('item')); E.t18ItemAdd(fw, S.sc('room')); E.t18ItemAdd(fw, S.sc('game')); E.t18Points(fw, 4321); g1 = E.t18RomWriteGuest(t18Rom_, fw); const back = E.t18FromRom(g1); return sha(g1) + ' same=' + bo(Buffer.from(back).equals(Buffer.from(fw))) + ' ' + itemsStr(E.t18Items(back)); });
    T(ed + '.t18.write2', () => { const fw = E.t18FromRom(g1); E.t18ItemAdd(fw, S.sc('acc')); E.t18ItemDel(fw, 'food', 0); fillRnd(fw, 0x7D0000, 0x1000, 3); fillRnd(fw, 0x7D5000, 0x2000, 4); const g2 = E.t18RomWriteGuest(g1, fw), back = E.t18FromRom(g2); return sha(g2) + ' same=' + bo(Buffer.from(back).equals(Buffer.from(fw))) + ' up=' + (() => { const u = E.t18Upgrade(g2, t18app(), B.stub); return u ? sha(u) : 'null'; })(); });
    T(ed + '.t18.write.full', () => { const fw = E.t18FromRom(g1); for (let b = 0x60; b < 0x7F; b++) if (fw.subarray(b << 16, (b + 1) << 16).every((v) => v === 0xFF)) fillRnd(fw, b << 16, 0x10000, b); return sha(E.t18RomWriteGuest(g1, fw)); });
    T(ed + '.t18.write.none', () => sha(E.t18RomWriteGuest(rom, S.fw18)));
    T(ed + '.t18.upgrade.nohot', () => { const r = E.t18Patch(rom, S.fw18, t18app(), B.stub, { hotWindow: false }).rom; const a = E.t18Upgrade(r, t18app()), b = E.t18Upgrade(r, t18app(), B.stub); return (a ? sha(a) : 'null') + ' ' + (b ? sha(b) : 'null'); });
  }
  T(ed + '.installApp', () => sha(E.installApp(rom, B.gb, B.stub)));
  T(ed + '.installApp.big', () => sha(E.installApp(rom, new Uint8Array(0x10001), B.stub)));
  // more programs in the menu
  const small = () => [{ rom: S.v46 }, { kind: 'gb', rom: S.gb32, keys: [1, 2, 4, 8, 16, 32, 64, 128, 3], inv: true, save: rndBytes(0x3000, 11) }, { kind: 'sms', rom: S.smsNo, title: 'NO HEADER', gg: true, sess: false }, { kind: 'pm', rom: S.pmS, title: 'TINY', bios: S.bios, save: rndBytes(0x10000, 12), keys: [256, 128, 64, 32, 16, 8, 4, 2, 1] }, { kind: 'ab', rom: S.abData, title: 'ARDU', save: rndBytes(0x5000, 13), clock: false }];
  const mid = () => [{ rom: S.go, figs: [{ name: 'Tama-Go_Kuchipatchi.bin', data: S.figA }], clock: false }, { rom: S.v3 }, { kind: 'wolf', pack: S.wolfSh, keys: { fire: 2, turn: 30, run: false, invert: false }, save: rndBytes(0x8000, 14) }, { kind: 'wolf', pack: S.sod }, { kind: 'gb', rom: S.gbcTrim }, { kind: 'gb', rom: S.gb256, save: new Uint8Array(0) }, { kind: 'sms', rom: S.sms1, keys: [1, 2, 3], inv: true, save: rndBytes(0x20000, 15) }, { kind: 'pm', rom: S.pm1, inv: true }, { kind: 'ab', rom: S.abOdd, inv: true, keys: [9, 8, 7, 6, 5, 4, 3, 2, 1] }, { rom: S.fr, figs: [{ name: 'x', data: S.figA }], sess: false }];
  const bigs = () => [{ kind: 'gb', rom: S.gbc2m }, { kind: 'gb', rom: S.gbTrim }, { kind: 'wolf', pack: S.wolf }, { kind: 'gb', rom: S.gbc1m }];
  const sets = [['small', small, {}], ['small.en', small, { lang: 'en', clock: false, nfc: false, noClock: true }], ['small.launch', small, { launch: true, dlApp: B.gb }], ['mid', mid, {}], ['mid.launch', mid, { launch: true, lang: 'en', noResv: true }], ['bigs', bigs, {}], ['bigs.launch', bigs, { launch: true }],
    ['keep', small, { keep: [[0xC00000, 0xD40000], [0xF80000, 0x1000000]], launch: true }], ['thirteen', () => new Array(13).fill({ rom: S.v46 }), {}], ['twelve', () => new Array(12).fill(0).map(() => ({ rom: S.v48 })), { launch: true }]];
  const reads = [];
  for (const [n, mk, o] of sets) {
    T(ed + '.apps.' + n, () => { const r = E.appsPlace(rom, mk(), APPS(), o); reads.push([n, r]); return placedStr(r); });
  }
  for (const [n, r] of reads) {
    T(ed + '.apps.' + n + '.read', () => E.appsRead(r.rom, r.list.map((l) => ({ src: l.src, name: l.name }))).map(xStr).join(' | '));
    T(ed + '.apps.' + n + '.cfg', () => r.list.map((l) => cfgStr(E.extraCfg(r.rom, l.off))).join(' | '));
    T(ed + '.apps.' + n + '.clear', () => { const back = E.appsRead(r.rom, r.list), c = E.appsClear(r.rom, back), c1 = E.appsClear(r.rom, back.slice(1)); return sha(c) + ' ' + sha(c1) + ' base=' + bo(Buffer.from(c).equals(Buffer.from(rom))) + ' ' + sha(E.appsClear(r.rom, null)); });
    T(ed + '.apps.' + n + '.again', () => { const back = E.appsRead(r.rom, r.list); const o2 = sets.find((s) => s[0] === n)[2]; const r2 = E.appsPlace(E.appsClear(r.rom, back), back, APPS(), o2); return placedStr(r2) + ' same=' + bo(Buffer.from(r2.rom).equals(Buffer.from(r.rom))); });
    T(ed + '.apps.' + n + '.hiFree', () => { const a = E.hiFree(r.rom, r.list.map((l) => l.off)), b = E.hiFree(r.rom, []); return bo(a === r.rom) + sha(a) + ' ' + bo(b === r.rom) + sha(b); });
  }
  const full = () => ({ t7: t7app(), v1: v1app(), tama: B.emu, t18: t18app(), doom: { app: B.doomApp, xip: B.doomXip }, gb: B.gb, gbc: B.gbc, sms: B.sms, pm: B.pm, ab: B.ab, wolf: B.wolf, wolfsod: B.wolfsod });
  const miss = [['t7', { rom: S.go }, (A) => { A.t7 = null; }], ['v1', { rom: S.v46 }, (A) => { A.v1 = null; }], ['gb', { kind: 'gb', rom: S.gb32 }, (A) => { A.gb = B.t7; }], ['gbc', { kind: 'gb', rom: S.gbcTrim }, (A) => { A.gbc = B.gb; }], ['sms', { kind: 'sms', rom: S.smsNo }, (A) => { A.sms = B.t7; }],
    ['pm', { kind: 'pm', rom: S.pmS }, (A) => { A.pm = B.t7; }], ['ab', { kind: 'ab', rom: S.abOdd }, (A) => { A.ab = B.t7; }], ['wolf', { kind: 'wolf', pack: S.wolfSh }, (A) => { A.wolf = new Uint8Array(0x20001); }], ['sod', { kind: 'wolf', pack: S.sod }, (A) => { A.wolfsod = B.gb; }],
    ['tama', { kind: 'tama', guest: S.fws['pc.50'], dev: 'pc' }, (A) => { A.tama = null; }], ['tama2', { kind: 'tama', guest: S.fws['pc.50'], dev: 'pc' }, (A) => { A.tama = B.t7; }], ['t18', { kind: 't18', fw: S.fw18 }, (A) => { A.t18 = new Uint8Array(B.t18); }], ['doom', { kind: 'doom', mcu: S.wadC }, (A) => { A.doom = null; }], ['doom2', { kind: 'doom', mcu: S.wadC }, (A) => { A.doom = { app: B.gb, xip: B.doomXip }; }], ['full', { kind: 'ab', rom: S.abOdd }, () => {}]];
  T(ed + '.apps.missing', () => miss.map(([k, x, f]) => { const A = full(); f(A); try { E.appsPlace(rom, [x], A, { launch: true }); return k + '=ok'; } catch (e) { return k + '=' + e.message; } }).join(' ; '));
  T(ed + '.apps.bad', () => [[{ kind: 'zz' }], [{ rom: S.gb32 }], [{ kind: 'ab', rom: rndBytes(0x8001, 1) }], [{ kind: 'wolf', pack: rndBytes(100, 2) }], [{ kind: 'tama', guest: S.fws['pc.50'], dev: 'pc' }], [{ kind: 't18', fw: S.fw18 }], [{ kind: 'doom', mcu: S.wadC }], [{ kind: 'doom' }]].map((xs, i) => { try { E.appsPlace(rom, xs, APPS(), { launch: i === 7 }); return 'ok'; } catch (e) { return e.message; } }).join(' ; '));
  // start device: the colour Tamas, T18Emu, DOOM
  const tamaSets = [['pc', [{ kind: 'tama', guest: S.fws['pc.50'], dev: 'pc', opt: { vol: 1, dim: 3, off: 2 } }], { launch: true }], ['id.pack', [{ kind: 'tama', guest: S.fws['id.50'], dev: 'pc', pack: true, nfc: false, sess: false }, { rom: S.v46 }], { launch: true, lang: 'en' }],
    ['idl', [{ kind: 'tama', guest: S.fws['idl.40'], dev: 'idl' }], { launch: true }], ['idl.pack', [{ kind: 'tama', guest: S.fws['idl.62'], dev: 'idl', pack: true, clock: false }], { launch: true, txSpare: 0x20000 }], ['ps', [{ kind: 'tama', guest: S.fws['ps.45'], dev: 'ps' }, { kind: 'gb', rom: S.gb32 }], { launch: true }],
    ['4u.big', [{ kind: 'tama', guest: S.fws['4u.95'], dev: '4u' }], { launch: true }], ['4u.big.pack', [{ kind: 'tama', guest: S.fws['4u.95'], dev: '4u', pack: true }], { launch: true }], ['lzAll', [{ kind: 'tama', guest: S.fws['pc.50'], dev: 'pc', pack: true, lzAll: true }], { launch: true }], ['lzExtra', [{ kind: 'tama', guest: S.fws['idl.40'], dev: 'idl', pack: true, lzExtra: [0x0b, 0x40] }], { launch: true }],
    ['two', [{ kind: 'tama', guest: S.fws['pc.50'], dev: 'pc' }, { kind: 'tama', guest: S.fws['pc.100'], dev: 'pc', pack: true }, { kind: 'sms', rom: S.gg, gg: true }], { launch: true, dlApp: B.gb }],
    ['t18', [{ kind: 't18', fw: S.fw18, opt: { vol: 3, dim: 1, off: 0 } }, { rom: S.v46 }], { launch: true }], ['t18.few', [{ kind: 't18', fw: S.fw18s, sess: false, clock: false }], { launch: true, t18More: false, noResv: true, lang: 'en' }], ['t18.two', [{ kind: 't18', fw: S.fw18 }, { kind: 't18', fw: S.fw18s }], { launch: true }], ['t18.big', [{ kind: 't18', fw: S.fw18big }, { kind: 'gb', rom: S.gb256 }], { launch: true }],
    ['doom', [{ kind: 'doom', mcu: S.wadA, keys: { fire: 4, run: true, invert: false, mod: 2 }, save: rndBytes(0x3000, 16) }, { kind: 'ab', rom: S.abOdd }], { launch: true }], ['doom.two', [{ kind: 'doom', mcu: S.wadB, region: 0x100000 }, { kind: 'doom', mcu: S.wadA, title: 'SECOND' }], { launch: true }], ['mixed', [{ rom: S.v46 }, { kind: 'tama', guest: S.fws['pc.50'], dev: 'pc', pack: true }, { kind: 't18', fw: S.fw18s }, { kind: 'pm', rom: S.pmS }, { kind: 'wolf', pack: S.wolfSh }], { launch: true }]];
  const reads2 = [];
  for (const [n, xs, o] of tamaSets) {
    if (!first && !/^(pc|idl\.pack|t18|doom|mixed)$/.test(n)) continue;
    T(ed + '.start.' + n, () => { const r = E.appsPlace(rom, xs, APPS(), o); reads2.push([n, r, xs, o]); return placedStr(r); });
  }
  for (const [n, r, xs, o] of reads2) {
    let back = [];
    T(ed + '.start.' + n + '.read', () => { back = E.appsRead(r.rom, r.list); return back.map(xStr).join(' | ') + ' same=' + back.map((x, i) => bo(Buffer.from(x.guest || x.fw || x.mcu || x.rom || x.pack).equals(Buffer.from(xs[i].guest || xs[i].fw || xs[i].mcu || xs[i].rom || xs[i].pack)))).join(''); });
    T(ed + '.start.' + n + '.cfg', () => r.list.map((l) => cfgStr(E.extraCfg(r.rom, l.off))).join(' | ') + ' packed=' + E.appsPacked(r.rom, r.list).join(','));
    T(ed + '.start.' + n + '.clear', () => { const c = E.appsClear(r.rom, back); return sha(c) + ' base=' + bo(Buffer.from(c).equals(Buffer.from(rom))); });
    T(ed + '.start.' + n + '.hiFree', () => { const a = E.hiFree(r.rom, r.list.map((l) => l.off), 0xFE0000), b = E.hiFree(r.rom, []); return bo(a === r.rom) + sha(a) + ' ' + bo(b === r.rom) + sha(b); });
    if (n === 't18' || n === 'mixed') T(ed + '.start.' + n + '.keep', () => { const t = back.find((x) => x.kind === 't18'); E.t18ItemAdd(t.fw, S.sc('meal'), 3); E.t18ItemAdd(t.fw, S.sc('place')); const xs2 = back.map((x) => (x === t ? Object.assign({}, x, { keepOff: x.off, items: true, opt: { vol: 1, dim: 2, off: 3 } }) : x));
      const cl = E.appsClear(r.rom, back.filter((x) => x !== t)), r2 = E.appsPlace(cl, xs2, APPS(), Object.assign({}, o, { lang: 'en' })), b2 = E.appsRead(r2.rom, r2.list); return placedStr(r2) + ' ' + b2.map(xStr).join(' | ') + ' items=' + itemsStr(E.t18Items(b2.find((x) => x.kind === 't18').fw)); });
    if (n === 'pc' || n === 'idl.pack') T(ed + '.start.' + n + '.pages', () => { const x = back[0], c = E.extraCfg(r.rom, x.off), img = new Uint8Array(r.rom); const lo = (c.guestOff + c.guestSize + 0x1FFF) & ~0x1FFF, data = lo + 0x2000;
      // the device wrote two pages of an empty block and (packed) erased a packed block
      let fb = -1; for (let b = 1; b < 0x40; b++) if (c.map[b] === 0xFF && !(c.lzOff && u32(img, c.lzOff + 4 * b))) { fb = b; break; }
      const n0 = Math.min(64, ((c.spareEnd & ~0x1FFF) - data) >> 13), vp = []; for (let i = 0; i < 64; i++) vp.push(img[lo + 16 + 2 * i] | (img[lo + 17 + 2 * i] << 8));
      let fi = vp.indexOf(0xFFFF); if (u32(img, lo) !== 0x50584D50) { fi = 0; vp.fill(0xFFFF); img.fill(0xFF, lo, lo + 0x1000); }
      vp[fi] = fb << 3; vp[fi + 1] = (fb << 3) + 5; fillRnd(img, data + (fi << 13), 0x4000, 21);
      let gone = -1; if (c.lzOff) { for (let b = 0; b < 128; b++) if (u32(img, c.lzOff + 4 * b)) { gone = b; break; } w32(img, lo + 144 + 4 * (gone >> 5), 1 << (gone & 31)); let gx = 0x454E4F47; for (let i = 0; i < 4; i++) gx = (gx ^ u32(img, lo + 144 + 4 * i)) >>> 0; w32(img, lo + 160, gx); vp[fi + 2] = (gone << 3) + 1; fillRnd(img, data + ((fi + 2) << 13), 0x2000, 22); }
      let xx = (0x50584D50 ^ Math.imul(n0, 0x9E3779B1)) >>> 0; for (let i = 0; i < 64; i++) { img[lo + 16 + 2 * i] = vp[i] & 255; img[lo + 17 + 2 * i] = vp[i] >> 8; xx = (((xx << 5) | (xx >>> 27)) ^ vp[i]) >>> 0; }
      w32(img, lo, 0x50584D50); w32(img, lo + 4, n0); w32(img, lo + 8, xx);
      const b2 = E.appsRead(img, r.list); return 'fb=' + hx(fb) + ' gone=' + gone + ' ' + H(b2[0].guest) + ' same=' + bo(Buffer.from(b2[0].guest).equals(Buffer.from(x.guest))); });
  }
}
function cleanRom(S) {
  const blank = new Uint8Array(0x1000000).fill(0xFF);
  const sets = [['doom', [{ kind: 'doom', mcu: S.wadA }], {}], ['doom.link', [{ kind: 'doom', mcu: S.wadA, keys: { fwd: 1, back: 2, use: 4, run: false } }, { kind: 'doom', mcu: S.wadB, ep: 5 }, { kind: 'doom', mcu: S.wadC, name: 'TINY' }], { lang: 'en' }], ['doom.top', [{ kind: 'doom', mcu: S.wadB }, { kind: 'doom', mcu: S.wadA }], { doomTop: true }],
    ['all', [{ rom: S.go }, { rom: S.v46 }, { rom: S.v3 }, { kind: 'gb', rom: S.gbc2m }, { kind: 'sms', rom: S.gg }, { kind: 'pm', rom: S.pm1 }, { kind: 'ab', rom: S.abData }, { kind: 'wolf', pack: S.wolf }, { kind: 'tama', guest: S.fws['idl.40'], dev: 'idl' }, { kind: 't18', fw: S.fw18 }, { kind: 'doom', mcu: S.wadA }, { kind: 'tama', guest: S.fws['pc.50'], dev: 'pc', pack: true }], { dlApp: B.gb, noClock: true }],
    ['tamas', [{ kind: 'tama', guest: S.fws['4u.95'], dev: '4u' }, { kind: 'tama', guest: S.fws['ps.45'], dev: 'ps', pack: true }], { txSpare: 0x30000 }], ['full', [{ kind: 'tama', guest: S.fws['4u.95'], dev: '4u', pack: true }, { kind: 'tama', guest: S.fws['idl.85'], dev: 'idl' }, { kind: 'tama', guest: S.fws['ps.70'], dev: 'ps' }, { kind: 'tama', guest: S.fws['idl.62'], dev: 'idl' }], {}],
    ['full.packed', [{ kind: 'tama', guest: S.fws['4u.95'], dev: '4u', pack: true }, { kind: 'tama', guest: S.fws['idl.85'], dev: 'idl', pack: true }, { kind: 'tama', guest: S.fws['ps.70'], dev: 'ps', pack: true }, { kind: 'tama', guest: S.fws['idl.62'], dev: 'idl', pack: true }, { kind: 'tama', guest: S.fws['4u-plain.66'], dev: '4u-plain', pack: true }], {}]];
  for (const [n, xs, o] of sets) {
    let r = null, back = [];
    T('clean.' + n, () => { r = E.appsPlace(blank, xs, APPS(), Object.assign({ clean: true, launch: true }, o)); return placedStr(r); });
    if (!r) continue;
    T('clean.' + n + '.read', () => { back = E.appsRead(r.rom, r.list); return back.map(xStr).join(' | ') + ' same=' + back.map((x, i) => bo(Buffer.from(x.guest || x.fw || x.mcu || x.rom || x.pack).equals(Buffer.from(xs[i].guest || xs[i].fw || xs[i].mcu || xs[i].rom || xs[i].pack)))).join(''); });
    T('clean.' + n + '.cfg', () => r.list.map((l) => cfgStr(E.extraCfg(r.rom, l.off)) + '/' + cfgStr(E.doomCfg(r.rom, l.off))).join(' | ') + ' packed=' + E.appsPacked(r.rom, r.list).join(','));
    T('clean.' + n + '.clear', () => sha(E.appsClear(r.rom, back)));
  }
  T('clean.noclean.doom', () => placedStr(E.appsPlace(blank, [{ kind: 'doom', mcu: S.wadA }], APPS(), {})));
  T('clean.t18Free', () => E.t18Free(blank).length + ',' + E.t18Free(blank, true).length + ' ' + resStr(E.appReserved(blank)) + ' ' + cfgStr(E.extraCfg(blank, 0xA0000)));
  T('clean.sceneTable', () => Object.keys(E.sceneTable(blank)).length);
  T('clean.hiFree', () => bo(E.hiFree(blank, []) === blank));
}

const S = pure();
for (const ed of EDS) onRom(ed, new Uint8Array(fs.readFileSync(path.join(DUMPS, ed + '.bin'))), S);
cleanRom(S);
console.log(lines.join('\n'));
