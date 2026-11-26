// Checks lib/paramix/save_flow.dart against the handlers of Paramix Studio's Save tab and device
// panel as tool/paramix_check/saveflow.js restates them over the Studio's own modules: prints the
// same lines (one per case: <case name> <sha256 or value>).
// DUMPS=<folder with water.bin ...> dart run tool/paramix_check/saveflow_check.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tama_tools/paramix/bytes.dart';
import 'package:tama_tools/paramix/feld.dart' as feld;
import 'package:tama_tools/paramix/flash.dart' show FlashError, rescueBlock;
import 'package:tama_tools/paramix/save_flow.dart';
import 'package:tama_tools/paramix/saves.dart';

final String src = '${File.fromUri(Platform.script).parent.parent.parent.path}/third_party/paramix-studio';
Uint8List bin(String f) => File('$src/$f').readAsBytesSync();
final Uint8List feldBin = bin('feld/feld.bin'), stubBin = bin('feld/stub_feld_tpl.bin'), feldSBin = bin('feld/feld_s.bin');
const eds = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];
String sha(Object b) => sha256.convert(b is String ? utf8.encode(b) : b as List<int>).toString();
int count = 0;
void P(String n, Object? v) {
  count++;
  stdout.writeln('$n $v');
}

String pagesSha(Map<int, Uint8List> pages) {
  final b = BytesBuilder();
  pages.forEach((a, d) {
    b.add(le32(a));
    b.add(le32(d.length));
    b.add(d);
  });
  return '${pages.length}:${sha(b.takeBytes())}';
}

final DateTime now = DateTime(2026, 3, 4, 5, 6, 7);
final int sec = now.millisecondsSinceEpoch ~/ 1000;

/// The device: a flash in memory behind [SaveDevice] (what the flash app answers).
class MemDevice implements SaveDevice {
  MemDevice(this.flash, this.edition, this.clock);
  final Uint8List flash;
  @override
  final int edition;
  ParaClockIn? clock;
  final List<int> log = [];
  @override
  String get name => feld.editionNames[edition] ?? 'Edition $edition';
  @override
  Future<Uint8List> read(int off, int len) async => Uint8List.fromList(Uint8List.sublistView(flash, off, off + len));
  @override
  Future<int> crc(int off, int len) async => crc32(flash, off, len);
  @override
  Future<ParaClockIn?> clockRead() async => clock;
  @override
  Future<bool> clockSet(int v) async {
    if (clock == null) return false;
    clock = ParaClockIn(v, clock!.ctrl);
    return true;
  }

  @override
  void ready() {}
  @override
  Future<void> writeBegin() async {}
  @override
  Future<void> putSector(int s, Uint8List d) async {
    flash.setAll(s, d);
    log.add(s);
  }

  @override
  Future<void> writeFinish() async {}
}

/// The rescue start on the toy as writeSectors looks for it; false when 0xFF0000 is in use.
bool rescueOn(Uint8List fl, Uint8List guard) {
  if (!allFF(fl, 0xFF0000, 0x10000)) return false;
  final rb = rescueBlock(guard, Uint8List.sublistView(fl, 0, 0x1000), Uint8List.fromList(fl.sublist(0xFFF000, 0x1000000)));
  if (rb == null) return false;
  fl.setAll(0xFF0000, rb);
  return true;
}

String logStr(List<int> l) => '${l.length}:${sha(l.map(hex).join(','))}';
String msgOf(Object e) => e is SaveFlowError
    ? e.message
    : e is FlashError
        ? e.message
        : e is StateError
            ? e.message
            : e is FormatException
                ? e.message
                : '$e';
String em(Object e) => 'err:${msgOf(e)}';
Future<void> T(String name, Future<void> Function() fn) async {
  try {
    await fn();
  } catch (e) {
    P(name, em(e));
  }
}

String choices(feld.SaveSlots ss, Uint8List rom) => [for (final c in slotChoices(ss, rom)) '${c.live ? 'live' : c.index}=${c.label}'].join('\n');

