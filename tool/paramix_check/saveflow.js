// Reference output for saveflow_check.dart (lib/paramix/save_flow.dart): the handlers of the Studio's
// Save tab and of the device panel's save buttons (third_party/paramix-studio/src/app.js) are page
// glue and do not run without the DOM, so their bodies are restated here, line for line, over the
// real modules: saves.js, feld.js, core.js, and flash.js' own Paradise object (usedSectors, changed,
// writeSectors with the rescue guard, clockRead, clockSet) talking to a flash in memory. The English
// texts are read out of app.js itself.
// DUMPS=<folder with water.bin ...> node tool/paramix_check/saveflow.js
// One line per case: <case name> <sha256 or value>. Only hashes, sizes, offsets and the Studio's own texts.
'use strict';
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const ROOT = path.join(__dirname, '../../third_party/paramix-studio'), SRC = path.join(ROOT, 'src');
const C = require(path.join(SRC, 'core.js')); globalThis.ParamixCore = C;
const E = require(path.join(SRC, 'emu.js'));
const F = require(path.join(SRC, 'feld.js')); globalThis.ParamixFeld = F;
const SV = require(path.join(SRC, 'saves.js'));
const FL = require(path.join(SRC, 'flash.js'));
const bin = (f) => new Uint8Array(fs.readFileSync(path.join(ROOT, f)));
const FELD = bin('feld/feld.bin'), STUB = bin('feld/stub_feld_tpl.bin');
const DUMPS = process.env.DUMPS;
const EDS = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];
const sha = (b) => crypto.createHash('sha256').update(typeof b === 'string' ? Buffer.from(b, 'utf8') : Buffer.from(b.buffer, b.byteOffset, b.length)).digest('hex');
const hex = (v) => '0x' + (v >>> 0).toString(16);
const u32 = (b, o) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;
const le = (v) => new Uint8Array([v & 255, (v >>> 8) & 255, (v >>> 16) & 255, (v >>> 24) & 255]);
let count = 0;
const P = (n, v) => { count++; console.log(n + ' ' + v); };
function pagesSha(pages) { const h = crypto.createHash('sha256'); for (const [a, d] of pages) { h.update(le(a)); h.update(le(d.length)); h.update(d); } return pages.size + ':' + h.digest('hex'); }

// ---- the English texts of app.js (T.en comes second) and its t()
const APP = fs.readFileSync(path.join(SRC, 'app.js'), 'utf8');
function en(key) {
  const re = new RegExp('[{ ,]' + key + ": '((?:[^'\\\\]|\\\\.)*)'", 'g'); let m, last = null, n = 0;
  while ((m = re.exec(APP))) { last = m[1]; n++; }
  if (n !== 2) throw new Error('text ' + key + ': ' + n);
  return last.replace(/\\(.)/g, (x, c) => c === 'n' ? '\n' : c);
}
const t = (k, p) => en(k).replace(/\{(\w+)\}/g, (m, n) => p && n in p ? p[n] : m);
const saveMsg = (x) => t('fl_' + x.code, x.p);                                                    // app.js:3111
const edSlug = (id) => (FL.EDITIONS[id] || 'paradise').toLowerCase().replace(/[ /]/g, '-');      // app.js:3110
const NOW = new Date(2026, 2, 4, 5, 6, 7), SEC = Math.floor(NOW.getTime() / 1000);
const stamp = () => { const d = NOW, z = (n) => String(n).padStart(2, '0'); return d.getFullYear() + z(d.getMonth() + 1) + z(d.getDate()) + '-' + z(d.getHours()) + z(d.getMinutes()); };   // app.js:3109

