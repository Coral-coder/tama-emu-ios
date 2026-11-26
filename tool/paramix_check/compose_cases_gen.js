// Writes tool/paramix_check/compose_cases.json: the cases of compose.js / compose_check.dart.
//   node tool/paramix_check/compose_cases_gen.js
// A case is [name, steps]; the steps are explained in compose_cases.md.
'use strict';
const fs = require('fs'), path = require('path');
const EDS = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];
const A0 = ['water', 'land', 'sky'];          // room for a main program at 0x0A0000
const NOA0 = ['jade', 'tropical', 'glacier', 'neon'];
const cases = [];
const C = (name, ...steps) => cases.push([name, steps.flat(1).filter(Boolean)]);
// steps
const open = (ed) => [['open', ed]];
const set = (k, v) => [['set', k, v]];
const fw = (spec, name) => [name ? ['fw', spec, name] : ['fw', spec]];
const save = [['save']], compose = [['compose']], plan = [['plan']], state = [['state']], reopen = [['reopen']];
const sps = [['state'], ['plan'], ['save']];       // look, then build
const again = [['reopen'], ['state'], ['plan'], ['save']];   // load what was built: read back, nothing to do
const row = (key, what, a, b) => [['row', key, what, a, b].filter((x) => x !== undefined)];
const chk = (key, label, v) => row(key, 'check', label, v);
const sel = (key, label, v) => row(key, 'sel', label, v);
// synthetic programs
const P = { idl: 'tama:idl:30:77', idl2: 'tama:idl:30:23', pc: 'tama:pc:40:11', ps: 'tama:ps:30:21', u4: 'tama:4u:30:31', u4p: 'tama:4u-plain:25:41', full: 'tama:idl:100:55',
  go: 't7:go:5', go2: 't7:go:6', fr: 't7:friends:7', t18: 't18:131:0:38', t18b: 't18:132:1:30', v1: 'v1:12288:61', v1b: 'v1:16384:62', v3: 'v3:63',
  gb: 'gb:0:0:TETRIS:71', gb2: 'gb:3:0:ZELDA:72', gbc: 'gb:5:128:GOLD:74', sms: 'sms:131072:4:91', sms2: 'sms:32768:3:92', gg: 'sms:262144:6:93', pm: 'pm:524288:101', pm2: 'pm:8704:102', bios: 'pmbios:104',
  ab: 'ab:8192:111', ab2: 'ab:20000:112', wolf: 'wolf:1193046:0:121', wolfSh: 'wolf:393216:1:122', sod: 'wolf:589824:2:123', fig: 'fig:1048576:196608:51', fig2: 'fig:262144:74565:55',
  wad: 'wad:1:900:700:5', wad3: 'wad:123:900:700:6', wadBig: 'wad:1:6000:5000:7', wadMid: 'wad:1:5000:3000:8', wadM: 'wad:M:3000:2500:9', iw1: 'iwad:8193:1:2', iw3: 'iwad:8194:123:2', iwM: 'iwad:8197:M:3' };

// ---------------------------------------------------------------- A. every edition as it is
for (const ed of EDS) C('orig.' + ed, open(ed), state, [['names']], plan, save);
C('load.bad', [['open', 'water']], [['openSyn', 'rnd:4096:1']], [['openSyn', 'junk:17000000:2']]);

// ---------------------------------------------------------------- B. names
for (const ed of EDS) {
  C('names.' + ed, open(ed), [['name', 'fields', 0, 'my island']], [['name', 'fields', 2, 'HOME & CO.']], [['name', 'chars', 0, 'Bernd 1']], [['name', 'chars', 5, 'x?y!z/w\'q']], [['name', 'items', 3, 'an item with a long name 123']],
    [['name', 'items', 0, 'ÄÖ*#<>']], state, plan, save, reopen, state, [['names']], plan, save,
    [['name', 'chars', 0, 'OTHER']], [['name', 'fields', 0, '']], save, reopen, [['names']], save);
}
C('names.back.water', open('water'), [['name', 'chars', 1, 'ABC']], [['name', 'chars', 1, '']], state, save);
C('names.menu.water', open('water'), set('feld', true), set('bag', true), [['name', 'fields', 1, 'LAKE']], [['name', 'items', 1, 'CAKE']], save, again, [['name', 'fields', 1, 'POND']], save, again);

