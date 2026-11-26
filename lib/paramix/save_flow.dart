// Paramix Studio: the Paradise save, in and out of ROMs, .tamasave files and the device.
// A native port of the handlers of the Studio's Save tab and of the device panel's save
// buttons (third_party/paramix-studio/src/app.js, mameise, GPL-3.0-or-later), without their
// page glue. Each function names the handler and the lines it follows. The messages are the
// Studio's English texts (the T.en table of app.js), under the same keys.
//
// The device is taken as [SaveDevice], the calls app.js makes on flash.js' Paradise object;
// [ParadiseSaveDevice] is the real one (lib/paramix/flash.dart), a test gives a simulated toy.
// The device helpers flash.dart does not have in the shape app.js uses them (usedSectors, the
// cancellable changed, writeSectors with the rescue guard) are ported here from flash.js.

import 'dart:async';
import 'dart:typed_data';

import 'bytes.dart';
import 'core_more.dart' as core;
import 'edition.dart' show editionNames;
import 'feld.dart' as feld;
import 'flash.dart' show FlashError, FlashTimeout, Paradise, Progress, batPicOff, block64, cmdClockRead, cmdWriteBegin, cmdWriteFinish, cmdWriteTest, flashSize, rescueBlock, rescueOff, sector;
import 'saves.dart';
import 'sprites.dart' show Rgba, spriteDecode;

// ------------------------------------------------------------------ messages
/// The Studio's English texts used by these handlers (T.en of app.js), by key.
const Map<String, String> saveTexts = {
  'petKeep': 'unchanged',
  'petKid': 'Kid',
  'petYoung': 'Teen',
  'petAdult': 'Adult',
  'petNow': 'In the save: level {l}, Tama {c}, hunger {h}/6, happiness {j}/20{s}.',
  'petSick': ', sick',
  'petOther': 'The save is for another edition than the loaded ROM.',
  'petNoSet': 'The settings block is missing in the save.',
  'petDone': '{n} saved. Send it with "Save to device".',
  'petNothing': 'Nothing changed.',
  'petRomDone': 'Changed in the ROM. Now save the ROM or write it to the device (without "Keep saves", otherwise the device keeps its save).',
  'saveNoClock': '{n} saved. The clock is not included, set it in the app if needed.',
  'saveSlot': 'Save {n}',
  'slotLive': '{n} (active)',
  'slotEmpty': '{n} (empty)',
  'slotNone': 'There is no save in this slot.',
  'slotField': 'The save is for {a}, the slot for {b}.',
  'slotDevOther': 'The menu on the device does not match the loaded ROM. Load the ROM from the device first.',
  'slotSure': 'The save goes into {n} on the device and replaces the one there. Continue?',
  'slotDone': 'Done: {n} replaced on the device.',
  'slotClearSure': '{n} is deleted on the device. A new game starts there afterwards, the field can be chosen. Continue?',
  'slotClearDone': 'Done: {n} is empty.',
  'devErr': 'Error: {e}',
  'devCancelled': 'Cancelled.',
  'devSaveSure': 'The save is written to the device ({ed}) and replaces the current one. Continue?',
  'devSaveDone': 'Done: {w} pages written. {c} The device can be restarted.',
  'devSaveClock': 'Clock taken over.',
  'devSaveClockNo': 'Please set the clock on the device.',
  'devSaveGot': 'Backed up: {n}.',
  'fl_saveOtherEd': 'the save is from another edition ({s}), the device is {d}',
  'fl_saveFamily': 'the save does not fit this edition',
  'fl_saveNoSettings': 'the settings block is missing, this is not a complete Paradise save',
  'fl_saveOutside': '{n} pages lie outside the save and are not written',
  'fl_saveIncomplete': 'the save does not hold every page, missing ones stay as on the device',
};

/// app.js t(): the text of [key] with {name} filled from [p].
String t(String key, [Map<String, Object?> p = const {}]) =>
    (saveTexts[key] ?? key).replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => p.containsKey(m[1]) ? '${p[m[1]]}' : m[0]!);

/// app.js saveMsg (3111), with the edition names put in as fileSave does (app.js:3586).
String saveMsg(SaveNote x) {
  final p = <String, Object?>{...?x.p};
  if (x.p != null) {
    for (final k in const ['s', 'd']) {
      if (p[k] is int) p[k] = editionNames[p[k]] ?? p[k];
    }
  }
  return t('fl_${x.code}', p);
}

