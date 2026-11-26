// The native Paramix device protocol against a simulated flash app (PAU1 over a fake serial
// line, 16 MB flash in memory): connect, read, only changes, keep saves, other edition refused.
// And the save flow of the Studio's Save tab and device panel (lib/paramix/save_flow.dart)
// against the same simulated toy: back up, edit, write back, read again; file round trips.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tama_tools/paramix/bytes.dart';
import 'package:tama_tools/paramix/feld.dart' as feld;
import 'package:tama_tools/paramix/flash.dart';
import 'package:tama_tools/paramix/save_flow.dart' as sf;
import 'package:tama_tools/paramix/saves.dart';

/// The device side of PAU1, as Paramix's flash app (flash/src/fw.c) answers.
class FakeFlashApp {
  FakeFlashApp(this.flash);
  final Uint8List flash;
  final _toHost = StreamController<Uint8List>.broadcast();
  final List<int> _rx = [];
  final Uint8List _buf = Uint8List(sector);
  int writes = 0;

  /// Sectors in the order they were committed.
  final List<int> committed = [];

  /// The always powered clock: seconds counter and control register (bit 7: running). A
  /// flash app before 1.3.0 does not know the clock commands ([hasClock] false: no answer).
  int counter = 0, ctrl = 0xE0;
  bool hasClock = true;

  Stream<Uint8List> get toHost => _toHost.stream;

  Future<void> fromHost(Uint8List d) async {
    for (final b in d) {
      if (b == 0) {
        if (_rx.isNotEmpty) _frame(cobsDecode(Uint8List.fromList(_rx), _rx.length));
        _rx.clear();
      } else {
        _rx.add(b);
      }
    }
  }

  void _reply(Uint8List req, Uint8List payload, [int status = 0]) {
    final plen = payload.length;
    final d = Uint8List(28 + plen);
    d.setAll(0, req.sublist(0, 20));
    d[20] = plen & 255;
    d[21] = plen >> 8;
    d[22] = status;
    d.setAll(24, payload);
    w32(d, 24 + plen, crc32(d, 0, 24 + plen));
    scheduleMicrotask(() => _toHost.add(cobsEncode(d)));
  }

  void _frame(Uint8List d) {
    if (d.length < 28 || u32(d, 0) != 0x31554150) return;
    final type = d[6], off = u32(d, 16), plen = d[20] | (d[21] << 8);
    final p = Uint8List.sublistView(d, 24, 24 + plen);
    switch (type) {
      case cmdHello:
        final h = Uint8List(44);
        h[8] = 1;
        w16(h, 10, 4096);
        w32(h, 24, 0xC22018);
        w32(h, 32, flashSize);
        _reply(d, h);
      case cmdRead:
        final n = u32(p, 0);
        _reply(d, Uint8List.fromList(flash.sublist(off, off + n)));
      case cmdCrc:
        _reply(d, le32(crc32(flash, off, u32(p, 0))));
      case cmdWriteState:
        _reply(d, Uint8List(16)..[12] = 1);
      case cmdWriteBegin:
        _reply(d, le32(0));
      case cmdWriteData:
        _buf.setAll(off & (sector - 1), p);
        _reply(d, Uint8List(0));
      case cmdWriteCommit:
        flash.setAll(off, _buf);
        writes++;
        committed.add(off);
        final r = Uint8List(8);
        w32(r, 0, crc32(flash, off, sector));
        _reply(d, r);
      case cmdWriteTest:
      case cmdWriteFinish:
        _reply(d, Uint8List(0));
      case cmdClockRead:
        if (!hasClock) return;
        final r = Uint8List(8);
        w32(r, 0, counter);
        w32(r, 4, ctrl);
        _reply(d, r);
      case cmdClockSet:
        if (!hasClock) return;
        counter = u32(p, 0);
        _reply(d, le32(counter));
    }
  }
}

