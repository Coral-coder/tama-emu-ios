// Check of lib/paramix/build_state.dart and compose_full.dart against the Studio's page itself:
// third_party/paramix-studio/dist/ParamixStudio.html (index.html with core.js, emu.js, ... and app.js
// and the embedded binaries, as build.js makes it) is loaded under jsdom, a ROM is opened through
// the page's own file dialog handler (loadRom), the controls are set through their own handlers,
// "Save new ROM" is clicked (composeRom) and the download is hashed.
//
//   npm install --prefix <scratch> jsdom
//   DUMPS=<folder with water.bin ...> JSDOM=<scratch>/node_modules/jsdom node tool/paramix_check/compose.js [shard/of]
//
// Prints one line per step that has a result: "<case> <step>: <value>". compose_check.dart prints
// the same lines. The cases are in compose_cases.json; the steps are explained in compose_cases.md.
// Outputs contain hashes, sizes, names of programs and the page's messages only.
//
// What is not the page's own code here (the same on the Dart side):
// - canvas, ImageData, IntersectionObserver, Blob, URL.createObjectURL, confirm: stand-ins (jsdom has none);
//   confirm answers yes and its question is printed.
// - timers of 400 ms and more are dropped: the quiet trial build for the free-room bar (roomSoon) and the hiding
//   of the toast. roomSoon only fills state.roomFree.
// - the WAD conversion of doom.js needs a real WAD: ParamixDoom.wadEpisodes, wadSub, gbaExtras and convert are
//   replaced by a synthetic converter, and ParamixDoom.doomBuild by its own source text over those (so that it
//   calls them); doomPatch, doomKeysSet, doomCompute (app.js) are the real ones.
// - ParamixWolf.build needs the game's files: replaced by one that returns the synthetic pack.
// - imported saves, eye and mouth shifts, blank sprites and grow-up pictures ("raw" steps) are put into
//   window.__paramix (the page's state object) directly, as their handlers would.
'use strict';
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const S = require('./compose_syn.js');
const ROOT = path.join(__dirname, '..', '..');
const PS = path.join(ROOT, 'third_party', 'paramix-studio');
const { JSDOM, VirtualConsole } = require(process.env.JSDOM || 'jsdom');
const DUMPS = process.env.DUMPS;
if (!DUMPS) { console.error('DUMPS is not set'); process.exit(2); }
// the page as built, with one line added: composeRom is handed out next to the state object (app.js ends with
// "window.__paramix = state; // for tests"), so that the "compose" step can look at what it returns
const HOOK = 'window.__paramix = state;';
const html0 = fs.readFileSync(path.join(PS, 'dist', 'ParamixStudio.html'), 'utf8');
if (html0.split(HOOK).length !== 2) { console.error('app.js: the line "' + HOOK + '" is not there once'); process.exit(2); }
const html = html0.replace(HOOK, HOOK + ' window.__paramixCompose = composeRom;');
const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, 'compose_cases.json'), 'utf8'));
const [shard, shards] = (process.argv[2] || '0/1').split('/').map(Number);
const only = process.env.ONLY ? new RegExp(process.env.ONLY) : null;

const sha = (b) => crypto.createHash('sha256').update(Buffer.from(b.buffer, b.byteOffset, b.length)).digest('hex');
const shaS = (s) => crypto.createHash('sha256').update(Buffer.from(s, 'utf8')).digest('hex').slice(0, 16);
const H = (b) => (b === null || b === undefined ? '-' : b.length + ':' + sha(b).slice(0, 16));
const bo = (v) => (v === null || v === undefined ? '-' : v ? '1' : '0');
const dumps = new Map();
const dump = (n) => { if (!dumps.has(n)) dumps.set(n, new Uint8Array(fs.readFileSync(path.join(DUMPS, n + '.bin')))); return dumps.get(n); };
const ascii = (s) => Uint8Array.from(Buffer.from(s, 'latin1'));
const str = (b) => Buffer.from(b.buffer, b.byteOffset, b.length).toString('latin1');

// English labels of the controls the steps look for (app.js T.en)
const L = { emuAuto: 'Start when switched on', emuClock: 'Take the clock from the Paradise at the start', emuSess: 'Remember where you left off', emuNfc: '4U: emulate the NFC chip', emuPack: 'Pack the firmware',
  optVol: 'Volume', optDim: 'Brightness', optScr: 'Screen off after', progDel: 'Remove', progUndo: 'Undo', doomOff: 'Remove DOOM', emuOff: 'Remove emulator', t7FigPick: 'Add figures', doomWhole: 'Whole WAD as one entry' };