/// Where the page shows an error toast or "Error: ..." and stops. [code] is the text key.
class SaveFlowError implements Exception {
  SaveFlowError(this.code, this.message);
  final String code, message;
  @override
  String toString() => message;
}

SaveFlowError _err(String key, [Map<String, Object?> p = const {}]) => SaveFlowError(key, t(key, p));

/// app.js stamp (3109): YYYYMMDD-HHMM, local time.
String stamp([DateTime? now]) {
  final d = now ?? DateTime.now();
  String z(int n) => n.toString().padLeft(2, '0');
  return '${d.year}${z(d.month)}${z(d.day)}-${z(d.hour)}${z(d.minute)}';
}

/// app.js edSlug (3110).
String edSlug(int id) => (editionNames[id] ?? 'paradise').toLowerCase().replaceAll(RegExp('[ /]'), '-');

int _secs(DateTime? now) => (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;

// ------------------------------------------------------------------ edition of a ROM
// from core.js: editionIdOf (ctx.editionId of the loaded ROM), with isNeon and edPage
const List<int> _edC = [0, 0x70169E2C, 0x70169E2C, 0x70169E2C, 0x849633DB, 0x96CB83B8, 0x96CB83B8];
int _edPage(Uint8List rom, int p, bool check) {
  if (p + 0x1000 > rom.length) return 0;
  final v = u32(rom, p), k = u32(rom, p + 0xFF8);
  bool foot(int c) => ((k + v) & 0xFFFFFFFF) == c && u32(rom, p + 0xFFC) == (~k & 0xFFFFFFFF);
  if (v == 4 && p != 0xD49000 && foot(_edC[5])) return 7;
  if (!(p == 0xD29000
      ? v == 5 || v == 6
      : p == 0xD49000
          ? v >= 1 && v <= 4
          : v >= 1 && v <= 6)) {
    return 0;
  }
  if (!check) return v;
  return foot(_edC[v]) ? v : 0;
}

/// The edition ID of a 16 MB image as the Studio reads it (ctx.editionId), 0 unknown.
int romEdition(Uint8List rom) {
  if (core.isNeon(rom)) return 8;
  for (final p in const [0xD29000, 0xD49000, 0xEFD000]) {
    final v = _edPage(rom, p, true);
    if (v != 0) return v;
  }
  for (final p in const [0xD49000, 0xD29000]) {
    final v = p + 4 <= rom.length ? u32(rom, p) : 0;
    if (v >= 1 && v <= 6) return v;
  }
  return 0;
}

// ------------------------------------------------------------------ device
/// What the save handlers of app.js ask of the device (flash.js Paradise).
abstract class SaveDevice {
  /// d.info.edition and d.info.name.
  int get edition;
  String get name;
  Future<Uint8List> read(int off, int len);
  Future<int> crc(int off, int len);

  /// Seconds counter and clock control register; null with an older flash app.
  Future<ParaClockIn?> clockRead();
  Future<bool> clockSet(int v);

  /// writeSectors of flash.js in its steps: ready(), then the writer is opened, every sector
  /// is put and checked by the device, then the writer is closed.
  void ready();
  Future<void> writeBegin();
  Future<void> putSector(int s, Uint8List d);
  Future<void> writeFinish();
}

/// The real Paradise behind [SaveDevice].
class ParadiseSaveDevice implements SaveDevice {
  ParadiseSaveDevice(this.dev);
  final Paradise dev;

  @override
  int get edition => dev.info!.edition;
  @override
  String get name => dev.info!.name;
  @override
  Future<Uint8List> read(int off, int len) => dev.read(off, len);
  @override
  Future<int> crc(int off, int len) => dev.crc(off, len);

  // flash.js clockRead (469): counter and ctrl (flash.dart's clockRead gives the counter only)
  @override
  Future<ParaClockIn?> clockRead() async {
    try {
      final r = await dev.link.request(cmdClockRead, 0, null, 2500);
      if (r.payload.length == 8) return ParaClockIn(u32(r.payload, 0), u32(r.payload, 4));
    } on FlashTimeout {
      // older app
    }
    return null;
  }

  @override
  Future<bool> clockSet(int v) => dev.clockSet(v & 0xFFFFFFFF);
  @override
  void ready() => dev.ready();

  // flash.js writeSectors (510-512)
  @override
  Future<void> writeBegin() async {
    final st = await dev.writeState();
    if (!(st.payload.length >= 16 && u32(st.payload, 12) != 0)) await dev.link.request(cmdWriteTest, 0, null, 15000);
    await dev.link.request(cmdWriteBegin, 0, Uint8List(36), 15000);
  }

  @override
  Future<void> putSector(int s, Uint8List d) => dev.putSector(s, d);
  @override
  Future<void> writeFinish() async {
    await dev.link.request(cmdWriteFinish, 0, null, 15000);
  }
}

typedef Cancel = bool Function();

Uint8List _ffPage() => Uint8List(sector)..fillRange(0, sector, 0xFF);

/// flash.js usedSectors (481): which 4 KB sectors in [from, to) are not empty. Uses the CRC,
/// reads nothing.
Future<List<int>> usedSectors(SaveDevice d, int from, int to, [Progress? progress, Cancel? cancel]) async {
  final ff = Uint8List(block64)..fillRange(0, block64, 0xFF), cB = crc32(ff, 0, block64), cS = crc32(ff, 0, sector), out = <int>[];
  for (var off = from & ~(block64 - 1); off < to; off += block64) {
    if (cancel != null && cancel()) throw FlashError('cancelled', 'cancelled');
    if (await d.crc(off, block64) != cB) {
      for (var s = off; s < off + block64; s += sector) {
        if (s >= from && s < to && await d.crc(s, sector) != cS) out.add(s);
      }
    }
    progress?.call('compare', off + block64 - from, to - from);
  }
  return out;
}

/// flash.js changed (615): sectors where the device differs from img, in [from, to).
Future<Set<int>> changed(SaveDevice d, Uint8List img, [Progress? progress, Cancel? cancel, int from = 0, int to = flashSize]) async {
  final out = <int>{};
  for (var off = from; off < to; off += block64) {
    if (cancel != null && cancel()) throw FlashError('cancelled', 'cancelled');
    if (await d.crc(off, block64) != crc32(img, off, block64)) {
      for (var s = off; s < off + block64; s += sector) {
        if (await d.crc(s, sector) != crc32(img, s, sector)) out.add(s);
      }
    }
    progress?.call('compare', off + block64 - from, to - from);
  }
  return out;
}

/// flash.js writeSectors (500): single 4 KB sectors (address -> data), checked one by one.
/// [guard] is the flash app (FL.embedded()): with the rescue start on the device, the device's
/// own table is off while the pages are written and comes back last, also after a cancel.
/// Returns the number of sectors of [map] written.
Future<int> writeSectors(SaveDevice d, Map<int, Uint8List> map, [Progress? progress, Cancel? cancel, Uint8List? guard]) async {
  d.ready();
  var jobs = [for (final s in map.keys.toList()..sort()) (s, map[s]!)];
  var extra = 0;
  if (guard != null && !map.containsKey(0)) {
    final hdr = Uint8List.fromList(await d.read(0, sector)), rb = rescueBlock(guard, hdr, Uint8List.fromList(await d.read(batPicOff, sector)));
    if (rb != null && await d.crc(rescueOff, block64) == crc32(rb)) {
      jobs = [(0, _ffPage()), ...jobs, (0, hdr)];
      extra = 2;
    }
  }
  await d.writeBegin();
  var n = 0;
  for (var q = 0; q < jobs.length; q++) {
    if (cancel != null && cancel()) {
      // the table always comes back
      const msg = 'cancelled. Keep the device switched on and write again';
      if (extra == 0 || n == jobs.length - 1) throw FlashError('cancelledWrite', msg);
      if (n != 0) {
        jobs = [...jobs.sublist(0, n), jobs.last];
        cancel = null;
      } else {
        throw FlashError('cancelledWrite', msg);
      }
    }
    final (s, data) = jobs[q];
    await d.putSector(s, data);
    n++;
    progress?.call('write', n, jobs.length);
  }
  await d.writeFinish();
  return n - extra;
}

/// What "Back up save" got from the device.
class DeviceBackup {
  DeviceBackup({required this.file, required this.name, required this.save, required this.clock, required this.used, required this.message});

  /// The .tamasave and its file name.
  final Uint8List file;
  final String name;

  /// The same, decoded.
  final ParaSave save;

  /// The clock is in the save.
  final bool clock;

  /// Pages read from the device (the others are empty there).
  final int used;
  final String message;
}

/// "Back up save" (btnSaveRead, app.js:3531-3539 and 3576), the Paradise save with its clock:
/// the region of the device's edition, only the used sectors are read (usedSectors over the
/// CRC), in ascending order; then the clock. Empty pages are 0xFF. The emulator saves the
/// same button also takes (TamaEmu, T7Emu, app.js:3540-3575) are not part of this.
Future<DeviceBackup> devSaveRead(SaveDevice d, {Progress? progress, Cancel? cancel, DateTime? now}) async {
  final ed = d.edition, r = region(ed), a = r[0], b = r[1];
  final used = await usedSectors(d, a, b, progress, cancel);
  final pages = <int, Uint8List>{}, ff = _ffPage();
  for (var p = a; p < b; p += 0x1000) {
    pages[p] = ff;
  }
  var n = 0;
  for (final s in used) {
    if (cancel != null && cancel()) throw FlashError('cancelled', 'cancelled');
    pages[s] = Uint8List.fromList(await d.read(s, 0x1000));
    progress?.call('read', ++n * 0x1000, used.length * 0x1000);
  }
  final clock = await d.clockRead();
  final name = '${edSlug(ed)}-${stamp(now)}.tamasave';
  final withClock = clock != null && (clock.ctrl & 0x80) != 0;
  final file = paraEncode(pages, ed, withClock ? clock : null, _secs(now));
  return DeviceBackup(
    file: file,
    name: name,
    save: paraDecode(file),
    clock: withClock && clock.counter != 0,
    used: used.length,
    message: t('devSaveGot', {'n': name}) + (clock != null ? '' : ' ${t('devSaveClockNo')}'),
  );
}

/// A save checked against a device or a ROM: what [devSaveCheck] gives.
class SaveToDevice {
  SaveToDevice(this.chk, this.error, this.warn, this.confirm);
  final ParaCheck chk;

  /// "Error: ..." when the save cannot go there, else null.
  final String? error;

  /// The warnings, one per line ('' without).
  final String warn;

  /// The question to confirm before writing.
  final String confirm;
}

/// "Save to device", before the write (fileSave, app.js:3583-3590): paraCheck against the
/// device's edition, errors as "Error: a, b", warnings behind the confirm text.
SaveToDevice devSaveCheck(ParaSave save, int devEdition, String devName) {
  final chk = paraCheck(save, devEdition);
  final warn = chk.warnings.map(saveMsg).join('\n');
  return SaveToDevice(
    chk,
    chk.errors.isNotEmpty ? t('devErr', {'e': chk.errors.map(saveMsg).join(', ')}) : null,
    warn,
    t('devSaveSure', {'ed': devName}) + (warn.isNotEmpty ? '\n\n$warn' : ''),
  );
}

class DeviceWritten {
  DeviceWritten(this.written, this.planned, this.clock, this.message);

  /// Pages written, and pages that differed. Fewer written than planned: the write was
  /// cancelled with the rescue start on the device (flash.js then stops early, puts the
  /// device's table back and ends without an error; app.js reports it as done).
  final int written, planned;
  final bool clock;
  final String message;
}

/// "Save to device", the live save (fileSave, app.js:3591-3602): a 16 MB image of 0xFF with the
/// checked pages; the device's 64 KB blocks from the one the region starts in up to 0xF00000
/// are compared by CRC; only pages of the save that differ are written (ascending, the rescue
/// guard around them); then the clock is set to the saved counter plus the time since
/// (paraClock), when the save has one.
Future<DeviceWritten> devSaveWrite(SaveDevice d, ParaSave save, ParaCheck chk, {Uint8List? guard, Progress? progress, Cancel? cancel, DateTime? now}) async {
  final r = region(d.edition), a = r[0], b = r[1];
  // only pages that differ from the device
  final img = Uint8List(flashSize)..fillRange(0, flashSize, 0xFF);
  chk.pages.forEach((p, data) => img.setAll(p, data));
  final diff = await changed(d, img, progress, cancel, a & ~0xFFFF, b);
  final map = <int, Uint8List>{};
  chk.pages.forEach((p, data) {
    if (diff.contains(p)) map[p] = data;
  });
  final w = map.isNotEmpty ? await writeSectors(d, map, progress, cancel, guard) : 0;
  final v = paraClock(save, _secs(now));
  final cl = v != null && await d.clockSet(v);
  return DeviceWritten(w, map.length, cl, t('devSaveDone', {'w': w, 'c': cl ? t('devSaveClock') : t('devSaveClockNo')}));
}

// ------------------------------------------------------------------ slots of the menu
/// One line of the Studio's "Slot" list (renderSave, app.js:3239-3240).
class SlotChoice {
  SlotChoice(this.index, this.label, this.used);

  /// -1: the save in use ("live"), else the slot.
  final int index;
  final String label;
  final bool used;
  bool get live => index < 0;
}

/// app.js paraSlots (3245): the save slots the menu of this ROM keeps, null without.
/// [stubTpl]: stub_feld_tpl.bin.
feld.SaveSlots? paraSlots(Uint8List rom, Uint8List stubTpl) {
  try {
    return feld.saveSlots(rom, stubTpl);
  } catch (_) {
    return null;
  }
}

/// app.js slotLabel (3246).
String slotLabel(feld.SaveSlots ss, Uint8List rom, int i) {
  if (ss.saves) return t('saveSlot', {'n': i + 1});
  final fn = feld.fieldNames(rom);
  return i >= 0 && i < fn.length && fn[i].isNotEmpty ? fn[i] : t('saveSlot', {'n': i + 1});
}

/// The options of the slot list (renderSave, app.js:3239-3240).
List<SlotChoice> slotChoices(feld.SaveSlots ss, Uint8List rom) => [
      if (ss.live < 0) SlotChoice(-1, t('slotLive', {'n': feld.fieldNow(rom)}), true),
      for (final x in ss.list)
        x.i == ss.live
            ? SlotChoice(-1, t('slotLive', {'n': slotLabel(ss, rom, x.i)}), true)
            : SlotChoice(x.i, x.used ? slotLabel(ss, rom, x.i) : t('slotEmpty', {'n': slotLabel(ss, rom, x.i)}), x.used),
    ];

// app.js slotWrite / btnSlotClear: the menu's settings block on the device against the ROM's
Future<void> _slotSameMenu(SaveDevice d, Uint8List rom, feld.FeldInfo f) async {
  final mine = Uint8List.sublistView(rom, f.off + 0x140, f.off + 0x140 + 0x180), dev = Uint8List.sublistView(await d.read(f.off, 0x1000), 0x140, 0x140 + 0x180);
  for (final o in const [0, 8, 12, 16, 364, 368]) {
    if (mine[o] != dev[o] || mine[o + 1] != dev[o + 1] || mine[o + 2] != dev[o + 2] || mine[o + 3] != dev[o + 3]) throw _err('slotDevOther');
  }
}

/// "Write to device" into slot [i], before the write (slotWrite, app.js:3607-3613): with one
/// save per field the save's field must be the slot's. Returns the question to confirm.
String slotWriteCheck(feld.SaveSlots ss, Uint8List rom, ParaCheck chk, int i, [String warn = '']) {
  if (!ss.saves) {
    final fi = feld.fieldOfSettings(rom, chk.pages[0xEFE000]), fn = feld.fieldNames(rom);
    if (fi != i) throw SaveFlowError('slotField', t('devErr', {'e': t('slotField', {'a': fi >= 0 && fi < fn.length && fn[fi].isNotEmpty ? fn[fi] : '?', 'b': slotLabel(ss, rom, i)})}));
  }
  return t('slotSure', {'n': slotLabel(ss, rom, i)}) + (warn.isNotEmpty ? '\n\n$warn' : '');
}

/// A save into slot [i] of the menu on the device (slotWrite, app.js:3614-3627): packed like
/// the menu does it; first the header page as 0xFF and all other pages, then the header page.
Future<String> slotWrite(SaveDevice d, feld.SaveSlots ss, Uint8List rom, ParaCheck chk, int i, {Uint8List? guard, Progress? progress, Cancel? cancel}) async {
  final f = ss.f, r = region(d.edition), a = r[0], b = r[1];
  await _slotSameMenu(d, rom, f);
  final heads = <Uint8List?>[];
  for (var j = 0; j < f.nslots; j++) {
    heads.add(Uint8List.fromList(await d.read(feld.slotAddr(f, j), 0x1000)));
  }
  final s = feld.slotBuild(chk.pages, i, a, b), img = Uint8List(flashSize)..fillRange(0, flashSize, 0xFF);
  final written = feld.slotPlace(img, f, i, s, feld.poolUsed(f, heads, i));
  final first = <int, Uint8List>{written[0]: _ffPage()};
  for (final p in written.skip(1)) {
    first[p] = Uint8List.fromList(Uint8List.sublistView(img, p, p + 0x1000));
  }
  await writeSectors(d, first, progress, cancel, guard);
  await writeSectors(d, {written[0]: Uint8List.fromList(Uint8List.sublistView(img, written[0], written[0] + 0x1000))}, progress, cancel, guard);
  return t('slotDone', {'n': slotLabel(ss, rom, i)});
}

/// "Clear slot" (btnSlotClear, app.js:3260-3270): the header page of slot [i] on the device is
/// erased. Returns the ROM with the same page blanked and the text.
Future<(Uint8List rom, String message)> slotClear(SaveDevice d, feld.SaveSlots ss, Uint8List rom, int i, {Uint8List? guard, Progress? progress, Cancel? cancel}) async {
  final f = ss.f;
  await _slotSameMenu(d, rom, f);
  final at = feld.slotAddr(f, i);
  await writeSectors(d, {at: _ffPage()}, progress, cancel, guard);
  final out = Uint8List.fromList(rom)..fillRange(at, at + 0x1000, 0xFF);
  return (out, t('slotClearDone', {'n': slotLabel(ss, rom, i)}));
}

// ------------------------------------------------------------------ ROM image
/// The save of a ROM as the pet editor opens it ("Save in the ROM", btnPetRom,
/// app.js:3405-3408): every page of the region, no clock.
ParaSave romSave(Uint8List rom, [int? edition]) {
  final ed = edition ?? romEdition(rom);
  return ParaSave(stamp: 0, counter: 0, alarm: 0, status: 0, regs: [], pages: paraFromImage(rom, ed), edition: ed);
}

/// A save stored in slot [i] of the menu of a ROM (btnParaOut, app.js:3461-3466): every page
/// of the region, from the slot or 0xFF. Throws "There is no save in this slot.".
Future<ParaSave> romSlotSave(Uint8List rom, feld.SaveSlots ss, int i, [int? edition]) async {
  final ed = edition ?? romEdition(rom);
  final sv = await feld.slotReadAsync((a, n) async => Uint8List.sublistView(rom, a, a + n), ss.f, i);
  if (sv == null) throw _err('slotNone');
  final r = region(ed), got = feld.slotPages(sv), pages = <int, Uint8List>{};
  for (var p = r[0]; p < r[1]; p += 0x1000) {
    pages[p] = got[p] ?? _ffPage();
  }
  return ParaSave(stamp: 0, counter: 0, alarm: 0, status: 0, regs: [], pages: pages, edition: ed);
}

class SavedFile {
  SavedFile(this.bytes, this.name, this.message);
  final Uint8List bytes;
  final String name, message;
}

/// "Export (.tamasave)" of the Save tab (btnParaOut, app.js:3458-3470): the save of the ROM
/// (or of slot [slot] of its menu) without a clock, named `<edition>[-<slot>]-<stamp>.tamasave`.
Future<SavedFile> romSaveExport(Uint8List rom, {feld.SaveSlots? slots, int slot = -1, DateTime? now}) async {
  final ed = romEdition(rom);
  var pages = paraFromImage(rom, ed), tag = '';
  if (slot >= 0) {
    if (slots == null) throw _err('slotNone');
    pages = (await romSlotSave(rom, slots, slot, ed)).pages;
    tag = '-${slotLabel(slots, rom, slot).toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '')}';
  }
  final name = '${edSlug(ed)}$tag-${stamp(now)}.tamasave';
  return SavedFile(paraEncode(pages, ed, null, _secs(now)), name, t('saveNoClock', {'n': name}));
}

/// A save put into a ROM image. The Studio does this for the ROM's own changed save
/// (btnPetSave, app.js:3447-3448: every 4 KB page of the save goes to its address in a copy);
/// for a save from elsewhere the rules of "Save to device" apply first (paraCheck against the
/// ROM's edition: wrong edition and a missing settings block are refused, pages outside the
/// region are left out, pages the save lacks stay as in the ROM). Throws [SaveFlowError].
(Uint8List rom, String warn) romSaveWrite(Uint8List rom, ParaSave save) {
  final ed = romEdition(rom), c = devSaveCheck(save, ed, editionNames[ed] ?? 'Edition $ed');
  if (c.error != null) throw SaveFlowError('devErr', c.error!);
  final r = Uint8List.fromList(rom);
  c.chk.pages.forEach((a, d) {
    if (d.length == 0x1000 && a + 0x1000 <= r.length) r.setAll(a, d);
  });
  return (r, c.warn);
}

// ------------------------------------------------------------------ a game of the app
/// The save of a game played in the app. The app's core (Capybara) keeps a game in the same
/// file format as a .tamasave (format 3, with the clock and the system registers), but only
/// the pages the game wrote since the dump, any page of the flash, and without the Paramix
/// trailer that names the edition. So it goes through the image: the ROM of the game with the
/// file's pages on it is the flash as the toy would hold it, and its save region (every page)
/// is the save; the clock of the file is kept.
ParaSave gameSave(Uint8List rom, Uint8List saveFile) {
  final g = paraDecode(saveFile), img = Uint8List.fromList(rom);
  g.pages.forEach((a, d) {
    if (a < img.length) img.setRange(a, a + d.length < img.length ? a + d.length : img.length, d);
  });
  final ed = romEdition(img);
  return ParaSave(stamp: g.stamp, counter: g.counter, alarm: g.alarm, status: g.status, regs: g.regs, pages: paraFromImage(img, ed), edition: ed);
}

// ------------------------------------------------------------------ pet editor
/// A save opened in the pet editor.
class PetOpen {
  PetOpen(this.save, this.edition, this.pet);

  /// The save with its edition set.
  final ParaSave save;
  final int edition;
  final ParaPet pet;
}

/// petOpen (app.js:3411-3417): the save's edition (or the ROM's when the file names none) must
/// be of the ROM's family, and the settings block must be there. [romEditionId]: ctx.editionId
/// of the ROM the names come from; null without a ROM (then the save must name its edition).
PetOpen petOpen(ParaSave save, int? romEditionId) {
  final ed = save.edition != 0 ? save.edition : (romEditionId ?? 0);
  if (romEditionId != null && family(ed) != family(romEditionId)) throw _err('petOther');
  final pet = ed == 0 ? null : paraPet(save, ed);
  if (pet == null) throw _err('petNoSet');
  return PetOpen(save.copyWith(edition: ed), ed, pet);
}

/// A character of the pickers: option value id:stage, text as the Studio shows it.
class PetChar {
  PetChar(this.id, this.stage, this.name, this.field);
  final int id, stage;

  /// Capitalised name.
  final String name;

  /// Field name or ''.
  final String field;
  String get text => name + (field.isNotEmpty ? ' ($field)' : '');
}

/// The groups of the character picker (petOpen, app.js:3422-3433): "Kid" (stage 3), "Teen"
/// (4), "Adult" (5) from F.characters(rom).
List<({String label, int stage, List<PetChar> chars})> petChars(Uint8List rom) {
  final chars = feld.characters(rom), fn = feld.fieldNames(rom);
  return [
    for (final (st, k) in const [(3, 'petKid'), (4, 'petYoung'), (5, 'petAdult')])
      (
        label: t(k),
        stage: st,
        chars: [
          for (final c in chars.where((x) => x.stage == st))
            PetChar(c.id, c.stage, _capital(c.name), c.field >= 0 && c.field < fn.length ? fn[c.field] : ''),
        ],
      ),
  ];
}

String _capital(String s) => s.isEmpty ? s : s[0] + s.substring(1).toLowerCase();

/// The status line of the editor (petNow, app.js:3436); the character by its name in the
/// picker's list, else its number.
String petNow(ParaPet pet, List<({String label, int stage, List<PetChar> chars})> groups) {
  var cur = '';
  for (final g in groups) {
    for (final c in g.chars) {
      if (c.id == pet.id) cur = c.name;
    }
  }
  return t('petNow', {'l': pet.level, 'c': cur.isNotEmpty ? cur : pet.id, 'h': pet.hunger, 'j': pet.happy, 's': pet.sick != 0 ? t('petSick') : ''});
}

/// What the editor changes: only what differs from the save (btnPetSave, app.js:3441-3445).
class PetChange {
  PetChange({this.level, this.id, this.stage, this.care = false});
  final int? level, id, stage;
  final bool care;
  bool get isEmpty => level == null && id == null && !care;
}

/// The change from the controls: [level] as chosen, [char] the chosen character or null for
/// "unchanged", [care] the "Fed, happy, healthy" tick.
PetChange petChange(ParaPet pet, {required int level, PetChar? char, bool care = false}) {
  final ch = char != null && (char.id != pet.id || char.stage != pet.stage);
  return PetChange(level: level != pet.level ? level : null, id: ch ? char.id : null, stage: ch ? char.stage : null, care: care);
}

/// The changed save (SV.paraPetSet). Throws "Nothing changed." without a change; errors of
/// paraPetSet (the Tama's own file is missing) come as [SaveFlowError] with the Studio's text.
ParaSave petApply(PetOpen o, PetChange ch) {
  if (ch.isEmpty) throw _err('petNothing');
  try {
    return paraPetSet(o.save, o.edition, level: ch.level, id: ch.id, stage: ch.stage, care: ch.care).copyWith(edition: o.edition);
  } on StateError catch (e) {
    throw SaveFlowError('petSet', e.message);
  }
}

/// "Save changed save" for the save of the ROM itself (btnPetSave, app.js:3446-3450): every
/// 4 KB page of the changed save goes into a copy of the ROM.
(Uint8List rom, ParaSave save, String message) petSaveRom(Uint8List rom, PetOpen o, PetChange ch) {
  final nw = petApply(o, ch), r = Uint8List.fromList(rom);
  nw.pages.forEach((a, d) {
    if (d.length == 0x1000) r.setAll(a, d);
  });
  return (r, nw, t('petRomDone'));
}

/// "Save changed save" for a save from a file (btnPetSave, app.js:3452-3455): written back as
/// it was (time stamp, clock, registers kept) under `<name>-<stamp>.tamasave`.
SavedFile petSaveFile(PetOpen o, PetChange ch, String petName, {DateTime? now}) {
  final out = paraWrite(petApply(o, ch), o.edition);
  final name = '${petName.replaceFirst(RegExp(r'\.tamasave$', caseSensitive: false), '')}-${stamp(now)}.tamasave';
  return SavedFile(out, name, t('petDone', {'n': name}));
}

// ------------------------------------------------------------------ names and pictures
/// A character of the ROM's character table with its name and first picture.
class CharLook {
  CharLook(this.id, this.stage, this.name, this.picture);
  final int id, stage;

  /// Capitalised name, '' when the ROM has none in Latin letters.
  final String name;
  final Rgba? picture;
}

/// Every character of the ROM (also the ones the pickers do not offer: babies, specials), by
/// ID: the name from the texts (C.charTable, C.textGet) and the first picture of its sprite
/// group (C.charGroups). For showing what is in a save; the Studio shows the number there.
Map<int, CharLook> charLooks(Uint8List rom, {bool pictures = true}) {
  final out = <int, CharLook>{};
  try {
    final ctx = core.openRom(rom);
    final group = <int, int>{
      for (final c in core.charGroups(ctx))
        if (c.group != null) c.id: c.group!,
    };
    for (final c in core.charTable(ctx.files[0])) {
      if (c.id <= 1000 || c.id >= 9000) continue;
      Rgba? pic;
      final g = group[c.id];
      if (pictures && g != null && g >= 0 && g < ctx.entries.length) {
        try {
          pic = spriteDecode(ctx.entries[g]);
        } catch (_) {
          // no picture
        }
      }
      out[c.id] = CharLook(c.id, c.stage, _capital(core.textGet(rom, c.name)), pic);
    }
  } catch (_) {
    // not a ROM with a character table
  }
  return out;
}