Uint8List landImage() {
  final img = Uint8List(flashSize)..fillRange(0, flashSize, 0xFF);
  img.setAll(0, 'SONIXDEV'.codeUnits);
  final r = Random(1);
  for (var i = 0x11000; i < 0x300000; i++) {
    img[i] = r.nextInt(256);
  }
  // edition ID page: Land (1) with its footer
  const c = 0x70169E2C, k = c - 1;
  w32(img, 0xD49000, 1);
  w32(img, 0xD49000 + 0xFF8, k);
  w32(img, 0xD49000 + 0xFFC, ~k & 0xFFFFFFFF);
  // a save page
  for (var i = 0xEFE000; i < 0xEFF000; i++) {
    img[i] = i & 255;
  }
  return img;
}

void main() {
  test('connect, read, write only changes and keep the save', () async {
    final device = landImage();
    final app = FakeFlashApp(device);
    final link = FlashLink(app.toHost, app.fromHost);
    final (dev, loaded) = await connectParadise(link, Uint8List(16), null);
    expect(loaded, isFalse); // the flash app already answered
    expect(dev.info!.name, 'Land');

    final r = await dev.read(0x20000, 0x3000);
    expect(r, device.sublist(0x20000, 0x23000));

    // new image: one byte in the characters, one in the save
    final img = Uint8List.fromList(device);
    img[0x200010] ^= 0x5A;
    img[0xEFE100] ^= 0x33;
    final saveBefore = Uint8List.fromList(device.sublist(0xEFE000, 0xEFF000));
    final res = await dev.write(img, onlyChanged: true, keepSaves: true);
    expect(res.written, 1);
    expect(res.kept, 1);
    expect(device.sublist(0xEFE000, 0xEFF000), saveBefore);
    expect(device[0x200010], img[0x200010]);

    // without keep: the save sector is written too
    final res2 = await dev.write(img, onlyChanged: true, keepSaves: false);
    expect(res2.written, 1);
    expect(device, img);

    // another firmware family (Jade Forest) is refused with keep saves; Land -> Water (same
    // firmware) would be allowed and keep the device's field, as in Paramix
    final other = Uint8List.fromList(img);
    w32(other, 0xD49000, 4);
    w32(other, 0xD49000 + 0xFF8, 0x849633DB - 4);
    w32(other, 0xD49000 + 0xFFC, ~(0x849633DB - 4) & 0xFFFFFFFF);
    await expectLater(dev.write(other, onlyChanged: true, keepSaves: true), throwsA(isA<FlashError>()));
    link.dispose();
  });

  saveFlowTests();
}

// ---------------------------------------------------------------- the save flow (save_flow.dart)

const int _tama = 0x104, _level = 0x7C; // Land/Water/Sky: the pet and the planet level in the settings block

void _crcFix(Uint8List p) {
  final c = crc16arc(p, 4, 0x1000);
  p[0] = c & 255;
  p[1] = c >> 8;
  p[2] = ~c & 255;
  p[3] = (~c >> 8) & 255;
}

/// A settings block as the game keeps it at 0xEFE000 and 0xEFF000.
Uint8List settingsPage({int id = 2003, int stage = 3, int level = 2, int hunger = 1, int happy = 4, int sick = 1}) {
  final r = Random(7), p = Uint8List(0x1000);
  for (var i = 0x200; i < 0x1000; i++) {
    p[i] = r.nextInt(256);
  }
  w16(p, 12, 0x0150); // not 0x016D: that marks Tropical/Glacier
  p[_level] = level;
  w16(p, _tama + 4, id);
  w16(p, _tama + 6, id);
  p[_tama + 0x10] = sick;
  p[_tama + 0x18] = stage << 2;
  p[_tama + 0x1C] = hunger;
  p[_tama + 0x1D] = happy;
  _crcFix(p);
  return p;
}