// ------------------------------------------------------------ synthetic inputs by a short text
const synMemo = new Map();
function syn(spec) {
  if (synMemo.has(spec)) return synMemo.get(spec);
  const p = spec.split(':'), n = (i) => Number(p[i]);
  let b;
  switch (p[0]) {
    case 'tama': b = S.tamaFw(p[1], n(2), n(3)); break;
    case 't7': b = S.t7Rom(p[1] === 'friends', n(2)); break;
    case 't18': b = S.t18Fw(n(1), p[2] === '1', n(3)); break;
    case 'v1': b = S.v1Rom(n(1), n(2)); break;
    case 'v3': b = S.v3Rom(n(1)); break;
    case 'gb': b = S.gbRom(n(1), n(2), p[3], n(4)); break;
    case 'sms': b = S.smsRom(n(1), n(2), n(3)); break;
    case 'pm': b = S.pmRom(n(1), n(2)); break;
    case 'pmbios': b = S.pmBios(n(1)); break;
    case 'ab': b = ascii(S.abHexText(S.rndBytes(n(1), n(2)), '\n')); break;
    case 'wolf': b = S.wolfPack(n(1), n(2), n(3)); break;
    case 'fig': b = S.t7Fig(n(1), n(2), n(3)); break;
    case 'wad': b = ascii('FAKEWAD ' + p.slice(1).join(' ')); break;   // episodes, KB with music, KB without, seed
    case 'rnd': b = S.rndBytes(n(1), n(2)); break;
    case 'junk': b = S.rndBytes(n(1), n(2)); b[0] = 0x12; break;
    default: throw new Error('syn ' + spec);
  }
  synMemo.set(spec, b); return b;
}
/* the synthetic converter: a "WAD" is the text "FAKEWAD <episodes> <KB with music> <KB without> <seed>" */
const fakeDoom = {
  wadEpisodes: (w) => str(w).split(' ')[1].split(''),
  wadMerge: (base) => base,
  wadSub: (src, eps, music) => { const q = str(src).split(' '); return ascii(['FAKESUB', eps, music ? 1 : 0, q[2], q[3], q[4]].join(' ')); },
  gbaExtras: () => new Uint8Array(0),
  convert: (sub) => {
    const q = str(sub).split(' '), eps = q[1].split(''), music = q[2] === '1', kb = Number(music ? q[3] : q[4]), seed = Number(q[5]);
    const lumps = [['PLAYPAL', S.rndBytes(768, seed)], ['COLORMAP', S.rndBytes(34 * 256, seed + 1)]];
    for (const e of eps) { const c = e.charCodeAt(0); lumps.push([e === 'M' ? 'MAP01' : 'E' + e + 'M1', new Uint8Array(0)], ['THINGS', S.rndBytes(300, seed + 10 + c)], ['DATA' + e, S.rndBytes(kb * 1024, seed + 20 + c + (music ? 100 : 0))]); }
    lumps.push(['TEX1', S.rndBytes(0x8000, seed + 2)]);
    return S.doomWad(lumps);
  },
};

