// Paramix Studio: save games in and out of the Paradise. A native port of Paramix Studio's
// src/saves.js (mameise, GPL-3.0-or-later).
//
// Paradise: the game keeps its progress in the flash after the edition ID page
// (0xD4A000, Tropical/Glacier 0xD2A000) up to 0xF00000. Exported as a
// .tamasave (format 3 of the TamaParadise app): every page of that region,
// the seconds counter of the device and an armed wake alarm, so the app
// continues instead of starting like a fresh battery. Behind the pages a
// Paramix trailer ("PMXE", edition, region) that the app ignores and the
// Studio uses to refuse a save of another edition.
//
// TamaEmu: the guest's own save is its flash. Exported as the raw image the
// TamaEmu app uses (.sav, 4 MB or 8 MB; named after the app's device: plus-color, idl, ps, 4u):
// packed blocks plus the spare pages the emulator wrote. Importing a .sav works like choosing a
// firmware.

import 'dart:async';
import 'dart:typed_data';

import 'bytes.dart';

const int _page = 0x1000;
const String _magic = 'TAMASAVE';
const int _version = 3, _trailer = 0x45584D50; // "PMXE"
const int _setA = 0xEFE000, _setB = 0xEFF000, _regionEnd = 0xF00000;

int _s32(int v) => (v & 0xFFFFFFFF).toSigned(32);

/// Edition 5/6 (Tropical, Glacier) keep their ID page lower.
/// 8: Neon Planets (1.7.6); 7: Tropical/Glacier with ID 4 (1.7.6)
int idPage(int edition) => edition == 8
    ? 0xD85000
    : edition == 5 || edition == 6 || edition == 7
        ? 0xD29000
        : 0xD49000;
List<int> region(int edition) => [idPage(edition) + _page, _regionEnd];
String family(int edition) => edition == 8
    ? 'neon'
    : edition == 5 || edition == 6 || edition == 7
        ? 'gen3'
        : edition == 4
            ? 'jade'
            : 'gen1';

/// Settings block: CRC-16/ARC over bytes 4..4095 at 0, its inverse at 2.
int crc16arc(Uint8List d, int from, int to) {
  var c = 0;
  for (var i = from; i < to; i++) {
    c ^= d[i];
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1;
    }
  }
  return c;
}

bool settingsOk(Uint8List p) {
  final c = crc16arc(p, 4, _page);
  return u16(p, 0) == c && u16(p, 2) == (~c & 0xFFFF);
}

// ---------------------------------------------------------------- Paradise
// 1.7.6 NEON_SAVE: Neon Planets keeps its settings block in a ring of 5 pages behind its ID page
// (0xD86000..0xD8A000), the newest valid page (highest number at +0xAD0) counts. The other
// Paradise editions: 0xEFE000 and its copy 0xEFF000.
const int _ringN = 5, _ringSeq = 0xAD0;

List<int> setAddrs(int edition) {
  if (family(edition) == 'neon') {
    return [for (var i = 0; i < _ringN; i++) idPage(edition) + _page * (i + 1)];
  }
  return [_setA, _setB];
}

/// A settings block of a save: where it is and the page.
class SettingsAt {
  SettingsAt(this.at, this.p);
  final int at;
  final Uint8List p;
}

/// The valid settings block of a save: at, p (Neon: the newest page of the ring) or null.
SettingsAt? setOf(Map<int, Uint8List> pages, int edition) {
  SettingsAt? best;
  final neon = family(edition) == 'neon';
  for (final a in setAddrs(edition)) {
    final p = pages[a];
    if (p == null || p.length != _page || !settingsOk(p)) continue;
    if (best == null) {
      best = SettingsAt(a, p);
      if (!neon) break;
      continue;
    }
    if (_s32(u32(p, _ringSeq) - u32(best.p, _ringSeq)) > 0) best = SettingsAt(a, p);
  }
  return best;
}

/// Pages of the save region from a 16 MB image (all of them, empty ones too).
Map<int, Uint8List> paraFromImage(Uint8List img, int edition) {
  final r = region(edition);
  final pages = <int, Uint8List>{};
  for (var p = r[0]; p < r[1]; p += _page) {
    final a = p < img.length ? p : img.length, b = p + _page < img.length ? p + _page : img.length;
    pages[p] = Uint8List.fromList(Uint8List.sublistView(img, a, b));
  }
  return pages;
}

