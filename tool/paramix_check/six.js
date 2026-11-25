// Check of lib/paramix/six.dart against Paramix Studio's six.js (the original, run in Node).
// DUMPS=<folder with water.bin land.bin sky.bin jade.bin tropical.bin glacier.bin neon.bin> node tool/paramix_check/six.js
// Prints one line per case (hashes, sizes, values only); the output must equal that of six_check.dart.
'use strict';
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const SRC = path.join(__dirname, '../../third_party/paramix-studio');
const C = require(SRC + '/src/core.js'); globalThis.ParamixCore = C;
const S = require(SRC + '/src/six.js');
// build.js fills the placeholder __SIX_B64__ with six/six.bin; here the file is passed in directly
const blob = new Uint8Array(fs.readFileSync(SRC + '/six/six.bin'));
const D = process.env.DUMPS;
if (!D) { console.error('DUMPS is not set'); process.exit(2); }
const NAMES = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];
const rom = {}; for (const n of NAMES) rom[n] = new Uint8Array(fs.readFileSync(path.join(D, n + '.bin')));
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const same = (a, b) => a.length === b.length && Buffer.compare(Buffer.from(a.buffer, a.byteOffset, a.length), Buffer.from(b.buffer, b.byteOffset, b.length)) === 0;
let count = 0;
function line(name, v) { console.log(name + ' ' + v); count++; }
function run(name, fn) { let v; try { v = fn(); } catch (e) { v = 'ERR ' + e.message; } line(name, v); }
const info = (r) => JSON.stringify(S.sixInfo(r));
const romLine = (name, r) => { line(name, r.length + ' ' + sha(r)); line(name + '.info', info(r)); };

// A. every edition as it is
for (const n of NAMES) {
  const r = rom[n];
  line(n + '.kindOf', S.kindOf(r)); line(n + '.sixCan', S.sixCan(r)); line(n + '.sixSource', S.sixSource(r));
  line(n + '.sixNeedsSource', S.sixNeedsSource(r)); line(n + '.sixInfo', info(r)); line(n + '.sixStale', S.sixStale(S.sixInfo(r)));
  line(n + '.sixDnaCan', S.sixDnaCan(r));
  line(n + '.sixStrip.same', S.sixStrip(r) === r); line(n + '.sixFix.same', S.sixFix(r) === r);
  line(n + '.sixHunt.same', S.sixHunt(r) === r); line(n + '.sixDna.same', S.sixDna(r, blob, true) === r);
}
line('sixSource.null', S.sixSource(null)); line('sixStale.null', S.sixStale(null));
line('const', [S.VERSION, S.DNA, S.HUNT, S.FLAG_OFF, S.SIX_OFF].join(','));

// B. maps
function cellsHash(m) {
  const h = crypto.createHash('sha256');
  for (const c of m.cells) h.update(c);
  const f = new Float64Array(m.pal.length * 3); m.pal.forEach((p, i) => f.set(p, 3 * i));
  h.update(Buffer.from(f.buffer));
  return m.cells.length + ' ' + m.cells.reduce((a, c) => a + c.length, 0) + ' ' + h.digest('hex');
}
function packLine(name, p) {
  p.forEach((e, j) => line(name + '.' + j, e.length + ' ' + sha(e)));
  line(name + '.outside', sha(Buffer.from(JSON.stringify(p.outside))));
  line(name + '.bdata', p.bdata.length + ' ' + sha(p.bdata));
}
for (const n of ['tropical', 'glacier', 'land', 'water', 'sky', 'jade']) {
  const ent = C.openRom(rom[n]).entries, maps = [];
  ent.forEach((e, i) => { if (e.length >= 24 && e[5] === 3 && (e[4] & 0x20) && (e[6] | (e[7] << 8)) === 64) maps.push(i); });
  line(n + '.maps', maps.length + ' ' + maps.slice(0, 3).join(','));
  run(n + '.mapCells.err', () => cellsHash(S.mapCells(ent[0])));
  const first = maps.slice(0, 3);
  first.forEach((i) => run(n + '.mapCells.' + i, () => cellsHash(S.mapCells(ent[i]))));
  for (const k of [128, 16]) run(n + '.reduceOne.' + k, () => { const e = S.reduceOne(ent[first[0]], k); return e.length + ' ' + sha(e); });
  const group = () => first.map((i) => { const m = S.mapCells(ent[i]); m.h.raw = ent[i]; return m; });
  packLine(n + '.packGroup.128', S.packGroup(group(), 128));
  packLine(n + '.packGroup.64ext', S.packGroup(group(), 64, [false, false, true]));
  packLine(n + '.packGroup.300', S.packGroup(group().slice(0, 2), 300, [true, false]));
}