// ------------------------------------------------------------ the page
class Page {
  constructor() {
    this.confirms = [];
    const vc = new VirtualConsole(); this.errs = [];
    vc.on('jsdomError', (e) => this.errs.push(String(e && e.detail && e.detail.stack || e.stack || e.message).slice(0, 600)));
    const self = this;
    this.dom = new JSDOM(html, { runScripts: 'dangerously', pretendToBeVisual: true, url: 'https://localhost/', virtualConsole: vc,
      beforeParse(w) {
        w.localStorage.setItem('paramix-lang', 'en');
        const st = w.setTimeout.bind(w); w.setTimeout = (f, ms, ...a) => (ms >= 400 ? 0 : st(f, ms, ...a));
        w.HTMLCanvasElement.prototype.getContext = function () { const cv = this; return new Proxy({}, { get: (o, k) => (k === 'canvas' ? cv : k in o ? o[k] : () => ({ data: new w.Uint8ClampedArray(4) })), set: (o, k, v) => { o[k] = v; return true; } }); };
        w.ImageData = function (d, ww, hh) { this.data = d; this.width = ww; this.height = hh; };
        w.IntersectionObserver = function () { this.observe = () => {}; this.unobserve = () => {}; this.disconnect = () => {}; };
        w.confirm = (q) => { self.confirms.push(q); return true; }; w.alert = () => {};
        w.URL.createObjectURL = (b) => { self.dl = b; return 'blob:x'; }; w.URL.revokeObjectURL = () => {};
        w.Blob = function (parts, o) { this.parts = parts; this.type = o && o.type; };
        w.HTMLAnchorElement.prototype.click = function () { self.dlName = this.download; };
      } });
    const w = this.w = this.dom.window; this.st = w.__paramix; this.E = w.ParamixEmu; this.C = w.ParamixCore;
    const D = w.ParamixDoom;
    D.wadEpisodes = fakeDoom.wadEpisodes; D.wadMerge = fakeDoom.wadMerge; D.gbaExtras = fakeDoom.gbaExtras;
    D.wadSub = (src, eps, music) => this.u8(fakeDoom.wadSub(src, eps, music));
    D.convert = async (sub) => this.u8(fakeDoom.convert(sub));
    // doom.js doomBuild, word for word, over the functions above
    D.doomBuild = async function doomBuild(rom, wad, opts, emb, E) {
      const eps = opts.episode || '1';
      const sub = D.wadSub(wad, eps, opts.music !== false);
      const mcu = await D.convert(sub, D.gbaExtras(sub), emb.wasm);
      const r = D.doomPatch(rom, mcu, emb, E);
      if (opts.keys) r.rom = D.doomKeysSet(r.rom, opts.keys);
      return r;
    };
    w.ParamixWolf.build = (set) => { const pack = Object.values(set)[0]; return { pack, sod: this.E.wolfSod(pack) }; };
  }
  $(id) { return this.w.document.getElementById(id); }
  u8(b) { const a = new this.w.Uint8Array(b.length); a.set(b); return a; }   // an array of the page's own realm
  file(name, b) { return { name, size: b.length, arrayBuffer: async () => this.u8(b).buffer }; }
  ev(files) { return { target: { files, value: '' } }; }
  async settle() { let q = 0; while (q < 3) { await new Promise((r) => setTimeout(r, 4)); q = this.$('busy').classList.contains('on') ? 0 : q + 1; } }
  close() { this.w.close(); }
  rows() { const out = []; let cur = null; for (const el of this.$('appsList').children) { if (el.classList.contains('prow')) { cur = { el, det: null }; out.push(cur); } else if (el.classList.contains('pdet') && cur) cur.det = el; } return out; }
  row(key) {
    const rs = this.rows(), btn = (r, t) => [...r.el.querySelectorAll('button')].find((b) => b.title === t);
    const isX = (r) => !!btn(r, L.progDel), isDoom = (r) => !isX(r) && r.el.querySelector('.pname').textContent === 'DOOM';
    if (key === 'doom') return rs.find(isDoom) || null;
    if (key === 'main') return rs.find((r) => !isX(r) && !isDoom(r)) || null;
    const xs = rs.filter(isX), n = this.st.extras.length, first = xs.length && xs[0].el.classList.contains('main') ? this.st.extras.indexOf(this.st.mainPick) : -1;
    const order = []; if (first >= 0) order.push(first); for (let i = 0; i < n; i++) if (i !== first) order.push(i);
    const k = order.indexOf(Number(key.slice(1))); return k >= 0 ? xs[k] || null : null;
  }
  async rowOpen(key) {
    let r = this.row(key); if (!r) return null;
    if (!r.det) { const tb = r.el.querySelector('.ptog'); if (!tb) return r; tb.onclick(); await this.settle(); r = this.row(key); }
    return r;
  }
}