/// The seconds counter and the clock control register of a device.
class ParaClockIn {
  const ParaClockIn(this.counter, this.ctrl);
  final int counter, ctrl;
}

/// A decoded .tamasave.
class ParaSave {
  ParaSave({required this.stamp, required this.counter, required this.alarm, required this.status, required this.regs, required this.pages, required this.edition});
  final int stamp, counter, alarm, status;
  final List<(int, int)> regs;
  final Map<int, Uint8List> pages; // address -> page, in the order of the file
  final int edition;

  ParaSave copyWith({Map<int, Uint8List>? pages, int? edition}) =>
      ParaSave(stamp: stamp, counter: counter, alarm: alarm, status: status, regs: regs, pages: pages ?? this.pages, edition: edition ?? this.edition);
}

int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Uint8List _write(List<(int, int)> regs, Map<int, Uint8List> pages, int stampLo, int stampHi, int counter, int alarm, int status, int edition) {
  final list = pages.keys.toList()..sort();
  var size = 36 + 8 * regs.length + 4 + 16;
  for (final a in list) {
    size += 8 + pages[a]!.length;
  }
  final out = Uint8List(size);
  for (var i = 0; i < 8; i++) {
    out[i] = _magic.codeUnitAt(i);
  }
  w32(out, 8, _version);
  w32(out, 12, stampLo);
  w32(out, 16, stampHi); // u64 time stamp (seconds since 1970)
  w32(out, 20, counter);
  w32(out, 24, alarm);
  w32(out, 28, status);
  w32(out, 32, regs.length);
  var o = 36;
  for (final (k, v) in regs) {
    w32(out, o, k);
    w32(out, o + 4, v);
    o += 8;
  }
  w32(out, o, list.length);
  o += 4;
  for (final a in list) {
    final d = pages[a]!;
    w32(out, o, a ~/ _page);
    w32(out, o + 4, d.length);
    out.setAll(o + 8, d);
    o += 8 + d.length;
  }
  w32(out, o, _trailer);
  w32(out, o + 4, edition);
  w32(out, o + 8, region(edition)[0]);
  w32(out, o + 12, region(edition)[1]);
  return out;
}

/// .tamasave from pages (Map address -> 4 KB). clock: counter and ctrl of the device or null.
Uint8List paraEncode(Map<int, Uint8List> pages, int edition, ParaClockIn? clock, [int? now]) {
  now ??= _nowSeconds();
  final counter = clock != null ? clock.counter & 0xFFFFFFFF : 0;
  final alarm = counter != 0 ? counter - 1 : 0, status = counter != 0 ? 0x100 : 0; // armed, as the app does when it puts the console away
  // the always powered system registers as the app stores them (clock and PLL as the firmware sets them)
  final regs = counter != 0
      ? <(int, int)>[
          (0x000, 0xC051), (0x004, 0xA55A0000), (0x00C, 4), (0x010, 0), (0x018, 0x21), (0x020, 0x42), (0x050, 0), //
          (0x100, 0x157EB7), (0x108, 0), (0x10C, 0x1FFFFD), (0x110, 0), (0x200, (clock!.ctrl & 0x80) != 0 ? clock.ctrl & 0xFFFFFFFF : 0xE0), (0x204, 0), //
          (0x210, 0), (0x214, 0), (0x218, 0), (0x230, alarm), (0x234, status), (0x300, 0x10),
        ]
      : <(int, int)>[];
  return _write(regs, pages, counter != 0 ? now : 0, 0, counter, alarm, status, edition);
}

/// Write a decoded save back as it was (time stamp, clock, registers kept).
Uint8List paraWrite(ParaSave save, [int? edition]) {
  final ed = (edition ?? 0) != 0 ? edition! : save.edition;
  return _write(save.regs, save.pages, save.stamp & 0xFFFFFFFF, save.stamp ~/ 4294967296, save.counter, save.alarm, save.status, ed);
}