// ---- the device: flash.js' Paradise over a flash in memory (what the flash app answers)
function device(flash, ed, clock) {
  const st = { flash, log: [], buf: new Uint8Array(0x1000), clock: clock ? { ...clock } : null };
  const link = { async request(type, off, pl) {
    const r = (payload, status = 0) => ({ payload, status });
    switch (type) {
      case 5: { const n = u32(pl, 0); return r(flash.slice(off, off + n)); }
      case 6: return r(le(FL.crc32(flash, off, u32(pl, 0))));
      case 13: { const p = new Uint8Array(16); p[12] = 1; return r(p); }
      case 9: return r(le(0));
      case 10: st.buf.set(pl, off & 0xFFF); return r(new Uint8Array(0));
      case 11: { flash.set(st.buf, off); st.log.push(off); const p = new Uint8Array(8); p.set(le(FL.crc32(flash, off, 0x1000))); return r(p); }
      case 8: case 12: return r(new Uint8Array(0));
      case 14: if (!st.clock) throw new FL.TimeoutError('clock'); { const p = new Uint8Array(8); p.set(le(st.clock.counter)); p.set(le(st.clock.ctrl), 4); return r(p); }
      case 15: if (!st.clock) throw new FL.TimeoutError('clock'); st.clock.counter = u32(pl, 0); return r(le(st.clock.counter));
    }
    throw new Error('command ' + type);
  } };
  const d = new FL.Paradise(link);
  d.info = { edition: ed, name: FL.EDITIONS[ed] || 'Edition ' + ed, wave: 0, maxBlock: 4096, jedec: 0, capacity: 0x1000000, flashError: 0 };
  st.d = d; return st;
}
const logStr = (l) => l.length + ':' + sha(l.map(hex).join(','));
const em = (e) => 'err:' + (e && e.message || e);
async function T(name, fn) { try { await fn(); } catch (e) { P(name, em(e)); } }