// ---------------------------------------------------------------- C. menu options
for (const ed of EDS) {
  for (const k of ['feld', 'bag', 'tama', 'gplay']) C('menu.' + k + '.' + ed, open(ed), set(k, true), sps, again);
  C('menu.all.' + ed, open(ed), set('feld', true), set('bag', true), set('tama', true), set('gplay', true), sps, again,
    set('tama', false), plan, save, again, set('feld', false), set('bag', false), set('gplay', false), plan, save, again);
  C('menu.exit.' + ed, open(ed), set('bag', true), set('exit', 2), sps, again, set('exit', 1), save, again, set('exit', 0), save, again);
}
C('menu.exitonly.water', open('water'), set('exit', 3), save);

// ---------------------------------------------------------------- D. more fields
for (const ed of ['tropical', 'glacier']) {
  for (const src of ['land', 'water', 'sky']) C('six.' + ed + '.' + src, open(ed), set('sixOn', true), [['sixSrc', src]], state, [['names']], plan, save, again);
  C('six.opts.' + ed, open(ed), set('sixOn', true), [['sixSrc', 'land']], set('sixPlanet', false), set('sixMenu', false), set('bag', true), set('tama', true), sps, again,
    set('sixPlanet', true), save, [['sixSrc', 'water']], save, again, set('sixMenu', true), [['sixSrc', 'land']], [['name', 'fields', 3, 'MEADOW']], [['name', 'fields', 0, 'BEACH']], save, again,
    set('sixOn', false), state, plan, save, again);
  C('six.need.' + ed, open(ed), set('sixOn', true), state, save, [['sixBad', 'rnd:16777216:3']], save, [['sixSrc', ed === 'tropical' ? 'glacier' : 'tropical']], save, set('sixOn', false), save);
  C('six.apps.' + ed, open(ed), set('sixOn', true), [['sixSrc', 'sky']], fw(P.go), save, row('x0', 'del'), save, reopen, set('launch', true), fw(P.go), save);
}
C('six.jade', open('jade'), set('sixOn', true), state, [['names']], plan, save, again, [['name', 'fields', 3, 'CLOUDS']], save, again, set('sixPlanet', false), save, again, set('sixOn', false), plan, save, again);
C('six.jade.menu', open('jade'), set('sixOn', true), set('feld', true), set('bag', true), set('tama', true), set('gplay', true), sps, again, set('feld', false), save, again);
C('six.none.water', open('water'), set('sixOn', true), state, save);

// ---------------------------------------------------------------- E. the main program at 0x0A0000
for (const ed of A0) {
  for (const k of ['idl', 'pc', 'ps', 'u4', 'u4p', 'go', 'fr', 't18', 'v1', 'v1b', 'v3']) {
    if (ed !== 'water' && !['idl', 'go', 't18', 'v1'].includes(k)) continue;
    C('main.' + k + '.' + ed, open(ed), fw(P[k]), sps, again);
  }
}
C('main.set.idl', open('water'), fw(P.idl), chk('main', 'emuAuto', true), chk('main', 'emuClock', false), chk('main', 'emuSess', false), sel('main', 'optVol', 2), sel('main', 'optDim', 3), sel('main', 'optScr', 5), sps, again,
  chk('main', 'emuAuto', false), sel('main', 'optDim', 10), save, again, chk('main', 'emuClock', true), chk('main', 'emuSess', true), save, again);
