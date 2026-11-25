// Paramix menu in the ROM (field switch, items, Tamapoints): a port of Paramix Studio's feld.js
// (mameise, GPL-3.0).
//
// A small program in the ROM, launched like the emulator and DOOM through the stub
// (hold A and C on the home screen). It can
//   - switch the field (Land/Water/Sky or Tropical/Glacier), each field with
//     its own save, which is packed into a slot when switching,
//   - put items into the bag and set Tamapoints (as in the TamaParadise app),
//   - launch an installed program (DOOM, TamaEmu).
// Anything that depends on the edition lives in the program's settings block and is
// set here (profiles below, measured on the factory images).
//
// Location in flash:
//   without DOOM: program and catalog from 0x0B1000, slots behind the character data
//   with DOOM:    program, catalog and slots in the free end of the DOOM program region
//
// The embedded binaries of the JS (feld.bin, stub_feld_tpl.bin, feldc.bin, feld_s.bin,
// feldc_s.bin) are passed in with [FeldEmbedded]; the functions of emu.js the JS gets as `E`
// are passed in as a [FeldEmu] ([FeldEmuPort] is a port of exactly those four).

import 'dart:typed_data';

import 'bytes.dart' show crc32, w16, w32;
import 'edition.dart';
import 'sprites.dart' show arc2Parse, assetBase;

export 'edition.dart' show Edition, edition, editionNames, familyOf, isSix;

const int _xipDec = 0x11000;
int _xip(int off) => 0x10000000 + off - _xipDec;
const int _appOff = 0xA0000, _stubOff = 0xB0000, _feldOff = 0xB1000, _feldEnd = 0xC0000;
const int _doomCode = 0xB1000, _doomSave = 0x10E000;
const int _slotBase = 0x830000, _slotSize = 0x58000, _guestOff = 0x940000;
const int _feldMagic = 0x444C4546, _slotMagic = 0x544C5346, _catMagic = 0x54414350, _pmxc = 0x43584D50, _pdmc = 0x434D4450;
const int _phRing = 0x77777771, _phApp = 0x1234ABCD, _phFeld = 0x6789EF01, _phAuto = 0x66666661;
const List<int> _phOrig = [0x22222221, 0x33333331, 0x44444441, 0x55555551];
const List<int> _hookOff = [0x40, 0x46, 0x4C, 0x52];

/// Flags of the menu's settings block.
const int fFields = 1, fBag = 2, fTama = 4, fSaves = 8, fLaunch = 16;

/* GPLAY (1.7.2 test14): play time in DOOM, Wolfenstein, Game Boy and Master System earns Tamapoints (the programs read
 * this flag from the menu's settings block, see emu/src/emu/gplay.h). Only in a ROM with the Paradise. */
const int fGplay = 64;
const bool gplay = true;

/*
 * Launcher ROM (1.6.8): the handlers of every scene after the setup point to the stub's launch entry
 * (+0x20), so the menu comes up instead of the game. The setup scenes below stay. The original handlers
 * are kept in the stub page at +0x400 ("PLNC", count, then per scene: table offset, four handlers).
 */
const int _launchEntry = 0x20, _lrecOff = 0x400, _lrecMagic = 0x434E4C50;
// Only the game's own scenes (home, care, events, lab, shop, space); the setup and everything not clearly part of the
// game stay (also SETTING_*: the clock after "continue" may use it). Measured in the Paradise emulator (1.6.8): the four
// handlers 8 bytes behind a scene's name belong to the NEXT scene of the table (the setup runs, in this naming,
// OSEWAGAME_03, STARTUP, CORRECTTIME, LANGUAGE, DATETIME, BIRTHDAY, i.e. really STARTUP, INITIAL_LOGO, LANGUAGE,
// DATETIME, BIRTHDAY, PLANETNAME). So scene N is redirected in the entry of the scene before it.
final RegExp _launchScene = RegExp(
    r'^PSID_(HOME|HOME_\w+|OSEWA_\w+|CELL_STATUS|LABOMENU\w*|LBMENU_\w+|INFO_\w+|SHOP_\w+|BOOK_\w+|HELP_\w+|EVENT_\w+|LABOGAME_\w+|OSEWAGAME_\w+|TAMASPACE_\w+)$');
bool _isHandler(int v) => v >= 0x10000000 && v < 0x10100000 && (v & 1) == 1;
/*
 * Per redirected scene a block of 52 bytes in the trampoline pages (behind the menu program): table offset, the four
 * original handlers, then four trampolines "ldr.w r12, <original>; b.w <stub + 0x2C>". The stub starts the menu only
 * once the Paradise has a save, otherwise it jumps to r12 (the original), so a setup after a reset finishes normally.
 * The stub page holds at +0x400: "PLNC", count, offset of the trampoline pages.
 */
const int _lcheckEntry = 0x2C, _tblk = 52;

// ---------------------------------------------------------------- JS-like byte access
// Reads outside the buffer give 0 (as `undefined | 0` in the JS), fills and views are clamped.
int _b(Uint8List d, int i) => i >= 0 && i < d.length ? d[i] : 0;
int _u16(Uint8List b, int o) => o >= 0 && o + 2 <= b.length ? b[o] | (b[o + 1] << 8) : _b(b, o) | (_b(b, o + 1) << 8);
int _u32(Uint8List b, int o) => o >= 0 && o + 4 <= b.length
    ? b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)
    : _b(b, o) | (_b(b, o + 1) << 8) | (_b(b, o + 2) << 16) | (_b(b, o + 3) << 24);
bool _isFF(Uint8List b, int a, int n) {
  for (var i = a; i < a + n; i++) {
    if (_b(b, i) != 0xFF) return false;
  }
  return true;
}

int _page(int n) => (n + 0xFFF) & ~0xFFF;
int _clamp(int v, int len) => v < 0 ? (len + v < 0 ? 0 : len + v) : (v > len ? len : v);
void _fill(Uint8List b, int v, int a, int e) {
  a = _clamp(a, b.length);
  e = _clamp(e, b.length);
  if (a < e) b.fillRange(a, e, v);
}

Uint8List _sub(Uint8List b, int a, int e) {
  a = _clamp(a, b.length);
  e = _clamp(e, b.length);
  return Uint8List.sublistView(b, a, e < a ? a : e);
}

void _set(Uint8List out, Uint8List src, int at) => out.setRange(at, at + src.length, src);
Uint8List _ffPage() => Uint8List(0x1000)..fillRange(0, 0x1000, 0xFF);
int _findWord(Uint8List b, int v, [int from = 0, int? to]) {
  final end = to ?? b.length;
  for (var i = from; i + 4 <= end; i += 2) {
    if (_u32(b, i) == v) return i;
  }
  return -1;
}

String _str8(Uint8List b) => String.fromCharCodes(_sub(b, 0, 8));
String _cap(String s) => s.isEmpty ? s : s[0] + s.substring(1).toLowerCase();
String _cut(String s, int n) => s.length > n ? s.substring(0, n) : s;

/// Sort as Array.prototype.sort does (stable).
void _stableSort<T>(List<T> l, int Function(T) key) {
  final idx = [for (var i = 0; i < l.length; i++) (key(l[i]), i, l[i])];
  idx.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  for (var i = 0; i < l.length; i++) {
    l[i] = idx[i].$3;
  }
}

String _msg(Object e) => e is FormatException
    ? e.message
    : e is StateError
        ? e.message
        : e.toString();

// ---------------------------------------------------------------- embedded binaries, emulator functions
/// The binaries of third_party/paramix-studio/feld (assets/paramix in the app).
class FeldEmbedded {
  const FeldEmbedded({required this.stub, this.feld, this.feldS, this.feldc, this.feldcS, this.oldStub});

  /// stub_feld_tpl.bin: the launcher with the menu entry.
  final Uint8List stub;

  /// The menu program the call installs: feld.bin for [feldApply], feldc.bin for [cleanApply].
  final Uint8List? feld;

  /// feld_s.bin (1.7.6 FELD_BIG): the 1.7.5 menu where the big one does not fit.
  final Uint8List? feldS;

  /// feldc.bin (1.7.2 CLEAN_ROM): the menu for ROMs without the Paradise; use [forClean] to install it.
  final Uint8List? feldc;

  /// feldc_s.bin: the 1.7.5 menu for ROMs without the Paradise.
  final Uint8List? feldcS;

  /// emu/stub_tpl.bin: the launcher of the emulator and DOOM alone ([feldStrip] puts it back).
  final Uint8List? oldStub;

  /// The same set with feldc.bin as the program, for [cleanApply] (the JS passes { feld: fe.feldc, stub }).
  FeldEmbedded forClean() => FeldEmbedded(stub: stub, feld: feldc, feldS: feldS, feldc: feldc, feldcS: feldcS, oldStub: oldStub);
}

/// The functions of emu.js that feld.js calls on its `E` argument.
abstract class FeldEmu {
  /// Paradise scene table: name -> flash offset of the 28-byte entry.
  Map<String, int> sceneTable(Uint8List d);

  /// Is an emulator already installed? Returns the original handlers or null.
  List<int>? installedOrigs(Uint8List rom, Map<String, int> tab);

  /// Install only the program and stub. Returns a new image.
  Uint8List installApp(Uint8List rom, Uint8List app, Uint8List stubTpl, {bool keep = false});

  /// Lowest flash offset T18Emu uses below 0xF00000; 0 = none.
  int t18Low(Uint8List rom);
}

/// Port of the four functions from emu.js (sceneTable, installedOrigs, installApp, t18Low).
class FeldEmuPort implements FeldEmu {
  const FeldEmuPort();
  @override
  Map<String, int> sceneTable(Uint8List d) => _sceneTable(d);
  @override
  List<int>? installedOrigs(Uint8List rom, Map<String, int> tab) => _installedOrigs(rom, tab);
  @override
  Uint8List installApp(Uint8List rom, Uint8List app, Uint8List stubTpl, {bool keep = false}) => _installApp(rom, app, stubTpl, keep: keep);
  @override
  int t18Low(Uint8List rom) => _t18Low(rom);
}

// from emu.js: sceneTable
Map<String, int> _sceneTable(Uint8List d) {
  final names = <int, String>{};
  for (var i = 0; i + 5 < d.length; i++) {
    if (d[i] != 0x50 || d[i + 1] != 0x53 || d[i + 2] != 0x49 || d[i + 3] != 0x44 || d[i + 4] != 0x5F) continue; // "PSID_"
    var j = i + 5;
    while (j < d.length && ((d[j] >= 0x41 && d[j] <= 0x5A) || (d[j] >= 0x30 && d[j] <= 0x39) || d[j] == 0x5F)) {
      j++;
    }
    if (j >= d.length || d[j] != 0) continue;
    names[_xip(i)] = String.fromCharCodes(d, i, j);
    i = j;
  }
  final ptrs = <(int, int)>[];
  for (var o = 0; o + 4 <= d.length; o += 4) {
    final w = d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);
    if (names.containsKey(w)) ptrs.add((o, w));
  }
  if (ptrs.isEmpty) throw const FormatException('scene table not found');
  var best = <(int, int)>[], run = [ptrs[0]];
  for (var k = 1; k < ptrs.length; k++) {
    if (ptrs[k].$1 - ptrs[k - 1].$1 == 28) {
      run.add(ptrs[k]);
    } else {
      if (run.length > best.length) best = run;
      run = [ptrs[k]];
    }
  }
  if (run.length > best.length) best = run;
  final base = best[0].$1 - 4, tab = <String, int>{};
  for (var i = 0; i < best.length; i++) {
    tab[names[best[i].$2]!] = base + i * 28;
  }
  return tab;
}