// ---- the handlers, restated
/* btnSaveRead, app.js:3531-3539, 3576 (the Paradise save) */
async function saveRead(d) {
  const ed = d.info.edition, [a, b] = SV.region(ed);
  const used = await d.usedSectors(a, b, null, null);
  const pages = new Map(), ff = new Uint8Array(0x1000).fill(0xFF);
  for (let p = a; p < b; p += 0x1000) pages.set(p, ff);
  for (const s of used) pages.set(s, await d.read(s, 0x1000));
  const clock = await d.clockRead();
  const names = [edSlug(ed) + '-' + stamp() + '.tamasave'];
  const file = SV.paraEncode(pages, ed, clock && (clock.ctrl & 0x80) ? clock : null, SEC);
  return { file, used: used.length, name: names[0], msg: t('devSaveGot', { n: names.join(', ') }) + (clock ? '' : ' ' + t('devSaveClockNo')) };
}
/* fileSave, app.js:3583-3590 */
function saveCheck(save, d) {
  const ed = d.info.edition, chk = SV.paraCheck(save, ed);
  chk.errors.forEach((x) => { if (x.p) { x.p.s = FL.EDITIONS[x.p.s] || x.p.s; x.p.d = FL.EDITIONS[x.p.d] || x.p.d; } });
  if (chk.errors.length) return { chk, error: t('devErr', { e: chk.errors.map(saveMsg).join(', ') }) };
  const warn = chk.warnings.map(saveMsg).join('\n');
  return { chk, error: null, warn, confirm: t('devSaveSure', { ed: d.info.name }) + (warn ? '\n\n' + warn : '') };
}
/* fileSave, app.js:3591-3602 */
async function saveWrite(d, save, chk, guard, cancel) {
  const ed = d.info.edition, [a, b] = SV.region(ed);
  const img = new Uint8Array(0x1000000).fill(0xFF);
  for (const [p, data] of chk.pages) img.set(data, p);
  const diff = await d.changed(img, null, cancel, a & ~0xFFFF, b);
  const map = new Map();
  for (const [p, data] of chk.pages) if (diff.has(p)) map.set(p, data);
  const w = map.size ? await d.writeSectors(map, null, cancel, guard) : 0;
  const v = SV.paraClock(save, SEC + 90);
  const cl = v !== null && await d.clockSet(v);
  return t('devSaveDone', { w, c: cl ? t('devSaveClock') : t('devSaveClockNo') });
}
/* petOpen, app.js:3411-3436 */
function petOpen(save, rom, romEd) {
  const ed = save.edition || romEd;
  if (SV.family(ed) !== SV.family(romEd)) throw new Error(t('petOther'));
  const pet = SV.paraPet(save, ed);
  if (!pet) throw new Error(t('petNoSet'));
  save.edition = ed;
  const chars = F.characters(rom), fn = F.fieldNames(rom), opts = [];
  let cur = '';
  for (const [st, k] of [[3, 'petKid'], [4, 'petYoung'], [5, 'petAdult']]) {
    opts.push('[' + t(k) + ']');
    for (const c of chars.filter((x) => x.stage === st)) {
      const nm = c.name.charAt(0) + c.name.slice(1).toLowerCase();
      opts.push(c.id + ':' + c.stage + '=' + nm + (c.field >= 0 && fn[c.field] ? ' (' + fn[c.field] + ')' : ''));
      if (c.id === pet.id) cur = nm;
    }
  }
  return { save, ed, pet, chars, opts, stat: t('petNow', { l: pet.level, c: cur || pet.id, h: pet.hunger, j: pet.happy, s: pet.sick ? t('petSick') : '' }) };
}
/* btnPetSave, app.js:3439-3456: the controls are level, the option value "id:stage" or '', the tick */
function petSave(o, lv, v, care, rom, petName) {
  const ed = o.save.edition, pet = SV.paraPet(o.save, ed), ch = {};
  if (lv !== pet.level) ch.level = lv;
  if (v) { const [id, st] = v.split(':').map(Number); if (id !== pet.id || st !== pet.stage) { ch.id = id; ch.stage = st; } }
  if (care) ch.care = true;
  if (!Object.keys(ch).length) throw new Error(t('petNothing'));
  if (rom) {
    const nw = SV.paraPetSet(o.save, ed, ch), r = new Uint8Array(rom);
    for (const [a, d] of nw.pages) if (d.length === 0x1000) r.set(d, a);
    nw.edition = ed;
    return { rom: r, save: nw, msg: t('petRomDone') };
  }
  const out = SV.paraWrite(SV.paraPetSet(o.save, ed, ch), ed);
  const name = petName.replace(/\.tamasave$/i, '') + '-' + stamp() + '.tamasave';
  return { out, name, msg: t('petDone', { n: name }) };
}
/* paraSlots, slotLabel, the slot list of renderSave: app.js:3245, 3246, 3239-3240 */
const paraSlots = (rom) => { try { return F.saveSlots(rom, STUB); } catch (e) { return null; } };
const slotLabel = (ss, rom, i) => ss.saves ? t('saveSlot', { n: i + 1 }) : (F.fieldNames(rom)[i] || t('saveSlot', { n: i + 1 }));
function slotChoices(ss, rom) {
  const l = [];
  if (ss.live < 0) l.push('live=' + t('slotLive', { n: F.fieldNow(rom) }));
  for (const x of ss.list) l.push((x.i === ss.live ? 'live' : String(x.i)) + '=' + (x.i === ss.live ? t('slotLive', { n: slotLabel(ss, rom, x.i) }) : x.used ? slotLabel(ss, rom, x.i) : t('slotEmpty', { n: slotLabel(ss, rom, x.i) })));
  return l;
}
/* btnParaOut, app.js:3458-3470 */
async function paraOut(rom, ed, ss, v) {
  let pages = SV.paraFromImage(rom, ed), tag = '';
  if (v !== 'live') {
    const i = +v, sv = ss && await F.slotReadAsync((a, n) => rom.subarray(a, a + n), ss.f, i);
    if (!sv) throw new Error(t('slotNone'));
    const [a, b] = SV.region(ed), got = F.slotPages(sv);
    pages = new Map(); for (let p = a; p < b; p += 0x1000) pages.set(p, got.get(p) || new Uint8Array(0x1000).fill(0xFF));
    tag = '-' + slotLabel(ss, rom, i).toLowerCase().replace(/[^a-z0-9]+/g, '');
  }
  const name = edSlug(ed) + tag + '-' + stamp() + '.tamasave';
  return { file: SV.paraEncode(pages, ed, null, SEC), name, msg: t('saveNoClock', { n: name }), pages };
}
/* slotWrite, app.js:3606-3628 */
function slotCheck(ss, rom, chk, i, warn) {
  if (!ss.saves) {
    const set = chk.pages.get(0xEFE000), fi = F.fieldOfSettings(rom, set);
    if (fi !== i) throw new Error(t('devErr', { e: t('slotField', { a: F.fieldNames(rom)[fi] || '?', b: slotLabel(ss, rom, i) }) }));
  }
  return t('slotSure', { n: slotLabel(ss, rom, i) }) + (warn ? '\n\n' + warn : '');
}
async function sameMenu(d, rom, f) {
  const mine = rom.subarray(f.off + 0x140, f.off + 0x140 + 0x180), dev = (await d.read(f.off, 0x1000)).subarray(0x140, 0x140 + 0x180);
  for (const o of [0, 8, 12, 16, 364, 368]) if (mine[o] !== dev[o] || mine[o + 1] !== dev[o + 1] || mine[o + 2] !== dev[o + 2] || mine[o + 3] !== dev[o + 3]) throw new Error(t('slotDevOther'));
}
async function slotWrite(d, ss, rom, chk, i, guard) {
  const f = ss.f, [a, b] = SV.region(d.info.edition);
  await sameMenu(d, rom, f);
  const heads = [];
  for (let j = 0; j < f.nslots; j++) heads.push(new Uint8Array(await d.read(F.slotAddr(f, j), 0x1000)));
  const s = F.slotBuild(chk.pages, i, a, b), img = new Uint8Array(0x1000000).fill(0xFF);
  const written = F.slotPlace(img, f, i, s, F.poolUsed(f, heads, i));
  const first = new Map([[written[0], new Uint8Array(0x1000).fill(0xFF)]]);
  for (const p of written.slice(1)) first.set(p, img.slice(p, p + 0x1000));
  await d.writeSectors(first, null, null, guard);
  await d.writeSectors(new Map([[written[0], img.slice(written[0], written[0] + 0x1000)]]), null, null, guard);
  return t('slotDone', { n: slotLabel(ss, rom, i) });
}
/* btnSlotClear, app.js:3260-3270 */
async function slotClear(d, ss, rom, i, guard) {
  const f = ss.f;
  await sameMenu(d, rom, f);
  const at = F.slotAddr(f, i);
  await d.writeSectors(new Map([[at, new Uint8Array(0x1000).fill(0xFF)]]), null, null, guard);
  const r = new Uint8Array(rom); r.fill(0xFF, at, at + 0x1000);
  return { rom: r, msg: t('slotClearDone', { n: slotLabel(ss, rom, i) }) };
}