C('main.set.4u', open('land'), fw(P.u4), chk('main', 'emuNfc', false), chk('main', 'emuAuto', true), sps, again, chk('main', 'emuNfc', true), save, again);
C('main.pack.idl', open('water'), fw(P.idl), chk('main', 'emuPack', true), sps, again, chk('main', 'emuPack', false), state, save, again);
C('main.pack.after', open('sky'), fw(P.idl2), save, reopen, chk('main', 'emuPack', true), state, plan, save, again);
C('main.full.idl', open('water'), fw(P.full), state, save, chk('main', 'emuPack', true), save, again);
C('main.set.t7', open('water'), fw(P.go), row('main', 'fig', P.fig, 'figure_one.bin'), row('main', 'fig', P.fig2, 'second.bin'), row('main', 'fig', P.fig, 'figure_one.bin'), row('main', 'fig', 'rnd:4096:9', 'nofig.bin'),
  chk('main', 'emuAuto', true), chk('main', 'emuClock', false), sps, again, row('main', 'fig', 'fig:1048576:524288:56', 'third.bin'), state, save, again, chk('main', 'emuSess', false), save, again);
C('main.set.fr', open('land'), fw(P.fr), row('main', 'fig', P.fig), chk('main', 'emuAuto', true), sps, again);
C('main.set.t18', open('water'), fw(P.t18), chk('main', 'emuAuto', true), chk('main', 'emuClock', false), sel('main', 'optVol', 1), sel('main', 'optScr', 2), sps, again, sel('main', 'optVol', 0), save, again);
C('main.pics.t18', open('water'), fw(P.t18), [['raw', 't18pics', 181, 16]], save, again);
C('main.set.v1', open('sky'), fw(P.v1), chk('main', 'emuAuto', true), chk('main', 'emuClock', false), chk('main', 'emuSess', false), sps, again, chk('main', 'emuAuto', false), save, again);
C('main.set.v3', open('water'), fw(P.v3), chk('main', 'emuAuto', true), sps, again);
C('main.menu.idl', open('water'), fw(P.idl), set('feld', true), set('bag', true), set('tama', true), set('gplay', true), chk('main', 'emuAuto', true), sps, again, set('bag', false), save, again);
C('main.menu.t18', open('land'), fw(P.t18), set('bag', true), set('tama', true), sps, again);
C('main.undo', open('water'), fw(P.idl), row('main', 'del'), state, save, fw(P.go), row('main', 'star'), state, save);
C('main.out', open('water'), fw(P.idl), set('bag', true), save, reopen, row('main', 'del'), state, plan, save, again);
C('main.out.undo', open('water'), fw(P.go), save, reopen, row('main', 'del'), row('main', 'undo'), state, save);
C('main.swap', open('water'), fw(P.idl), save, reopen, row('main', 'del'), fw(P.t18), state, plan, save, again, row('main', 'del'), fw(P.v1), save, again, row('main', 'del'), fw(P.go), save, again, row('main', 'del'), fw(P.pc), save, again);
C('main.second', open('water'), fw(P.idl), fw(P.idl2), state, fw(P.t18), state, save, again);
C('main.twice', open('water'), fw(P.go), fw(P.go), fw(P.t18), fw(P.t18b), state, save);
C('main.t7save', open('water'), fw(P.go), save, reopen, [['raw', 't7save', 'rnd:4098:33']], compose, save, again);
C('main.savein.v1', open('water'), fw(P.v1), save, reopen, [['raw', 'saveIn', 'm', 'v1', 'rnd:8192:34']], compose, save, again);
C('main.savein.tama', open('water'), fw(P.idl), save, reopen, [['raw', 'saveIn', 'm', 'tama']], compose, save);
C('main.savein.big', open('land'), fw('tama:idl:70:24'), save, reopen, [['raw', 'saveIn', 'm', 'tama']], compose);
for (const ed of NOA0) C('main.noa0.' + ed, open(ed), fw(P.idl), fw(P.t18), state, save, fw(P.go), state, save, set('bag', true), plan, save, again);
C('main.bad', open('water'), fw('rnd:300000:5', 'what.bin'), fw('rnd:8388608:6', 'big.bin'), state, save);