// from emu.js: installedOrigs
List<int>? _installedOrigs(Uint8List rom, Map<String, int> tab) {
  final o = tab['PSID_HOME'];
  if (o == null) return null;
  final lo = _xip(_stubOff), hi = lo + 0x1000;
  var hit = false;
  for (var k = 0; k < 4; k++) {
    final v = _u32(rom, o + 12 + 4 * k);
    if (v >= lo && v < hi) hit = true;
  }
  if (!hit) return null;
  return [for (var k = 0; k < 4; k++) _u32(rom, _stubOff + 0x94 + 4 * k)];
}

/// Replace a placeholder word of a launcher template (it must be there exactly once).
void _put(Uint8List st, int ph, int v) {
  var n = 0;
  for (var i = 0; i + 4 <= st.length; i += 2) {
    if (_u32(st, i) == ph) {
      w32(st, i, v);
      n++;
    }
  }
  if (n != 1) throw StateError('launcher template does not fit');
}

// from emu.js: installStub
void _installStub(Uint8List out, Map<String, int> tab, List<int>? prev, Uint8List stubTpl) {
  final home = tab['PSID_HOME']!;
  final origs = prev ?? [for (var k = 0; k < 4; k++) _u32(out, home + 12 + 4 * k)];
  final st = Uint8List.fromList(stubTpl);
  _put(st, _phApp, _xip(_appOff));
  for (var k = 0; k < 4; k++) {
    _put(st, _phOrig[k], origs[k]);
  }
  for (var i = 0; i + 4 <= st.length; i += 2) {
    if (_u32(st, i) == _phAuto) w32(st, i, 0); // autostart off, see autoSet
  }
  _fill(out, 0xFF, _stubOff, _stubOff + 0x1000);
  _set(out, st, _stubOff);
  for (var k = 0; k < 4; k++) {
    w32(out, home + 12 + 4 * k, (_xip(_stubOff) + _hookOff[k]) | 1);
  }
}

// from emu.js: t18Cfg (only the block map, the spare blocks and the flags)
const int _t18Magic = 0x38584D50, _t18SpareMax = 64, _t18fHotwin = 4;
({List<int> blocks, int flags})? _t18Cfg(Uint8List rom) {
  const c = _appOff + 0x140;
  if (_u32(rom, c) != _t18Magic) return null;
  final nspare = _u32(rom, c + 12) < _t18SpareMax ? _u32(rom, c + 12) : _t18SpareMax;
  return (
    blocks: [for (var i = 0; i < 128; i++) _u16(rom, c + 16 + 2 * i), for (var i = 0; i < nspare; i++) _u16(rom, c + 272 + 2 * i)],
    flags: _u32(rom, c + 400),
  );
}

// from emu.js: freeT18 (an installed T18Emu gives its blocks back)
void _freeT18(Uint8List out) {
  final c = _t18Cfg(out);
  if (c == null) return;
  for (final b in c.blocks) {
    if (b != 0xFFFF) _fill(out, 0xFF, b << 16, (b + 1) << 16);
  }
  if (c.flags & _t18fHotwin != 0) _fill(out, 0xFF, 0xFD0000, 0xFF0000);
  _fill(out, 0xFF, 0xC0000, 0x110000);
}

// from emu.js: t18Low
int _t18Low(Uint8List rom) {
  final c = _t18Cfg(rom);
  if (c == null) return 0;
  int? low;
  for (final x in c.blocks) {
    if (x != 0xFFFF && x < 0xF0 && (low == null || x < low)) low = x;
  }
  return low != null ? low << 16 : 0xD40000;
}

// from emu.js: installApp
Uint8List _installApp(Uint8List rom, Uint8List app, Uint8List stubTpl, {bool keep = false}) {
  if (rom.length != 0x1000000) throw const FormatException('the Paradise image must be 16 MB');
  final out = Uint8List.fromList(rom);
  final tab = _sceneTable(out);
  if ((tab['PSID_HOME'] ?? 0) == 0) throw const FormatException('home screen not found');
  final prev = _installedOrigs(out, tab);
  if (prev == null && !_isFF(out, _appOff, 0x11000)) throw StateError('area 0x0A0000 is in use');
  if (app.length > 0x10000) throw StateError('program too big');
  if (!keep) _freeT18(out); // keep (1.6.8): the same program again (stub swap), T18Emu keeps its blocks
  _fill(out, 0x00, _appOff, _appOff + 0x10000);
  _set(out, app, _appOff);
  _installStub(out, tab, prev, stubTpl);
  return out;
}

// ---------------------------------------------------------------- launcher ROM
List<int> _launchScenes(Map<String, int> tab) {
  final ent = tab.entries.toList();
  _stableSort(ent, (e) => e.value);
  return [
    for (var i = 1; i < ent.length; i++)
      if (_launchScene.hasMatch(ent[i].key)) ent[i - 1].value
  ];
}

List<int> _launchList(Uint8List out, Map<String, int> tab) => [
      for (final o in _launchScenes(tab))
        if ([0, 1, 2, 3].every((k) => _isHandler(_u32(out, o + 12 + 4 * k)))) o
    ];
int _launchSize(Uint8List out, Map<String, int> tab) => _page(_tblk * _launchList(out, tab).length);

/// Thumb-2 b.w from address `from` to `to` (both in the XIP window): two halfwords
List<int> _bw(int from, int to) {
  final off = to - (from + 4), s = off < 0 ? 1 : 0, imm = (off & 0xFFFFFFFF) >> 1;
  final imm11 = imm & 0x7FF, imm10 = (imm >> 11) & 0x3FF, i2 = (imm >> 21) & 1, i1 = (imm >> 22) & 1;
  final j1 = (~i1 ^ s) & 1, j2 = (~i2 ^ s) & 1;
  return [0xF000 | (s << 10) | imm10, 0x9000 | (j1 << 13) | (j2 << 11) | imm11];
}

void _launchRedirect(Uint8List out, Map<String, int> tab, int stubOff, int tOff) {
  final list = _launchList(out, tab);
  if (list.length > 200) throw StateError('too many scenes');
  _fill(out, 0xFF, tOff, tOff + _page(_tblk * list.length));
  for (var i = 0; i < list.length; i++) {
    final o = list[i], b = tOff + _tblk * i;
    w32(out, b, o);
    for (var k = 0; k < 4; k++) {
      w32(out, b + 4 + 4 * k, _u32(out, o + 12 + 4 * k));
      final t = b + 20 + 8 * k, lit = b + 4 + 4 * k, imm = ((t + 4) & ~3) - lit; // literal behind: ldr.w r12, [pc, #-imm]
      w16(out, t, 0xF85F);
      w16(out, t + 2, 0xC000 | imm);
      final h = _bw(_xip(t + 4), _xip(stubOff) + _lcheckEntry);
      w16(out, t + 4, h[0]);
      w16(out, t + 6, h[1]);
      w32(out, o + 12 + 4 * k, _xip(t) | 1);
    }
  }
  final at = stubOff + _lrecOff;
  _fill(out, 0xFF, at, stubOff + 0x1000);
  w32(out, at, _lrecMagic);
  w32(out, at + 4, list.length);
  w32(out, at + 8, tOff);
}

/// Undo launchRedirect (the record in the stub page and the trampoline pages).
bool launchRestore(Uint8List out, int stubOff) {
  final at = stubOff + _lrecOff;
  if (_u32(out, at) != _lrecMagic) return false;
  final n = _u32(out, at + 4) < 200 ? _u32(out, at + 4) : 200, tOff = _u32(out, at + 8);
  if (tOff < 0x90000 || tOff + _tblk * n > 0x110000) return false;
  for (var i = 0; i < n; i++) {
    final b = tOff + _tblk * i, o = _u32(out, b);
    for (var k = 0; k < 4; k++) {
      if (o + 12 + 4 * k + 4 <= out.length) w32(out, o + 12 + 4 * k, _u32(out, b + 4 + 4 * k));
    }
  }
  _fill(out, 0xFF, tOff, tOff + _page(_tblk * n));
  _fill(out, 0xFF, at, at + 12);
  return true;
}

/// Is the ROM a launcher ROM (menu with the launch flag)?
bool isLaunch(Uint8List rom, Uint8List tpl) {
  final f = feldFind(rom, tpl);
  return f != null && f.version >= 2 && (f.flags & fLaunch) != 0;
}

// Six fields (six.js): helper page at 0x10F000, set byte in the settings block
const int _sixFlag = 0xF04, _codeEnd = 0x10F000;
/* 1.7.2: lab games per start field (six fields version 7): a fresh field from the menu gets its game family
   in the settings byte 0xF05 (0 Tropical/Glacier, 1 Land/Water/Sky, 2 Forest = Jade Forest). Switching the
   field in the game leaves the byte alone. */
const int _sixGamesFam = 0xF05;
bool _sixGames(Uint8List rom) => isSix(rom) && _u32(rom, sixOff + 4) >= 7 && (_u32(rom, sixOff + 32) & 4) == 4;

int _rgb(int r, int g, int b) => ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);

/*
 * Editions. ID page: word 0 = ID, footer u16 h0, u16 h1, C minus ID,
 * inverse. Factory settings (0xEFE000/0xEFF000): zeros and these bytes, plus the
 * checksum, which the program computes itself. Bag and money as in the app.
 */
class _Profile {
  const _Profile(
      {required this.name,
      required this.idPage,
      required this.ids,
      required this.names,
      required this.h,
      required this.c,
      required this.cols,
      required this.fieldByte,
      required this.common,
      required this.field,
      required this.bag,
      required this.tama,
      required this.level,
      this.ring = false,
      this.six = 0,
      this.sixMap = const []});
  final String name;
  final int idPage;
  final List<int> ids;
  final List<String> names;
  final List<int> h;
  final int c;
  final List<int> cols;
  final int fieldByte;
  final List<List<int>> common;
  final List<List<List<int>>> field;
  final List<int> bag; // money, item list, item counts
  final int tama, level;
  final bool ring;
  final int six; // offset of the set byte, 0 without six fields
  final List<int> sixMap;

  _Profile _six({required List<int> ids, required List<String> names, required List<int> cols, required List<List<List<int>>> field, required List<int> sixMap}) => _Profile(
      name: name,
      idPage: idPage,
      ids: ids,
      names: names,
      h: h,
      c: c,
      cols: cols,
      fieldByte: fieldByte,
      common: common,
      field: field,
      bag: bag,
      tama: tama,
      level: level,
      ring: ring,
      six: _sixFlag,
      sixMap: sixMap);
}