Future<void> main() async {
  final dumps = Platform.environment['DUMPS']!;
  for (final k in ['petKeep', 'petKid', 'petYoung', 'petAdult', 'petNow', 'petSick', 'petOther', 'petNoSet', 'petDone', 'petNothing', 'petRomDone', 'saveNoClock', 'saveSlot', 'slotLive', 'slotEmpty', 'slotNone', 'slotField', 'slotDevOther', 'slotSure', 'slotDone', 'slotClearSure', 'slotClearDone', 'devErr', 'devCancelled', 'devSaveSure', 'devSaveDone', 'devSaveClock', 'devSaveClockNo', 'devSaveGot', 'fl_saveOtherEd', 'fl_saveFamily', 'fl_saveNoSettings', 'fl_saveOutside', 'fl_saveIncomplete']) {
    P('text.$k', jsonEncode(saveTexts[k]));
  }
  for (var e = 0; e <= 9; e++) {
    P('edSlug$e', edSlug(e));
  }
  P('stamp', stamp(now));
  final guard = Uint8List(0x3000);
  for (var i = 0; i < guard.length; i++) {
    guard[i] = (i * 7 + 3) & 255;
  }
  final emb = feld.FeldEmbedded(stub: stubBin, feld: feldBin, feldS: feldSBin);
  const emu = feld.FeldEmuPort();

  final saves = <String, (int, ParaSave)>{};
  for (final name in eds) {
    final rom = File('$dumps/$name.bin').readAsBytesSync();
    final ed = romEdition(rom);
    void Q(String n, Object? v) => P('$name.$n', v);
    Q('edition', ed);

    final ex = await romSaveExport(rom, now: now);
    Q('export', '${ex.name} ${ex.bytes.length} ${sha(ex.bytes)} ${sha(ex.message)}');
    PetOpen? o;
    final groups = petChars(rom);
    await T('$name.petOpen', () async {
      o = petOpen(romSave(rom), ed);
      final opts = [
        for (final g in groups) ...['[${g.label}]', for (final c in g.chars) '${c.id}:${c.stage}=${c.text}'],
      ];
      Q('petOpen', '${jsonEncode(o!.pet.toJson())} ${sha(petNow(o!.pet, groups))} ${opts.length}:${sha(opts.join('\n'))}');
    });
    final op = o;
    if (op == null) continue;
    final pet = op.pet;
    await T('$name.petSave.nothing', () async => petSaveRom(rom, op, petChange(pet, level: pet.level)));
    await T('$name.petSave.same', () async => petSaveRom(rom, op, petChange(pet, level: pet.level, char: PetChar(pet.id, pet.stage, '', ''))));
    PetChar? pick(int st) {
      final c = [
        for (final g in groups)
          if (g.stage == st) ...g.chars.where((x) => x.id != pet.id),
      ];
      return c.isNotEmpty ? c[c.length >> 1] : null;
    }

    final lv = (pet.level + 3) % 11;
    ParaSave? edited;
    for (final (tag, l, c, care) in [('level', lv, null, false), ('care', pet.level, null, true), ('kid', pet.level, pick(3), false), ('teen', lv, pick(4), true), ('adult', lv, pick(5), true)]) {
      await T('$name.petSave.rom.$tag', () async {
        final (r, sv, _) = petSaveRom(rom, op, petChange(pet, level: l, char: c, care: care));
        Q('petSave.rom.$tag', '${sha(r)} ${jsonEncode(paraPet(sv, ed)!.toJson())} ${pagesSha(sv.pages)}');
        if (tag == 'level' || tag == 'adult') edited = sv;
      });
    }
    final fileIn = paraDecode(paraEncode(paraFromImage(rom, ed), ed, const ParaClockIn(123456, 0xE0), sec - 1000));
    await T('$name.petSave.file', () async {
      final fo = petOpen(fileIn, ed), r = petSaveFile(fo, petChange(fo.pet, level: lv, char: pick(5), care: true), 'My Save.TamaSave', now: now);
      Q('petSave.file', '${r.name} ${r.bytes.length} ${sha(r.bytes)} ${sha(r.message)}');
    });
    saves[name] = (ed, fileIn);

    final dv = MemDevice(Uint8List.fromList(rom), ed, const ParaClockIn(500000, 0xE0));
    final bk = await devSaveRead(dv, now: now);
    Q('devSaveRead', '${bk.name} ${bk.used} ${bk.file.length} ${sha(bk.file)} ${sha(bk.message)}');
    for (final (tag, ck) in [('noclock', null), ('stopped', const ParaClockIn(77, 0x60))]) {
      final b2 = await devSaveRead(MemDevice(Uint8List.fromList(rom), ed, ck), now: now);
      Q('devSaveRead.$tag', '${sha(b2.file)} ${jsonEncode(b2.message.replaceAll(b2.name, '{n}'))}');
    }
    final back = bk.save, later = now.add(const Duration(seconds: 90));
    final ed0 = edited;
    if (ed0 != null) {
      for (final (tag, sv, g) in [('edited', ed0, null), ('backup', back, null), ('edited.guard', ed0, guard), ('backup.guard', back, guard)]) {
        await T('$name.devSaveWrite.$tag', () async {
          final fl = Uint8List.fromList(rom);
          var on = 'none';
          if (g != null) on = rescueOn(fl, g) ? 'on' : 'busy';
          final d2 = MemDevice(fl, ed, const ParaClockIn(9, 0xE0));
          var s2 = sv;
          if (tag.startsWith('backup')) {
            final bo = petOpen(paraDecode(bk.file), ed);
            s2 = paraPetSet(bo.save, ed, level: lv, care: true);
          }
          final c = devSaveCheck(s2, d2.edition, d2.name);
          if (c.error != null) {
            Q('devSaveWrite.$tag', c.error);
            return;
          }
          final w = await devSaveWrite(d2, s2, c.chk, guard: g, now: later);
          Q('devSaveWrite.$tag', '$on ${jsonEncode(c.confirm)} ${jsonEncode(w.message)} ${logStr(d2.log)} ${sha(fl)} ${d2.clock!.counter}');
          final again = await devSaveRead(d2, now: now);
          Q('devSaveWrite.$tag.again', '${sha(again.file)} ${jsonEncode(paraPet(again.save, ed)!.toJson())}');
        });
      }
      for (final (tag, g) in [('cancel', null), ('cancel.guard', guard)]) {
        await T('$name.devSaveWrite.$tag', () async {
          final fl = Uint8List.fromList(rom);
          if (g != null) rescueOn(fl, g);
          final d2 = MemDevice(fl, ed, const ParaClockIn(9, 0xE0)), c = devSaveCheck(ed0, d2.edition, d2.name);
          final need = g != null ? 2 : 1;
          String r;
          try {
            r = jsonEncode((await devSaveWrite(d2, ed0, c.chk, guard: g, cancel: () => d2.log.length >= need, now: later)).message);
          } on FlashError catch (e) {
            r = '${em(e)} ${e.code}';
          }
          Q('devSaveWrite.$tag', '$r ${logStr(d2.log)} ${sha(fl)}');
        });
      }
    }
    await T('$name.devSaveCheck.part', () async {
      final a0 = region(ed)[0];
      final part = back.copyWith(pages: {
        for (final e in back.pages.entries)
          if (e.key >= 0xEF0000 || e.key < a0 + 0x8000) e.key: e.value,
        0x100000: Uint8List(0x1000),
      });
      final d2 = MemDevice(Uint8List.fromList(rom), ed, null), c = devSaveCheck(part, d2.edition, d2.name);
      Q('devSaveCheck.part', '${jsonEncode(c.error ?? c.confirm)} ${pagesSha(c.chk.pages)}');
      if (c.error == null) {
        final w = await devSaveWrite(d2, part, c.chk, now: later);
        Q('devSaveWrite.part', '${jsonEncode(w.message)} ${logStr(d2.log)} ${sha(d2.flash)}');
      }
    });

    for (final (mt, opts) in [('saves', const feld.FeldOpts(fields: true)), ('fields', const feld.FeldOpts(fields: true, saves: false))]) {
      final tag = '$name.slots.$mt';
      await T(tag, () async {
        final mrom = feld.feldApply(rom, opts, [], emb, emu), ss = paraSlots(mrom, stubBin);
        if (ss == null) {
          P(tag, 'null');
          return;
        }
        P(tag, '${ss.saves} ${ss.live} ${ss.list.length} ${sha(choices(ss, mrom))}');
        final dv2 = MemDevice(Uint8List.fromList(mrom), ed, null);
        final c = devSaveCheck(romSave(mrom, ed), dv2.edition, dv2.name);
        for (final x in ss.list) {
          await T('$tag.write${x.i}', () async {
            final q = slotWriteCheck(ss, mrom, c.chk, x.i, c.warn);
            final msg = await slotWrite(dv2, ss, mrom, c.chk, x.i);
            P('$tag.write${x.i}', '${sha(q)} ${sha(msg)} ${logStr(dv2.log)} ${sha(dv2.flash)}');
          });
        }
        final got = Uint8List.fromList(dv2.flash), ss2 = paraSlots(got, stubBin);
        P('$tag.after', ss2 != null ? sha(choices(ss2, got)) : 'null');
        for (final x in ss.list) {
          await T('$tag.export${x.i}', () async {
            final e2 = await romSaveExport(got, slots: ss2, slot: x.i, now: now);
            P('$tag.export${x.i}', '${sha(e2.name)} ${sha(e2.bytes)} ${pagesSha((await romSlotSave(got, ss2!, x.i, ed)).pages)}');
          });
        }
        await T('$tag.clear', () async {
          final i = ss.list.last.i;
          final (r, msg) = await slotClear(dv2, ss2!, got, i);
          P('$tag.clear', '${sha(msg)} ${logStr(dv2.log)} ${sha(dv2.flash)} ${sha(r)}');
        });
        await T('$tag.other', () async => slotWrite(dv2, ss, rom, c.chk, 0));
      });
    }
  }

  for (final a in saves.keys) {
    for (final b in saves.keys) {
      final c = devSaveCheck(paraDecode(paraWrite(saves[a]!.$2)), saves[b]!.$1, feld.editionNames[saves[b]!.$1] ?? '');
      P('cross.$a.$b', jsonEncode(c.error ?? c.confirm));
    }
  }
  stderr.writeln('$count cases');
}