// ---------------------------------------------------------------- F. programs of the menu
const kinds = { go: fw(P.go), fr: fw(P.fr), v1: fw(P.v1), v3: fw(P.v3), gb: [['gb', P.gb, 'tetris.gb']], gbc: [['gb', P.gbc, 'gold.gbc']], sms: [['sms', P.sms, 'Alex Kidd (E).sms']], gg: [['sms', P.gg, 'sonic.gg']],
  pm: [['pm', P.pm, 'Party mini.min']], ab: [['ab', P.ab, 'arduventure.hex']], wolf: [['wolf', P.wolf]], sod: [['wolf', P.sod]] };
for (const ed of ['water', 'tropical']) for (const k of Object.keys(kinds)) C('app.' + k + '.' + ed, open(ed), set('bag', true), kinds[k], sps, again);
for (const ed of ['land', 'sky', 'jade', 'glacier', 'neon']) C('app.mix.' + ed, open(ed), set('bag', true), kinds.go, kinds.gb, kinds.v1, sps, again);
C('app.nomenu', open('water'), fw(P.idl), fw(P.go), state, plan, save, set('tama', true), save, again, set('tama', false), save);
C('app.nomenu.noa0', open('tropical'), fw(P.go), save, set('feld', true), save, again);
C('app.many.water', open('water'), set('bag', true), set('feld', true), fw(P.idl), kinds.go, kinds.fr, kinds.v1, kinds.v3, kinds.gb, kinds.gbc, kinds.sms, kinds.gg, kinds.pm, kinds.ab, kinds.wolf, kinds.sod, state, plan, save, again,
  fw('v1:16384:62'), state, row('x3', 'del'), row('x0', 'del'), [['gb', P.gb2, 'zelda.gb']], state, plan, save, again);
C('app.max.neon', open('neon'), set('bag', true), kinds.go, kinds.fr, kinds.v1, kinds.v3, kinds.gb, kinds.gbc, kinds.sms, kinds.gg, kinds.pm, kinds.ab, kinds.wolf, kinds.sod, fw(P.v1b), [['gb', P.gb2, 'zelda.gb']], [['wolf', P.wolfSh]], state, plan, save, again);
C('app.twice', open('water'), set('bag', true), kinds.go, kinds.go, kinds.gb, kinds.gb, kinds.v1, fw(P.v1), kinds.pm, kinds.pm, kinds.ab, kinds.ab, state, save);
C('app.set', open('water'), set('bag', true), fw(P.idl), kinds.go, kinds.v1, kinds.gb, kinds.sms, chk('x0', 'emuClock', false), chk('x0', 'emuSess', false), chk('x1', 'emuClock', false), chk('x1', 'emuSess', false), chk('x2', 'emuSess', false), chk('x3', 'emuSess', false),
  chk('x2', 'emuClock', false), state, save, again, chk('x0', 'emuClock', true), chk('x3', 'emuSess', true), state, plan, save, again);
C('app.figs', open('water'), set('bag', true), fw(P.idl), kinds.go, row('x0', 'fig', P.fig, 'one.bin'), row('x0', 'fig', P.fig2, 'two.bin'), row('x0', 'fig', P.fig2, 'two.bin'), kinds.fr, row('x1', 'fig', P.fig), state, save, again, row('x0', 'fig', 'fig:1048576:524288:56', 'three.bin'), save, again);
C('app.keys', open('water'), set('bag', true), kinds.gb, kinds.sms, kinds.pm, kinds.ab, kinds.wolf, [['inv', 'gb', false]], [['inv', 'sms', false]], [['inv', 'pm', false]], [['inv', 'ab', false]], [['wolfKey', 'turn', 30]], [['wolfKey', 'run', false]], state, save, again,
  [['gb', P.gb2, 'zelda.gb']], [['pm', P.bios, 'bios.min']], [['pm', P.pm2, 'small.min']], [['inv', 'gb', true]], [['wolfKey', 'fire', 2]], state, plan, save, again);