/// Read a .tamasave (format 3). Throws on anything else.
ParaSave paraDecode(Uint8List b) {
  if (b.length < 40 || String.fromCharCodes(b, 0, 8) != _magic) throw const FormatException('not a Paradise save (.tamasave)');
  if (u32(b, 8) != _version) throw FormatException('unknown save version ${u32(b, 8)}');
  final stamp = u32(b, 12) + u32(b, 16) * 4294967296, counter = u32(b, 20), alarm = u32(b, 24), status = u32(b, 28);
  final nr = u32(b, 32);
  var o = 36;
  final regs = <(int, int)>[];
  for (var i = 0; i < nr; i++) {
    if (o + 8 > b.length) throw const FormatException('save is cut off');
    regs.add((u32(b, o), u32(b, o + 4)));
    o += 8;
  }
  if (o + 4 > b.length) throw const FormatException('save is cut off');
  final np = u32(b, o);
  o += 4;
  final pages = <int, Uint8List>{};
  for (var i = 0; i < np; i++) {
    if (o + 8 > b.length) throw const FormatException('save is cut off');
    final a = u32(b, o) * _page, n = u32(b, o + 4);
    o += 8;
    if (o + n > b.length) throw const FormatException('save is cut off');
    pages[a] = Uint8List.fromList(Uint8List.sublistView(b, o, o + n));
    o += n;
  }
  var edition = 0;
  if (o + 16 <= b.length && u32(b, o) == _trailer) edition = u32(b, o + 4);
  return ParaSave(stamp: stamp, counter: counter, alarm: alarm, status: status, regs: regs, pages: pages, edition: edition);
}

/// An error or a warning of [paraCheck]: a code (saveOtherEd, saveOutside, saveNoSettings,
/// saveFamily, saveIncomplete) and its values.
class SaveNote {
  const SaveNote(this.code, [this.p]);
  final String code;
  final Map<String, int>? p;
  Map<String, Object?> toJson() => {'code': code, if (p != null) 'p': p};
}

class ParaCheck {
  ParaCheck(this.errors, this.warnings, this.pages, this.complete);
  final List<SaveNote> errors, warnings;
  final Map<int, Uint8List> pages; // only the save region, full 4 KB
  final bool complete;
}

/// Can this save go onto a device of this edition? Returns errors, warnings, pages (only the
/// save region, full 4 KB), complete.
ParaCheck paraCheck(ParaSave save, int edition) {
  final errors = <SaveNote>[], warnings = <SaveNote>[], r = region(edition), pages = <int, Uint8List>{};
  final a = r[0], b = r[1];
  // 1.7.6 SAVE_FAMILY: the field switch changes the ID (Land/Water/Sky, Tropical/Glacier and their Forest/Sky): a save
  // of the same firmware fits, before a save from Tropical was refused on the device once it had switched to Glacier
  if (save.edition != 0 && family(save.edition) != family(edition)) errors.add(SaveNote('saveOtherEd', {'s': save.edition, 'd': edition}));
  var outside = 0;
  save.pages.forEach((p, d) {
    if (p < a || p >= b || d.length != _page) {
      outside++;
      return;
    }
    pages[p] = d;
  });
  if (outside != 0) warnings.add(SaveNote('saveOutside', {'n': outside}));
  final so = setOf(pages, edition), set = so?.p;
  if (set == null) {
    errors.add(const SaveNote('saveNoSettings'));
  } else if ((u16(set, 12) == 0x016D) != (family(edition) == 'gen3' || family(edition) == 'neon')) {
    errors.add(const SaveNote('saveFamily'));
  }
  var complete = true;
  for (var p = a; p < b; p += _page) {
    if (!pages.containsKey(p)) {
      complete = false;
      break;
    }
  }
  // NEON_SAVE: ring pages the save lacks are erased on the device, so an older page there cannot win over the save
  if (family(edition) == 'neon' && set != null) {
    for (final rp in setAddrs(edition)) {
      if (!pages.containsKey(rp)) pages[rp] = Uint8List(_page)..fillRange(0, _page, 0xFF);
    }
  }
  if (!complete) warnings.add(const SaveNote('saveIncomplete'));
  return ParaCheck(errors, warnings, pages, complete);
}

/// Seconds counter to set on the device: the saved one plus the time since.
int? paraClock(ParaSave save, [int? now]) {
  now ??= _nowSeconds();
  if (save.counter == 0 || save.stamp == 0) return null;
  final since = now - save.stamp;
  return (save.counter + (since > 0 ? since : 0)) & 0xFFFFFFFF;
}

// ---------------------------------------------------------------- change a Paradise save (1.6.8)
// The pet in the settings block: +4/+6 character, +0x10 sickness, +0x18 bits 2..4 stage, +0x1C hunger 0..6,
// +0x1D happiness 0..20. Planet level: low nibble = level, high nibble = level already celebrated.
const Map<String, (int tama, int level)> _pet = {'gen1': (0x104, 0x7C), 'jade': (0x108, 0x7C), 'gen3': (0x114, 0x88), 'neon': (0x114, 0x88)};