final List<_Profile> _profiles = [
  _Profile(name: 'gen1', idPage: 0xD49000, ids: const [1, 2, 3], names: const ['LAND', 'WATER', 'SKY'], h: const [1, 4], c: 0x70169E2C,
      cols: [_rgb(80, 200, 60), _rgb(40, 120, 255), _rgb(120, 210, 255)], fieldByte: 439,
      common: const [[8, 0x11], [16, 0xc0], [17, 0xa8], [168, 1], [576, 0x3f], [577, 0x1f], [1856, 1]],
      field: const [[[4, 0x0c], [170, 2], [439, 0]], [[4, 4], [170, 1], [439, 1]], [[4, 4], [170, 1], [439, 2]]],
      bag: const [0xb4, 0x240, 0x740], tama: 0x104, level: 0x7C),
  // Jade Forest: one ID (4), three fields in the save (byte 443): LAND, WATER, FOREST (texts 14 to 16 in the ROM).
  // 1.6.9: the block has 4 bytes more from about 0xf8 on (the firmware's offsets from 0x114 are 4 higher than Land's):
  // the bag list is at 0x244 and its amounts at 0x744 (count getter LDR [r0,#0x740] from block + 4), the money stays at 0xb4
  _Profile(name: 'jade', idPage: 0xD49000, ids: const [0, 0, 0], names: const ['LAND', 'WATER', 'FOREST'], h: const [2, 0], c: 0x849633DB,
      cols: [_rgb(80, 200, 60), _rgb(40, 120, 255), _rgb(60, 190, 110)], fieldByte: 443,
      common: const [[4, 4], [8, 17], [16, 192], [17, 168], [168, 1], [170, 3], [580, 63], [581, 31], [1860, 1]],
      field: const [[[443, 0]], [[443, 1]], [[443, 2]]], bag: const [0xb4, 0x244, 0x744], tama: 0x108, level: 0x7C),
  // Tropical and Glacier: same firmware, three fields (byte 499): TROPICAL, ICE (Glacier), FOREST
  // 1.7.6 GEN3_ID4 (User: Forest and Sky kept the ID of the save before, the special characters there never came): the
  // Tropical/Glacier firmware takes the ID 4, 5 or 6 and makes the home of it (1/5 first, 2/6 second, 3/4 third), so
  // Forest and Sky get the ID 4. Read back, such a page counts as edition 7 (Tropical/Glacier family, third home).
  _Profile(name: 'gen3', idPage: 0xD29000, ids: const [5, 6, 4], names: const ['TROPICAL', 'GLACIER', 'FOREST'], h: const [3, 1], c: 0x96CB83B8,
      cols: [_rgb(255, 150, 60), _rgb(150, 220, 255), _rgb(60, 190, 110)], fieldByte: 499,
      common: const [[4, 4], [8, 17], [12, 109], [13, 1], [16, 192], [17, 168], [180, 1], [182, 1], [624, 62], [625, 31], [1904, 1]],
      field: const [[[499, 0]], [[499, 1]], [[499, 2]]], bag: const [0xc0, 0x270, 0x770], tama: 0x114, level: 0x88),
  /* 1.7.6 NEON_FELD: Neon Planets (ID 7 at 0xD85000 with its own footer, edition 8 in the Studio). Its planets switch in the
   * game itself, so no fields here. The settings block is a ring of 5 pages behind the ID page (menu flag F_RING), its
   * layout is that of Tropical/Glacier with the item list 0x14 further (measured in the emulator: Tamapoints at 0xC0,
   * planet level 0x88, pet 0x114, items 0x284, counts 0x784). */
  const _Profile(name: 'neon', idPage: 0xD85000, ids: [], names: ['COSMIC', 'NEW TAMA', 'TAMA'], h: [0, 0], c: 0x99431749,
      cols: [], fieldByte: 0xFFFF, common: [], field: [], bag: [0xc0, 0x284, 0x784], tama: 0x114, level: 0x88, ring: true),
];
const int _fRing = 128;

_Profile _base(Edition e) => _profiles.firstWhere((p) => p.name == e.profile.name);

/* Tropical/Glacier with six fields: the second three are slots 0..2 with the set byte 1. */
_Profile _profileOf(Uint8List rom, _Profile p) {
  if (!isSix(rom)) return p;
  final g = _profiles[0];
  if (p.name == 'gen3') {
    final fam = _sixGames(rom) ? const [0, 0, 2, 1, 1, 1] : null;
    final field = [
      ...p.field,
      for (final f in p.field) [...f, [_sixFlag, 1]]
    ];
    return p._six(
      ids: [...p.ids, ...p.ids],
      names: [...p.names, ...g.names],
      cols: [...p.cols, ...g.cols],
      field: fam != null
          ? [
              for (var i = 0; i < field.length; i++) [...field[i], [_sixGamesFam, fam[i]]]
            ]
          : field,
      sixMap: const [0, 1, 2, 255, 3, 4, 5, 255],
    );
  }
  // Jade Forest: Sky is slot 1 (Water) with the set byte
  if (p.name == 'jade') {
    return p._six(
      ids: [...p.ids, 0],
      names: [...p.names, 'SKY'],
      cols: [...p.cols, g.cols[2]],
      field: [
        ...p.field,
        [
          [p.fieldByte, 1],
          [_sixFlag, 1]
        ]
      ],
      sixMap: const [0, 1, 2, 255, 0, 3, 2, 255],
    );
  }
  return p;
}

/// Edition ID (1 Land ... 6 Glacier) or 0.
int feldId(Uint8List rom) => edition(rom)?.id ?? 0;

/// Does this ROM support the field switch? (every recognized edition has three fields)
bool canFields(Uint8List rom) {
  final e = edition(rom);
  return e != null && !e.profile.ring; // Neon: its planets switch in the game
}

/// The fields of this ROM (names).
List<String> fieldNames(Uint8List rom) {
  final e = edition(rom);
  return e != null && !e.profile.ring ? _profileOf(rom, _base(e)).names.map(_cap).toList() : [];
}

/// Active field (name), read from the save.
String fieldNow(Uint8List rom) {
  final e = edition(rom);
  if (e == null) return '';
  if (e.profile.ring) return editionNames[e.id] ?? '';
  final p = _profileOf(rom, _base(e));
  var f = _b(rom, 0xEFE000 + p.fieldByte);
  if (p.six != 0 && f < 4) f = p.sixMap[(_b(rom, 0xEFE000 + p.six) == 1 ? 4 : 0) + f];
  return f < p.names.length ? _cap(p.names[f]) : (editionNames[e.id] ?? '');
}

/// Program in the ROM: 0 none, 1 DOOM, 2 emulator (TamaEmu, T7Emu or T18Emu, see emuType).
int appKind(Uint8List rom) {
  final m = _u32(rom, _appOff + 0x140);
  if (m == 0x37584D50) return 2; // "PMX7": T7Emu
  if (m == 0x38584D50) return 2; // "PMX8": T18Emu
  if (m == 0x31584D50) return 2; // "PMX1": V1Emu (1.6.8)
  if (m != _pmxc) return 0;
  for (var i = 0x140; i < 0x400; i += 4) {
    if (_u32(rom, _appOff + i) == _pdmc) return 1;
  }
  return 2;
}

/*
 * Where is the stub? Normally at 0x0B0000 (shared with the emulator and DOOM).
 * In editions whose firmware code still occupies that spot (Tropical, Glacier),
 * right after the code in the first free region below 0x110000.
 */
int _freeStubOff(Uint8List rom) {
  if (_isFF(rom, _stubOff, 0x2000)) return _stubOff;
  var p = 0x10F000;
  while (p > 0x90000 && _isFF(rom, p - 0x1000, 0x1000)) {
    p -= 0x1000;
  }
  return p;
}

/// An installed menu (or, for [slotAddr], [slotParse] and [slotPlace], only its slot layout).
class FeldInfo {
  FeldInfo({this.off = 0, this.stubOff = 0, this.version = 0, this.slotOff = 0, this.slotSize = 0, this.nslots = 0, this.flags = fFields, this.catOff = 0, this.catN = 0, this.slotOff2 = 0, this.slotN1 = 0});
  int off, stubOff, version, slotOff, slotSize, nslots, flags, catOff, catN, slotOff2, slotN1;
}

FeldInfo? _feldAt(Uint8List rom, int stubOff, int ph) {
  final v = _u32(rom, stubOff + ph);
  if (v < 0x10000000 || v >= 0x11000000) return null;
  final off = v - 0x10000000 + _xipDec;
  final c = off + 0x140;
  if (off + 0x200 > rom.length || _u32(rom, c) != _feldMagic) return null;
  final version = _u32(rom, c + 4);
  final f = FeldInfo(off: off, stubOff: stubOff, version: version, slotOff: _u32(rom, c + 8), slotSize: _u32(rom, c + 12), nslots: _u32(rom, c + 16));
  if (version >= 2) {
    f.flags = _u32(rom, c + 36);
    f.catOff = _u32(rom, c + 272);
    f.catN = _u32(rom, c + 276);
  }
  f.slotOff2 = version >= 4 ? _u32(rom, c + 364) : 0;
  f.slotN1 = version >= 4 ? _u32(rom, c + 368) : 0;
  return f;
}

/// Flash address of slot i (from menu version 4 the slots can lie in two regions).
int slotAddr(FeldInfo f, int i) => f.slotOff2 != 0 && f.slotN1 != 0 && i >= f.slotN1 ? f.slotOff2 + (i - f.slotN1) * f.slotSize : f.slotOff + i * f.slotSize;

/// Is the menu installed? Returns its place and settings or null. tpl: stub_feld_tpl.bin.
FeldInfo? feldFind(Uint8List rom, Uint8List tpl) {
  final ph0 = _findWord(tpl, _phFeld);
  if (ph0 < 0) return null;
  // older stubs: menu address at 0xF0 (up to 1.2.6), 0x118 (1.2.7) and 0x148 (1.6.0 to 1.6.7)
  for (final ph in <int>{ph0, 0xF0, 0x118, 0x148}) {
    final f = _feldAt(rom, _stubOff, ph);
    if (f != null) return f;
    for (var p = 0x90000; p < 0x110000; p += 0x1000) {
      if (p == _stubOff) continue;
      final g = _feldAt(rom, p, ph);
      if (g != null) return g;
    }
  }
  return null;
}

/// A program the menu can start.
class FeldApp {
  const FeldApp(this.src, this.name);
  final int src;
  final String name;
}

/// More programs of the menu (version 5), see [feldApps].
class FeldApps {
  String name0 = '';
  final List<FeldApp> apps = [];
  bool v9 = false;
  int? mainSrc, dl;
  bool? auto, noClock;
}

/// More programs of the menu (version 5): name0 and the apps (empty without).
FeldApps feldApps(Uint8List rom, Uint8List tpl) {
  final f = feldFind(rom, tpl), r = FeldApps();
  if (f == null || f.version < 5) return r;
  final c = f.off + 0x140;
  String str(int o) {
    final t = StringBuffer();
    for (var k = 0; k < 12 && _b(rom, o + k) != 0; k++) {
      t.writeCharCode(_b(rom, o + k));
    }
    return t.toString();
  }

  r.name0 = str(c + 380);
  final max = f.version >= 8 ? 12 : 6, n = _u32(rom, c + 392) < max ? _u32(rom, c + 392) : max;
  for (var i = 0; i < n; i++) {
    final o = i < 6 ? c + 396 + 16 * i : c + 504 + 16 * (i - 6);
    r.apps.add(FeldApp(_u32(rom, o), str(o + 4)));
  }
  // 1.6.9 test13 (version 9): main program of the start device out of the list, start when switched on
  if (f.version >= 9) {
    r.v9 = true;
    r.mainSrc = _u32(rom, c + 600);
    r.auto = (_u32(rom, c + 604) & 1) == 1;
    r.noClock = (_u32(rom, c + 604) & 2) == 2; // 1.7.3 test7: clean ROM, clock not asked at the start
  }
  if (f.version >= 7) r.dl = _u32(rom, c + 500); // test20: the flash app of the start device (DOWNLOAD)
  return r;
}

/*
 * Saved fields and the shared pool (1.2.12). The header page of field i sits at the start
 * of its slot. Older menus put the packed data right after it; from 1.2.12 the header says
 * "POOL" (word 5) and lists the pool pages (word 6 = count, u16 list at 2032). The pool is
 * every slot page except the header pages, numbered slot by slot.
 */