C('app.pm.bios', open('land'), set('tama', true), [['pm', P.bios, 'bios.min']], [['pm', P.pm, 'a.min']], [['pm', 'pm:1572864:103', 'big.min']], [['pm', 'rnd:9000:1', 'no.min']], state, save, again);
C('app.wolf.two', open('water'), set('bag', true), kinds.wolf, kinds.sod, [['wolf', P.wolfSh]], state, plan, save, again, row('x0', 'del'), plan, save, again);
C('app.bad', open('water'), set('bag', true), [['gb', 'rnd:32768:1', 'no.gb']], [['sms', 'rnd:5000:1', 'no.sms']], [['ab', 'rnd:100:1', 'no.hex']], [['ab', 'ab:40000:113', 'big.hex']], fw('rnd:300000:5', 'what.bin'), state, save);
C('app.star', open('water'), set('bag', true), fw(P.go), fw(P.go2), fw(P.v1), state, row('x1', 'star'), state, row('x0', 'star'), state, plan, save, again, row('x1', 'star'), state, save, again);
C('app.star.gb', open('water'), set('bag', true), kinds.gb, kinds.go, row('x0', 'star'), row('x1', 'star'), state, save, again);
C('app.star.tama', open('water'), set('bag', true), fw(P.idl), fw(P.go), fw(P.v1), row('x0', 'star'), state, save, row('main', 'del'), state, fw(P.t18), state, save, again);
C('app.take.out', open('water'), set('bag', true), fw(P.go), kinds.gb, kinds.sms, save, reopen, row('x1', 'del'), state, plan, save, again, row('x0', 'del'), row('x0', 'del'), row('main', 'del'), state, plan, save, again, set('bag', false), save, again);
C('app.t7savex', open('water'), set('bag', true), fw(P.idl), kinds.go, kinds.v1, save, reopen, [['raw', 't7saveX', 0, 'rnd:4098:35']], [['raw', 'saveIn', 1, 'v1', 'rnd:8192:36']], compose, save, again, [['raw', 'saveIn', 0, 'tama']], [['raw', 'carry', 0]], compose);

// ---------------------------------------------------------------- G. start device
for (const ed of EDS) {
  C('launch.none.' + ed, open(ed), set('launch', true), state, plan, save, set('feld', true), set('sixOn', true));
  C('launch.go.' + ed, open(ed), set('launch', true), fw(P.go), state, plan, save, again, set('launch', false), set('clean', true), fw(P.v1), state, plan, save, again, row('x0', 'del'), row('main', 'del'), plan, save);
  C('launch.mix.' + ed, open(ed), set('launch', true), fw(P.idl), fw(P.t18), fw(P.go), kinds.gb, kinds.wolf, state, plan, save, again, row('x0', 'star'), state, save, again);
}
C('launch.set', open('water'), set('launch', true), fw(P.u4), fw(P.idl), fw(P.t18), chk('main', 'emuAuto', true), chk('main', 'emuNfc', false), chk('x0', 'emuPack', true), chk('x0', 'emuClock', false), sel('x0', 'optVol', 3), sel('x1', 'optDim', 2), sel('x1', 'optScr', 7),
  state, plan, save, again, chk('x0', 'emuPack', false), chk('main', 'emuAuto', false), sel('x1', 'optDim', 0), state, save, again, set('exit', 1), save, again);
C('launch.set.noa0', open('glacier'), set('launch', true), fw(P.u4), fw(P.idl), fw(P.t18), chk('x0', 'emuNfc', false), chk('x1', 'emuPack', true), chk('x2', 'emuClock', false), sel('x2', 'optVol', 2), state, plan, save, again,
  chk('x1', 'emuPack', false), row('x2', 'del'), state, save, again);