// ------------------------------------------------------------ what the state looks like
function xStr(P, x) {
  const E = P.E, k = E.extraKind(x), keys = x.keys;
  return [k, E.extraName(x), H(x.rom || x.guest || x.fw || (x.kind === 'wolf' ? x.pack : null) || x.mcu || null), 'figs=' + (x.figs ? x.figs.map((f) => f.name + ':' + H(f.data)).join(',') : '-'),
    'keys=' + (!keys ? '-' : Array.isArray(keys) ? keys.join('.') : JSON.stringify(keys)), 'inv=' + bo(!!x.inv), 'clock=' + bo(x.clock), 'nfc=' + bo(x.nfc), 'sess=' + bo(x.sess), 'opt=' + (x.opt ? [x.opt.vol, x.opt.dim, x.opt.off].join('/') : '-'),
    'pack=' + bo(x.kind === 'tama' ? !!x.pack : null), 'keepOff=' + (x.keepOff === undefined ? '-' : x.keepOff.toString(16)), 'title=' + (x.title || '-'), 'gg=' + bo(!!x.gg), 'save=' + H(x.save), 'bios=' + H(x.bios), 'region=' + (x.region || '-'), 'ep=' + (x.ep || '-'),
    'size=' + (x.kind === 'doom' ? x.size || '-' : '-'), 'fresh=' + bo(!!x.fresh), 'para=' + bo(!!x.fromPara) + bo(!!x.fromParaMain), 'carry=' + bo(!!x.carry), 'keys0=' + (x.keys0 || '-'), 'wad=' + bo(!!x.wadSrc)].join(' ');
}
function stateLines(P) {
  const s = P.st, c = s.ctx, o = [];
  const m = (name, v) => o.push(name + ' ' + v);
  m('ctx', c.clean ? 'clean ed=' + c.edition : ['ed=' + c.edition, 'id=' + c.editionId, 'entries=' + c.entries.length, 'groups=' + c.groups.length, 'adult=' + c.adult, 'egg=' + c.egg, 'limit=' + c.limit.toString(16), 'assetEnd=' + c.assetEnd.toString(16)].join(' '));
  m('changed', s.changed.size + ':' + shaS([...s.changed.keys()].sort((a, b) => a - b).map((i) => i + '=' + H(s.changed.get(i))).join(',')));
  m('flags', ['clean=' + bo(s.clean) + bo(s.cleanInit), 'launch=' + bo(s.launch) + bo(s.launchInit), 'feld=' + bo(s.feld) + bo(s.feldInit), 'bag=' + bo(s.bag) + bo(s.bagInit), 'tama=' + bo(s.tama) + bo(s.tamaInit), 'gplay=' + bo(s.gplay) + bo(s.gplayInit),
    'saves=' + bo(s.saves), 'exit=' + s.exitKey + '/' + s.exitKeyInit, 'six=' + bo(s.sixPlanet) + bo(s.sixMenu) + bo(s.sixWant) + bo(s.sixOff) + bo(!!s.six), 'stale=' + bo(s.feldStale), 'cleanClock=' + bo(s.cleanClock), 't18Few=' + bo(s.t18Few), 'paraMain=' + bo(!!s.paraMainTaken)].join(' '));
  const em = s.emu;
  m('emu', !em ? '-' : [em.v1 ? 'v1' : em.t7 ? 't7' : em.t18 ? 't18' : 'tama', em.dev, H(em.guest || em.rom), 'size=' + em.size, 'big=' + bo(!!em.big), 'kept=' + bo(!!em.kept), 'figs=' + (em.figs ? em.figs.map((f) => f.name + ':' + H(f.data)).join(',') : '-')].join(' '));
  m('main', ['remove=' + bo(s.emuRemove), 'pack=' + bo(s.emuPack), 'auto=' + bo(s.emuAuto), 'clock=' + bo(s.emuClock), 'sess=' + bo(s.emuSess), 'nfc=' + bo(s.emuNfc), 'opt=' + [s.emuOpt.vol, s.emuOpt.dim, s.emuOpt.off].join('/'),
    'pick=' + (s.mainPick === 'emu' ? 'emu' : s.mainPick ? s.extras.indexOf(s.mainPick) : '-'), 'mainDirty=' + bo(!!s.mainDirty), 'guest=' + bo(!!s.mainGuest)].join(' '));
  m('extras', ['n=' + s.extras.length, 'dirty=' + bo(s.extrasDirty), 'up=' + (s.extrasUp ? [...s.extrasUp].sort().join(',') : '-'), 'wolf=' + bo(s.wolfInit) + bo(s.wolfKeysDirty), 'oldT7=' + s.oldT7.join(','), 't18Broken=' + bo(s.t18Broken)].join(' '));
  s.extras.forEach((x, i) => m('x' + i, xStr(P, x)));
  const d = s.doom;
  m('doom', (!d ? '-' : ['eps=' + d.eps.join(''), 'ok=' + d.ok.join(','), 'sel=' + [...d.sel].sort().join(','), 'whole=' + bo(d.whole), 'd2=' + bo(d.d2), 'fit=' + Object.keys(d.fit).sort().map((k) => k + ':' + bo(d.fit[k].music) + bo(d.fit[k].plain) + ':' + d.fit[k].sizeM + ':' + d.fit[k].sizeP).join(',')].join(' '))
    + ' keys=' + (s.doomKeys ? JSON.stringify(s.doomKeys) : '-') + ' ep=' + P.$('doomEp').value + ' music=' + bo(P.$('doomMusic').checked));
  m('games', ['gb=' + (s.gbKeys ? s.gbKeys.join('.') + '/' + bo(s.gbInv) : '-'), 'sms=' + (s.smsKeys ? s.smsKeys.join('.') + '/' + bo(s.smsInv) : '-'), 'pm=' + (s.pmKeys ? s.pmKeys.join('.') + '/' + bo(s.pmInv) : '-'), 'ab=' + (s.abKeys ? s.abKeys.join('.') + '/' + bo(s.abInv) : '-'),
    'bios=' + H(s.pmBios || null), 'wolf=' + (s.wolfKeys ? JSON.stringify(s.wolfKeys) : '-')].join(' '));
  m('texts', [...s.texts.entries()].sort((a, b) => a[0] - b[0]).map(([i, v]) => i + '=' + v).join('|') || '-');
  m('fields', s.fields.length + ':' + shaS(JSON.stringify(s.fields)) + ' names=' + s.charNames.size + ':' + shaS([...s.charNames.entries()].sort((a, b) => a[0] - b[0]).map(([g, n]) => g + '=' + n).join('|')));
  m('room', s.roomFree ? 'kb=' + s.roomFree.kb : '-');
  return o;
}