const int _poolMagic = 0x4C4F4F50, _dpgOff = 2032, _dpgMax = 1024;
// 1.7.6 SLOT_TIME (Pull Request 41): a save received over the menu's save link keeps the clock origins of both devices
// at the end of its slot header; the Studio keeps them and rebases the clock of the settings pages like the menu
const int _slotTimeMagic = 0x43544D50, _slotTimeOff = 4080;
int _poolPages(FeldInfo f) => f.slotSize ~/ 0x1000 - 1;

/// Flash address of pool page k.
int poolAddr(FeldInfo f, int k) {
  final n = _poolPages(f);
  return slotAddr(f, k ~/ n) + (k % n + 1) * 0x1000;
}

/// A stored save: header page, field number (1..6), packed bytes, and the packed stream once read.
class FeldSlot {
  FeldSlot({required this.head, required this.field, required this.bytes, this.pool = false, List<int>? list, this.b = 0, Uint8List? stream, this.index = -1})
      : list = list ?? [],
        stream = stream ?? Uint8List(0);
  Uint8List head;
  int field, bytes;
  bool pool;

  /// Flash addresses of the pool pages (pool format).
  List<int> list;

  /// Flash address of the slot.
  int b;
  Uint8List stream;

  /// Slot the save belongs to (set by [feldSlots]).
  int index;
}

/// Parse the header page of slot i (the stream is read by [slotRead] or [slotReadAsync]). Null: no save.
FeldSlot? slotParse(FeldInfo f, int i, Uint8List head) {
  if (_u32(head, 0) != _slotMagic) return null;
  final field = _u32(head, 4), bytes = _u32(head, 12);
  if (field < 1 || field > 6 || _u32(head, 8) > 500) return null;
  final pool = _u32(head, 20) == _poolMagic, nd = pool ? _u32(head, 24) : 0, np = f.nslots * _poolPages(f), list = <int>[];
  if (pool) {
    if (nd > _dpgMax || bytes > nd * 0x1000) return null;
    for (var k = 0; k < nd; k++) {
      final x = _u16(head, _dpgOff + 2 * k);
      if (x >= np) return null;
      list.add(poolAddr(f, x));
    }
  } else if (bytes > f.slotSize - 0x1000) {
    return null;
  }
  return FeldSlot(head: head, field: field, bytes: bytes, pool: pool, list: list, b: slotAddr(f, i));
}

void _slotFill(FeldSlot p, Uint8List chunk, int k) {
  final n = p.bytes - k * 0x1000;
  _set(p.stream, _sub(chunk, 0, chunk.length < n ? chunk.length : n), k * 0x1000);
}

/// Read slot i of a ROM image: the save or null.
FeldSlot? slotRead(Uint8List rom, FeldInfo f, int i) {
  final p = slotParse(f, i, _sub(rom, slotAddr(f, i), slotAddr(f, i) + 0x1000));
  if (p == null) return null;
  p.stream = Uint8List(p.bytes);
  if (p.pool) {
    for (var k = 0; k < p.list.length; k++) {
      _slotFill(p, _sub(rom, p.list[k], p.list[k] + 0x1000), k);
    }
  } else {
    _set(p.stream, _sub(rom, p.b + 0x1000, p.b + 0x1000 + p.bytes), 0);
  }
  return p;
}

/// Read slot i with read(addr, len) (from the device): the save or null.
Future<FeldSlot?> slotReadAsync(Future<Uint8List> Function(int addr, int len) read, FeldInfo f, int i) async {
  final p = slotParse(f, i, Uint8List.fromList(await read(slotAddr(f, i), 0x1000)));
  if (p == null) return null;
  p.stream = Uint8List(p.bytes);
  if (p.pool) {
    for (var k = 0; k < p.list.length; k++) {
      _slotFill(p, await read(p.list[k], 0x1000), k);
    }
  } else {
    _set(p.stream, _sub(await read(p.b + 0x1000, (p.bytes + 0xFFF) & ~0xFFF), 0, p.bytes), 0);
  }
  return p;
}

/// Write a saved field into slot i of image out (pool format). used: Set of pool pages taken
/// by fields already placed. Returns the written addresses; throws if the pool is full.
List<int> slotPlace(Uint8List out, FeldInfo f, int i, FeldSlot s, Set<int> used) {
  final n = f.nslots * _poolPages(f), nd = (s.bytes + 0xFFF) ~/ 0x1000, pages = <int>[], own = i * _poolPages(f);
  for (var r = 0; r < n && pages.length < nd; r++) {
    final x = (own + r) % n;
    if (!used.contains(x)) {
      used.add(x);
      pages.add(x);
    }
  }
  if (pages.length < nd || nd > _dpgMax) throw StateError('the stored saves do not fit into the room for the fields');
  final h = _ffPage();
  _set(h, _sub(s.head, 0, _dpgOff), 0);
  _set(h, _sub(s.head, _slotTimeOff, 0x1000), _slotTimeOff); // imported UART saves: clock origins
  w32(h, 4, i + 1);
  w32(h, 20, _poolMagic);
  w32(h, 24, nd);
  w32(h, 28, 0);
  for (var k = 0; k < pages.length; k++) {
    w16(h, _dpgOff + 2 * k, pages[k]);
  }
  final b = slotAddr(f, i), written = [b];
  _set(out, h, b);
  for (var k = 0; k < pages.length; k++) {
    final a = poolAddr(f, pages[k]), pg = _ffPage(), e = (k + 1) * 0x1000;
    _set(pg, _sub(s.stream, k * 0x1000, s.bytes < e ? s.bytes : e), 0);
    _set(out, pg, a);
    written.add(a);
  }
  return written;
}

// ---------------------------------------------------------------- one stored save as pages (1.6.8)
/* The menu packs every page with LZSS: flag byte for 8 entries (bit = reference), reference = 2 bytes
 * ((distance-1)<<4 | (length-3)), length field 15: one more byte added to 18 (up to 273). Same as feld/main.c. */
Uint8List lzUnpack(Uint8List inp, int n) {
  final out = Uint8List(0x1000);
  var i = 0, o = 0;
  while (o < 0x1000) {
    if (i >= n) throw const FormatException('stored save damaged');
    final f = _b(inp, i++);
    for (var b = 0; b < 8 && o < 0x1000; b++) {
      if (f & (1 << b) != 0) {
        if (i + 2 > n) throw const FormatException('stored save damaged');
        final v = _u16(inp, i);
        i += 2;
        final off = (v >> 4) + 1;
        var len = (v & 15) + 3;
        if ((v & 15) == 15) {
          if (i >= n) throw const FormatException('stored save damaged');
          len += _b(inp, i++);
        }
        if (off > o || o + len > 0x1000) throw const FormatException('stored save damaged');
        for (var k = 0; k < len; k++, o++) {
          out[o] = out[o - off];
        }
      } else {
        if (i >= n) throw const FormatException('stored save damaged');
        out[o++] = _b(inp, i++);
      }
    }
  }
  if (i != n) throw const FormatException('stored save damaged');
  return out;
}

/// Pack one 4 KB page as the menu does.
Uint8List lzPack(Uint8List p) {
  final out = <int>[], head = Int32List(4096)..fillRange(0, 4096, -1), prev = Int32List(4096)..fillRange(0, 4096, -1);
  int h(int i) => (p[i] * 1089 + p[i + 1] * 33 + p[i + 2]) & 4095;
  var i = 0, fpos = 0, bit = 8;
  while (i < 0x1000) {
    if (bit == 8) {
      fpos = out.length;
      out.add(0);
      bit = 0;
    }
    var best = 0, boff = 0;
    if (i + 3 <= 0x1000) {
      var j = head[h(i)], tries = 0;
      while (j >= 0 && tries < 48) {
        var l = 0;
        while (l < 273 && i + l < 0x1000 && p[j + l] == p[i + l]) {
          l++;
        }
        if (l > best) {
          best = l;
          boff = i - j;
          if (l == 273) break;
        }
        j = prev[j];
        tries++;
      }
    }
    final step = best >= 3 ? best : 1;
    if (best >= 3) {
      final ln = best - 3;
      out[fpos] |= 1 << bit;
      if (ln < 15) {
        final v = ((boff - 1) << 4) | ln;
        out.add(v & 255);
        out.add(v >> 8);
      } else {
        final v = ((boff - 1) << 4) | 15;
        out.add(v & 255);
        out.add(v >> 8);
        out.add(ln - 15);
      }
    } else {
      out.add(p[i]);
    }
    bit++;
    for (var k = 0; k < step; k++, i++) {
      if (i + 3 <= 0x1000) {
        final x = h(i);
        prev[i] = head[x];
        head[x] = i;
      }
    }
  }
  return Uint8List.fromList(out);
}

Uint8List _slotClock(Uint8List p, Uint8List h) {
  if (_u32(h, _slotTimeOff) != _slotTimeMagic) return p;
  final from = _u32(h, _slotTimeOff + 4), to = _u32(h, _slotTimeOff + 8);
  if (_u32(h, _slotTimeOff + 12) != (_slotTimeMagic ^ from ^ to)) throw const FormatException('stored save clock damaged');
  int crc() {
    var c = 0;
    for (var i = 4; i < p.length; i++) {
      c ^= p[i];
      for (var b = 0; b < 8; b++) {
        c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1;
      }
    }
    return c;
  }

  final c = crc(), days = _u32(p, 12), sec = _u32(p, 16), base = days * 86400 + sec + from - to;
  if (_u16(p, 0) != c || _u16(p, 2) != (~c & 0xFFFF) || days > 40000 || sec >= 86400 || base < 0 || base > 0xFFFFFFFF) {
    throw const FormatException('stored save clock damaged');
  }
  w32(p, 12, base ~/ 86400);
  w32(p, 16, base % 86400);
  final next = crc();
  w16(p, 0, next);
  w16(p, 2, ~next);
  return p;
}

/// Pages of a stored save (from slotRead/slotReadAsync): Map address -> 4 KB.
Map<int, Uint8List> slotPages(FeldSlot s) {
  final np = _u32(s.head, 8), pages = <int, Uint8List>{};
  var pos = 0, sum = 0;
  for (var k = 0; k < s.bytes; k++) {
    sum = (sum + _b(s.stream, k)) & 0xFFFFFFFF;
  }
  if (np > 500 || sum != _u32(s.head, 16)) throw const FormatException('stored save damaged');
  for (var k = 0; k < np; k++) {
    final pg = _u16(s.head, 32 + 4 * k), n = _u16(s.head, 34 + 4 * k);
    if (pos + n > s.bytes) throw const FormatException('stored save damaged');
    final addr = pg * 0x1000, p = lzUnpack(_sub(s.stream, pos, pos + n), n);
    pages[addr] = addr == 0xEFE000 || addr == 0xEFF000 ? _slotClock(p, s.head) : p;
    pos += n;
  }
  return pages;
}