C('launch.t18first', open('land'), set('launch', true), fw(P.t18), fw(P.idl), fw(P.ps), fw(P.go), state, save, again, row('main', 'del'), state, plan, save, again);
C('launch.keep.t18', open('water'), set('launch', true), fw(P.go), fw(P.t18), fw(P.idl), save, reopen, state, fw(P.v1), row('x1', 'del'), state, save, again, row('main', 'del'), state, save, again);
C('launch.swap', open('sky'), set('launch', true), fw(P.idl), fw(P.go), fw(P.v1), save, reopen, row('x1', 'star'), state, save, again, row('x0', 'star'), row('x1', 'del'), save, again);
C('launch.sprites', open('water'), set('launch', true), fw(P.go), [['raw', 'blank', 3, 1]], [['raw', 'eye', 5, 2, -3]], [['name', 'chars', 2, 'STARTER']], state, plan, save, again);
C('launch.off.again', open('water'), set('launch', true), fw(P.go), fw(P.v1), save, reopen, set('launch', false), state, set('launch', true), row('x0', 'del'), save);
C('launch.many', open('land'), set('launch', true), fw(P.idl), fw(P.idl2), fw(P.ps), fw(P.u4), fw(P.pc), state, plan, save, again);
C('launch.full', open('tropical'), set('launch', true), fw(P.idl), fw(P.idl2), fw(P.ps), fw(P.u4), fw(P.u4p), fw(P.t18), state, plan, save, chk('x0', 'emuPack', true), chk('x1', 'emuPack', true), state, save, again);
C('launch.figs.room', open('neon'), set('launch', true), fw(P.go), fw(P.idl), fw(P.ps), fw(P.u4), row('x0', 'fig', 'fig:1048576:1048576:57', 'a.bin'), row('x0', 'fig', 'fig:1048576:1048576:58', 'b.bin'), row('x0', 'fig', 'fig:1048576:1048576:59', 'c.bin'), state, plan, save);

// ---------------------------------------------------------------- H. without the Paradise
for (const ed of EDS) {
  C('clean.go.' + ed, open(ed), set('launch', true), set('clean', true), fw(P.go), state, plan, save, again, kinds.gb, fw(P.idl), row('x1', 'star'), state, plan, save, again, row('x0', 'del'), set('cleanClock', false), state, save, again, row('x0', 'del'), row('x0', 'del'), save);
  C('clean.mix.' + ed, open(ed), set('launch', true), set('clean', true), fw(P.t18), fw(P.idl), fw(P.go), kinds.v1, kinds.sms, kinds.pm, kinds.ab, kinds.wolf, state, plan, save, again, chk('x0', 'emuAuto', true), set('exit', 2), save, again);
}
C('clean.none', open('water'), set('launch', true), set('clean', true), state, plan, save, set('clean', false), save);
C('clean.frommain', open('water'), fw(P.idl), chk('main', 'emuAuto', true), sel('main', 'optVol', 2), save, reopen, set('launch', true), set('clean', true), state, plan, save, again);
C('clean.frommain.t18', open('land'), fw(P.t18), fw(P.go), set('bag', true), save, reopen, set('launch', true), set('clean', true), state, fw(P.v1), row('x2', 'star'), state, save, again);
C('clean.fromlaunch', open('sky'), set('launch', true), fw(P.go), fw(P.idl), kinds.gb, save, reopen, set('clean', true), state, plan, save, again, set('cleanClock', false), save, again);
C('clean.back', open('water'), fw(P.go), save, reopen, set('launch', true), set('clean', true), state, set('clean', false), state, save, again);
C('clean.star', open('tropical'), set('launch', true), set('clean', true), fw(P.go), fw(P.v1), fw(P.idl), row('x2', 'star'), chk('x2', 'emuAuto', true), state, save, again, row('x0', 'star'), state, save, again, row('x0', 'del'), state, save, again);
C('clean.set', open('jade'), set('launch', true), set('clean', true), fw(P.u4), fw(P.t18), fw(P.go), chk('x0', 'emuNfc', false), chk('x0', 'emuPack', true), chk('x1', 'emuClock', false), sel('x1', 'optVol', 1), chk('x2', 'emuSess', false), state, save, again, chk('x0', 'emuPack', false), save, again);
C('clean.savein', open('water'), set('launch', true), set('clean', true), fw(P.go), fw(P.v1), fw(P.idl), save, reopen, [['raw', 't7saveX', 0, 'rnd:4098:37']], [['raw', 'saveIn', 1, 'v1', 'rnd:8192:38']], [['raw', 'carry', 2]], compose, save, again, [['raw', 'saveIn', 2, 'tama']], compose);
C('launch.savein', open('land'), set('launch', true), fw(P.t18), fw(P.go), fw(P.v1), fw(P.idl), fw(P.ps), save, reopen, [['raw', 't7saveX', 0, 'rnd:4098:39']], [['raw', 'saveIn', 2, 'tama']], [['raw', 'carry', 3]], compose, save, again);
C('clean.many', open('neon'), set('launch', true), set('clean', true), fw(P.idl), fw(P.idl2), fw(P.ps), fw(P.u4), fw(P.u4p), fw(P.pc), fw(P.t18), state, plan, save, again);