Uint8List? paraSettings(ParaSave save, [int? edition]) => setOf(save.pages, (edition ?? 0) != 0 ? edition! : save.edition)?.p;

class ParaPet {
  ParaPet({required this.level, required this.id, required this.stage, required this.hunger, required this.happy, required this.sick});
  final int level, id, stage, hunger, happy, sick;
  Map<String, int> toJson() => {'level': level, 'id': id, 'stage': stage, 'hunger': hunger, 'happy': happy, 'sick': sick};
}

/// What the save says about the pet: level, id, stage, hunger, happy, sick, or null.
ParaPet? paraPet(ParaSave save, int edition) {
  final p = paraSettings(save, edition), o = _pet[family(edition)];
  if (p == null || o == null) return null;
  final t = o.$1;
  return ParaPet(level: p[o.$2] & 15, id: u16(p, t + 4), stage: (p[t + 0x18] >> 2) & 7, hunger: p[t + 0x1C], happy: p[t + 0x1D], sick: p[t + 0x10]);
}

/// Changed copy of the save. level, id, stage, care are each optional. A new character goes
/// into the settings block and into the pet's own file (pages with the old character in the header).
ParaSave paraPetSet(ParaSave save, int edition, {int? level, int? id, int? stage, bool care = false}) {
  final so = setOf(save.pages, edition), p0 = so?.p, o = _pet[family(edition)], sets = setAddrs(edition);
  if (so == null || p0 == null || o == null) throw StateError('the save has no settings block');
  final t = o.$1, lv = o.$2, p = Uint8List.fromList(p0), pages = Map<int, Uint8List>.of(save.pages);
  final old = u16(p, t + 4);
  if (level != null) {
    final v = level < 0 ? 0 : (level > 10 ? 10 : level), now = p[lv] & 15;
    p[lv] = v > now ? (p[lv] & 0xF0) | v : (v << 4) | v;
  }
  if (id != null && id != 0) {
    p[t + 4] = id & 255;
    p[t + 5] = (id >> 8) & 255;
    p[t + 6] = id & 255;
    p[t + 7] = (id >> 8) & 255;
    if (stage != null && stage != 0) p[t + 0x18] = (p[t + 0x18] & ~0x1C) | ((stage & 7) << 2);
    var found = 0;
    if (old != 0 && old != id) {
      save.pages.forEach((a, d) {
        if (sets.contains(a) || d.length != _page) return;
        // 1.7.2 TAMA_ANY: a bred Tama's file was not found (GitHub): small number at +8, character at +0x0C or +0x0E
        if (u32(d, 8) == 0 || u32(d, 8) > 255 || (u16(d, 14) != old && u16(d, 12) != old)) return;
        final n = Uint8List.fromList(d);
        found++;
        if (u16(n, 14) == old) {
          n[14] = id & 255;
          n[15] = (id >> 8) & 255;
        }
        if (u16(n, 12) == old) {
          n[12] = id & 255;
          n[13] = (id >> 8) & 255;
        }
        if (u16(n, 0x10A) == old) {
          n[0x10A] = id & 255;
          n[0x10B] = (id >> 8) & 255;
        }
        pages[a] = n;
      });
    }
    if (old != 0 && old != id && found == 0) throw StateError('the Tama\'s own file is not in the save, the Tama would not change');
  }
  if (care) {
    p[t + 0x1C] = 6;
    p[t + 0x1D] = 20;
    p[t + 0x10] = 0;
  }
  final c = crc16arc(p, 4, _page);
  p[0] = c & 255;
  p[1] = c >> 8;
  p[2] = ~c & 255;
  p[3] = (~c >> 8) & 255;
  if (family(edition) == 'neon') {
    pages[so.at] = p; // the newest page of the ring, in place
  } else {
    pages[_setA] = p;
    pages[_setB] = Uint8List.fromList(p);
  }
  return save.copyWith(pages: pages);
}

// ---------------------------------------------------------------- TamaEmu
const int _appCfg = 0xA0140, _pmxc = 0x43584D50, _pgMagic = 0x50584D50, _pgMax = 64;

class EmuKind {
  const EmuKind(this.dev, this.size, this.app);
  final String dev;
  final int size;
  final String app;
}