/// A save (Map address -> 4 KB, only pages from..to that are not empty) packed like the menu does, for slotPlace.
FeldSlot slotBuild(Map<int, Uint8List> pages, int i, int from, int to) {
  final head = _ffPage(), parts = <Uint8List>[];
  var np = 0, bytes = 0, sum = 0;
  for (final a in pages.keys.toList()..sort()) {
    final d = pages[a]!;
    if (a < from || a >= to || d.length != 0x1000 || d.every((v) => v == 0xFF)) continue;
    if (np >= 500) throw StateError('save too big for a slot');
    final c = lzPack(d);
    parts.add(c);
    w16(head, 32 + 4 * np, a >> 12);
    w16(head, 34 + 4 * np, c.length);
    np++;
    bytes += c.length;
    for (final v in c) {
      sum = (sum + v) & 0xFFFFFFFF;
    }
  }
  final stream = Uint8List(bytes);
  var o = 0;
  for (final c in parts) {
    _set(stream, c, o);
    o += c.length;
  }
  w32(head, 0, _slotMagic);
  w32(head, 4, i + 1);
  w32(head, 8, np);
  w32(head, 12, bytes);
  w32(head, 16, sum);
  return FeldSlot(head: head, field: i + 1, bytes: bytes, stream: stream);
}

/// Pool pages used by the stored saves (heads: slot index -> header page or null), except slot skip.
Set<int> poolUsed(FeldInfo f, List<Uint8List?> heads, int skip) {
  final used = <int>{};
  for (var j = 0; j < heads.length; j++) {
    final h = heads[j];
    if (j == skip || h == null) continue;
    final p = slotParse(f, j, h);
    if (p == null) continue;
    if (p.pool) {
      for (var k = 0; k < _u32(h, 24); k++) {
        used.add(_u16(h, _dpgOff + 2 * k));
      }
    } else {
      for (var k = 0; k < (p.bytes + 0xFFF) ~/ 0x1000; k++) {
        used.add(j * _poolPages(f) + k);
      }
    }
  }
  return used;
}

/// Field number a settings block (4 KB) stands for, -1 unknown.
int fieldOfSettings(Uint8List rom, Uint8List? p) {
  final e = edition(rom);
  if (e == null || p == null) return -1;
  final pr = _profileOf(rom, _base(e));
  if (pr.fieldByte >= p.length) return -1;
  var f = p[pr.fieldByte];
  if (pr.six != 0 && f < 4) f = pr.sixMap[(_b(p, pr.six) == 1 ? 4 : 0) + f];
  return f < pr.names.length ? f : -1;
}

/// The save slots of the menu, see [saveSlots].
class SaveSlots {
  SaveSlots(this.f, this.saves, this.live, this.list);
  final FeldInfo f;

  /// Numbered saves (true) or one save per field.
  final bool saves;

  /// Slot of the save now in use (it is not stored in a slot).
  final int live;
  final List<({int i, bool used})> list;
}

/// The save slots of the menu for the Studio (1.6.8): numbered saves or one per field, the live slot, and per slot
/// whether it is used; null without slots.
SaveSlots? saveSlots(Uint8List rom, Uint8List tpl) {
  final f = feldFind(rom, tpl);
  if (f == null || (f.flags & fFields) == 0 || f.nslots < 1) return null;
  final saves = f.version >= 6 && (f.flags & fSaves) != 0 && f.nslots >= 2, list = <({int i, bool used})>[];
  for (var i = 0; i < f.nslots; i++) {
    list.add((i: i, used: slotParse(f, i, _sub(rom, slotAddr(f, i), slotAddr(f, i) + 0x1000)) != null));
  }
  var live = -1;
  if (saves) {
    final v = _b(rom, 0xEFE000 + 0xF06);
    if (v >= 1 && v <= f.nslots) {
      live = v - 1;
    } else {
      live = 0;
      for (final x in list) {
        if (!x.used) {
          live = x.i;
          break;
        }
      }
    }
  } else {
    live = fieldOfSettings(rom, _sub(rom, 0xEFE000, 0xEFF000));
  }
  return SaveSlots(f, saves, live, list);
}

/// Saved slots (raw bytes) of a ROM with the menu, for moving them over.
List<FeldSlot> feldSlots(Uint8List rom, Uint8List tpl) {
  final f = feldFind(rom, tpl);
  if (f == null || (f.flags & fFields) == 0) return [];
  final out = <FeldSlot>[];
  for (var i = 0; i < f.nslots; i++) {
    final s = slotRead(rom, f, i);
    if (s == null) continue;
    // Slot ID: from menu version 3 the field number + 1, before that (v0.9.4/v0.9.5) the edition ID
    s.index = f.version >= 3 ? s.field - 1 : i;
    out.add(s);
  }
  return out;
}

// ---------------------------------------------------------------- catalog
/*
 * Items from the user's own image, as in the TamaParadise app (Bilder.kt):
 * picture table found by its shape, item table (46-byte records), English
 * text table found by its marker words. Name = text number in the record plus one.
 */
const int _satz = 46, _chA = 318;
final Map<int, String> _sonder = {
  305: ' ', 317: ' ', 375: '&', 376: "'", 381: '.', 370: '!', 388: '?', 382: '/',
  for (var i = 0; i < 10; i++) 306 + i: '$i', // 1.6.8: digits (names changed in the Studio)
};
const List<String> _worte = ['FOOD', 'SNACKS', 'OUTSIDE TOY', 'LAB LOG', 'MILK'];
int _assetEnd(Uint8List rom) => 0x111000 + 16 + _u32(rom, 0x111000 + 8);
/*
 * The image table of the ROM. Only searched inside the asset archive (from 0x111000 to
 * its end): programs built in by the Studio (DOOM, TamaEmu) contain tables that look
 * alike, and DOOM sits before the archive's image table.
 */
int _bildTabelle(Uint8List d) {
  final ae = _assetEnd(d), end = d.length < ae ? d.length : ae;
  for (var o = 0x111000; o + 4 < end; o += 4) {
    final e0 = _u32(d, o);
    if (e0 < 0x1000 || e0 > 0x8000 || e0 % 4 != 0) continue;
    var prev = e0, ok = true;
    for (var i = 1; i < 60; i++) {
      final w = _u32(d, o + 4 * i);
      if (w <= prev || w > 0x1000000) {
        ok = false;
        break;
      }
      prev = w;
    }
    if (!ok) continue;
    final k = o + e0;
    if (k + 24 >= d.length) continue;
    final g = _u32(d, k), p = _u32(d, k + 20);
    if (p > 24 && p < g && g >= 1 && g <= 0x20000 && p % 8 == 0 && d[k + 8] > 0 && d[k + 9] > 0) return o;
  }
  return -1;
}

/// [offset, count] of the item table; nb4 = four times the number of pictures (the first word of the picture table).
(int, int) _itemTabelle(Uint8List d, int nb4) {
  var best = -1, bn = 0;
  for (var o = 0; o + _satz < d.length; o += 2) {
    final k0 = d[o] | (d[o + 1] << 8);
    if (k0 < 5001 || k0 > 9999) continue;
    final seen = <int>{};
    var n = 0;
    while (n < 400 && o + n * _satz + 5 < d.length) {
      final k = _u16(d, o + n * _satz), b = _u16(d, o + n * _satz + 4);
      if (k < 5001 || k > 9999 || 4 * b >= nb4 || seen.contains(k)) break;
      seen.add(k);
      n++;
    }
    if (n > bn) {
      bn = n;
      best = o;
    }
    if (n > 8) o += n * _satz - 2;
  }
  return (best, bn);
}

/// Text n of the text table at t (letters, digits and a few signs; '' for anything else).
String zeichenkette(Uint8List d, int t, int n) {
  final ab = _u16(d, t + 2 * n);
  if (ab <= 0 || ab > 0x8000) return '';
  var o = t + 2 * ab;
  final s = StringBuffer();
  while (s.length < 40) {
    final c = _u16(d, o);
    if (c == 0) break;
    if (c >= _chA && c < _chA + 26) {
      s.writeCharCode(65 + c - _chA);
    } else if (_sonder.containsKey(c)) {
      s.write(_sonder[c]);
    } else {
      return '';
    }
    o += 2;
  }
  return s.toString().trim();
}

bool _wort3(Uint8List d, int t, int n) {
  final ab = _u16(d, t + 2 * n);
  if (ab <= 0 || ab > 0x8000) return false;
  for (var k = 0; k < 3; k++) {
    final c = _u16(d, t + 2 * ab + 2 * k);
    if (c < _chA || c >= _chA + 26) return false;
  }
  return true;
}

/// Offset of the English text table, -1 if not found.
int textTabelle(Uint8List d) {
  var best = -1, bp = 0;
  for (var o = 0; o < d.length - 8; o += 2) {
    final n = d[o] | (d[o + 1] << 8);
    if (n < 100 || n > 4000) continue;
    final a = _u16(d, o + 2), b = _u16(d, o + 4);
    if (!(a > n && b > a && _u16(d, o + 6) > b) || !_wort3(d, o, 1)) continue;
    var prev = n, ok = true;
    for (var i = 1; i < (n < 200 ? n : 200); i++) {
      final w = _u16(d, o + 2 * i);
      if (w < prev || w > 0x8000) {
        ok = false;
        break;
      }
      prev = w;
    }
    if (!ok) continue;
    var p = 0;
    for (var k = 1; k < 120; k++) {
      if (_worte.contains(zeichenkette(d, o, k))) p++;
    }
    if (p > bp) {
      bp = p;
      best = o;
    }
  }
  return bp >= 2 ? best : -1;
}

/// Where a picture entry lies in flash, its length, byte sum and first word.
class PicInfo {
  const PicInfo(this.addr, this.len, this.sum, this.head);
  final int addr, len, sum, head;
}

/*
 * Byte sum of an item picture entry, as the menu computes it after copying the entry
 * to RAM (header, sub-image table, palette, pixel data of all sub-images).
 */
/* Where the picture entry lies in flash, its length, byte sum and first word (or null). */
PicInfo? _picInfo(Uint8List d, int pt, int pic) {
  if (4 * pic >= _u32(d, pt)) return null;
  final e = pt + _u32(d, pt + 4 * pic);
  if (e & 3 != 0) return null;
  final flags = _b(d, e + 4), bpp = _b(d, e + 5), sw = _b(d, e + 8), sh = _b(d, e + 9);
  if (bpp > 3 || sw == 0 || sh == 0) return null;
  final iw = _b(d, e + 12) == 0 ? 1 : _b(d, e + 12), ih = _b(d, e + 13) == 0 ? 1 : _b(d, e + 13), cnt = iw * ih, bits = 1 << bpp, mask = (1 << bits) - 1;
  final need = (sw * sh * bits + 7) >> 3, po = _u16(d, e + 18), px = _u16(d, e + 20);
  var end = px + 8 * cnt;
  for (var c = 0; c < cnt; c++) {
    int x;
    if (flags & 0x60 != 0) {
      final w = _u32(d, e + px + 8 * c), off = w & 0x7FFFFFFF, ln = _u32(d, e + px + 8 * c + 4);
      x = px + off + ((w & 0x80000000) != 0 ? need : ln);
    } else {
      x = px + (c + 1) * need;
    }
    if (x > end) end = x;
  }
  if (po + 2 * (mask + 1) > end) end = po + 2 * (mask + 1);
  if (end > 12288 || e + end > d.length) return null;
  var sum = 0;
  for (var i = 0; i < end; i++) {
    sum += d[e + i];
  }
  return PicInfo(e, end, (sum & 0xFFFF) == 0 ? 1 : sum & 0xFFFF, _u32(d, e));
}

/// An entry of the menu's catalog: an item (fixed 0 or 1) or a character (fixed 2).
class CatItem {
  CatItem({required this.id, required this.fixed, required this.pic, required this.sum, this.at, this.text = 0, required this.name});
  final int id;

  /// 1: an item with a fixed amount (the JS `fixed: true`), 2: a character of the TAMA menu, else 0.
  final int fixed;
  final int pic, sum;
  final PicInfo? at;