// C. Tropical/Glacier with Land, Water, Sky
const VAR = { planet0: { planet: false }, menu0: { fieldMenu: false }, games0: { games: false }, dna0: { dna: false }, hunt0: { hunt: false }, cook0: { cook: false },
  huntcook0: { hunt: false, cook: false }, all0: { planet: false, fieldMenu: false, games: false, dna: false, hunt: false, cook: false } };
const rebuild = (r) => C.buildRom(C.openRom(r), new Map(), null).rom;
for (const t of ['tropical', 'glacier']) {
  const built = {};
  for (const l of ['land', 'water', 'sky']) { built[l] = S.sixApply(rom[t], rom[l], blob); romLine('apply.' + t + '.' + l, built[l]); }
  const l = t === 'tropical' ? 'land' : 'sky', six = built[l], p = 'six.' + t + '.' + l;
  const v = {};
  for (const [k, o] of Object.entries(VAR)) { v[k] = S.sixApply(rom[t], rom[l], blob, o); romLine(p + '.' + k, v[k]); }
  line(p + '.kindOf', S.kindOf(six)); line(p + '.sixCan', S.sixCan(six)); line(p + '.sixSource', S.sixSource(six));
  line(p + '.sixNeedsSource', S.sixNeedsSource(six)); line(p + '.sixStale', S.sixStale(S.sixInfo(six))); line(p + '.sixDnaCan', S.sixDnaCan(six));
  const st = S.sixStrip(six); line(p + '.strip', sha(st)); line(p + '.strip.base', same(st, rom[t]));
  for (const k of ['games0', 'dna0', 'all0']) line(p + '.' + k + '.strip', sha(S.sixStrip(v[k])));
  line(p + '.again.same', S.sixApply(six, rom[l], blob) === six);
  line(p + '.again.nosrc.same', S.sixApply(six, null, blob) === six);
  run(p + '.again.menu0', () => sha(S.sixApply(six, rom[l], blob, { fieldMenu: false })));
  run(p + '.again.othersrc', () => sha(S.sixApply(six, rom.water, blob, { planet: false })));
  run(p + '.again.menu0.nosrc', () => sha(S.sixApply(six, null, blob, { fieldMenu: false })));
  const off = S.sixDna(six, blob, false); romLine(p + '.dnaOff', off);
  line(p + '.dnaOff.is.dna0', same(off, v.dna0));
  const on = S.sixDna(off, blob, true); line(p + '.dnaOn', sha(on)); line(p + '.dnaOn.six', same(on, six));
  line(p + '.dnaOn.noblob.same', S.sixDna(off, null, true) === off);
  line(p + '.dnaOn.again.same', S.sixDna(six, blob, true) === six);
  const hc = S.sixHunt(v.huntcook0); romLine(p + '.sixHunt', hc); line(p + '.sixHunt.six', same(hc, six));
  romLine(p + '.sixHunt.hunt0', S.sixHunt(v.hunt0)); romLine(p + '.sixHunt.cook0', S.sixHunt(v.cook0));
  run(p + '.apply.dna0', () => { const r = S.sixApply(v.dna0, null, blob); return sha(r) + ' ' + same(r, six); });
  run(p + '.apply.huntcook0', () => { const r = S.sixApply(v.huntcook0, null, blob); return sha(r) + ' ' + same(r, six); });
  run(p + '.apply.dnaOffOpt', () => { const r = S.sixApply(six, null, blob, { dna: false }); return sha(r) + ' ' + same(r, off); });
  line(p + '.sixFix', sha(S.sixFix(six)));
  const moved = rebuild(six); line(p + '.moved', sha(moved));
  const fixed = S.sixFix(moved); line(p + '.moved.sixFix', sha(fixed)); line(p + '.moved.sixFix.six', same(fixed, six));
}