// ignore: constant_identifier_names
const Map<int, EmuKind> KINDS = {
  0: EmuKind('pc', 0x400000, 'plus-color'),
  1: EmuKind('idl', 0x800000, 'idl'),
  2: EmuKind('ps', 0x800000, 'ps'),
  3: EmuKind('4u', 0x800000, '4u'),
  4: EmuKind('4u-plain', 0x800000, '4u-plain'),
};

class EmuCfg {
  EmuCfg({required this.version, required this.guestOff, required this.guestSize, required this.saveOff, required this.kind, required this.map, required this.spareEnd, required this.lzOff, required this.dev, required this.size, required this.app});
  final int version, guestOff, guestSize, saveOff, kind;
  final Uint8List map; // 128 bytes: block of the guest -> packed block (0xFF empty, 0xFE itself)
  final int spareEnd, lzOff;
  final String dev;
  final int size;
  final String app;
}

int _u32z(Uint8List b, int o) => o + 4 <= b.length ? u32(b, o) : ((o < b.length ? b[o] : 0) | ((o + 1 < b.length ? b[o + 1] : 0) << 8) | ((o + 2 < b.length ? b[o + 2] : 0) << 16) | ((o + 3 < b.length ? b[o + 3] : 0) << 24)) & 0xFFFFFFFF;
int _u16z(Uint8List b, int o) => (o < b.length ? b[o] : 0) | ((o + 1 < b.length ? b[o + 1] : 0) << 8);

/// Settings block of the emulator in an image (or the 4 KB sector at 0xA0000).
EmuCfg? emuCfg(Uint8List sec, [int base = 0xA0000]) {
  final c = _appCfg - base;
  if (_u32z(sec, c) != _pmxc) return null;
  final v = _u32z(sec, c + 4), kind = _u32z(sec, c + 20);
  final k = KINDS[kind];
  if (k == null) return null;
  final a = c + 24 < sec.length ? c + 24 : sec.length, b = c + 152 < sec.length ? c + 152 : sec.length;
  return EmuCfg(
      version: v,
      guestOff: _u32z(sec, c + 8),
      guestSize: _u32z(sec, c + 12),
      saveOff: _u32z(sec, c + 16),
      kind: kind,
      map: Uint8List.fromList(Uint8List.sublistView(sec, a, b)),
      spareEnd: v >= 3 ? _u32z(sec, c + 152) : 0,
      lzOff: v >= 5 ? _u32z(sec, c + 160) : 0,
      dev: k.dev,
      size: k.size,
      app: k.app);
}

// LZ4 block (as emu.js)
Uint8List _lzDec(Uint8List s, int n) {
  final d = Uint8List(n)..fillRange(0, n, 0xFF);
  var ip = 0, op = 0;
  for (;;) {
    final t = ip < s.length ? s[ip] : 0;
    ip++;
    var l = t >> 4;
    if (l == 15) {
      int x;
      do {
        if (ip >= s.length) {
          ip++;
          l = 0; // past the end: no count
          break;
        }
        x = s[ip++];
        l += x;
      } while (x == 255);
    }
    while (l-- > 0 && op < n) {
      d[op++] = ip < s.length ? s[ip] : 0;
      ip++;
    }
    if (op >= n || ip >= s.length) return d;
    final o = s[ip] | ((ip + 1 < s.length ? s[ip + 1] : 0) << 8);
    ip += 2;
    var m = (t & 15) + 4;
    if ((t & 15) == 15) {
      int x;
      do {
        if (ip >= s.length) {
          ip++;
          m = 0;
          break;
        }
        x = s[ip++];
        m += x;
      } while (x == 255);
    }
    while (m-- > 0 && op < n) {
      d[op] = op - o >= 0 ? d[op - o] : 0;
      op++;
    }
  }
}

/// 1.7.3 test21 LZ_GONE: TamaEmu notes behind its page table which packed blocks the pet erased
/// (four words, then their xor with 0x454E4F47). Those blocks read empty, apart from the parts in
/// spare pages (written after this).
void lzGoneApply(Uint8List t, int o, Uint8List g, int size) {
  if (t.length < o + 20) return;
  var x = 0x454E4F47;
  for (var i = 0; i < 4; i++) {
    x = (x ^ u32(t, o + 4 * i)) & 0xFFFFFFFF;
  }
  if (x != u32(t, o + 16)) return;
  for (var b = 0; b < 128 && (b << 16) < size; b++) {
    if (((u32(t, o + 4 * (b >> 5)) >> (b & 31)) & 1) != 0) {
      final a = (b << 16) < g.length ? b << 16 : g.length, e = ((b + 1) << 16) < g.length ? (b + 1) << 16 : g.length;
      g.fillRange(a, e, 0xFF);
    }
  }
}