  /// Text number of the name (items).
  final int text;
  final String name;
}

/// Result of [itemCatalog]: the items and the offset of the picture table (-1 without).
class ItemCatalog {
  ItemCatalog(this.items, this.pack);
  final List<CatItem> items;
  int pack;
}

/// Catalog: the items ascending by ID, only groups 5 to 8.
ItemCatalog itemCatalog(Uint8List d) {
  final bt = _bildTabelle(d);
  if (bt < 0) return ItemCatalog([], -1);
  final (it, n) = _itemTabelle(d, _u32(d, bt));
  if (it < 0 || n < 100) return ItemCatalog([], -1);
  final tt = textTabelle(d);
  final out = <CatItem>[];
  for (var i = 0; i < n; i++) {
    final o = it + i * _satz, id = _u16(d, o);
    if (id < 5001 || id > 8999) continue;
    final pic = _u16(d, o + 4);
    final pi = _picInfo(d, bt, pic);
    out.add(CatItem(id: id, fixed: _u16(d, o + 24) == 0xFFFF ? 1 : 0, pic: pic, sum: pi?.sum ?? 0, at: pi, text: _u16(d, o + 2) + 1, name: tt >= 0 ? zeichenkette(d, tt, _u16(d, o + 2) + 1) : ''));
  }
  _stableSort(out, (c) => c.id);
  return ItemCatalog(out, bt);
}

/*
 * Characters for the TAMA menu (1.6.8): kid, young and adult of the character table with their
 * English names. fixed 2, stage, field = index + 1 in the menu's field list (P.names), 0 = none.
 */
const Set<String> _fieldDefault = {'LAND', 'WATER', 'SKY', 'FOREST', 'TROPICAL', 'ICE', 'GLACIER'};

/// Text numbers of the field names (1.6.8): the three fields at 14..16, the further ones of six fields at 64..66
const List<int> fieldText = [14, 15, 16, 64, 65, 66];
const Map<int, String> _typeNames = {1: 'LAND', 2: 'WATER', 3: 'SKY', 4: 'FOREST', 5: 'TROPICAL', 6: 'GLACIER', 7: 'COSMIC', 8: 'NEW TAMA', 9: 'TAMA'}; // 7..9: Neon Planets

// from core.js: openRom (only what charCatalog uses: the data pack, files[0] of the asset archive; null where openRom throws)
Uint8List? _dataPack(Uint8List rom) {
  if (rom.length < assetBase + 16 || _str8(rom) != 'SONIXDEV') return null;
  try {
    final root = arc2Parse(rom, assetBase);
    if (root.ents.length != 3) return null;
    final e = root.ents[0];
    return _sub(rom, assetBase + e.$2, assetBase + e.$2 + e.$4);
  } catch (_) {
    return null;
  }
}

// from core.js: charTable (30 byte records: id, graphic, name index, stage, line, ..., field at word 7)
List<({int id, int name, int stage, int field})> _charTable(Uint8List dp) {
  final n = _u32(dp, 0);
  for (var t = 0; t < (n < 40 ? n : 40); t++) {
    final a = _u32(dp, 4 + 4 * t) * 2, b = _u32(dp, 8 + 4 * t) * 2;
    if (b > a && b <= dp.length && (b - a) % 30 == 0 && b - a >= 60 && _u16(dp, a) == 0xFFFF && _u16(dp, a + 30) == 1000) {
      return [for (var o = a; o < b; o += 30) (id: _u16(dp, o), name: _u16(dp, o + 4) + 1, stage: _u16(dp, o + 6), field: _u16(dp, o + 14))];
    }
  }
  return [];
}

final RegExp _spaces = RegExp(r'\s+');
List<CatItem> _charCatalog(Uint8List d, _Profile p) {
  final dp = _dataPack(d);
  if (dp == null) return [];
  final tt = textTabelle(d), out = <CatItem>[];
  for (final c in _charTable(dp)) {
    final type = _typeNames[c.field];
    if (c.id < 2000 || c.id > 4999 || c.stage < 3 || c.stage > 5 || type == null) continue;
    final t = tt >= 0 ? zeichenkette(d, tt, c.name) : '';
    final nm = t.isNotEmpty ? t : 'NO. ${c.id}';
    final fi = p.names.indexOf(type);
    out.add(CatItem(id: c.id, fixed: 2, pic: 0, sum: (c.stage & 255) | ((fi + 1) << 8), name: nm.replaceAll(_spaces, ' ')));
  }
  return out;
}

/// Characters the TAMA menu offers (for the Studio's save editor too): id, stage, field (index in the field list, -1 none), name
List<({int id, int stage, int field, String name})> characters(Uint8List d) {
  final e = edition(d);
  if (e == null) return [];
  final p = _profileOf(d, _base(e));
  return [for (final c in _charCatalog(d, p)) (id: c.id, stage: c.sum & 255, field: (c.sum >> 8) - 1, name: c.name)];
}

/*
 * Catalog: 8 byte header, 28 bytes per entry, then "PEXT" and 12 bytes per entry:
 * flash address of the picture entry, its length, byte sum, first word. The menu
 * reads the picture straight from there (no lookup in the ROM's image table).
 */
const int _extMagic = 0x54584550;
Uint8List _catalogBlob(List<CatItem> cat) {
  final x = 8 + 28 * cat.length;
  final b = Uint8List(x + 4 + 12 * cat.length);
  w32(b, x, _extMagic);
  for (var i = 0; i < cat.length; i++) {
    final at = cat[i].at, o = x + 4 + 12 * i;
    if (at != null) {
      w32(b, o, at.addr);
      w16(b, o + 4, at.len);
      w16(b, o + 6, at.sum);
      w32(b, o + 8, at.head);
    }
  }
  w32(b, 0, _catMagic);
  w32(b, 4, cat.length);
  for (var i = 0; i < cat.length; i++) {
    final c = cat[i], o = 8 + 28 * i, nm = _cut(c.name, 20);
    w16(b, o, c.id);
    b[o + 2] = c.fixed;
    b[o + 3] = nm.length;
    w16(b, o + 4, c.pic);
    w16(b, o + 6, c.sum);
    for (var k = 0; k < nm.length; k++) {
      b[o + 8 + k] = nm.codeUnitAt(k);
    }
  }
  return b;
}

// ---------------------------------------------------------------- install and remove
int _doomCodeEnd(Uint8List rom) {
  var e = _doomSave;
  while (e > _doomCode && rom[e - 1] == 0xFF) {
    e--;
  }
  return _page(e);
}

/// Remove the menu (program, catalog, slots, stub). Call feldSlots() first if the saves should be kept.
/// emb: stub (and oldStub, the launcher of emu.js, to keep an installed program).
Uint8List feldStrip(Uint8List rom, FeldEmbedded emb, FeldEmu E) {
  final out = Uint8List.fromList(rom);
  final f = feldFind(out, emb.stub);
  if (f == null) return out;
  final tab = E.sceneTable(out);
  launchRestore(out, f.stubOff); // start device: scene handlers back, trampolines gone (before the menu area is erased)
  final prev = f.stubOff == _stubOff ? E.installedOrigs(out, tab) : [for (var k = 0; k < 4; k++) _u32(out, f.stubOff + 0x94 + 4 * k)];
  // Program and catalog
  var end = f.off + (f.version >= 2 ? 0x8000 : 0x4000);
  // 1.7.6 FELD_MENU7: the menu with Pull Request 41 is over 32 KB: erase to its last used page (at most 64 KB)
  {
    var e = f.off + 0x1000;
    while (e < f.off + 0x10000 && !_isFF(out, e, 0x1000)) {
      e += 0x1000;
    }
    if (e > end) end = e;
  }
  if (f.catOff > f.off && _u32(rom, f.catOff) == _catMagic) {
    var ce = f.catOff + 8 + (f.version >= 3 ? 28 : 24) * f.catN;
    if (_u32(rom, ce) == _extMagic) ce += 4 + 12 * f.catN;
    if (_page(ce) > end) end = _page(ce);
  }
  if (f.slotOff > f.off && f.slotOff < end) end = f.slotOff;
  final top = f.stubOff == _stubOff && f.off < _feldEnd ? _feldEnd : (isSix(out) ? _codeEnd : 0x110000);
  if (top < end) end = top;
  _fill(out, 0xFF, f.off, end);
  // Slots: never erase into the character data
  if (f.nslots != 0 && f.slotSize != 0) {
    if (f.slotOff2 != 0 && f.slotN1 != 0) {
      for (var i = 0; i < f.nslots; i++) {
        final b = slotAddr(f, i);
        if (b >= _page(_assetEnd(out)) || b < 0x111000) _fill(out, 0xFF, b, b + f.slotSize);
      }
    } else {
      final ae = _page(_assetEnd(out)), from = f.slotOff < 0x800000 ? f.slotOff : (f.slotOff > ae ? f.slotOff : ae);
      _fill(out, 0xFF, from, f.slotOff + f.nslots * f.slotSize);
    }
  }
  // the flash app of the start device (version 7)
  if (f.version >= 7) {
    final d = _u32(out, f.off + 0x140 + 500);
    if (d >= 0x10000000 && d < 0x11000000) {
      final o = d - 0x10000000 + _xipDec;
      if (o >= 0x111000 && o + 0x10000 <= out.length) _fill(out, 0xFF, o, o + 0x10000);
    }
  }
  if (prev != null) {
    final old = emb.oldStub;
    if (f.stubOff == _stubOff && appKind(out) != 0 && old != null) {
      return E.installApp(out, Uint8List.fromList(_sub(out, _appOff, _appOff + 0x10000)), old, keep: true); // 1.6.8: before, this freed the blocks of T18Emu
    }
    final home = tab['PSID_HOME'];
    if (home != null) {
      for (var k = 0; k < 4; k++) {
        w32(out, home + 12 + 4 * k, prev[k]);
      }
    }
    _fill(out, 0xFF, f.stubOff, f.stubOff + 0x1000);
  }
  return out;
}

/// Options of [feldApply] and [cleanApply].
class FeldOpts {
  const FeldOpts(
      {this.fields = false,
      this.bag = false,
      this.tama = false,
      this.gplay = false,
      this.saves = true,
      this.launch = false,
      this.clean = false,
      this.apps = const [],
      this.name0 = '',
      this.appsLow = 0,
      this.dl = 0,
      this.mainSrc = 0,
      this.auto = false,
      this.noClock = false,
      this.fieldNames = const [],
      this.app = 0,
      this.spot});

  /// Field switch (each field with its own save), items and Tamapoints, change the Tama.
  final bool fields, bag, tama;

  /// Play time in the built-in programs earns Tamapoints.
  final bool gplay;

  /// Several saves (with fields; the JS default is on: `opts.saves !== false`).
  final bool saves;

  /// Start device: the menu comes up instead of the game.
  final bool launch;
  final bool clean;

  /// More programs the menu can start, and the name of the stub's program.
  final List<FeldApp> apps;
  final String name0;

  /// The field saves end below this address (0: no limit of this kind).
  final int appsLow;

  /// The flash app of the start device (DOWNLOAD), its main program and autostart.
  final int dl, mainSrc;
  final bool auto;

  /// cleanApply: the clock is not asked at the start.
  final bool noClock;

  /// Field names from the ROM's text table (a renamed field shows its new name in the menu).
  final List<String?> fieldNames;

  /// cleanApply: address of the stub's program (0 none) and the places of menu and clock sector.
  final int app;
  final CleanInfo? spot;
}