// D. Jade Forest
{
  const j = rom.jade, six = S.sixApply(j, null, blob), p = 'six.jade';
  romLine('apply.jade', six);
  line('apply.jade.land.is', same(S.sixApply(j, rom.land, blob), six));
  const v = {};
  for (const [k, o] of Object.entries(VAR)) { v[k] = S.sixApply(j, null, blob, o); romLine(p + '.' + k, v[k]); }
  line(p + '.kindOf', S.kindOf(six)); line(p + '.sixCan', S.sixCan(six)); line(p + '.sixNeedsSource', S.sixNeedsSource(six));
  line(p + '.sixStale', S.sixStale(S.sixInfo(six))); line(p + '.sixDnaCan', S.sixDnaCan(six));
  const st = S.sixStrip(six); line(p + '.strip', sha(st)); line(p + '.strip.base', same(st, j));
  line(p + '.all0.strip', sha(S.sixStrip(v.all0)));
  line(p + '.again.same', S.sixApply(six, null, blob) === six);
  run(p + '.again.menu0', () => sha(S.sixApply(six, null, blob, { fieldMenu: false })));
  const off = S.sixDna(six, blob, false); romLine(p + '.dnaOff', off); line(p + '.dnaOff.is.dna0', same(off, v.dna0));
  const on = S.sixDna(off, blob, true); line(p + '.dnaOn', sha(on)); line(p + '.dnaOn.six', same(on, six));
  const hc = S.sixHunt(v.huntcook0); romLine(p + '.sixHunt', hc); line(p + '.sixHunt.six', same(hc, six));
  run(p + '.apply.dna0', () => { const r = S.sixApply(v.dna0, null, blob); return sha(r) + ' ' + same(r, six); });
  line(p + '.sixFix.same', S.sixFix(six) === six);
  run(p + '.shortblob', () => sha(S.sixApply(j, null, blob.slice(0, 0xC40))));
}

// E. errors
run('err.land', () => sha(S.sixApply(rom.land, rom.sky, blob)));
run('err.neon', () => sha(S.sixApply(rom.neon, rom.land, blob)));
run('err.src.tropical', () => sha(S.sixApply(rom.tropical, rom.tropical, blob)));
run('err.src.null', () => sha(S.sixApply(rom.glacier, null, blob)));
run('err.src.jade', () => sha(S.sixApply(rom.glacier, rom.jade, blob)));
run('err.blob.null', () => sha(S.sixApply(rom.tropical, rom.land, null)));
run('err.blob.short', () => sha(S.sixApply(rom.tropical, rom.land, blob.slice(0, 3))));
run('err.blob.version', () => { const b = blob.slice(); b[4] ^= 1; return sha(S.sixApply(rom.jade, null, b)); });
run('err.blob.long', () => sha(S.sixApply(rom.jade, null, new Uint8Array(0x1001))));
run('err.area', () => { const r = rom.jade.slice(); r[0x10F800] = 0; return sha(S.sixApply(r, null, blob)); });
run('err.areaB', () => { const r = rom.tropical.slice(); r[0xF12345] = 0; return sha(S.sixApply(r, rom.land, blob)); });
run('err.firmware', () => { const r = rom.tropical.slice(); r[0x11000 + 0xAEAC] ^= 1; return sha(S.sixApply(r, rom.land, blob)); });
run('err.gameplace', () => { const r = rom.tropical.slice(); r[0x10050b1e - 0x10000000 + 0x11000 + 2] ^= 1; return sha(S.sixApply(r, rom.land, blob)); });
run('ok.gameplace.games0', () => { const r = rom.tropical.slice(); r[0x10050b1e - 0x10000000 + 0x11000 + 2] ^= 1; return sha(S.sixApply(r, rom.land, blob, { games: false })); });
run('ok.nomenu', () => { const r = rom.glacier.slice(); r[0x11000 + 0x41496 + 2] ^= 1; const o = S.sixApply(r, rom.water, blob); return sha(o) + ' ' + info(o); });
run('ok.nodna', () => { const r = rom.tropical.slice(); r[0x10081C68 - 0x10000000 + 0x11000] ^= 1; const o = S.sixApply(r, rom.sky, blob); return sha(o) + ' ' + info(o); });
run('ok.nohunt', () => { const r = rom.jade.slice(); r[0x11000 + 0x3DEE2] ^= 1; const o = S.sixApply(r, null, blob); return sha(o) + ' ' + info(o); });
console.error(count + ' cases');