/// Guest flash (the .sav of the TamaEmu app) from the packed firmware and the spare pages.
/// read(addr, len) gives bytes of the Paradise flash (sync or async).
Future<Uint8List> emuGuestAsync(FutureOr<Uint8List> Function(int addr, int len) read, EmuCfg cfg, [void Function(String what, int done, int todo)? progress]) async {
  final out = Uint8List(cfg.size)..fillRange(0, cfg.size, 0xFF), nb = cfg.size >> 16;
  int mapAt(int b) => b < cfg.map.length ? cfg.map[b] : 0;
  void put(Uint8List src, int at) {
    if (at + src.length > out.length) throw RangeError('offset is out of bounds');
    out.setAll(at, src);
  }

  var done = 0;
  var todo = 0;
  for (var b = 0; b < nb && b < cfg.map.length; b++) {
    if (cfg.map[b] != 0xFF) todo++;
  }
  for (var b = 0; b < nb; b++) {
    var k = mapAt(b);
    if (k == 0xFF) continue;
    if (k == 0xFE) k = b;
    put(await read(cfg.guestOff + (k << 16), 0x10000), b << 16);
    if (progress != null) progress('read', ++done, todo);
  }
  // 1.7.3 GUEST_LZ: the packed cold blocks (LZ4 parts of 1 KB, see emu.js lzPack)
  if (cfg.lzOff != 0) {
    final t = await read(cfg.lzOff, 512);
    for (var b = 0; b < nb; b++) {
      final lp = _u32z(t, 4 * b);
      if (lp == 0 || mapAt(b) != 0xFF) continue;
      final l = await read(cfg.lzOff + lp, 65 * 4), a0 = _u32z(l, 0), z0 = _u32z(l, 256);
      final raw = z0 > a0 ? await read(cfg.lzOff + a0, z0 - a0) : Uint8List(0);
      for (var k = 0; k < 64; k++) {
        final a = _u32z(l, 4 * k) - a0, z = _u32z(l, 4 * k + 4) - a0, at = (b << 16) + k * 0x400;
        if (z == a) continue;
        int cl(int v) => v < 0 ? (raw.length + v < 0 ? 0 : raw.length + v) : (v > raw.length ? raw.length : v);
        if (z - a >= 0x400) {
          final s = cl(a), e = cl(a + 0x400);
          put(Uint8List.sublistView(raw, s, e < s ? s : e), at);
        } else {
          final s = cl(a), e = cl(z);
          put(_lzDec(Uint8List.sublistView(raw, s, e < s ? s : e), 0x400), at);
        }
      }
    }
  }
  // spare pages (8 KB parts the guest wrote into blocks that are empty in the firmware)
  if (cfg.spareEnd != 0) {
    final lo = (cfg.guestOff + cfg.guestSize + 0x1FFF) & ~0x1FFF & 0xFFFFFFFF, hi = cfg.spareEnd & ~0x1FFF & 0xFFFFFFFF;
    if (_s32(hi) >= _s32(lo) + 0x4000) {
      final data = _s32(lo) + 0x2000;
      var n = _s32(_s32(hi) - data) >> 13;
      if (n > _pgMax) n = _pgMax;
      final t = await read(_s32(lo), 16 + 2 * _pgMax + 20);
      var x = (_pgMagic ^ ((n * 0x9E3779B1) & 0xFFFFFFFF)) & 0xFFFFFFFF;
      for (var i = 0; i < _pgMax; i++) {
        x = ((((x << 5) & 0xFFFFFFFF) | (x >> 27)) ^ _u16z(t, 16 + 2 * i)) & 0xFFFFFFFF;
      }
      if (_u32z(t, 0) == _pgMagic && _u32z(t, 4) == (n & 0xFFFFFFFF) && _u32z(t, 8) == x) {
        lzGoneApply(t, 16 + 2 * _pgMax, out, cfg.size); // 1.7.3 test21 LZ_GONE: packed blocks the pet erased
        for (var i = 0; i < n; i++) {
          final v = _u16z(t, 16 + 2 * i);
          if (v == 0xFFFF || (v << 13) >= cfg.size) continue;
          if (mapAt((v << 13) >> 16) != 0xFF) continue; // only blocks that are empty in the firmware
          put(await read(data + (i << 13), 0x2000), v << 13);
        }
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------- T7Emu
// The pet's EEPROM (4 KB) in the ROM: two slots of 8 KB from 0x0C1000 (header sector:
// "T7EE", sequence, page mask, checksum; then the pages). The T7Emu app keeps it as
// save.bin: page mask (2 bytes) and the 16 pages, 4098 bytes. Same content, so it can go back and forth.
// ignore: constant_identifier_names
const int T7_EE = 0xC1000;
const int _t7Magic = 0x45453754, _t7SaveLen = 4098;

int _t7Sum(Uint8List b, int o) {
  var s = 0x7E7E;
  for (var i = 0; i < 4096; i++) {
    s = (s * 31 + b[o + i]) & 0xFFFFFFFF;
  }
  return s;
}

// test27: up to test26 the T7Emu could write its pages 2 bytes off (the flash DMA takes words, its buffer lay at ...2):
// 2 other bytes first, the pages without their last 2. The header sum is over the right pages, so such a slot is found.
int _t7Sum2(Uint8List b, int o) {
  var s = 0x7E7E;
  for (var i = 2; i < 4096; i++) {
    s = (s * 31 + b[o + i]) & 0xFFFFFFFF;
  }
  return (((s * 31) & 0xFFFFFFFF) * 31) & 0xFFFFFFFF;
}

class _T7Slot {
  _T7Slot(this.seq, this.have, this.at, this.sh);
  final int seq, have, at, sh;
}

_T7Slot? _t7Slot(Uint8List img, int at) {
  if (at + 0x2000 > img.length || u32(img, at) != _t7Magic) return null;
  final sum = u32(img, at + 12);
  final sh = sum == _t7Sum(img, at + 0x1000)
      ? 0
      : sum == _t7Sum2(img, at + 0x1000)
          ? 2
          : -1;
  if (sh < 0) return null;
  return _T7Slot(u32(img, at + 4), u32(img, at + 8) & 0xFFFF, at, sh);
}

_T7Slot? _t7Newest(Uint8List img, [int ee = T7_EE]) {
  final a = _t7Slot(img, ee), b = _t7Slot(img, ee + 0x2000);
  if (a != null && b != null) return _s32(a.seq - b.seq) > 0 ? a : b;
  return a ?? b;
}

/// save.bin of the T7Emu app from a 16 MB image (null: the pet has no save yet). base: save area of
/// the T7Emu (0x0C0000, a further one from 1.6.0 its own).
Uint8List? t7SaveOut(Uint8List img, [int base = 0xC0000]) {
  final s = _t7Newest(img, base + 0x1000);
  if (s == null) return null;
  final out = Uint8List(_t7SaveLen);
  out[0] = s.have & 255;
  out[1] = s.have >> 8;
  out.setRange(2, 2 + 0x1000 - s.sh, img, s.at + 0x1000 + s.sh); // shifted slot: the last 2 bytes stay 0
  return out;
}

bool t7SaveCheck(Uint8List? b) => b != null && b.length == _t7SaveLen;

/// save.bin into the image: into the older slot, as the device does. Returns a new image.
Uint8List t7SaveIn(Uint8List img, Uint8List? save, [int base = 0xC0000]) {
  if (save == null || !t7SaveCheck(save)) throw const FormatException('not a T7Emu save (save.bin, 4098 bytes)');
  final ee = base + 0x1000, out = Uint8List.fromList(img), cur = _t7Newest(img, ee);
  final at = cur != null && cur.at == ee ? ee + 0x2000 : ee;
  out.fillRange(at, at + 0x2000, 0xFF);
  out.setRange(at + 0x1000, at + 0x2000, save, 2);
  w32(out, at, _t7Magic);
  w32(out, at + 4, cur != null ? (cur.seq + 1) & 0xFFFFFFFF : 1);
  w32(out, at + 8, save[0] | (save[1] << 8));
  w32(out, at + 12, _t7Sum(out, at + 0x1000));
  out.fillRange(base, base + 0x1000, 0xFF); // the running session belongs to the old pet
  return out;
}