void _name12(Uint8List f, int o, String nm) {
  for (var k = 0; k < 12; k++) {
    f[o + k] = k < nm.length ? nm.codeUnitAt(k) : 0;
  }
}

void _appList(Uint8List f, int ci, List<FeldApp> apps, int max) {
  for (var i = 0; i < max; i++) {
    final a = i < apps.length ? apps[i] : null, o = i < 6 ? ci + 396 + 16 * i : ci + 504 + 16 * (i - 6);
    w32(f, o, a?.src ?? 0);
    _name12(f, o + 4, a?.name ?? '');
  }
}

/*
 * Install the menu into an image without a menu (after emulator/DOOM).
 * opts: { fields, bag }, saved: feldSlots() of the source ROM,
 * emb: { feld, stub } (embedded), E: ParamixEmu. Returns a new image.
 */
Uint8List _feldApply0(Uint8List rom, FeldOpts opts, List<FeldSlot> saved, Uint8List feld, Uint8List stub, FeldEmu E) {
  if (rom.length != 0x1000000) throw const FormatException('the Paradise image must be 16 MB');
  final out = Uint8List.fromList(rom);
  if (feldFind(out, stub) != null) throw StateError('the menu is already built in');
  final ed = edition(out);
  if (ed == null) throw const FormatException('edition not recognised');
  final p = _profileOf(out, _base(ed));
  final v6 = _u32(feld, _findWord(feld, _feldMagic) + 4) >= 6;
  final launch = opts.launch;
  final gp = gplay && opts.gplay && !launch && !opts.clean && !p.ring;
  final fields = opts.fields && !launch && !p.ring, bag = opts.bag && !launch, tama = opts.tama && v6 && !launch, saves = fields && v6 && opts.saves;
  if (!fields && !bag && !tama && !gp && !launch) throw StateError('nothing chosen');
  if (launch && (_u32(stub, _launchEntry) != 0x4C01B672 || (_u32(stub, _lcheckEntry) & 0xF800) != 0xF000)) {
    throw StateError('launcher template does not fit'); // cpsid i; ldr r4, feld_src / b.w lcheck
  }
  final tab = E.sceneTable(out);
  final home = tab['PSID_HOME'] ?? 0;
  if (home == 0) throw const FormatException('home screen not found');
  final prev = E.installedOrigs(out, tab);
  final kind = appKind(out);
  final stubOff = prev != null || kind != 0 ? _stubOff : _freeStubOff(out);
  if (prev == null && !_isFF(out, stubOff, 0x1000)) throw StateError('no room for the launcher');
  final catList = bag ? itemCatalog(out) : ItemCatalog([], -1);
  if (tama) {
    catList.items.addAll(_charCatalog(out, p));
    _stableSort(catList.items, (c) => c.id);
  }
  final cat = bag || tama ? _catalogBlob(catList.items) : Uint8List(0);
  final fsz = _page(feld.length), csz = _page(cat.length);
  final doom = kind == 1;
  var prog = doom ? _doomCodeEnd(out) : stubOff + 0x1000;
  // DOOM with T18Emu as a further program (start device, 1.6.8): its flash part at 0x0F0000 lies in DOOM's free end
  final tsz = launch ? _launchSize(out, E.sceneTable(out)) : 0; // start device: trampoline pages behind the menu
  if (doom) {
    while (prog + fsz + csz + tsz <= _doomSave && !_isFF(out, prog, fsz + csz + tsz)) {
      prog += 0x1000;
    }
  }
  final tOff = _page(prog + fsz + csz);
  final catOff = cat.isNotEmpty ? prog + fsz : 0;

  final nslots = fields ? p.ids.length : 0;
  var slotOff = 0, slotSize = 0, slotOff2 = 0, slotN1 = 0;
  if (doom) {
    if (prog + fsz + csz + tsz > _doomSave) throw StateError('no room for the menu next to DOOM');
    if (fields) {
      slotOff = prog + fsz + csz;
      slotSize = ((_doomSave - slotOff) / nslots / 0x1000).floor() * 0x1000;
      if (slotSize < 0x8000) throw StateError('no room for the saves next to DOOM');
    }
  } else {
    if (prog + fsz + csz + tsz > (stubOff == _stubOff ? _feldEnd : _codeEnd)) throw StateError('menu program too big');
    if (!_isFF(out, prog, fsz + csz + tsz)) throw StateError('the area for the menu is in use');
    if (fields && p.six != 0) {
      // six fields: slots behind the menu (up to the helper page) and behind the character data
      final a1 = _page(prog + fsz + csz), r1 = _codeEnd - a1, a2 = _page(_assetEnd(out)), r2 = p.idPage - 0x1000 - a2;
      for (var s = _slotSize; s >= 0x10000; s -= 0x1000) {
        final f1 = (r1 / s).floor(), f2 = (r2 / s).floor(), n1 = f1 > 0 ? f1 : 0, n2 = f2 > 0 ? f2 : 0;
        if (n1 + n2 >= nslots) {
          slotSize = s;
          slotN1 = n1 < nslots ? n1 : nslots;
          slotOff = slotN1 != 0 ? a1 : a2;
          slotOff2 = slotN1 != 0 && slotN1 < nslots ? a2 : 0;
          break;
        }
      }
      if (slotSize == 0) throw StateError('no room for the saves');
    } else if (fields) {
      final ae = _page(_assetEnd(out));
      slotOff = _slotBase > ae ? _slotBase : ae;
      // the emulator's firmware starts at 0x940000, a big one (P's, 4U+) already at 0x840000 (1.3.2)
      // T18Emu (1.5.1) puts its firmware from the top down: the saves get the room below its lowest block
      int min(int a, int b) => a < b ? a : b;
      final t18low = _u32(out, 0xA0140) == _t18Magic ? E.t18Low(out) : 0;
      final limit0 = kind == 2
          ? (_u32(out, 0xA0140) == _pmxc
              ? min(_u32(out, 0xA0148), _guestOff)
              : t18low != 0
                  ? min(t18low, p.idPage - 0x1000)
                  : _guestOff)
          : p.idPage - 0x1000;
      final limit = opts.appsLow != 0 ? min(limit0, opts.appsLow) : limit0;
      if (limit - slotOff < nslots * 0x10000) throw StateError('no room for the field saves next to this emulator firmware');
      // all the room up to the emulator or the device's save area (1.2.11; before at most 0x58000 each)
      slotSize = ((limit - slotOff) / nslots / 0x1000).floor() * 0x1000;
      if (slotSize < 0x10000) throw StateError('no room for the saves');
    }
  }
  final fs = FeldInfo(slotOff: slotOff, slotSize: slotSize, slotOff2: slotOff2, slotN1: slotN1, nslots: nslots);
  if (fields) {
    for (var i = 0; i < nslots; i++) {
      if (!_isFF(out, slotAddr(fs, i), slotSize)) throw StateError('the area for the saves is in use');
    }
  }
  // Program with settings
  final f = Uint8List.fromList(feld);
  final ci = _findWord(f, _feldMagic);
  if (ci < 0 || _u32(f, ci + 4) < 3) throw StateError('settings block of the menu missing');
  final ver = _u32(f, ci + 4);
  w32(f, ci + 8, slotOff);
  w32(f, ci + 12, slotSize);
  w32(f, ci + 16, nslots);
  w32(f, ci + 20, p.idPage + 0x1000);
  w32(f, ci + 24, p.six != 0 || p.ring ? 0xF00000 : 0x1000000); // NEON_HI: Neon's programs may lie behind its save   // six fields: rain pictures from 0xF00000
  w32(f, ci + 28, p.idPage); // ID page (1.2.2 to 1.2.11 lost this line: Tropical/Glacier wrote the ID to 0xD49000)
  w32(f, ci + 32, stubOff);
  w32(f, ci + 36, (fields ? fFields : 0) | (bag ? fBag : 0) | (tama ? fTama : 0) | (saves ? fSaves : 0) | (launch ? fLaunch : 0) | (gp ? fGplay : 0) | (p.ring ? _fRing : 0));
  w32(f, ci + 40, p.c);
  w16(f, ci + 44, p.h[0]);
  w16(f, ci + 46, p.h[1]);
  // 1.6.8: a field renamed in the Studio (text table) shows its new name in the menu too
  String shownName(int i) {
    final x = i < opts.fieldNames.length ? opts.fieldNames[i] : null;
    return x != null && x.isNotEmpty && !_fieldDefault.contains(x) ? _cut(x, 11) : (i < p.names.length ? p.names[i] : '');
  }

  void pair(int o, List<int>? v) {
    w16(f, o, v != null ? v[0] : 0);
    f[o + 2] = v != null ? v[1] : 0;
    f[o + 3] = 0;
  }

  int col(int i) => i < p.cols.length && p.cols[i] != 0 ? p.cols[i] : 0xFFFF;
  List<int>? fieldAt(int i, int k) => i < p.field.length && k < p.field[i].length ? p.field[i][k] : null;

  w32(f, ci + 48, p.ids.length);
  for (var i = 0; i < 4; i++) {
    w32(f, ci + 52 + 4 * i, i < p.ids.length ? p.ids[i] : 0);
    _name12(f, ci + 68 + 12 * i, shownName(i));
    w32(f, ci + 116 + 4 * i, col(i));
  }
  for (var k = 0; k < 16; k++) {
    pair(ci + 132 + 4 * k, k < p.common.length ? p.common[k] : null);
  }
  for (var i = 0; i < 4; i++) {
    for (var k = 0; k < 4; k++) {
      pair(ci + 196 + 16 * i + 4 * k, fieldAt(i, k));
    }
  }
  w32(f, ci + 260, p.bag[0]);
  w32(f, ci + 264, p.bag[1]);
  w32(f, ci + 268, p.bag[2]);
  w32(f, ci + 272, catOff);
  w32(f, ci + 276, cat.isNotEmpty ? _u32(cat, 4) : 0);
  w32(f, ci + 280, p.fieldByte);
  w32(f, ci + 284, bag && catList.pack > 0 ? catList.pack : 0);
  if (p.six != 0) {
    if (ver < 4) throw StateError('menu program too old for six fields');
    w32(f, ci + 288, p.six);
    for (var i = 4; i < 6; i++) {
      w32(f, ci + 292 + 4 * (i - 4), i < p.ids.length ? p.ids[i] : 0);
      _name12(f, ci + 300 + 12 * (i - 4), shownName(i));
      w32(f, ci + 324 + 4 * (i - 4), col(i));
      for (var k = 0; k < 4; k++) {
        pair(ci + 332 + 16 * (i - 4) + 4 * k, fieldAt(i, k));
      }
    }
    w32(f, ci + 364, slotOff2);
    w32(f, ci + 368, slotOff2 != 0 ? slotN1 : 0);
    for (var k = 0; k < p.sixMap.length; k++) {
      f[ci + 372 + k] = p.sixMap[k];
    }
  }
  // more programs (1.6.0, version 5): name of the stub's program and the list the menu can start
  if (ver >= 5) {
    _name12(f, ci + 380, _cut(opts.name0, 12));
    final max = ver >= 8 ? 12 : 6; // 1.6.8 (version 8): 12
    if (opts.apps.length > max) throw StateError('at most $max more programs');
    w32(f, ci + 392, opts.apps.length);
    _appList(f, ci, opts.apps, max);
  } else if (opts.apps.isNotEmpty) {
    throw StateError('menu program too old for more programs');
  }
  // TAMA menu (1.6.8, version 6): where the pet and the planet level lie in the settings block
  if (ver >= 6) {
    w32(f, ci + 492, tama ? p.tama : 0);
    w32(f, ci + 496, tama ? p.level : 0);
  }
  // DOWNLOAD in the start device (1.6.8, version 7): the flash app placed by appsPlace
  if (ver >= 7) {
    w32(f, ci + 500, launch ? opts.dl : 0);
  } else if (launch && opts.dl != 0) {
    throw StateError('menu program too old for the start device');
  }
  // 1.6.9 test13 (version 9): the main program of the start device (one of the list, shown first) and its autostart
  if (ver >= 9) {
    w32(f, ci + 600, launch ? opts.mainSrc : 0);
    w32(f, ci + 604, launch && opts.auto ? 1 : 0);
  }
  _set(out, f, prog);
  if (cat.isNotEmpty) _set(out, cat, catOff);
  // carry over saved slots (the active field lives in the save itself)
  if (fields) {
    final used = <int>{};
    for (final s in saved) {
      final i = s.index;
      if (i < 0 || i >= nslots) continue;
      try {
        slotPlace(out, fs, i, s, used);
      } catch (_) {
        throw StateError('the stored save of ${_cap(p.names[i])} does not fit here');
      }
    }
  }
  // Stub
  final origs = prev ?? [for (var k = 0; k < 4; k++) _u32(out, home + 12 + 4 * k)];
  final st = Uint8List.fromList(stub);
  _put(st, _phApp, kind != 0 ? _xip(_appOff) : 0);
  _put(st, _phFeld, _xip(prog));
  for (var k = 0; k < 4; k++) {
    _put(st, _phOrig[k], origs[k]);
  }
  final ia = _findWord(st, _phAuto);
  if (ia >= 0) w32(st, ia, 0); // autostart off, the Studio sets it at the end
  final ir = _findWord(st, _phRing);
  if (ir >= 0) w32(st, ir, p.ring ? 0x60000000 + p.idPage + 0x1000 : 0); // 1.7.6 RING_CHECK: start device on Neon, any page of the ring is a save
  _fill(out, 0xFF, stubOff, stubOff + 0x1000);
  _set(out, st, stubOff);
  for (var k = 0; k < 4; k++) {
    w32(out, home + 12 + 4 * k, (_xip(stubOff) + _hookOff[k]) | 1);
  }
  if (launch) _launchRedirect(out, tab, stubOff, tOff);
  return out;
}