/// A Land toy with a game on it: settings block twice, the Tama's own file, some game data.
Uint8List landToy() {
  final img = landImage();
  final set = settingsPage();
  img.setAll(0xEFE000, set);
  img.setAll(0xEFF000, set);
  final file = Uint8List(0x1000)..fillRange(0, 0x1000, 0xFF);
  w32(file, 8, 1);
  w16(file, 12, 0);
  w16(file, 14, 2003);
  w16(file, 0x10A, 2003);
  img.setAll(0xD60000, file);
  final r = Random(3);
  for (var i = 0xD4C000; i < 0xD4E000; i++) {
    img[i] = r.nextInt(256);
  }
  return img;
}

Future<(FakeFlashApp, FlashLink, sf.SaveDevice)> _connect(Uint8List flash) async {
  final app = FakeFlashApp(flash);
  final link = FlashLink(app.toHost, app.fromHost);
  final (dev, _) = await connectParadise(link, Uint8List(16), null);
  return (app, link, sf.ParadiseSaveDevice(dev));
}

void saveFlowTests() {
  final t0 = DateTime(2026, 3, 4, 5, 6);

  test('back up the save from the toy, edit it, write it back, read again', () async {
    final flash = landToy(), before = Uint8List.fromList(flash);
    final (app, link, d) = await _connect(flash);
    app.counter = 5000;
    expect(d.edition, 1);

    // "Back up save": every page of the region, the used ones read, the clock with it
    final phases = <String>{};
    final bk = await sf.devSaveRead(d, progress: (p, a, b) => phases.add(p), now: t0);
    expect(bk.name, 'land-20260304-0506.tamasave');
    expect(bk.message, 'Backed up: land-20260304-0506.tamasave.');
    expect(bk.used, 5);
    expect(bk.clock, isTrue);
    expect(phases, {'compare', 'read'});
    expect(app.writes, 0);
    final r = region(1);
    expect(bk.save.pages.length, (r[1] - r[0]) ~/ 0x1000);
    expect(bk.save.edition, 1);
    expect(bk.save.counter, 5000);
    for (final e in bk.save.pages.entries) {
      expect(e.value, before.sublist(e.key, e.key + 0x1000), reason: 'page ${hex(e.key)}');
    }

    // the editor: what is in it, then level, character and care
    final o = sf.petOpen(bk.save, 1);
    expect(o.pet.toJson(), {'level': 2, 'id': 2003, 'stage': 3, 'hunger': 1, 'happy': 4, 'sick': 1});
    expect(sf.petNow(o.pet, const []), 'In the save: level 2, Tama 2003, hunger 1/6, happiness 4/20, sick.');
    expect(() => sf.petApply(o, sf.petChange(o.pet, level: 2)), throwsA(isA<sf.SaveFlowError>().having((e) => e.message, 'message', 'Nothing changed.')));
    final ch = sf.petChange(o.pet, level: 7, char: sf.PetChar(4011, 5, 'Mametchi', 'Land'), care: true);
    final edited = sf.petApply(o, ch);
    expect(paraPet(edited, 1)!.toJson(), {'level': 7, 'id': 4011, 'stage': 5, 'hunger': 6, 'happy': 20, 'sick': 0});

    // "Save to device": only the pages that differ (two settings blocks, the Tama's file), the clock
    final c = sf.devSaveCheck(edited, d.edition, d.name);
    expect(c.error, isNull);
    expect(c.warn, '');
    expect(c.confirm, 'The save is written to the device (Land) and replaces the current one. Continue?');
    final w = await sf.devSaveWrite(d, edited, c.chk, now: t0.add(const Duration(seconds: 90)));
    expect(w.written, 3);
    expect(app.committed, [0xD60000, 0xEFE000, 0xEFF000]);
    expect(w.clock, isTrue);
    expect(app.counter, 5090); // the saved counter plus the time since
    expect(w.message, 'Done: 3 pages written. Clock taken over. The device can be restarted.');
    // nothing outside the save changed
    expect(flash.sublist(0, r[0]), before.sublist(0, r[0]));
    expect(flash.sublist(r[1]), before.sublist(r[1]));

    // read again: the toy holds the edited save, page for page
    final again = await sf.devSaveRead(d, now: t0);
    expect(paraPet(again.save, 1)!.toJson(), paraPet(edited, 1)!.toJson());
    expect(again.save.pages.keys.toList(), edited.pages.keys.toList());
    for (final e in edited.pages.entries) {
      expect(again.save.pages[e.key], e.value, reason: 'page ${hex(e.key)}');
    }
    expect(u16(flash, 0xD60000 + 14), 4011);
    expect(u16(flash, 0xD60000 + 0x10A), 4011);

    // the same save again: nothing to write
    app.committed.clear();
    final w2 = await sf.devSaveWrite(d, edited, c.chk, now: t0);
    expect(w2.written, 0);
    expect(app.committed, isEmpty);

    // and the backup from before brings the old game back
    final back = sf.devSaveCheck(bk.save, d.edition, d.name);
    await sf.devSaveWrite(d, bk.save, back.chk, now: t0);
    expect(flash, before);
    link.dispose();
  });

  test('a toy without the clock commands, and a save without a clock', () async {
    final flash = landToy();
    final (app, link, d) = await _connect(flash);
    app.hasClock = false;
    final bk = await sf.devSaveRead(d, now: t0);
    expect(bk.clock, isFalse);
    expect(bk.save.counter, 0);
    expect(bk.message, 'Backed up: land-20260304-0506.tamasave. Please set the clock on the device.');
    app.hasClock = true;
    app.counter = 77;
    final edited = sf.petApply(sf.petOpen(bk.save, 1), sf.PetChange(care: true));
    final w = await sf.devSaveWrite(d, edited, sf.devSaveCheck(edited, 1, 'Land').chk, now: t0);
    expect(w.written, 2);
    expect(w.clock, isFalse);
    expect(app.counter, 77); // not touched
    expect(w.message, 'Done: 2 pages written. Please set the clock on the device. The device can be restarted.');
    // a stopped clock (bit 7 of the control register clear) is not taken either
    app.ctrl = 0x60;
    expect((await sf.devSaveRead(d, now: t0)).clock, isFalse);
    link.dispose();
  });

  test('saves that do not fit are refused with the Studio\'s texts', () async {
    final flash = landToy();
    final (_, link, d) = await _connect(flash);
    final bk = await sf.devSaveRead(d, now: t0);
    // from another edition
    final jade = bk.save.copyWith(edition: 4);
    expect(sf.devSaveCheck(jade, 1, 'Land').error, 'Error: the save is from another edition (Jade Forest), the device is Land');
    // Water on a Land toy: the same firmware, it fits
    expect(sf.devSaveCheck(bk.save.copyWith(edition: 2), 1, 'Land').error, isNull);
    // without the settings block
    final none = bk.save.copyWith(pages: Map.of(bk.save.pages)..remove(0xEFE000)..remove(0xEFF000));
    expect(sf.devSaveCheck(none, 1, 'Land').error, 'Error: the settings block is missing, this is not a complete Paradise save');
    expect(() => sf.petOpen(none, 1), throwsA(isA<sf.SaveFlowError>().having((e) => e.message, 'message', 'The settings block is missing in the save.')));
    expect(() => sf.petOpen(jade, 1), throwsA(isA<sf.SaveFlowError>().having((e) => e.message, 'message', 'The save is for another edition than the loaded ROM.')));
    // a settings block of Tropical/Glacier
    final g3 = Uint8List.fromList(bk.save.pages[0xEFE000]!);
    w16(g3, 12, 0x016D);
    _crcFix(g3);
    expect(sf.devSaveCheck(bk.save.copyWith(pages: Map.of(bk.save.pages)..[0xEFE000] = g3), 1, 'Land').error, 'Error: the save does not fit this edition');
    // a partial save with a page from elsewhere: warnings, written all the same, the rest stays
    final part = bk.save.copyWith(pages: {0xEFE000: bk.save.pages[0xEFE000]!, 0xEFF000: bk.save.pages[0xEFF000]!, 0x100000: Uint8List(0x1000)});
    final c = sf.devSaveCheck(part, 1, 'Land');
    expect(c.error, isNull);
    expect(c.warn, '1 pages lie outside the save and are not written\nthe save does not hold every page, missing ones stay as on the device');
    expect(c.confirm, endsWith('Continue?\n\n${c.warn}'));
    final before = Uint8List.fromList(flash);
    final edited = sf.petApply(sf.petOpen(part, 1), sf.PetChange(level: 9));
    final w = await sf.devSaveWrite(d, edited, sf.devSaveCheck(edited, 1, 'Land').chk, now: t0);
    expect(w.written, 2);
    expect(flash.sublist(0, 0xEFE000), before.sublist(0, 0xEFE000));
    expect(paraPet((await sf.devSaveRead(d, now: t0)).save, 1)!.level, 9);
    link.dispose();
  });

  test('with the rescue start on the toy its own table is off while the save is written', () async {
    final flash = landToy(), guard = Uint8List(0x800)..fillRange(0, 0x800, 0x5A);
    flash.setAll(rescueOff, rescueBlock(guard, Uint8List.sublistView(flash, 0, sector), Uint8List.fromList(flash.sublist(batPicOff, batPicOff + sector)))!);
    final hdr = Uint8List.fromList(flash.sublist(0, sector));
    final (app, link, d) = await _connect(flash);
    final bk = await sf.devSaveRead(d, now: t0);
    final o = sf.petOpen(bk.save, 1);
    final edited = sf.petApply(o, sf.petChange(o.pet, level: 5, char: sf.PetChar(4011, 5, '', '')));
    final chk = sf.devSaveCheck(edited, 1, 'Land').chk;
    final w = await sf.devSaveWrite(d, edited, chk, guard: guard, now: t0);
    expect(w.written, 3);
    expect(app.committed, [0, 0xD60000, 0xEFE000, 0xEFF000, 0]);
    expect(flash.sublist(0, sector), hdr);

    // cancelled after the first page: the table still comes back (flash.js ends such a write
    // without an error, with fewer pages than asked for)
    app.committed.clear();
    final chk2 = sf.devSaveCheck(bk.save, 1, 'Land').chk;
    final cut = await sf.devSaveWrite(d, bk.save, chk2, guard: guard, cancel: () => app.committed.length >= 2, now: t0);
    expect(app.committed, [0, 0xD60000, 0]);
    expect(cut.written, 1);
    expect(cut.planned, 3);
    expect(flash.sublist(0, sector), hdr);
    // cancelled before the first page: nothing is written
    app.committed.clear();
    await expectLater(
      sf.writeSectors(d, {0xEFE000: chk2.pages[0xEFE000]!}, null, () => true, guard),
      throwsA(isA<FlashError>().having((e) => e.code, 'code', 'cancelledWrite')),
    );
    expect(app.committed, isEmpty);
    // without the rescue start a cancel between two pages stops with the error
    await expectLater(
      sf.devSaveWrite(d, bk.save, chk2, cancel: () => app.committed.isNotEmpty, now: t0),
      throwsA(isA<FlashError>().having((e) => e.code, 'code', 'cancelledWrite')),
    );
    expect(app.committed, [0xEFE000]);
    app.committed.clear();
    // another flash app as the guard: no rescue start of ours, the pages alone
    app.committed.clear();
    await sf.devSaveWrite(d, bk.save, chk2, guard: Uint8List(0x800), now: t0);
    expect(app.committed, [0xEFF000]);
    expect(flash.sublist(region(1)[0], region(1)[1]), landToy().sublist(region(1)[0], region(1)[1]));
    link.dispose();
  });

  test('save files: backup, edit, share, into a ROM, from a game of the app', () async {
    final rom = landToy();
    // the save of a ROM, exported as the Save tab does (no clock)
    final ex = await sf.romSaveExport(rom, now: t0);
    expect(ex.name, 'land-20260304-0506.tamasave');
    expect(ex.message, 'land-20260304-0506.tamasave saved. The clock is not included, set it in the app if needed.');
    final dec = paraDecode(ex.bytes);
    expect(dec.edition, 1);
    expect(dec.counter, 0);
    expect(paraClock(dec), isNull);
    expect(paraFromImage(rom, 1).keys.toList(), dec.pages.keys.toList());
    expect(sf.romEdition(rom), 1);

    // a file edited and saved again keeps its clock and its bytes outside the change
    final withClock = paraDecode(paraEncode(dec.pages, 1, const ParaClockIn(1234, 0xE0), 1700000000));
    final o = sf.petOpen(withClock, null);
    final out = sf.petSaveFile(o, sf.petChange(o.pet, level: 10, care: true), 'My Save.TAMASAVE', now: t0);
    expect(out.name, 'My Save-20260304-0506.tamasave');
    expect(out.message, 'My Save-20260304-0506.tamasave saved. Send it with "Save to device".');
    final re = paraDecode(out.bytes);
    expect(re.counter, 1234);
    expect(re.stamp, 1700000000);
    expect(re.regs, withClock.regs);
    expect(paraPet(re, 1)!.toJson(), {'level': 10, 'id': 2003, 'stage': 3, 'hunger': 6, 'happy': 20, 'sick': 0});
    var differ = 0;
    for (final e in withClock.pages.entries) {
      if (!_same(re.pages[e.key]!, e.value)) differ++;
    }
    expect(differ, 2);
    // unchanged: written back byte for byte
    expect(paraWrite(withClock), paraEncode(dec.pages, 1, const ParaClockIn(1234, 0xE0), 1700000000));

    // the ROM's own save changed in a copy of the ROM
    final ro = sf.petOpen(sf.romSave(rom), sf.romEdition(rom));
    final (rom2, sv2, msg) = sf.petSaveRom(rom, ro, sf.petChange(ro.pet, level: 4, char: sf.PetChar(3001, 4, 'X', '')));
    expect(msg, startsWith('Changed in the ROM.'));
    expect(paraPet(sf.romSave(rom2), 1)!.toJson(), paraPet(sv2, 1)!.toJson());
    expect(paraPet(sv2, 1)!.id, 3001);
    expect(rom2.sublist(0, region(1)[0]), rom.sublist(0, region(1)[0]));
    expect(rom, landToy()); // the original is not touched

    // a save from elsewhere into a ROM: same checks as for the toy
    final clean = landImage();
    final (rom3, warn) = sf.romSaveWrite(clean, re);
    expect(warn, '');
    expect(paraPet(sf.romSave(rom3), 1)!.level, 10);
    expect(rom3.sublist(region(1)[0], region(1)[1]), [for (final p in re.pages.values) ...p]);
    expect(() => sf.romSaveWrite(clean, re.copyWith(edition: 5)), throwsA(isA<sf.SaveFlowError>().having((e) => e.message, 'message', contains('another edition (Tropical), the device is Land'))));

    // a game of the app: its save file holds only the pages the game wrote, no edition
    final game = landImage(); // the dump the game started from
    final set = settingsPage(id: 2010, level: 6);
    final file = paraWrite(ParaSave(stamp: 1700000000, counter: 999, alarm: 998, status: 0x100, regs: [(0x200, 0xE0)], pages: {0x1000: Uint8List(0x1000), 0xD50000: Uint8List(0x1000)..[5] = 9, 0xEFE000: set, 0xEFF000: set}, edition: 0));
    final cut = file.sublist(0, file.length - 16); // without the Paramix trailer, as the core writes it
    expect(paraDecode(cut).edition, 0);
    final gs = sf.gameSave(game, cut);
    expect(gs.edition, 1);
    expect(gs.counter, 999);
    expect(gs.pages.length, paraFromImage(game, 1).length);
    expect(gs.pages[0xD50000]![5], 9);
    expect(paraPet(gs, 1)!.id, 2010);
    final gc = sf.devSaveCheck(gs, 1, 'Land');
    expect(gc.error, isNull);
    expect(gc.warn, '');
    expect(game, landImage());
  });

  test('saves in the slots of the menu on the toy', () async {
    final flash = landToy();
    // the menu's place and its slots (three saves of 64 KB each), as feldFind would read them
    final f = feld.FeldInfo(off: 0xB1000, version: 6, slotOff: 0x900000, slotSize: 0x10000, nslots: 3, flags: feld.fFields | feld.fSaves);
    final r = Random(5);
    for (var i = 0; i < 0x180; i++) {
      flash[f.off + 0x140 + i] = r.nextInt(256);
    }
    final rom = Uint8List.fromList(flash);
    final ss = feld.SaveSlots(f, true, 0, [(i: 0, used: false), (i: 1, used: false), (i: 2, used: false)]);
    expect([for (final c in sf.slotChoices(ss, rom)) '${c.index}:${c.label}'], ['-1:Save 1 (active)', '1:Save 2 (empty)', '2:Save 3 (empty)']);
    final (app, link, d) = await _connect(flash);
    final save = sf.petApply(sf.petOpen(sf.romSave(rom), 1), sf.PetChange(level: 8));
    final c = sf.devSaveCheck(save, 1, 'Land');
    expect(sf.slotWriteCheck(ss, rom, c.chk, 1), 'The save goes into Save 2 on the device and replaces the one there. Continue?');
    expect(await sf.slotWrite(d, ss, rom, c.chk, 1), 'Done: Save 2 replaced on the device.');
    // the header page went first as empty and last for real
    expect(app.committed.first, feld.slotAddr(f, 1));
    expect(app.committed.last, feld.slotAddr(f, 1));
    // what the menu will find there: the pages of the save that are not empty
    final got = feld.slotPages((await feld.slotReadAsync(d.read, f, 1))!);
    final want = {
      for (final e in save.pages.entries)
        if (e.value.any((v) => v != 0xFF)) e.key: e.value,
    };
    expect(got.keys.toList(), want.keys.toList());
    for (final e in want.entries) {
      expect(got[e.key], e.value);
    }
    // read out of a ROM that holds this slot (the Save tab's export of a slot)
    final ss2 = feld.SaveSlots(f, true, 0, [(i: 0, used: false), (i: 1, used: true), (i: 2, used: false)]);
    final fromRom = await sf.romSlotSave(flash, ss2, 1);
    expect(paraPet(fromRom, 1)!.level, 8);
    expect(fromRom.pages.length, save.pages.length);
    expect((await sf.romSaveExport(flash, slots: ss2, slot: 1, now: t0)).name, 'land-save2-20260304-0506.tamasave');
    await expectLater(sf.romSlotSave(flash, ss2, 2), throwsA(isA<sf.SaveFlowError>().having((e) => e.message, 'message', 'There is no save in this slot.')));
    // clear it
    final (rom4, msg) = await sf.slotClear(d, ss2, rom, 1);
    expect(msg, 'Done: Save 2 is empty.');
    expect(await feld.slotReadAsync(d.read, f, 1), isNull);
    expect(allFF(rom4, feld.slotAddr(f, 1), 0x1000), isTrue);
    // another menu on the toy than in the ROM: nothing is written
    final other = Uint8List.fromList(rom);
    other[f.off + 0x140 + 8] ^= 1;
    app.committed.clear();
    await expectLater(sf.slotWrite(d, ss, other, c.chk, 2), throwsA(isA<sf.SaveFlowError>().having((e) => e.message, 'message', startsWith('The menu on the device does not match'))));
    expect(app.committed, isEmpty);
    link.dispose();
  });
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