// ---------------------------------------------------------------- I. DOOM
C('doom.water', open('water'), [['wad', P.wad]], state, plan, save, again, [['doomKeys', { fire: 2, fwd: 1, run: false }]], state, save, again, row('doom', 'check', 'emuAuto', true), save, again, row('doom', 'del'), state, plan, save, again);
C('doom.eps', open('land'), [['wad', P.wad3]], state, [['doomEp', '2']], plan, save, again, [['wad', P.wad3]], [['doomEp', '3']], [['doomMusic', false]], state, plan, save, again);
C('doom.menu', open('sky'), [['wad', P.wad]], set('feld', true), set('bag', true), set('tama', true), sps, again, set('feld', false), save, again);
C('doom.big', open('water'), [['wad', P.wadBig]], state, plan, save, [['wad', P.wadMid]], state, [['doomMusic', true]], plan, save, again);
C('doom.keys.bad', open('water'), [['wad', P.wad]], [['doomKeys', { fire: 2, fwd: 2 }]], save, [['doomKeys', { fwd: 1, use: 2 }]], save, [['doomKeys', { use: 8 }]], save);
C('doom.vs.emu', open('water'), [['wad', P.wad]], fw(P.idl), state, plan, save, reopen, [['wad', P.wad]], state, save, again, fw(P.go), state, save, again);
C('doom.off', open('water'), [['wad', P.wad]], save, reopen, [['doomOff']], state, plan, save, again);
C('doom.back', open('water'), [['wad', P.wad]], save, reopen, row('doom', 'del'), row('doom', 'undo'), state, save, fw(P.v1), state, save, again);
C('doom.six', open('water'), [['wad', P.wad]], set('sixOn', true), save);
for (const ed of NOA0) C('doom.noa0.' + ed, open(ed), [['wad', P.wad]], state, save, set('launch', true), [['wad', P.wad3]], state, plan, save, again, [['doomSel', '2', true]], [['doomSel', '3', true]], state, plan, save, again,
  [['doomWhole', true]], [['doomMusic', false]], state, plan, save, again, [['doomKeys', { fire: 4, back: 1 }]], save, again, [['doomOff']], state, save);
C('doom.launch', open('water'), set('launch', true), [['wad', P.wad]], state, plan, save, again, fw(P.idl), fw(P.go), state, plan, save, again, row('main', 'star'), row('main', 'check', 'emuAuto', true), state, save, again, row('doom', 'star'), state, save, again);
C('doom.launch.star', open('land'), set('launch', true), [['wad', P.wad3]], fw(P.go), fw(P.v1), fw(P.t18), row('x1', 'star'), row('x1', 'check', 'emuAuto', true), state, plan, save, again, row('x0', 'star'), state, save, again, row('doom', 'del'), state, plan, save, again);
C('doom.launch.late', open('water'), [['wad', P.wad]], save, reopen, set('launch', true), fw(P.idl), state, plan, save, again, set('clean', true), state, plan, save, again);
C('doom.launch.emu', open('sky'), fw(P.idl), set('bag', true), save, reopen, set('launch', true), [['wad', P.wad]], state, plan, save, again);
for (const ed of ['water', 'tropical', 'neon']) C('doom.clean.' + ed, open(ed), set('launch', true), set('clean', true), [['wad', P.wad3]], state, plan, save, again, [['wad', P.wad3]], [['doomSel', '2', true]], [['doomMusic', false]], fw(P.go), state, plan, save, again,
  row('x0', 'star'), [['doomKeys', { invert: false, mod: 2 }]], state, save, again, row('x1', 'del'), state, save, again, [['doomOff']], state, save, again);