(async () => {
  // ---- texts and names
  for (const k of ['petKeep', 'petKid', 'petYoung', 'petAdult', 'petNow', 'petSick', 'petOther', 'petNoSet', 'petDone', 'petNothing', 'petRomDone', 'saveNoClock', 'saveSlot', 'slotLive', 'slotEmpty', 'slotNone', 'slotField', 'slotDevOther', 'slotSure', 'slotDone', 'slotClearSure', 'slotClearDone', 'devErr', 'devCancelled', 'devSaveSure', 'devSaveDone', 'devSaveClock', 'devSaveClockNo', 'devSaveGot', 'fl_saveOtherEd', 'fl_saveFamily', 'fl_saveNoSettings', 'fl_saveOutside', 'fl_saveIncomplete']) P('text.' + k, JSON.stringify(en(k)));
  for (let e = 0; e <= 9; e++) P('edSlug' + e, edSlug(e));
  P('stamp', stamp());
  const GUARD = new Uint8Array(0x3000); for (let i = 0; i < GUARD.length; i++) GUARD[i] = (i * 7 + 3) & 255;

  const saves = {};
  for (const name of EDS) {
    const rom = new Uint8Array(fs.readFileSync(path.join(DUMPS, name + '.bin')));
    const ed = C.openRom(rom).editionId, Q = (n, v) => P(name + '.' + n, v);
    Q('edition', ed);

    // Save tab: export, the pet editor on the ROM's own save and on a file
    const ex = await paraOut(rom, ed, null, 'live');
    Q('export', ex.name + ' ' + ex.file.length + ' ' + sha(ex.file) + ' ' + sha(ex.msg));
    let o = null;
    await T(name + '.petOpen', async () => {
      o = petOpen({ stamp: 0, counter: 0, alarm: 0, status: 0, regs: [], pages: SV.paraFromImage(rom, ed), edition: ed }, rom, ed);
      Q('petOpen', JSON.stringify(o.pet) + ' ' + sha(o.stat) + ' ' + o.opts.length + ':' + sha(o.opts.join('\n')));
    });
    if (!o) continue;
    await T(name + '.petSave.nothing', async () => { petSave(o, o.pet.level, '', false, rom); });
    await T(name + '.petSave.same', async () => { petSave(o, o.pet.level, o.pet.id + ':' + o.pet.stage, false, rom); });
    const pick = (st) => { const c = o.chars.filter((x) => x.stage === st && x.id !== o.pet.id); return c.length ? c[c.length >> 1].id + ':' + st : ''; };
    const lv = (o.pet.level + 3) % 11;
    let edited = null;
    for (const [tag, a] of [['level', [lv, '', false]], ['care', [o.pet.level, '', true]], ['kid', [o.pet.level, pick(3), false]], ['teen', [lv, pick(4), true]], ['adult', [lv, pick(5), true]]]) {
      await T(name + '.petSave.rom.' + tag, async () => {
        const r = petSave(o, a[0], a[1], a[2], rom);
        Q('petSave.rom.' + tag, sha(r.rom) + ' ' + JSON.stringify(SV.paraPet(r.save, ed)) + ' ' + pagesSha(r.save.pages));
        if (tag === 'level' || tag === 'adult') edited = r.save;
      });
    }
    const fileIn = SV.paraDecode(SV.paraEncode(SV.paraFromImage(rom, ed), ed, { counter: 123456, ctrl: 0xE0 }, SEC - 1000));
    await T(name + '.petSave.file', async () => {
      const fo = petOpen(fileIn, rom, ed), r = petSave(fo, lv, pick(5), true, null, 'My Save.TamaSave');
      Q('petSave.file', r.name + ' ' + r.out.length + ' ' + sha(r.out) + ' ' + sha(r.msg));
    });
    saves[name] = { ed, save: fileIn };

    // device panel: the toy holds this dump
    const dv = device(new Uint8Array(rom), ed, { counter: 500000, ctrl: 0xE0 });
    const bk = await saveRead(dv.d);
    Q('devSaveRead', bk.name + ' ' + bk.used + ' ' + bk.file.length + ' ' + sha(bk.file) + ' ' + sha(bk.msg));
    for (const [tag, ck] of [['noclock', null], ['stopped', { counter: 77, ctrl: 0x60 }]]) {
      const d2 = device(new Uint8Array(rom), ed, ck), b2 = await saveRead(d2.d);
      Q('devSaveRead.' + tag, sha(b2.file) + ' ' + JSON.stringify(b2.msg.replace(b2.name, '{n}')));
    }
    const back = SV.paraDecode(bk.file);
    if (edited) {
      // the changed save of the ROM (no clock) and the backup changed (clock): to the toy
      for (const [tag, sv, guard] of [['edited', edited, null], ['backup', back, null], ['edited.guard', edited, GUARD], ['backup.guard', back, GUARD]]) {
        await T(name + '.devSaveWrite.' + tag, async () => {
          const fl = new Uint8Array(rom);
          let on = 'none';
          if (guard) { const w = FL.withRescue(fl, guard); on = w ? 'on' : 'busy'; if (w) fl.set(w); }
          const d2 = device(fl, ed, { counter: 9, ctrl: 0xE0 });
          let s2 = sv;
          if (tag.startsWith('backup')) { const bo = petOpen(SV.paraDecode(bk.file), rom, ed); s2 = SV.paraPetSet(bo.save, ed, { level: lv, care: true }); }
          const c = saveCheck(s2, d2.d);
          if (c.error) { Q('devSaveWrite.' + tag, c.error); return; }
          const msg = await saveWrite(d2.d, s2, c.chk, guard, null);
          Q('devSaveWrite.' + tag, on + ' ' + JSON.stringify(c.confirm) + ' ' + JSON.stringify(msg) + ' ' + logStr(d2.log) + ' ' + sha(fl) + ' ' + d2.clock.counter);
          const again = await saveRead(d2.d);
          Q('devSaveWrite.' + tag + '.again', sha(again.file) + ' ' + JSON.stringify(SV.paraPet(SV.paraDecode(again.file), ed)));
        });
      }
      // cancelled while writing, with and without the rescue start
      for (const [tag, guard] of [['cancel', null], ['cancel.guard', GUARD]]) {
        await T(name + '.devSaveWrite.' + tag, async () => {
          const fl = new Uint8Array(rom);
          if (guard) { const w = FL.withRescue(fl, guard); if (w) fl.set(w); }
          const d2 = device(fl, ed, { counter: 9, ctrl: 0xE0 }), c = saveCheck(edited, d2.d);
          const need = guard ? 2 : 1;
          let r; try { r = JSON.stringify(await saveWrite(d2.d, edited, c.chk, guard, () => d2.log.length >= need)); } catch (e) { r = em(e) + ' ' + e.code; }
          Q('devSaveWrite.' + tag, r + ' ' + logStr(d2.log) + ' ' + sha(fl));
        });
      }
    }
    // partial saves and pages from elsewhere
    await T(name + '.devSaveCheck.part', async () => {
      const part = Object.assign({}, back, { pages: new Map([...back.pages].filter(([a]) => a >= 0xEF0000 || a < SV.region(ed)[0] + 0x8000).concat([[0x100000, new Uint8Array(0x1000)]])) });
      const d2 = device(new Uint8Array(rom), ed, null), c = saveCheck(part, d2.d);
      Q('devSaveCheck.part', JSON.stringify(c.error || c.confirm) + ' ' + pagesSha(c.chk.pages));
      if (!c.error) { const msg = await saveWrite(d2.d, part, c.chk, null, null); Q('devSaveWrite.part', JSON.stringify(msg) + ' ' + logStr(d2.log) + ' ' + sha(d2.flash)); }
    });

    // the menu with save slots in the ROM and on the toy
    for (const [mt, opts] of [['saves', { fields: true }], ['fields', { fields: true, saves: false }]]) {
      const tag = name + '.slots.' + mt;
      await T(tag, async () => {
        const mrom = F.feldApply(rom, opts, [], { feld: FELD, stub: STUB }, E), ss = paraSlots(mrom);
        if (!ss) { P(tag, 'null'); return; }
        P(tag, ss.saves + ' ' + ss.live + ' ' + ss.list.length + ' ' + sha(slotChoices(ss, mrom).join('\n')));
        const dv2 = device(new Uint8Array(mrom), ed, null);
        const live = { stamp: 0, counter: 0, alarm: 0, status: 0, regs: [], pages: SV.paraFromImage(mrom, ed), edition: ed };
        const c = saveCheck(live, dv2.d);
        for (const x of ss.list) {
          await T(tag + '.write' + x.i, async () => {
            const q = slotCheck(ss, mrom, c.chk, x.i, c.warn);
            const msg = await slotWrite(dv2.d, ss, mrom, c.chk, x.i, null);
            P(tag + '.write' + x.i, sha(q) + ' ' + sha(msg) + ' ' + logStr(dv2.log) + ' ' + sha(dv2.flash));
          });
        }
        // the toy read back as a ROM: its slots, exported
        const got = new Uint8Array(dv2.flash), ss2 = paraSlots(got);
        P(tag + '.after', ss2 ? sha(slotChoices(ss2, got).join('\n')) : 'null');
        for (const x of ss.list) {
          await T(tag + '.export' + x.i, async () => {
            const e2 = await paraOut(got, ed, ss2, String(x.i));
            P(tag + '.export' + x.i, sha(e2.name) + ' ' + sha(e2.file) + ' ' + pagesSha(e2.pages));
          });
        }
        await T(tag + '.clear', async () => {
          const i = ss.list[ss.list.length - 1].i, r = await slotClear(dv2.d, ss2, got, i, null);
          P(tag + '.clear', sha(r.msg) + ' ' + logStr(dv2.log) + ' ' + sha(dv2.flash) + ' ' + sha(r.rom));
        });
        await T(tag + '.other', async () => { await slotWrite(dv2.d, ss, rom, c.chk, 0, null); });
      });
    }
  }

  // ---- a save of every edition on a toy of every edition
  for (const a of Object.keys(saves)) for (const b of Object.keys(saves)) {
    const d2 = device(new Uint8Array(0), saves[b].ed, null), c = saveCheck(SV.paraDecode(SV.paraWrite(saves[a].save)), d2.d);
    P('cross.' + a + '.' + b, JSON.stringify(c.error || c.confirm));
  }
  console.error(count + ' cases');
})();