/*
 * 1.7.2 CLEAN_ROM: a ROM without the Paradise. The boot ROM of the chip starts our menu straight away: an unencrypted
 * load table at 0 (a copy of the device's own with LOAD_CFG bit 0 off, as the rescue start at 0xFFE000, confirmed on
 * the device) loads the menu (0x0B1000, as in every Paramix ROM) into the PRAM; the menu sets up clock, pins and
 * display itself. Programs go back through the routine at flash 0x110568 (the firmware's restart, the programs call
 * it at 0x100FF568 with the window at 0x60011000): here it starts the menu through the stub. The menu keeps the clock
 * in its own sector (0x0C0000). Kept from the device: only the ID page (its edition and identity, so the Studio and
 * the flasher know the device). Everything else of the 16 MB is free for programs, besides the rescue start.
 */
// The ID page of a clean ROM is `cleanId` (edition.dart, 0xEFD000: below the kept Paradise settings pages).
const bool cleanRom = true;
const int fClean = 32, clockSec = 0xC0000;
const int _cleanShim = 0x110568, _cleanLo = 0x10000, _cleanHi = 0xFF0000;

/// Areas a clean ROM keeps for itself (programs must not go there).
List<List<int>> cleanReserved() => [
      [0, _cleanLo],
      [_stubOff, clockSec + 0x1000],
      [_cleanShim & ~0xFFF, (_cleanShim & ~0xFFF) + 0x1000],
      [cleanId, 0xF00000],
      [_cleanHi, 0x1000000]
    ];

/// Is this a ROM without the Paradise (made by cleanApply)?
bool isClean(Uint8List? rom) => cleanInfo(rom) != null;

/// Menu place and clock sector of a clean ROM.
class CleanInfo {
  const CleanInfo(this.feld, this.clock);
  final int feld, clock;
}

/// Menu place and clock sector of a clean ROM, or null.
CleanInfo? cleanInfo(Uint8List? rom) {
  if (rom == null || rom.length != 0x1000000 || _str8(rom) != 'SONIXDEV') return null;
  final a = _u32(rom, 0x10) - 0x60000000;
  if (a != _feldOff) return null;
  final ci = _findWord(_sub(rom, a, a + 0x10000), _feldMagic);
  if (ci < 0 || (_u32(rom, a + ci + 36) & fClean) == 0) return null;
  return CleanInfo(a, _u32(rom, a + ci + 4) >= 10 ? _u32(rom, a + ci + 608) : clockSec);
}

/// Empty 16 MB with the device's ID page (from its own ROM src); the rest comes from appsPlace and cleanApply.
Uint8List cleanBase(Uint8List src) {
  final ed = edition(src);
  if (ed == null) throw const FormatException('edition not recognised');
  final out = Uint8List(0x1000000)..fillRange(0, 0x1000000, 0xFF);
  _set(out, _sub(src, ed.at, ed.at + 0x1000), cleanId); // 1.7.3 test13: at the top (was its own place 0xD49000/0xD29000)
  _set(out, _sub(src, 0, 0x1000), 0); // the load table, made ours in cleanApply
  return out;
}

/* Menu, stub, restart routine and load table into a clean ROM (programs already placed). opts: apps, dl, mainSrc, auto;
 * spot: { feld, clock } (the usual places when left out). */
Uint8List _cleanApply0(Uint8List rom, FeldOpts opts, Uint8List feld, Uint8List stub) {
  final out = Uint8List.fromList(rom);
  final sp = opts.spot ?? const CleanInfo(_feldOff, clockSec), fo = sp.feld;
  if (_str8(out) != 'SONIXDEV') throw const FormatException('load table missing');
  if (edition(out) == null) throw const FormatException('edition not recognised');
  final f = Uint8List.fromList(feld), ci = _findWord(f, _feldMagic);
  if (ci < 0 || _u32(f, ci + 4) < 10) throw StateError('menu program too old for a ROM without the Paradise');
  if (f.length > 0xE000) throw StateError('menu program too big');
  // settings: no fields, items or Tama; the programs, DOWNLOAD, the clock sector
  for (var k = 8; k < 36; k += 4) {
    w32(f, ci + k, 0);
  }
  w32(f, ci + 28, cleanId);
  w32(f, ci + 32, _stubOff);
  w32(f, ci + 36, fLaunch | fClean);
  w32(f, ci + 48, 0);
  w32(f, ci + 272, 0);
  w32(f, ci + 276, 0);
  w32(f, ci + 288, 0);
  w32(f, ci + 284, 0);
  _name12(f, ci + 380, opts.app != 0 ? _cut(opts.name0, 12) : '');
  const max = 12;
  if (opts.apps.length > max) throw StateError('at most $max more programs');
  w32(f, ci + 392, opts.apps.length);
  _appList(f, ci, opts.apps, max);
  w32(f, ci + 492, 0);
  w32(f, ci + 496, 0);
  w32(f, ci + 500, opts.dl);
  w32(f, ci + 600, opts.mainSrc);
  w32(f, ci + 604, (opts.auto ? 1 : 0) | (opts.noClock ? 2 : 0));
  w32(f, ci + 608, sp.clock);
  final size = _page(f.length);
  _fill(out, 0xFF, fo, fo + size);
  _set(out, f, fo);
  // stub: only its start entry is used (no home screen hooks)
  final st = Uint8List.fromList(stub);
  _put(st, _phApp, opts.app);
  _put(st, _phFeld, _xip(fo));
  for (final ph in _phOrig) {
    _put(st, ph, 0);
  }
  final ia = _findWord(st, _phAuto);
  if (ia >= 0) w32(st, ia, 0);
  if (_u32(st, 0x0C) != 0x4604B672) throw StateError('launcher template does not fit'); // cpsid i; mov r4, r0 (start_src)
  _fill(out, 0xFF, _stubOff, _stubOff + 0x1000);
  _set(out, st, _stubOff);
  // the restart routine the programs call: ldr r0, [menu]; ldr r1, [start_src]; bx r1
  const r = _cleanShim;
  _fill(out, 0xFF, r & ~0xFFF, (r & ~0xFFF) + 0x1000);
  w16(out, r, 0x4801);
  w16(out, r + 2, 0x4902);
  w16(out, r + 4, 0x4708);
  w16(out, r + 6, 0xBF00);
  w32(out, r + 8, _xip(fo));
  w32(out, r + 12, (_xip(_stubOff) + 0x0C) | 1);
  // the load table: the menu, not encrypted
  w32(out, 0x08, _u32(out, 0x08) & ~1);
  w32(out, 0x10, 0x60000000 + fo);
  w32(out, 0x14, size);
  w32(out, 0x24, crc32(out, fo, size));
  _fill(out, 0, 0x80, 0x84);
  return out;
}

// 1.7.6 FELD_BIG: the menu with Pull Request 41 (batch items, slot copy and clear, save link) is about 10 KB bigger.
// Where it does not fit (DOOM with the Paradise and saves, a big main program), the menu of 1.7.5 goes in instead.
final RegExp _roomRe = RegExp(r'no room|too big|in use|do not fit|not enough room', caseSensitive: false);
bool _roomErr(Object e) => _roomRe.hasMatch(_msg(e));

/// Install the menu into an image without a menu (after emulator/DOOM).
/// opts: what the menu offers, saved: feldSlots() of the source ROM, emb: feld (feld.bin), stub and feldS (the 1.7.5
/// menu, taken where the big one does not fit), E: the functions of emu.js. Returns a new image.
Uint8List feldApply(Uint8List rom, FeldOpts opts, List<FeldSlot> saved, FeldEmbedded emb, FeldEmu E) {
  final feld = emb.feld;
  if (feld == null) throw ArgumentError('emb.feld missing');
  try {
    return _feldApply0(rom, opts, saved, feld, emb.stub, E);
  } catch (e) {
    // the 1.7.5 menu has no settings ring: not for Neon
    final ed = edition(rom), s = _roomErr(e) && !(ed != null && ed.profile.ring) ? emb.feldS : null;
    if (s == null) rethrow;
    return _feldApply0(rom, opts, saved, s, emb.stub, E);
  }
}

/// Menu, stub, restart routine and load table into a clean ROM (programs already placed). opts: apps, dl, mainSrc,
/// auto, noClock, app, name0, spot. emb: feld (feldc.bin, see [FeldEmbedded.forClean]), stub and feldcS.
Uint8List cleanApply(Uint8List rom, FeldOpts opts, FeldEmbedded emb) {
  final feld = emb.feld;
  if (feld == null) throw ArgumentError('emb.feld missing');
  try {
    return _cleanApply0(rom, opts, feld, emb.stub);
  } catch (e) {
    final s = _roomErr(e) ? emb.feldcS : null;
    if (s == null) rethrow;
    return _cleanApply0(rom, opts, s, emb.stub);
  }
}

/// Kind of the built-in emulator: 't7', 't18', 'v1', 'tama' or ''.
String emuType(Uint8List rom) {
  final m = _u32(rom, _appOff + 0x140);
  return m == 0x37584D50
      ? 't7'
      : m == 0x38584D50
          ? 't18'
          : m == 0x31584D50
              ? 'v1'
              : m == _pmxc && appKind(rom) == 2
                  ? 'tama'
                  : '';
}