C('doom.clean.whole', open('land'), set('launch', true), set('clean', true), [['wad', P.wad3]], [['doomWhole', true]], state, plan, save, again, [['wad', P.wad3]], [['doomWhole', false]], [['doomSel', '3', true]], [['doomSel', '1', false]], state, plan, save, again);
C('doom.clean.d2', open('water'), [['wad', P.wadM]], state, set('launch', true), set('clean', true), [['wad', P.wadM]], state, plan, save, again);
C('doom.clean.big', open('jade'), set('launch', true), set('clean', true), [['wad', 'wad:1:14000:13500:10']], state, save, [['wad', 'wad:12:7000:6500:11']], state, plan, save);

// without a WAD converter: the conversions of doomCompute go in (the page converts again; the result is the same)
C('doom.noport', [['noport']], open('water'), [['wad', P.iw3]], [['doomEp', '2']], save, again);
// synthetic WADs through doom.js / doom.dart and the converter itself
C('doom.real.water', open('water'), [['wad', P.iw1]], state, plan, save, again, [['wad', P.iw3]], [['doomEp', '3']], [['doomMusic', false]], state, plan, save, again, [['doomKeys', { fire: 4, back: 1 }]], save, again);
C('doom.real.launch', open('land'), set('launch', true), [['wad', P.iw3]], [['doomEp', '2']], fw(P.go), state, plan, save, again);
C('doom.real.noa0', open('tropical'), set('launch', true), [['wad', P.iw3]], [['doomSel', '2', true]], fw(P.go), state, plan, save, again, [['doomWhole', true]], state, save, again);
C('doom.real.clean', open('sky'), set('launch', true), set('clean', true), [['wad', P.iw3]], [['doomSel', '3', true]], [['doomMusic', false]], fw(P.v1), state, plan, save, again, [['wad', P.iw3]], [['doomWhole', true]], state, save, again);
C('doom.real.d2', open('neon'), [['wad', P.iwM]], set('launch', true), set('clean', true), [['wad', P.iwM]], state, plan, save, again);
C('doom.real.bad', open('water'), [['wad', 'rnd:5000:3']], [['wad', 'iwad:8200:5:1']], state, save);

// ---------------------------------------------------------------- K. characters and pictures
C('spr.numbers', open('water'), [['numbers']], state, plan, compose, save, again);
C('spr.numbers.neon', open('neon'), [['numbers']], set('bag', true), plan, save, again);
for (const ed of EDS) C('spr.blank.' + ed, open(ed), [['raw', 'blank', 2, 1]], [['raw', 'blank', 2, 4]], [['raw', 'blank', 7, 2]], [['raw', 'eye', 4, 3, -2]], [['raw', 'mouth', 4, -1, 5]], [['raw', 'eye', 9, -16, 16]], state, plan, save, again);
C('spr.emu', open('land'), [['raw', 'blank', 1, 1]], fw(P.idl), set('bag', true), [['name', 'chars', 3, 'PIXEL']], state, plan, save, again);

fs.writeFileSync(path.join(__dirname, 'compose_cases.json'), '[\n' + cases.map((c) => JSON.stringify(c)).join(',\n') + '\n]\n');
console.log(cases.length + ' cases, ' + cases.reduce((n, c) => n + c[1].filter((s) => s[0] === 'save').length, 0) + ' builds');