// ------------------------------------------------------------ the steps
async function run(name, steps, out) {
  let P = null, last = null, lastName = '';
  const say = (i, op, v) => out.push(name + ' ' + i + ' ' + op + ': ' + String(v).replace(/\n/g, ' | '));
  const open = async (buf, fname) => { if (P) P.close(); P = new Page(); P.$('fileRom').onchange(P.ev([P.file(fname, buf)])); await P.settle(); };
  for (let i = 0; i < steps.length; i++) {
    const [op, ...a] = steps[i];
    if (P) { P.$('toast').textContent = ''; P.confirms.length = 0; }
    let res;   // undefined: nothing to print
    const $ = (id) => P.$(id), st = () => P.st;
    const check = (id, v) => { const el = $(id); if (el.disabled) return 'disabled'; el.checked = !!v; return el.onchange({ target: el }); };
    switch (op) {
      case 'open': await open(dump(a[0]), a[1] || a[0] + '.bin'); break;
      case 'openSyn': await open(syn(a[0]), 'x.bin'); break;
      case 'reopen': if (!last) { res = 'nothing built'; break; } await open(last, lastName); break;
      case 'set': {
        const id = { feld: 'feldOn', bag: 'bagOn', tama: 'tamaOn', gplay: 'gplayOn', launch: 'launchOn', clean: 'cleanOn', cleanClock: 'cleanClock', sixOn: 'sixOn', sixPlanet: 'sixPlanet', sixMenu: 'sixMenu' }[a[0]];
        if (a[0] === 'exit') { $('exitKey').value = String(a[1]); $('exitKey').onchange({ target: $('exitKey') }); }
        else { const r = check(id, a[1]); if (r === 'disabled') res = 'disabled'; else await r; }
        break; }
      case 'sixSrc': await $('fileSix').onchange(P.ev([P.file(a[0] + '.bin', dump(a[0]))])); break;
      case 'sixBad': await $('fileSix').onchange(P.ev([P.file('x.bin', syn(a[0]))])); break;
      case 'name': { const inp = $({ fields: 'namesFields', chars: 'namesChars', items: 'namesItems' }[a[0]]).querySelectorAll('input')[a[1]]; if (!inp) { res = 'norow'; break; } inp.value = a[2]; inp.onchange(); res = inp.value; break; }
      case 'names': res = ['namesFields', 'namesChars', 'namesItems'].map((id) => { const ls = [...$(id).querySelectorAll('label')]; return ls.length + ':' + shaS(ls.map((l) => l.querySelector('span').textContent + '/' + l.querySelector('input').maxLength).join('|')); }).join(' '); break;
      case 'fw': await $('fileEmu').onchange(P.ev([P.file(a[1] || 'fw.bin', syn(a[0]))])); break;
      case 'gb': await $('fileGb').onchange(P.ev([P.file(a[1] || 'game.gb', syn(a[0]))])); break;
      case 'sms': await $('fileSms').onchange(P.ev([P.file(a[1] || 'game.sms', syn(a[0]))])); break;
      case 'pm': await $('filePm').onchange(P.ev([P.file(a[1] || 'game.min', syn(a[0]))])); break;
      case 'ab': await $('fileAb').onchange(P.ev([P.file(a[1] || 'game.hex', syn(a[0]))])); break;
      case 'wolf': await $('fileWolf').onchange(P.ev([P.file('pack', syn(a[0]))])); break;
      case 'wad': $('fileWad').onchange(P.ev([P.file('doom.wad', syn(a[0]))])); break;
      case 'doomEp': $('doomEp').value = a[0]; $('doomEp').onchange(); break;
      case 'doomMusic': if ($('doomMusic').disabled) { res = 'disabled'; break; } $('doomMusic').checked = !!a[0]; $('doomMusic').onchange(); break;
      case 'doomSel': case 'doomWhole': {
        const text = op === 'doomWhole' ? L.doomWhole : (/^[PQ]/.test(a[0]) ? st().doom.titles[a[0]] : 'E' + a[0]), v = op === 'doomWhole' ? a[0] : a[1];
        const lab = [...$('doomEpsBox').querySelectorAll('label')].find((l) => l.textContent.trim().startsWith(text + ' ('));
        if (!lab) { res = 'nocontrol'; break; } const c = lab.querySelector('input'); if (c.disabled) { res = 'disabled'; break; } c.checked = !!v; c.onchange(); break; }
      case 'doomKeys': { const ids = { fire: 'kFire', fwd: 'kFwd', back: 'kBack', use: 'kUse', mod: 'kMod', run: 'kRun', invert: 'kInv' };
        if ($('doomKeys').hidden) { res = 'hidden'; break; }
        for (const [k, v] of Object.entries(a[0])) { if (typeof v === 'boolean') $(ids[k]).checked = v; else $(ids[k]).value = String(v); } $('kFire').onchange(); res = 'check=' + P.w.ParamixDoom.doomKeysCheck(st().doomKeys); break; }
      case 'doomOff': if ($('btnDoomOff').hidden) { res = 'hidden'; break; } $('btnDoomOff').onclick(); break;
      case 'inv': { const el = $(a[0] + 'Inv'); el.checked = !!a[1]; el.onchange(); break; }
      case 'wolfKey': { const ids = { fire: 'wkFire', fwd: 'wkFwd', back: 'wkBack', use: 'wkUse', mod: 'wkMod', turn: 'wkTurn', run: 'wkRun', invert: 'wkInv' }, el = $(ids[a[0]]);
        if (typeof a[1] === 'boolean') el.checked = a[1]; else el.value = String(a[1]); el.onchange(); break; }
      case 'row': {
        const [key, what, p1, p2] = a;
        if (what === 'check' || what === 'sel') {
          const r = await P.rowOpen(key); if (!r) { res = 'norow'; break; } if (!r.det) { res = 'nodetail'; break; }
          const lab = [...r.det.querySelectorAll('label.check')].find((l) => l.querySelector('span') && l.querySelector('span').textContent.trim() === L[p1]);
          const c = lab && lab.querySelector(what === 'check' ? 'input' : 'select'); if (!c) { res = 'nocontrol'; break; } if (c.disabled) { res = 'disabled'; break; }
          if (what === 'check') c.checked = !!p2; else c.value = String(p2);
          c.onchange();
        } else {
          const r = P.row(key); if (!r) { res = 'norow'; break; }
          const bs = [...r.el.querySelectorAll('button')];
          const b = what === 'star' ? bs.find((x) => x.classList.contains('pstar')) : what === 'del' ? bs.find((x) => x.textContent === '×') : what === 'undo' ? bs.find((x) => x.textContent === '↺') : what === 'fig' ? bs.find((x) => x.textContent.startsWith(L.t7FigPick)) : null;
          if (!b) { res = 'nobutton'; break; } if (b.disabled || !b.onclick) { res = 'disabled'; break; }
          b.onclick();
          if (what === 'fig') await $('fileT7Fig').onchange(P.ev([P.file(p2 || 'fig.bin', syn(p1))]));
        }
        break; }
      case 'numbers': $('btnNumbers').onclick(); break;
      case 'raw': {
        const s = st(), W = P.w;
        if (a[0] === 't7save') s.t7save = P.u8(syn(a[1]));
        else if (a[0] === 't7saveX') s.t7saveX = { i: a[1], save: P.u8(syn(a[2])) };
        else if (a[0] === 'saveIn') s.saveIn = a[2] === 'v1' ? { key: a[1], kind: 'v1', data: P.u8(syn(a[3])) } : { key: a[1], kind: 'tama' };
        else if (a[0] === 'eye') s.eyeShift.set(s.ctx.groups[a[1]], [a[2], a[3]]);
        else if (a[0] === 'mouth') s.mouthShift.set(s.ctx.groups[a[1]], [a[2], a[3]]);
        else if (a[0] === 'blank') { const i = s.ctx.groups[a[1]] + a[2]; s.changed.set(i, P.C.spriteBlank(s.ctx.entries[i], P.C.partOptions(a[2]))); }
        else if (a[0] === 'carry') s.extras[a[1]].carry = true;
        else if (a[0] === 't18pics') { const px = new W.Uint8ClampedArray(48 * 48 * 4); px.set(S.rndBytes(px.length, a[1])); for (let k = 3; k < px.length; k += 4) px[k] = 255; s.t18Pics = new W.Map([[a[2], P.E.t18PicMake({ w: 48, h: 48, rgba: px })]]); s.t18PicsDirty = true; }
        else throw new Error('raw ' + a[0]);
        $('exitKey').onchange({ target: $('exitKey') });   // renderPlan
        break; }
      case 'plan': $('exitKey').onchange({ target: $('exitKey') }); res = $('plan').textContent; break;
      case 'state': for (const l of stateLines(P)) say(i, 'state', l); break;
      case 'compose': {   // composeRom itself: what it returns (the ranges that come from the image even with "Keep saves")
        const c = await P.w.__paramixCompose();
        res = !c ? '! ' + $('toast').textContent : c.same ? 'same' : sha(c.rom) + ' ' + c.name + ' fresh=' + (c.fresh || []).map(([x, y]) => x.toString(16) + '-' + y.toString(16)).join(',') + ' free=' + (c.res ? c.res.free : '-');
        $('toast').textContent = '';
        break; }
      case 'noport': break;
      case 'save': {
        P.dl = null; P.dlName = '';
        await $('btnSave').onclick(); await P.settle();
        for (const q of P.confirms) say(i, 'confirm', q); P.confirms.length = 0;
        if (P.dl) { last = new Uint8Array(P.dl.parts[0]); lastName = P.dlName; if (process.env.KEEP) fs.writeFileSync(path.join(process.env.KEEP, name + '.' + i + '.js.bin'), last); res = sha(last) + ' ' + $('toast').textContent; }
        else res = '! ' + $('toast').textContent;
        $('toast').textContent = '';
        break; }
      default: throw new Error('step ' + op);
    }
    await P.settle();
    for (const q of P.confirms) say(i, 'confirm', q);
    if (res !== undefined) say(i, op, res);
    const t = P.$('toast').textContent; if (t) say(i, 'toast', t);
    if (P.errs.length) { say(i, 'PAGE ERROR', P.errs.join(' ## ')); P.errs.length = 0; }
  }
  if (P) P.close();
}

(async () => {
  const lines = [];
  let k = 0;
  for (const [name, steps] of CASES) {
    if (only && !only.test(name)) continue;
    if (k++ % shards !== shard) continue;
    const out = [];
    try { await run(name, steps, out); } catch (e) { out.push(name + ' HARNESS ' + (e && e.stack || e)); }
    for (const l of out) lines.push(l);
    if (process.env.LIVE) for (const l of out) console.log(l);
  }
  if (!process.env.LIVE) process.stdout.write(lines.join('\n') + (lines.length ? '\n' : ''));
  process.exit(0);
})();
