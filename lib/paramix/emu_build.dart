// Paramix Studio: emulators and programs into the Paradise ROM. A native port of Paramix Studio's
// emu.js (mameise, GPL-3.0). The programs (emu.bin, t7.bin, ...) are not in here: the app loads them
// from assets/paramix/ and hands them in (EmuBinaries, EmuApps). The user supplies the guest
// firmware and games; they never leave the device.
//
// Layout in the Paradise flash:
//   0x0A0000  emulator program (copied to PRAM at startup)
//   0x0B0000  stub and home screen hook (hold A+C)
//   0x0C0000  saved run state (written by the emulator itself)
//   0x940000  color Tama firmware, packed in 64 KB blocks; behind it, up to
//             0xD40000, spare pages for blocks the guest writes (item stores)
//   0x840000  instead, for firmware that does not fit there (P's, 4U+): up to 0xD48000.
//             The menu's field saves then have no room.

// ignore_for_file: constant_identifier_names, non_constant_identifier_names

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'bytes.dart';
import 'sprites.dart' show Rgba;

// ------------------------------------------------------------ errors, programs

/// Error of the builder (the JS Error with its extra properties).
class EmuError extends StateError {
  EmuError(super.message, {this.needPack = false, this.room = false, this.missing, this.frag = false, this.prog});
  bool needPack; // only fits packed: switch on "Pack the firmware"
  bool room; // no room in the flash
  int? missing; // KB missing (room)
  bool frag; // the room adds up, but not in pieces big enough
  bool packHint = false; // packing a TamaEmu could help
  String? prog;
}

/// T7Emu: t7.bin with its second part (t7x.bin, the translator for the JIT).
class T7App {
  T7App(this.app, [this.x]);
  final Uint8List app;
  final Uint8List? x;
}

/// T18Emu: t18.bin (PRAM part) with the flash part t18x.bin.
class T18App {
  T18App(this.app, [this.xip]);
  final Uint8List app;
  final Uint8List? xip;
}

/// V1Emu: v1.bin, with V3Emu (v3.bin) for a Connection V3 ROM.
class V1App {
  V1App(this.app, [this.v3]);
  final Uint8List app;
  final Uint8List? v3;
}

/// DOOM for the menu: doomf_app.bin and doomf_xip.bin.
class DoomApp {
  DoomApp(this.app, this.xip);
  final Uint8List app, xip;
}

/// The embedded binaries by name (third_party/paramix-studio/`dir`/`name`.bin, assets/paramix/).
class EmuBinaries {
  EmuBinaries({this.emu, this.stubTpl, this.t7, this.t7x, this.t18, this.t18x, this.v1, this.v3, this.gb, this.gbc, this.sms, this.pm, this.ab, this.wolf, this.wolfsod});
  Uint8List? emu, stubTpl, t7, t7x, t18, t18x, v1, v3, gb, gbc, sms, pm, ab, wolf, wolfsod;
}

/// Set once by the app after loading the assets; the `...Embedded()` functions read it.
EmuBinaries? emuBinaries;

/// The programs for appsPlace (JS: `{ t7, tama, t18, v1, ... }`).
class EmuApps {
  EmuApps({this.t7, this.tama, this.t18, this.v1, this.v3, this.gb, this.gbc, this.sms, this.pm, this.ab, this.wolf, this.wolfsod, this.doom});
  T7App? t7;
  Uint8List? tama;
  T18App? t18;
  V1App? v1;
  Uint8List? v3, gb, gbc, sms, pm, ab, wolf, wolfsod;
  DoomApp? doom;
}

// ------------------------------------------------------------ constants

const int _XIP_DEC = 0x11000;
int _xip(int off) => 0x10000000 + off - _XIP_DEC;
const int _APP_OFF = 0xA0000, _STUB_OFF = 0xB0000, _SAVE_OFF = 0xC0000, _SAVE_END = 0x110000;
const int _GUEST_OFF = 0x940000, _GUEST_END = 0xD40000;
const int _BIG_OFF = 0x840000, _BIG_END = 0xD48000, _SPARE_MIN = 0x4000; // big firmware (1.3.2); 256 KB aligned like 0x940000
const int _APP_MAX = 0x10000;
const int _PMXC = 0x43584D50;
// Placeholders in the prebuilt stub (stub_tpl.bin)
const int _PH_APP = 0x1234ABCD, _PH_AUTO = 0x66666661;
const List<int> _PH_ORIG = [0x22222221, 0x33333331, 0x44444441, 0x55555551];
const List<int> _HOOK_OFF = [0x40, 0x46, 0x4C, 0x52];

const int stubOff = _STUB_OFF, guestOff = _GUEST_OFF, bigOff = _BIG_OFF;

class EmuDevice {
  const EmuDevice(this.kind, this.size, this.label, this.par);
  final int kind, size, par;
  final String label;
}

const Map<String, EmuDevice> devices = {
  'pc': EmuDevice(0, 0x400000, '4 MB', 0x3F),
  'idl': EmuDevice(1, 0x800000, '8 MB', 0x00),
  'ps': EmuDevice(2, 0x800000, "P's", 0x00),
  '4u': EmuDevice(3, 0x800000, '4U+', 0x00),
  '4u-plain': EmuDevice(4, 0x800000, '4U', 0x00),
  't7': EmuDevice(99, 0, 'T7Emu', 0x00), // V7 (T7Emu), not packed like the others
  't18': EmuDevice(98, 0, 'T18Emu', 0x00), // TG18 (T18Emu), own block map
};
// 8 MB firmware by its reset vector (file offset 0x400000), as tamaemu's dlc tool tells them apart
const Map<int, String> _RESET_VEC = {0x024FDFE6: 'ps', 0x024F6256: '4u', 0x024C680A: '4u-plain'};
// Blocks with many data accesses first: they sit in the cached 1 MB window
const Map<String, List<int>> _HOT = {
  'pc': [0x25, 0x21, 0x04, 0x02, 0x01, 0x03, 0x05, 0x20, 0x22, 0x23, 0x24, 0x26, 0x27, 0x28, 0x29, 0x2a],
  'idl': [0x0b, 0x0e, 0x0d, 0x19, 0x08, 0x09, 0x16, 0x18, 0x0c, 0x17, 0x4f, 0x50, 0x40, 0x15, 0x4c, 0x4d], // v0.8.17 after measuring (0x08/0x09 added)
  // 1.6.13 test10: the blocks P's, 4U+ and 4U read most (measured in the device simulation: menus, status, letter
  // and room scenes); before, these took the first blocks in order and their hottest code was read uncached
  'ps': [0x14, 0x1d, 0x40, 0x1a, 0x1e, 0x53, 0x16, 0x20, 0x1b, 0x15, 0x50, 0x26, 0x51, 0x55, 0x41, 0x52],
  '4u': [0x0d, 0x10, 0x40, 0x53, 0x14, 0x23, 0x0e, 0x50, 0x51, 0x0f, 0x4f, 0x41, 0x55, 0x52, 0x4d, 0x19],
  '4u-plain': [0x0f, 0x13, 0x4f, 0x40, 0x0d, 0x10, 0x4c, 0x4d, 0x4e, 0x52, 0x41, 0x50, 0x18, 0x51],
};

// ------------------------------------------------------------ helpers (JS typed array semantics)

/// u32 as JS reads it: bytes behind the end count as 0.
int _u32s(Uint8List b, int o) {
  if (o >= 0 && o + 4 <= b.length) return u32(b, o);
  int at(int i) => i >= 0 && i < b.length ? b[i] : 0;
  return (at(o) | (at(o + 1) << 8) | (at(o + 2) << 16) | (at(o + 3) << 24)) & 0xFFFFFFFF;
}

/// Byte or -1 (JS: undefined) behind the end.
int _at(Uint8List b, int i) => i >= 0 && i < b.length ? b[i] : -1;

/* 1.7.2: placing into a ROM without the Paradise (appsPlace clean): no pictures, no Paradise save, the whole flash */
bool _clean = false;
int _assetEnd(Uint8List b) => _clean ? 0x10000 : 0x111000 + 16 + _u32s(b, 0x111000 + 8);

/// a & b as JS computes it (32 bits, signed): the asset end of a ROM without an archive is above 2^32.
int _and32(int a, int b) => (a & b).toSigned(32);

bool _isFF(Uint8List b, int a, int n) {
  if (n <= 0) return true;
  if (a < 0 || a + n > b.length) return false; // JS: undefined !== 0xFF
  for (var i = a; i < a + n; i++) {
    if (b[i] != 0xFF) return false;
  }
  return true;
}

/// TypedArray.fill(v, a, e): clamped to the array.
void _fill(Uint8List b, int v, int a, int e) {
  if (a < 0) a = math.max(b.length + a, 0);
  if (e < 0) e = math.max(b.length + e, 0);
  if (a > b.length) a = b.length;
  if (e > b.length) e = b.length;
  if (e > a) b.fillRange(a, e, v);
}

/// TypedArray.subarray(a, e): clamped view.
Uint8List _sub(Uint8List b, int a, [int? e]) {
  var z = e ?? b.length;
  if (a < 0) a = math.max(b.length + a, 0);
  if (z < 0) z = math.max(b.length + z, 0);
  if (a > b.length) a = b.length;
  if (z > b.length) z = b.length;
  if (z < a) z = a;
  return Uint8List.sublistView(b, a, z);
}

/// TypedArray.slice(a, e): clamped copy.
Uint8List _slice(Uint8List b, int a, [int? e]) => Uint8List.fromList(_sub(b, a, e));

/// TypedArray.set(src, off).
void _set(Uint8List dst, List<int> src, int off) {
  if (off < 0 || off + src.length > dst.length) throw RangeError('offset is out of bounds');
  dst.setRange(off, off + src.length, src);
}

Uint8List _copy(Uint8List b) => Uint8List.fromList(b);
Uint8List _ff(int n) => Uint8List(n)..fillRange(0, n, 0xFF);

bool _eqAt(Uint8List a, int ao, Uint8List b, int bo, int n) {
  for (var i = 0; i < n; i++) {
    if (a[ao + i] != b[bo + i]) return false;
  }
  return true;
}

/// Array.prototype.sort is stable; List.sort is not.
void _sort<T>(List<T> l, int Function(T a, T b) cmp) {
  if (l.length < 2) return;
  final tmp = List<T>.of(l);
  void merge(List<T> src, List<T> dst, int lo, int hi) {
    if (hi - lo < 2) return;
    final mid = (lo + hi) >> 1;
    merge(dst, src, lo, mid);
    merge(dst, src, mid, hi);
    var i = lo, j = mid;
    for (var k = lo; k < hi; k++) {
      if (i < mid && (j >= hi || cmp(src[i], src[j]) <= 0)) {
        dst[k] = src[i++];
      } else {
        dst[k] = src[j++];
      }
    }
  }

  merge(tmp, l, 0, l.length);
}

String _str(Iterable<int> codes) => String.fromCharCodes(codes);

/// Uint8ClampedArray assignment: round to nearest, ties to even.
int _clamp8(double v) {
  if (v.isNaN || v <= 0) return 0;
  if (v >= 255) return 255;
  final f = v.floorToDouble(), d = v - f;
  final n = f.toInt();
  if (d < 0.5) return n;
  if (d > 0.5) return n + 1;
  return n.isEven ? n : n + 1;
}

// 1.7.4 test2: ID_STRAP_ON: the Tamagotchi iD firmwares (also Lovely Melody) read the debug pin the other way round than the
// Plus Color; flags bit 13 tells TamaEmu to leave the pin on "no debug"
const bool _ID_STRAP_ON = true;
const int _ID_STRAP = 0x2000;
bool _idFirmware(Uint8List? g) {
  if (!_ID_STRAP_ON || g == null || g.length > 0x400000) return false;
  const t = [0x54, 0x41, 0x4D, 0x41, 0x47, 0x4F, 0x00]; // "TAMAGO\0", only in the iD firmwares
  outer:
  for (var i = 0; i + t.length <= g.length; i++) {
    if (g[i] != 0x54) continue;
    for (var j = 1; j < t.length; j++) {
      if (g[i + j] != t[j]) continue outer;
    }
    return true;
  }
  return false;
}

/* 1.7.6 DETECT_TAG (User: a Japanese P's showed as iD L): another version of a firmware has another reset vector. Its
 * download names tell the family: "DL_iDN" P's, "DL_T4U" 4U, "DL_iDL" iD L (UTF-16, a few hundred
 * times; P's and 4U+ hold one iD L name too). Only when the vector is not known. */
const bool detectTag = true;
final Expando<List<String?>> _tagCache = Expando();
String? _tagDev(Uint8List g) => (_tagCache[g] ??= [_tagDev0(g)])[0];
String? _tagDev0(Uint8List g) {
  int cnt(String s) {
    final t = <int>[];
    for (final c in s.codeUnits) {
      t..add(c)..add(0);
    }
    t.removeLast();
    var n = 0;
    outer:
    for (var i = 0; i + t.length <= g.length; i++) {
      if (g[i] != t[0]) continue;
      for (var j = 1; j < t.length; j++) {
        if (g[i + j] != t[j]) continue outer;
      }
      n++;
    }
    return n;
  }

  final ps = cnt('DL_iDN'), u4 = cnt('DL_T4U'), idl = cnt('DL_iDL');
  if (ps > 8 && ps > idl && ps >= u4) return 'ps';
  if (u4 > 8 && u4 > idl) return '4u';
  return null;
}

/// Which firmware is this? Returns 'pc', 'idl', 'ps', '4u' or '4u-plain', or throws an error.
String emuDetect(Uint8List g) {
  if (g.length >= 0x100 && g.length <= 0x400000) {
    final v = u32(g, 0);
    if (v >= 0xC00000 && v < 0x1000000) return 'pc';
  }
  if (g.length > 0x400000 && g.length <= 0x800000) {
    final v = _u32s(g, 0x400000);
    if (v >= 0x2000000 && v < 0x2800000) return _RESET_VEC[v] ?? (detectTag ? _tagDev(g) : null) ?? 'idl';
  }
  throw const FormatException('firmware not recognised (expected a 4 MB or 8 MB image of a colour Tamagotchi)');
}

/// Paradise scene table: name -> flash offset of the 28-byte entry.
Map<String, int> sceneTable(Uint8List d) {
  final names = <int, String>{};
  for (var i = 0; i + 5 < d.length; i++) {
    if (d[i] != 0x50 || d[i + 1] != 0x53 || d[i + 2] != 0x49 || d[i + 3] != 0x44 || d[i + 4] != 0x5F) continue; // "PSID_"
    var j = i + 5;
    while (j < d.length && ((d[j] >= 0x41 && d[j] <= 0x5A) || (d[j] >= 0x30 && d[j] <= 0x39) || d[j] == 0x5F)) {
      j++;
    }
    if (j >= d.length || d[j] != 0) continue;
    names[_xip(i)] = _str(Uint8List.sublistView(d, i, j));
    i = j;
  }
  final ptrs = <(int, int)>[];
  for (var o = 0; o + 4 <= d.length; o += 4) {
    final w = u32(d, o);
    if (w >= 0x10000000 - _XIP_DEC && names.containsKey(w)) ptrs.add((o, w));
  }
  if (ptrs.isEmpty) throw StateError('scene table not found');
  var best = <(int, int)>[], run = <(int, int)>[ptrs[0]];
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

/// Pack the firmware into 64 KB blocks. Returns { map, blob, blocks }.
/* 1.7.1 GUEST_SPARSE: a TamaEmu in the menu (sparse) keeps the almost empty firmware blocks (at most two 8 KB
 * parts with data, never read in the device simulation: menus, games, status, shop) as spare pages instead of whole
 * 64 KB blocks. The device reads them over its spare page table as it does since 1.6.6 for written blocks; the hot
 * blocks stay as they are, so the speed is the same. iD L 4 blocks (about 250 KB less), P's 7 (up to about 450 KB). */
const bool _GUEST_SPARSE = true;
const int _SPARSE_MAX = 2, _SPARSE_PG = 16;
const bool _LZ_GONE = true; // 1.7.3 test21: see guestPagesIn and emu/src/emu/state.c
const Map<String, List<int>> _SPARSE_SKIP = {
  'idl': [0x5b],
  '4u': [0x56],
}; // read now and then in the simulation (170 s of play): stays a whole block
/* a block that may go into spare pages: not the parameter block, not hot, not read in the simulation, no download item
 * store (the Studio writes items there, the device keeps its spare pages) */
bool _sparseOk(String? dev, int b) {
  final D = devices[dev];
  if (D == null || b == D.par || (_HOT[dev] ?? const []).contains(b) || (_SPARSE_SKIP[dev] ?? const []).contains(b)) return false;
  return !(_DLC_DEV[dev] ?? const <DlcStore>[]).any((k) => b >= k.base >> 16 && b <= (k.base + k.n * k.size - 1) >> 16);
}

/* GUEST_SPARSE: the firmware parts a TamaEmu in the menu keeps as spare pages, back into its guest (as SV.emuGuestAsync
 * reads them; only blocks that can be paged and at most SPARSE_MAX parts, so the pet's own writes elsewhere stay on the
 * device as before) */
void _guestPagesIn(Uint8List rom, ExtraCfg c, Uint8List g) {
  if (!_GUEST_SPARSE || c.spareEnd == 0) return;
  final lo = (c.guestOff + c.guestSize + 0x1FFF) & ~0x1FFF, hi = c.spareEnd & ~0x1FFF;
  if (hi < lo + 0x4000 || hi > rom.length) return;
  final data = lo + 0x2000, n = math.min(64, (hi - data) >> 13);
  var x = (0x50584D50 ^ ((n * 0x9E3779B1) & 0xFFFFFFFF)) & 0xFFFFFFFF;
  final vp = <int>[];
  for (var i = 0; i < 64; i++) {
    final v = rom[lo + 16 + 2 * i] | (rom[lo + 17 + 2 * i] << 8);
    vp.add(v);
    x = ((((x << 5) | (x >> 27)) & 0xFFFFFFFF) ^ v) & 0xFFFFFFFF;
  }
  if (u32(rom, lo) != 0x50584D50 || u32(rom, lo + 4) != n || u32(rom, lo + 8) != x) return;
  final per = <int, List<(int, int)>>{};
  // 1.7.3 test21 LZ_GONE: packed blocks the pet erased read empty, with all their written parts (as on the device)
  final gone = <int>{};
  {
    final t = _sub(rom, lo, lo + 164);
    const o = 144;
    var gx = 0x454E4F47;
    for (var i = 0; i < 4; i++) {
      gx = (gx ^ _u32s(t, o + 4 * i)) & 0xFFFFFFFF;
    }
    if (_LZ_GONE && c.lzOff != 0 && gx == _u32s(t, o + 16)) {
      for (var b = 0; b < 128; b++) {
        if (((_u32s(t, o + 4 * (b >> 5)) >> (b & 31)) & 1) != 0) {
          gone.add(b);
          if ((b << 16) < g.length) _fill(g, 0xFF, b << 16, (b + 1) << 16);
        }
      }
    }
  }
  for (var i = 0; i < n; i++) {
    final v = vp[i];
    if (v == 0xFFFF || (v << 13) >= g.length) continue;
    final b = v >> 3;
    if (gone.contains(b)) {
      _set(g, _sub(rom, data + (i << 13), data + ((i + 1) << 13)), v << 13);
      continue;
    }
    if (b >= c.map.length || c.map[b] != 0xFF || !_sparseOk(c.dev, b)) continue;
    (per[b] ??= []).add((v, i));
  }
  for (final l in per.values) {
    if (l.length <= _SPARSE_MAX) {
      for (final (v, i) in l) {
        _set(g, _sub(rom, data + (i << 13), data + ((i + 1) << 13)), v << 13);
      }
    }
  }
}

/* 1.7.3 GUEST_LZ: a TamaEmu in the menu keeps its cold firmware blocks packed (LZ4 blocks of 1 KB). Cold: not the
 * parameter block, not hot, no download item store and not read in the device simulation (170 s of play: menus, games,
 * status, shop, letters). The device unpacks a 1 KB part when the guest reads it (two parts kept in RAM); the hot and
 * warm blocks stay as they are, so the speed stays the same. Layout behind the packed blocks: 128 u32 (offset of the
 * block's part list from the table, 0 = not packed), per packed block 65 u32 (part k from [k] to [k+1]: same = erased,
 * 1024 bytes = stored, else LZ4), then the data. */
const bool guestLz = true;
const int _LZ_PART = 0x400;
/* 1.7.4 BIG_LZ: a save that ran for a long time fills more blocks than fit (User: P's and 4U, "firmware too big: 92
 * blocks"). Then the cold blocks are packed, also when "Pack the firmware" is off (packing was only for room before). */
const bool _BIG_LZ = true;
/* 1.7.5 PACK_ASK: a firmware that only fits packed (long save) is no longer packed by itself: the Studio says so and the
 * user switches on "Pack the firmware" (Bernd: packing only by choice) */
const bool packAsk = true;
/* 1.7.6 MENU_ROOM: a TamaEmu in the menu (start device, Clean ROM) is placed anywhere in the flash and the emulator reads
 * every block through the uncached window: the 5 MB of the main program's fixed area (BIG_OFF..BIG_END, beside the
 * Paradise firmware) do not apply there. Up to the whole 8 MB plus spare pages, as long as the flash has room. */
const bool menuRoom = true;
const int menuRoomLen = 0x800000 + _SPARE_MIN + 0x80000;

/// BIG_LZ: does this firmware only fit packed?
bool tamaNeedsLz(Uint8List g, String dev, [int? room]) {
  if (!_BIG_LZ) return false;
  try {
    packGuest(g, dev, sparse: true, room: room);
    return false;
  } catch (_) {
    try {
      packGuest(g, dev, lz: true, room: room);
      return true;
    } catch (_) {
      return false;
    }
  }
}

const bool _MAIN_LZ = true; // 1.7.2 test13: also for the main TamaEmu (emuPatch)
const Map<String, List<int>> _LZ_WARM = {
  // read in the device simulation (besides HOT): stay whole
  'idl': [0x00, 0x08, 0x09, 0x0b, 0x0c, 0x0d, 0x0e, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x25, 0x40, 0x41, 0x44, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x5b],
  'ps': [0x00, 0x0b, 0x14, 0x15, 0x16, 0x1a, 0x1b, 0x1d, 0x1e, 0x20, 0x21, 0x26, 0x2a, 0x40, 0x41, 0x43, 0x4f, 0x50, 0x51, 0x52, 0x53, 0x54, 0x55],
  '4u': [0x00, 0x08, 0x0d, 0x0e, 0x0f, 0x10, 0x12, 0x13, 0x14, 0x19, 0x23, 0x26, 0x35, 0x37, 0x38, 0x39, 0x40, 0x41, 0x4d, 0x4f, 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x6e],
  '4u-plain': [0x00, 0x08, 0x0d, 0x0f, 0x10, 0x12, 0x13, 0x18, 0x39, 0x3b, 0x3c, 0x40, 0x41, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51, 0x52],
  'pc': [0x00, 0x02, 0x03, 0x04, 0x21, 0x25, 0x3f], // 1.7.3: 123 s simulation
};
bool _lzOk(String dev, int b) {
  final D = devices[dev], warm = _LZ_WARM[dev];
  if (D == null || warm == null || b == D.par || (_HOT[dev] ?? const []).contains(b) || warm.contains(b)) return false;
  return !(_DLC_DEV[dev] ?? const <DlcStore>[]).any((k) => b >= k.base >> 16 && b <= (k.base + k.n * k.size - 1) >> 16);
}

/* LZ4 block (sequences: token, literals, offset, match; the last one only literals), hash chains */
Uint8List lzEnc(Uint8List src) {
  final n = src.length, out = BytesBuilder(copy: false);
  final head = Int32List(4096)..fillRange(0, 4096, -1), prev = Int32List(n)..fillRange(0, n, -1);
  // JS: (int32 * 2654435761 >>> 20) & 4095, the product as a double (rounded above 2^53)
  int h4(int i) {
    final v = (src[i] | (src[i + 1] << 8) | (src[i + 2] << 16) | (src[i + 3] << 24)).toSigned(32);
    return (((v.toDouble() * 2654435761.0).toInt() & 0xFFFFFFFF) >> 20) & 4095;
  }

  void put(int v) {
    while (v >= 255) {
      out.addByte(255);
      v -= 255;
    }
    out.addByte(v);
  }

  var i = 0, lit = 0;
  void emit(int ml, int off) {
    final ll = i - lit;
    out.addByte(((ll >= 15 ? 15 : ll) << 4) | (ml != 0 ? (ml - 4 >= 15 ? 15 : ml - 4) : 0));
    if (ll >= 15) put(ll - 15);
    out.add(Uint8List.sublistView(src, lit, i));
    if (ml != 0) {
      out..addByte(off & 255)..addByte((off >> 8) & 255);
      if (ml - 4 >= 15) put(ml - 19);
    }
  }

  void ins(int p) {
    if (p + 4 <= n) {
      final h = h4(p);
      prev[p] = head[h];
      head[h] = p;
    }
  }

  while (i + 4 <= n) {
    var best = 0, bo = 0;
    for (var c = head[h4(i)], d = 0; c >= 0 && d < 256; c = prev[c], d++) {
      var l = 0;
      while (i + l < n && src[c + l] == src[i + l]) {
        l++;
      }
      if (l > best) {
        best = l;
        bo = i - c;
        if (i + l == n) break;
      }
    }
    if (best >= 4) {
      emit(best, bo);
      for (var k = 0; k < best; k++) {
        ins(i + k);
      }
      i += best;
      lit = i;
    } else {
      ins(i);
      i++;
    }
  }
  i = n;
  emit(0, 0);
  return out.toBytes();
}

Uint8List lzDec(Uint8List s, int n) {
  final d = Uint8List(n);
  var ip = 0, op = 0;
  int rd() {
    final v = ip < s.length ? s[ip] : 0;
    ip++;
    return v;
  }

  for (;;) {
    final t = rd();
    var l = t >> 4;
    if (l == 15) {
      int x;
      do {
        x = rd();
        l += x;
      } while (x == 255);
    }
    while (l-- > 0 && op < n) {
      d[op++] = rd();
    }
    if (op >= n || ip >= s.length) return d;
    final o = rd() | (rd() << 8);
    var m = (t & 15) + 4;
    if ((t & 15) == 15) {
      int x;
      do {
        x = rd();
        m += x;
      } while (x == 255);
    }
    while (m-- > 0 && op < n) {
      d[op] = op - o >= 0 && op - o < n ? d[op - o] : 0;
      op++;
    }
  }
}

/* the packed blocks as stored behind the firmware blocks (blocks: list of block numbers) */
Uint8List lzPack(Uint8List g, List<int> blocks) {
  final tab = Uint8List(512), parts = <Uint8List>[], lists = <int, List<int>>{};
  var pos = 512 + blocks.length * 65 * 4;
  for (final b in blocks) {
    final l = <int>[];
    for (var k = 0; k < 64; k++) {
      l.add(pos);
      final p = _sub(g, (b << 16) + k * _LZ_PART, (b << 16) + (k + 1) * _LZ_PART);
      if (_isFF(p, 0, p.length)) continue;
      var c = lzEnc(p);
      if (c.length >= _LZ_PART) c = p;
      parts.add(c);
      pos += c.length;
    }
    l.add(pos);
    lists[b] = l;
  }
  final out = Uint8List(pos);
  var lp = 512;
  for (final b in blocks) {
    w32(tab, 4 * b, lp);
    final l = lists[b]!;
    for (var k = 0; k < l.length; k++) {
      w32(out, lp + 4 * k, l[k]);
    }
    lp += 65 * 4;
  }
  _set(out, tab, 0);
  var dp = 512 + blocks.length * 65 * 4;
  for (final c in parts) {
    _set(out, c, dp);
    dp += c.length;
  }
  return out;
}

/* 1.7.5 PACK_WARN: how many 64 KB blocks a TamaEmu keeps packed (table of 128 u32 at lzOff, absolute in the ROM). The
 * main TamaEmu always packs 2 or 3 cold blocks for its spare pages (MAIN_FEW): that does not count as packed. */
const int packFew = 8;
int lzCount(Uint8List rom, int lzOff) {
  if (lzOff == 0 || lzOff + 512 > rom.length) return 0;
  var n = 0;
  for (var b = 0; b < 128; b++) {
    if (u32(rom, lzOff + 4 * b) != 0) n++;
  }
  return n;
}

/// An entry of the menu's program list: src (XIP address of the image), name; off from appsPlace.
class AppEntry {
  AppEntry(this.src, this.name, [this.off = 0]);
  int src;
  String? name;
  int off;
}

/// PACK_WARN: names of the TamaEmus in the menu that are packed
List<String> appsPacked(Uint8List rom, List<AppEntry>? apps) {
  final out = <String>[];
  for (final e in apps ?? const <AppEntry>[]) {
    final off = e.src - 0x10000000 + _XIP_DEC;
    if (off < 0 || off + 0x10000 > rom.length) continue;
    final c = extraCfg(rom, off);
    if (c != null && c.kind == 'tama' && lzCount(rom, c.lzOff) > packFew) out.add((e.name != null && e.name!.isNotEmpty ? e.name : null) ?? _TX_NAMES[c.dev] ?? 'TAMAEMU');
  }
  return out;
}

/* back into the guest image g (rd(off, len) reads the flash at the table) */
void lzUnpack(Uint8List Function(int off, int len) rd, Uint8List g) {
  final t = rd(0, 512);
  for (var b = 0; b < 128 && (b << 16) < g.length; b++) {
    final lp = _u32s(t, 4 * b);
    if (lp == 0) continue;
    final l = rd(lp, 65 * 4);
    for (var k = 0; k < 64; k++) {
      final a = _u32s(l, 4 * k), z = _u32s(l, 4 * k + 4), at = (b << 16) + k * _LZ_PART;
      if (z == a) {
        _fill(g, 0xFF, at, at + _LZ_PART);
      } else if (z - a >= _LZ_PART) {
        _set(g, rd(a, _LZ_PART), at);
      } else {
        _set(g, lzDec(rd(a, z - a), _LZ_PART), at);
      }
    }
  }
}

/* GUEST_LZ: the TamaEmu program knows packed blocks (its settings block says version 5 in the template) */
bool tamaLzCan(Uint8List? app) {
  if (app == null) return false;
  for (var i = 0; i + 8 <= math.min(app.length, 0x400); i += 4) {
    if (u32(app, i) == _PMXC) return u32(app, i + 4) >= 5;
  }
  return false;
}

/// A spare page of the packed guest: v = guest page number (8 KB), data = its 8 KB.
class GuestPage {
  GuestPage(this.v, this.data);
  final int v;
  final Uint8List data;
}

/// Result of packGuest.
class PackedGuest {
  PackedGuest({required this.map, required this.blob, this.lzOff, this.lzBlocks, required this.blocks, required this.big, required this.pages});
  Uint8List map; // guest block -> index in blob, 0xFF none
  Uint8List blob;
  int? lzOff, lzBlocks;
  int blocks;
  bool big;
  List<GuestPage> pages;
  bool raw = false; // mainPick: went in unpacked
  int? few; // mainPick MAIN_FEW: only this many cold blocks packed
}

PackedGuest packGuest(Uint8List fw, String dev, {bool sparse = false, bool lz = false, bool lzAll = false, List<int>? lzOnly, List<int>? lzExtra, int? room}) {
  final D = devices[dev]!;
  final g = _ff(D.size);
  _set(g, _sub(fw, 0, math.min(fw.length, D.size)), 0);
  final n = D.size >> 16;
  var used = <int>[];
  for (var i = 0; i < n; i++) {
    if (i == D.par || !_isFF(g, i << 16, 0x10000)) used.add(i);
  }
  // 1.6.6: a save of another emulator (P's with download content) can hold more blocks than fit. The sparsest
  // blocks then go into spare pages (8 KB parts behind the packed firmware, as the device keeps written empty
  // blocks); the device reads them from there.
  List<int> parts(int b) {
    final r = <int>[];
    for (var k = 0; k < 8; k++) {
      if (!_isFF(g, (b << 16) + (k << 13), 0x2000)) r.add((b << 3) + k);
    }
    return r;
  }

  final roomLen = (menuRoom && room != null && room != 0) ? room : _BIG_END - _BIG_OFF;
  const PG_RES = 4;
  int need(int nb, int np) => np != 0 ? ((((nb << 16) + 0x1FFF) & ~0x1FFF) + 0x2000 + ((np + PG_RES) << 13)) : (nb << 16) + _SPARE_MIN;
  var paged = <(int, List<int>)>[];
  var lzb = <int>[];
  final lzBig = _BIG_LZ && guestLz && lz && lzOnly == null && _LZ_WARM[dev] != null && need(used.length, 0) > roomLen;
  if (need(used.length, 0) > roomLen && !lzBig) {
    final cand = used.where((b) => b != D.par).map((b) => (b, parts(b))).toList();
    _sort(cand, (x, y) => x.$2.length - y.$2.length);
    var nb = used.length, np = 0;
    for (final c in cand) {
      if (need(nb, np) <= roomLen) break;
      if (c.$2.length >= 8 || np + c.$2.length + PG_RES > 64) break;
      paged.add(c);
      nb--;
      np += c.$2.length;
    }
    if (need(nb, np) > roomLen) throw EmuError('firmware too big: ${used.length} blocks');
    used = used.where((b) => !paged.any((c) => c.$1 == b)).toList();
  } else if (guestLz && lz && (_LZ_WARM[dev] != null || lzAll)) {
    lzb = lzOnly != null
        ? used.where((b) => lzOnly.contains(b)).toList() // MAIN_FEW: only these
        : used.where((b) => lzAll ? b != D.par : _lzOk(dev, b) || (lzExtra ?? const []).contains(b)).toList(); // lzAll, lzExtra: tests only
    used = used.where((b) => !lzb.contains(b)).toList();
  } else if (_GUEST_SPARSE && sparse) {
    var np = 0;
    for (final b in used) {
      if (!_sparseOk(dev, b)) continue;
      final p = parts(b);
      if (p.length > _SPARSE_MAX || np + p.length > _SPARSE_PG) continue;
      paged.add((b, p));
      np += p.length;
    }
    used = used.where((b) => !paged.any((c) => c.$1 == b)).toList();
  }
  final hot = _HOT[dev]!;
  final order = hot.where((b) => used.contains(b)).followedBy(used.where((b) => !hot.contains(b))).toList();
  final map = Uint8List(128)..fillRange(0, 128, 0xFF);
  final blob = Uint8List(order.length << 16);
  for (var idx = 0; idx < order.length; idx++) {
    final b = order[idx];
    map[b] = idx;
    blob.setRange(idx << 16, (idx + 1) << 16, g, b << 16);
  }
  final pages = <GuestPage>[
    for (final c in paged)
      for (final v in c.$2) GuestPage(v, _sub(g, v << 13, (v + 1) << 13)),
  ];
  if (blob.length + _SPARE_MIN > roomLen) throw EmuError('firmware too big: ${order.length} blocks');
  if (lzb.isNotEmpty) {
    // GUEST_LZ: the packed cold blocks behind the others
    final z = lzPack(g, lzb), all = Uint8List(blob.length + z.length);
    _set(all, blob, 0);
    _set(all, z, blob.length);
    if (all.length + _SPARE_MIN > roomLen) throw EmuError('firmware too big: ${order.length + lzb.length} blocks');
    return PackedGuest(map: map, blob: all, lzOff: blob.length, lzBlocks: lzb.length, blocks: order.length, big: lzOnly != null && _GUEST_OFF + all.length + _SPARE_MIN > _GUEST_END, pages: pages);
  }
  return PackedGuest(map: map, blob: blob, blocks: order.length, big: pages.isNotEmpty || _GUEST_OFF + blob.length + _SPARE_MIN > _GUEST_END, pages: pages);
}

/// Spare pages of the guest behind the packed firmware: table (as state.c of the device) and 8 KB parts.
void _putPages(Uint8List out, int gOff, int gEnd, int blobLen, List<GuestPage> pages) {
  final lo = (gOff + blobLen + 0x1FFF) & ~0x1FFF, hi = gEnd & ~0x1FFF, data = lo + 0x2000;
  final n = math.min(64, (hi - data) >> 13);
  if (pages.length > n) throw EmuError('no room for the spare pages');
  final vp = List<int>.filled(64, 0xFFFF);
  for (var i = 0; i < pages.length; i++) {
    vp[i] = pages[i].v;
    _set(out, pages[i].data, data + (i << 13));
  }
  var x = (0x50584D50 ^ ((n * 0x9E3779B1) & 0xFFFFFFFF)) & 0xFFFFFFFF;
  for (var i = 0; i < 64; i++) {
    x = ((((x << 5) | (x >> 27)) & 0xFFFFFFFF) ^ vp[i]) & 0xFFFFFFFF;
  }
  _fill(out, 0xFF, lo, lo + 0x1000);
  w32(out, lo, 0x50584D50);
  w32(out, lo + 4, n);
  w32(out, lo + 8, x);
  w32(out, lo + 12, 0);
  for (var i = 0; i < 64; i++) {
    out[lo + 16 + 2 * i] = vp[i] & 255;
    out[lo + 17 + 2 * i] = vp[i] >> 8;
  }
}

/// Is an emulator already installed? Returns the original handlers or null.
List<int>? installedOrigs(Uint8List rom, Map<String, int> tab) {
  final o = tab['PSID_HOME']!;
  final cur = [for (var k = 0; k < 4; k++) u32(rom, o + 12 + 4 * k)];
  final lo = _xip(_STUB_OFF), hi = lo + 0x1000;
  if (!cur.any((v) => v >= lo && v < hi)) return null;
  return [for (var k = 0; k < 4; k++) u32(rom, _STUB_OFF + 0x94 + 4 * k)];
}

/// Install the stub with its home screen hook (shared by the emulator and DOOM).
void _installStub(Uint8List out, Map<String, int> tab, List<int>? prev, Uint8List stubTpl) {
  final home = tab['PSID_HOME']!;
  final origs = prev ?? [for (var k = 0; k < 4; k++) u32(out, home + 12 + 4 * k)];
  final st = _copy(stubTpl);
  void put(int ph, int v) {
    var n = 0;
    for (var i = 0; i + 4 <= st.length; i += 2) {
      if (u32(st, i) == ph) {
        w32(st, i, v);
        n++;
      }
    }
    if (n != 1) throw EmuError('launcher template does not fit');
  }

  put(_PH_APP, _xip(_APP_OFF));
  for (var k = 0; k < 4; k++) {
    put(_PH_ORIG[k], origs[k]);
  }
  for (var i = 0; i + 4 <= st.length; i += 2) {
    if (u32(st, i) == _PH_AUTO) w32(st, i, 0); // autostart off, see autoSet
  }
  _fill(out, 0xFF, _STUB_OFF, _STUB_OFF + 0x1000);
  _set(out, st, _STUB_OFF);
  for (var k = 0; k < 4; k++) {
    w32(out, home + 12 + 4 * k, (_xip(_STUB_OFF) + _HOOK_OFF[k]) | 1);
  }
}

/// Install only the program and stub (for DOOM). Returns a new image.
Uint8List installApp(Uint8List rom, Uint8List app, Uint8List stubTpl, {bool keep = false}) {
  if (rom.length != 0x1000000) throw EmuError('the Paradise image must be 16 MB');
  final out = _copy(rom);
  final tab = sceneTable(out);
  if ((tab['PSID_HOME'] ?? 0) == 0) throw EmuError('home screen not found');
  final prev = installedOrigs(out, tab);
  if (prev == null && !_isFF(out, _APP_OFF, 0x11000)) throw EmuError('area 0x0A0000 is in use');
  if (app.length > _APP_MAX) throw EmuError('program too big');
  if (!keep) _freeT18(out); // keep (1.6.8): the same program again (stub swap), T18Emu keeps its blocks
  _fill(out, 0x00, _APP_OFF, _APP_OFF + _APP_MAX);
  _set(out, app, _APP_OFF);
  _installStub(out, tab, prev, stubTpl);
  return out;
}

/// Result of emuPatch.
class EmuPatchResult {
  EmuPatchResult(this.rom, this.device, this.blocks, this.big);
  final Uint8List rom;
  final String device;
  final int blocks;
  final bool big;
}

/// Install the emulator. rom: 16 MB Paradise image, guest: color Tama
/// firmware, app/stub: embedded binaries. Returns a new image.
EmuPatchResult emuPatch(Uint8List rom, Uint8List guest, Uint8List app, Uint8List stubTpl, {String? device, bool pack = false, bool? clock, String? lang}) {
  if (rom.length != 0x1000000) throw EmuError('the Paradise image must be 16 MB');
  final dev = (device != null && device.isNotEmpty) ? device : emuDetect(guest);
  final out = _copy(rom);
  final tab = sceneTable(out);
  if ((tab['PSID_HOME'] ?? 0) == 0) throw EmuError('home screen not found');
  final prev = installedOrigs(out, tab);
  _freeT18(out);
  // Regions must be free (or already used by us)
  // MAIN_LZ (1.7.2 test13): the main TamaEmu packs its cold blocks as well (as in the menu). Before, a P's with a VDP set
  // kept only 3 spare pages for its own writes; installing the VDP writes about 35, the rest was lost and the game hung.
  final pk = _mainPick(guest, dev, app, pack), lzMain = pk.lzOff != null || (_MAIN_LZ && tamaLzCan(app) && !pk.raw);
  final map = pk.map, blob = pk.blob, blocks = pk.blocks, pages = pk.pages;
  final big = pk.big || _GUEST_OFF + blob.length + _SPARE_MIN > _GUEST_END;
  final gOff = big ? _BIG_OFF : _GUEST_OFF, gEnd = big ? _BIG_END : _GUEST_END;
  if (big && _assetEnd(out) > 0x830000) {
    throw EmuError('the character data reaches 0x${_assetEnd(out).toRadixString(16)}, the emulator needs 0x830000 onwards', needPack: pk.raw && _MAIN_LZ && tamaLzCan(app));
  }
  if (prev == null) {
    if (!_isFF(out, _APP_OFF, 0x11000)) throw EmuError('area 0x0A0000 is in use');
    if (!_isFF(out, gOff, gEnd - gOff)) throw EmuError('area 0x${gOff.toRadixString(16)} is in use');
  }
  if (!_isFF(out, _SAVE_OFF, _SAVE_END - _SAVE_OFF) && prev == null) throw EmuError('area 0x0C0000 is in use');
  // Store the packed guest (an earlier one may sit in the other layout)
  if (prev != null && u32(out, _APP_OFF + 0x140) == _PMXC) {
    final o = u32(out, _APP_OFF + 0x148);
    if (o == _BIG_OFF) {
      _fill(out, 0xFF, _BIG_OFF, _BIG_END);
    } else if (o == _GUEST_OFF) {
      _fill(out, 0xFF, _GUEST_OFF, _GUEST_END);
    }
  }
  _fill(out, 0xFF, gOff, gEnd);
  _set(out, blob, gOff);
  if (pages.isNotEmpty) _putPages(out, gOff, gEnd, blob.length, pages);
  // Program with settings
  if (app.length > _APP_MAX) throw EmuError('emulator program too big');
  final a = _copy(app);
  var ci = -1;
  for (var i = 0; i + 4 <= a.length; i += 4) {
    if (u32(a, i) == _PMXC) {
      ci = i;
      break;
    }
  }
  if (ci < 0) throw EmuError('settings block missing in the program');
  // version 3: the room behind the packed firmware up to GUEST_END holds the guest's spare pages
  // version 4 (1.5.1): flags at +156, bit 1 = clock from the Paradise at every start (on unless clock == false)
  final v4 = a.length >= ci + 160 && u32(a, ci + 156) == 0;
  w32(a, ci + 4, v4 ? 4 : 3);
  w32(a, ci + 8, gOff);
  w32(a, ci + 12, blob.length);
  w32(a, ci + 16, _SAVE_OFF);
  w32(a, ci + 20, devices[dev]!.kind);
  _set(a, map, ci + 24);
  w32(a, ci + 152, gEnd);
  if (v4) w32(a, ci + 156, (clock == false ? 0 : 2) | (lang == 'en' ? 1 : 0) | (dev == 'pc' && _idFirmware(guest) ? _ID_STRAP : 0)); // bit 0 (1.6.6): English texts
  if (lzMain && v4) {
    // MAIN_LZ: version 5, table of the packed blocks
    w32(a, ci + 4, 5);
    w32(a, ci + 160, pk.lzOff != null ? gOff + pk.lzOff! : 0);
  }
  _fill(out, 0x00, _APP_OFF, _APP_OFF + _APP_MAX);
  _set(out, a, _APP_OFF);
  _installStub(out, tab, prev, stubTpl);
  // erase the old save (it may belong to a different firmware)
  _fill(out, 0xFF, _SAVE_OFF, _SAVE_END);
  return EmuPatchResult(out, dev, blocks, big);
}

/// Newer emulator program into a ROM that already has the emulator (v1.2.6).
/// Only the program at 0x0A0000 changes: settings (firmware layout) are taken over,
/// the packed firmware, the spare pages and the saved session stay. Returns null if
/// the program is already the same.
Uint8List? emuUpgrade(Uint8List rom, Uint8List app) {
  const ci0 = 0x140;
  if (u32(rom, _APP_OFF + ci0) != _PMXC) return null;
  final a = _copy(app);
  var ci = -1;
  for (var i = 0; i + 4 <= a.length; i += 4) {
    if (u32(a, i) == _PMXC) {
      ci = i;
      break;
    }
  }
  if (ci != ci0) return null;
  final ver = u32(rom, _APP_OFF + ci + 4);
  if (ver < 2) return null;
  for (var i = 8; i < 152; i++) {
    a[ci + i] = rom[_APP_OFF + ci + i];
  }
  w32(a, ci + 4, 4);
  if (ver >= 5) {
    // MAIN_LZ: the packed layout stays
    if (!tamaLzCan(app)) return null;
    w32(a, ci + 4, 5);
    w32(a, ci + 160, u32(rom, _APP_OFF + ci + 160));
  }
  w32(a, ci + 152, ver >= 3 ? u32(rom, _APP_OFF + ci + 152) : _GUEST_END);
  w32(a, ci + 156, ver >= 4 ? u32(rom, _APP_OFF + ci + 156) : 2); // 1.5.1: the clock switch, on for older ROMs
  final go = u32(a, ci + 8);
  if (!(go == _GUEST_OFF && u32(a, ci + 152) <= _GUEST_END) && !(go == _BIG_OFF && u32(a, ci + 152) <= _BIG_END)) return null;
  if (_sameProgram(rom, a)) return null;
  final out = _copy(rom);
  _fill(out, 0x00, _APP_OFF, _APP_OFF + _APP_MAX);
  _set(out, a, _APP_OFF);
  return out;
}

/// The program at 0x0A0000 is a (padded with zeros); test24: 0x13C the way back (Studio) does not count.
bool _sameProgram(Uint8List rom, Uint8List a) {
  for (var i = 0; i < _APP_MAX; i++) {
    if ((i < 0x13C || i > 0x13F) && rom[_APP_OFF + i] != (i < a.length ? a[i] : 0)) return false;
  }
  return true;
}

/*
 * Autostart (v1.2.7): the stub holds a word (0/1, placeholder PH_AUTO in the template).
 * stubs = [(offset in the ROM, template), ...]. The ROM's stub must match the template
 * everywhere except the placeholder words.
 */
const List<int> _PH_ALL = [_PH_APP, 0x6789EF01, _PH_AUTO, ..._PH_ORIG];
int _autoAt(Uint8List rom, List<(int, Uint8List)> stubs) {
  for (final (off, tpl) in stubs) {
    if (off < 0 || off + tpl.length > rom.length) continue;
    var at = -1, ok = true;
    final skip = <int>{};
    for (var i = 0; i + 4 <= tpl.length; i += 2) {
      final w = u32(tpl, i);
      if (_PH_ALL.contains(w)) {
        for (var k = 0; k < 4; k++) {
          skip.add(i + k);
        }
        if (w == _PH_AUTO) at = i;
      }
    }
    if (at < 0) continue;
    for (var i = 0; i < tpl.length && ok; i++) {
      if (!skip.contains(i) && rom[off + i] != tpl[i]) ok = false;
    }
    if (ok && _u32s(rom, off + at) <= 1) return off + at;
  }
  return -1;
}

List<(int, Uint8List)> _legacyStubs(List<(int, Uint8List)> stubs) {
  final out = <(int, Uint8List)>[];
  for (final (off, _) in stubs) {
    for (final t in [..._STUB_127, _STUB_FELD_167, ..._STUB_172, ..._STUB_173]) {
      out.add((off, base64.decode(t)));
    }
  }
  return out;
}

/// Autostart setting of the ROM: true, false, or null (stub without the switch).
bool? autoGet(Uint8List rom, List<(int, Uint8List)> stubs) {
  final a = _autoAt(rom, stubs);
  return a < 0 ? null : u32(rom, a) == 1;
}

/// Was the autostart on in a stub of 1.2.7?
bool autoGetOld(Uint8List rom, List<(int, Uint8List)> stubs) {
  final a = _autoAt(rom, _legacyStubs(stubs));
  return a >= 0 && u32(rom, a) == 1;
}

/// Set the autostart word. Returns a new image, or null if the stub has no such word.
Uint8List? autoSet(Uint8List rom, List<(int, Uint8List)> stubs, bool on) {
  final a = _autoAt(rom, stubs);
  if (a < 0) return null;
  final out = _copy(rom);
  w32(out, a, on ? 1 : 0);
  return out;
}

/// Remove the emulator again (home screen back to the original handlers).
Uint8List emuRemove(Uint8List rom) {
  final out = _copy(rom);
  final tab = sceneTable(out);
  final prev = installedOrigs(out, tab);
  if (prev == null) throw EmuError('no emulator built in');
  final c18 = t18Cfg(rom);
  if (c18 != null) {
    for (final b in [...c18.map, ...c18.spare]) {
      if (b != 0xFFFF) _fill(out, 0xFF, b << 16, (b + 1) << 16);
    }
  }
  for (var k = 0; k < prev.length; k++) {
    w32(out, tab['PSID_HOME']! + 12 + 4 * k, prev[k]);
  }
  _fill(out, 0xFF, _APP_OFF, _APP_OFF + 0x11000);
  _fill(out, 0xFF, _SAVE_OFF, _SAVE_END);
  _fill(out, 0xFF, _GUEST_OFF, _GUEST_END);
  if (u32(rom, _APP_OFF + 0x140) == _PMXC && u32(rom, _APP_OFF + 0x148) == _BIG_OFF) _fill(out, 0xFF, _BIG_OFF, _BIG_END);
  // DOOM: program part in the flash window and WAD (only behind the character data)
  _fill(out, 0xFF, _STUB_OFF + 0x1000, _SAVE_OFF);
  final assetEnd = _and32(0x111000 + 16 + u32(out, 0x111000 + 8) + 0xFFF, ~0xFFF);
  _fill(out, 0xFF, math.max(0x830000, assetEnd), 0xD48000);
  return out;
}

// ------------------------------------------------------------ download content
/*
 * Download content (DLC) for the 8 MB firmware (iD L). Store geometry and routing
 * come from tamaemu (tools/dlc.c, GPL-3.0, maragotchi): a record is a TAMAGO
 * block, routed by (type [0x4E], category [0x50], flag [0x51]) into a store;
 * it goes into the first fully erased slot, existing slots are never overwritten.
 */
/* 1.7.6 PS_DL2: all P's downloads of tamaplanet (letters, stamp cards, recipes, iD L and 4U items for the P's).
 * The P's firmware takes only records made for it: byte 0xFF = 2 (P's) or 3 (iD L for P's); iD L files (1) it refuses. */
const bool _PS_DL2 = true;
const List<int> psStampAt = [0xE000, 0xE4E4]; // PS_STAMP: the two copies of the P's save in its flash
const int _PS_STAMP_AT = 0x4B, _PS_STAMP_ON = 0x0C;

/// A one-record store whose save byte the firmware sets when it receives one.
class SaveFlag {
  const SaveFlag(this.kind, this.at, this.off, this.on, this.len);
  final int kind, off, on, len;
  final List<int> at;
}

/* The one-record stores whose save byte the firmware sets when it receives one (measured the same way): P's stamp card,
 * iD L happy mail (one save copy at 0xE000, byte +0x4A = 3). */
const Map<String, SaveFlag> saveFlags = {
  'ps': SaveFlag(11, psStampAt, _PS_STAMP_AT, _PS_STAMP_ON, 0x4E4),
  'idl': SaveFlag(12, [0xE000], 0x4A, 0x03, 0x400),
};

/// An item store of an 8 MB firmware.
class DlcStore {
  const DlcStore(this.kind, this.base, this.size, this.n, this.label, {this.one = false});
  final int kind, base, size, n;
  final String label;
  final bool one;
}

const List<DlcStore> _IDL_STORES = [
  DlcStore(0, 0x590000, 0x0800, 20, 'Meals'),
  DlcStore(1, 0x5A0000, 0x0800, 20, 'Snacks'),
  DlcStore(2, 0x600000, 0x4000, 5, 'Clothing'),
  DlcStore(3, 0x650000, 0x2000, 10, 'Accessories'),
  DlcStore(4, 0x6A0000, 0x2000, 10, 'Items'),
  DlcStore(5, 0x740000, 0x8000, 5, 'Daily items'),
  DlcStore(6, 0x780000, 0x2000, 10, 'Wallpapers'),
  DlcStore(7, 0x7A0000, 0x8000, 2, 'Games'),
  DlcStore(8, 0x7B0000, 0x8000, 2, 'Destinations'),
  // 1.7.6 PS_DL2: measured on the iD L firmware like on the P's: letters 20 slots of 0x800, happy mail one record
  DlcStore(9, 0x7C0000, 0x0800, 20, 'Letters'),
  DlcStore(12, 0x7D0000, 0x10000, 1, 'Happy mail', one: true),
];
const List<List<int>> _IDL_ROUTE = [
  [0x81, 0x02, 0x01, 0], [0x81, 0x0C, 0x02, 1], [0x81, 0x0D, 0x02, 1], [0x81, 0x1F, 0x00, 6], //
  [0x81, 0x29, 0x00, 5], [0x81, 0x29, 0x02, 5], [0x81, 0x2A, 0x01, 4], [0x81, 0x33, 0x00, 2], //
  [0x81, 0x34, 0x00, 3], [0x81, 0x35, 0x00, 3], [0x94, 0x47, 0x02, 8], [0x94, 0x5B, 0x01, 7],
];
// 1.6.6: P's, 4U+ and 4U, stores and routing likewise from tamaemu's tools/dlc.c
const List<DlcStore> _PS_STORES = [
  DlcStore(0, 0x5A0000, 0x0800, 20, 'Meals'),
  DlcStore(1, 0x5B0000, 0x0800, 15, 'Snacks'),
  DlcStore(2, 0x610000, 0x4000, 5, 'Clothing'),
  DlcStore(3, 0x660000, 0x2000, 10, 'Accessories'),
  DlcStore(4, 0x6B0000, 0x2000, 10, 'Items'),
  DlcStore(6, 0x6F0000, 0x2000, 10, 'Wallpapers'),
  DlcStore(7, 0x710000, 0x8000, 2, 'Games'),
  DlcStore(8, 0x720000, 0x8000, 2, 'Destinations'),
  DlcStore(10, 0x750000, 0x8000, 4, 'VDP recipes'),
  // 1.7.6 PS_DL2: measured by sending the tamaplanet files to the P's firmware over emulated IR (DOWNLOAD):
  // letters 20 slots of 0x800, the stamp card one record (a new one replaces it, the save then gets +0x4B = 0x0C)
  DlcStore(9, 0x730000, 0x0800, 20, 'Letters'),
  DlcStore(11, 0x740000, 0x10000, 1, 'Stamp card', one: true),
];
const List<List<int>> _PS_ROUTE = [
  [0x81, 0x02, 0], [0x81, 0x0D, 1], [0x81, 0x33, 2], [0x81, 0x34, 3], [0x81, 0x35, 3], [0x81, 0x2A, 4], [0x81, 0x1F, 6], [0x81, 0x29, 10], [0x94, 0x47, 8], //
];
const List<DlcStore> _FOURU_STORES = [
  DlcStore(15, 0x5A0000, 0x2000, 4, 'Decorations'),
  DlcStore(0, 0x5B0000, 0x0800, 20, 'Meals'),
  DlcStore(1, 0x5C0000, 0x0800, 20, 'Snacks'),
  DlcStore(2, 0x610000, 0x4000, 5, 'Clothing'),
  DlcStore(3, 0x660000, 0x2000, 10, 'Accessories'),
  DlcStore(4, 0x6C0000, 0x2000, 15, 'Items'),
  DlcStore(6, 0x6F0000, 0x2000, 10, 'Wallpapers'),
  DlcStore(7, 0x710000, 0x8000, 2, 'Games'),
  DlcStore(8, 0x720000, 0x8000, 4, 'Destinations'),
  DlcStore(16, 0x740000, 0x2000, 1, 'Coupon'),
  DlcStore(17, 0x750000, 0x8000, 1, 'Bingo'),
  DlcStore(18, 0x760000, 0x8000, 1, 'Gashapon'),
  DlcStore(19, 0x780000, 0x8000, 8, 'Characters'),
];
const List<List<int>> _FOURU_ROUTE = [
  [0x81, 0x01, 0x01, 0], [0x81, 0x02, 0x01, 0], [0x81, 0x01, 0x02, 1], [0x81, 0x0D, 0x02, 1], [0x81, 0x1F, 0x00, 6], //
  [0x81, 0x33, 0x00, 2], [0x81, 0x34, 0x00, 3], [0x81, 0x35, 0x00, 3], [0x94, 0x5B, 0x01, 7], [0x94, 0x5B, 0x02, 8], //
  [0x94, 0x48, 0x03, 19], [0x94, 0x47, 0x02, 8],
];
const Map<String, List<DlcStore>> _DLC_DEV = {'idl': _IDL_STORES, 'ps': _PS_STORES, '4u': _FOURU_STORES, '4u-plain': _FOURU_STORES};
String? _dlcDev(Uint8List g) {
  String? d;
  try {
    d = emuDetect(g);
  } catch (_) {
    /* unknown: as before */
  }
  return _DLC_DEV[d] != null
      ? d
      : g.length >= 0x7B0000 && d == null
          ? 'idl'
          : null;
}

String _dlcAscii(Uint8List r) {
  final s = StringBuffer();
  for (var i = 0x34; i < 0x48 && i < r.length && r[i] != 0; i++) {
    s.writeCharCode(r[i]);
  }
  return s.toString();
}

double _fouruId(String s) {
  final m = RegExp(r'[0-9]{2,}').firstMatch(s);
  return m != null ? double.parse(m[0]!) : -1;
}

// kept for older callers: the game store
const int _GAME_BASE = 0x7A0000, _GAME_SIZE = 0x8000;
bool _isTamago(Uint8List g, int o) => o + 6 <= g.length && g[o] == 0x54 && g[o + 1] == 0x41 && g[o + 2] == 0x4D && g[o + 3] == 0x41 && g[o + 4] == 0x47 && g[o + 5] == 0x4F;
String dlcName(Uint8List r) {
  final s = StringBuffer();
  for (var i = 6; i + 1 < 0x34; i += 2) {
    final c = ((i < r.length ? r[i] : 0) << 8) | (i + 1 < r.length ? r[i + 1] : 0);
    if (c == 0) break;
    s.writeCharCode(c);
  }
  return s.toString().replaceFirst(RegExp(r'^DL_[A-Za-z]+_'), '').replaceFirst(RegExp(r'\.(jpg|JPG)$'), '').trim();
}

/// A slot of a store: its number and the name of its record (null: empty).
class DlcSlot {
  DlcSlot(this.slot, this.name);
  final int slot;
  final String? name;
}

/// A store with its slots.
class DlcStoreSlots {
  DlcStoreSlots(this.kind, this.label, this.slots);
  final int kind;
  final String label;
  final List<DlcSlot> slots;
}

/// All stores with their slots (8 MB firmware: iD L, P's, 4U+, 4U).
List<DlcStoreSlots> dlcStores(Uint8List g) {
  final dev = _dlcDev(g);
  if (dev == null) return [];
  return [
    for (final k in _DLC_DEV[dev]!)
      DlcStoreSlots(k.kind, k.label, [
        for (var i = 0; i < k.n; i++) DlcSlot(i, _isTamago(g, k.base + i * k.size) ? dlcName(_sub(g, k.base + i * k.size, k.base + i * k.size + 0x34)) : null),
      ]),
  ];
}

/// Game slots (compatibility with the old single-store view).
List<DlcSlot> dlcSlots(Uint8List g) {
  for (final k in dlcStores(g)) {
    if (k.kind == 7) return k.slots;
  }
  return [];
}

DlcStore? _storeOf(List<DlcStore> stores, int kind) {
  for (final k in stores) {
    if (k.kind == kind) return k;
  }
  return null;
}

/// Store for a record or null. dev: 'idl' (default), 'ps', '4u', '4u-plain'.
DlcStore? dlcRoute(Uint8List r, [String dev = 'idl']) {
  final t = _at(r, 0x4E), c = _at(r, 0x50), f = _at(r, 0x51), stores = _DLC_DEV[dev] ?? _IDL_STORES;
  var kind = -1;
  if (dev == 'ps' && _PS_DL2) {
    if (r.length > 0x200 && r[0xFF] != 2 && r[0xFF] != 3) {
      kind = -1; // not made for the P's: its firmware refuses it
    } else if (t == 0x94 && c == 0x5B) {
      kind = f == 0x01 ? 7 : 8;
    } else if (t == 0x81 && c == 0x01) {
      kind = f == 0x01 ? 0 : 1; // 4U for P's: meal / snack
    } else if (t == 0x81 && c == 0x0C) {
      kind = 1; // iD L for P's bakery: snack
    } else if (t == 0x81 && c == 0x51) {
      kind = 9; // letter
    } else if (t == 0x81 && c == 0x52) {
      kind = f == 0x03 ? 11 : -1; // stamp card (the happy mail 0x02 is refused)
    } else {
      // recipes share the store of the VDP recipes
      for (final x in _PS_ROUTE) {
        if (x[0] == t && x[1] == c) {
          kind = x[2];
          break;
        }
      }
    }
  } else if (dev == '4u' || dev == '4u-plain') {
    final id = _fouruId(_dlcAscii(r)), m1 = id.remainder(1000);
    if (t == 0x81 && c == 0x2A && f == 0x01) {
      kind = id < 0
          ? -1
          : m1 >= 601 && m1 <= 749
              ? 16
              : m1 >= 801 && m1 <= 949
                  ? 15
                  : 4;
    } else if (t == 0x81 && c == 0x29 && f == 0x00) {
      kind = id >= 0 && m1 >= 301 && m1 <= 449
          ? 17
          : id >= 0 && m1 >= 601 && m1 <= 749
              ? 18
              : -1;
    } else {
      for (final x in _FOURU_ROUTE) {
        if (x[0] == t && x[1] == c && x[2] == f) {
          kind = x[3];
          break;
        }
      }
    }
  } else {
    for (final x in _IDL_ROUTE) {
      if (x[0] == t && x[1] == c && x[2] == f) {
        kind = x[3];
        break;
      }
    }
    if (_PS_DL2 && dev == 'idl') {
      if (t == 0x81 && c == 0x51) {
        kind = 9; // letter
      } else if (t == 0x81 && c == 0x52 && f == 0x02) {
        kind = 12; // happy mail
      }
      if (r.length > 0x200 && r[0xFF] != 1 && r[0xFF] != 3) kind = -1; // the iD L takes its own and the iD L for P's, not the P's
    }
  }
  return kind < 0 ? null : _storeOf(stores, kind);
}

/// Extract and check the TAMAGO record of a download file (.jpg or raw). dev: firmware it goes into.
Uint8List dlcRecord(Uint8List d, [String dev = 'idl']) {
  var m = -1;
  if (_isTamago(d, 0)) {
    m = 0;
  } else {
    var e = -1;
    for (var i = 0; i + 1 < d.length; i++) {
      if (d[i] == 0xFF && d[i + 1] == 0xD9) {
        e = i + 2;
        break;
      }
    }
    for (var i = math.max(0, e); i + 6 <= d.length; i++) {
      if (_isTamago(d, i)) {
        m = i;
        break;
      }
    }
  }
  if (m < 0) throw const FormatException('no download content in the file');
  final b = _sub(d, m);
  bool ok(int n) {
    if (n < 3) return false;
    var s = 0;
    for (var i = 0; i < n - 2; i++) {
      s += b[i];
    }
    return (s & 0xFFFF) == ((b[n - 2] << 8) | b[n - 1]);
  }

  final decl = b.length >= 0x4C ? ((b[0x48] << 24) | (b[0x49] << 16) | (b[0x4A] << 8) | b[0x4B]) & 0xFFFFFFFF : 0;
  var len = 0;
  if (decl >= 0x60 && decl <= b.length && ok(decl)) {
    len = decl;
  } else {
    for (var s = 0; s <= 16; s++) {
      final n = b.length - s;
      if (n >= math.max(0x60, decl) && ok(n)) {
        len = n;
        break;
      }
    }
  }
  if (len == 0) throw const FormatException('content checksum does not match');
  var r = _slice(b, 0, len);
  // 1.7.6 PS_DL2: the P's stores everything it received from TAMAGO on (some files have 1 or 2 bytes behind the record),
  // written in halfwords: an odd end gets a 0 byte. The same here, so the store holds what the device itself would hold.
  if (_PS_DL2 && dev == 'ps' && b.length > len && b.length - len <= 16) {
    r = Uint8List(b.length + (b.length & 1));
    _set(r, b, 0);
  }
  final st = dlcRoute(r, dev);
  if (st == null && _PS_DL2 && dev == 'ps' && r.length > 0x200 && r[0xFF] == 1) throw const FormatException("made for the iD L, the P's does not take it");
  if (st == null && _PS_DL2 && dev == 'ps' && r[0x4E] == 0x81 && r[0x50] == 0x52) throw const FormatException("the P's does not take this letter");
  if (st == null && _PS_DL2 && dev == 'idl' && r.length > 0x200 && r[0xFF] == 2) throw const FormatException("made for the P's, the iD L does not take it");
  if (st == null) throw const FormatException('this content fits no store of this firmware');
  if (r.length > st.size) throw const FormatException('content too big for its store');
  return r;
}

Uint8List _grow(Uint8List g) {
  final out = _ff(math.max(g.length, 0x800000));
  _set(out, g, 0);
  return out;
}

/// Result of dlcAdd.
class DlcAdded {
  DlcAdded(this.guest, this.store, this.slot, {this.stamp = false});
  final Uint8List guest;
  final DlcStore store;
  final int slot;
  final bool stamp;
}

bool _recAt(Uint8List out, int o, Uint8List rec) {
  final s = _sub(out, o, o + rec.length);
  for (var k = 0; k < s.length; k++) {
    if (s[k] != rec[k]) return false;
  }
  return true;
}

/// Add a record to the first free slot of its store. Returns { guest, store, slot }.
DlcAdded dlcAdd(Uint8List g, Uint8List rec) {
  final dev = _dlcDev(g);
  if (dev == null) throw EmuError('only for the 8 MB firmware');
  final st = dlcRoute(rec, dev);
  if (st == null) throw EmuError('no matching store');
  final out = _grow(g);
  for (var i = 0; i < st.n; i++) {
    final o = st.base + i * st.size;
    if (_isTamago(out, o) && _recAt(out, o, rec)) throw EmuError('already added');
  }
  if (st.one) {
    // 1.7.6 PS_DL2: the stamp card: a new one replaces the old one, the save marks it
    _fill(out, 0xFF, st.base, st.base + st.size);
    _set(out, rec, st.base);
    final F = saveFlags[dev];
    if (F != null && F.kind == st.kind) saveFlag(out, dev, F.on);
    return DlcAdded(out, st, 0, stamp: true);
  }
  for (var i = 0; i < st.n; i++) {
    final o = st.base + i * st.size;
    if (_isTamago(out, o)) continue;
    if (!_isFF(out, o, st.size)) continue;
    _set(out, rec, o);
    return DlcAdded(out, st, i);
  }
  throw EmuError('${st.label}: all slots used, remove one first');
}

/// 1.7.6 DLC_KEEP: the item stores of a firmware as [start, end) ranges of the guest flash.
List<(int, int)> dlcAreas(String? dev) => [for (final k in _DLC_DEV[dev] ?? const <DlcStore>[]) (k.base, k.base + k.n * k.size)];

/// Empty one slot. Returns the new firmware.
Uint8List dlcFree(Uint8List g, int kind, int slot) {
  final dev = _dlcDev(g) ?? 'idl';
  final st = _storeOf(_DLC_DEV[dev]!, kind);
  if (st == null || slot < 0 || slot >= st.n) throw EmuError('no such slot');
  final out = _grow(g);
  final o = st.base + slot * st.size;
  _fill(out, 0xFF, o, o + st.size);
  if (_PS_DL2 && saveFlags[dev] != null && saveFlags[dev]!.kind == kind) saveFlag(out, dev, 0); // no card (mail) any more
  return out;
}

/// 1.7.6 PS_DL2: the P's save (both copies in its flash) says whether a stamp card is there. Only with a save.
void saveFlag(Uint8List g, String dev, int v) {
  final F = saveFlags[dev];
  if (F == null) return;
  for (final a in F.at) {
    if (g.length > a + 0x60 && !(g[a] == 0xFF && g[a + 1] == 0xFF)) g[a + F.off] = v;
  }
}

int saveFlagGet(Uint8List g, String dev) {
  final F = saveFlags[dev];
  if (F == null) return -1;
  final a = F.at[0];
  return g.length > a + 0x60 && !(g[a] == 0xFF && g[a + 1] == 0xFF) ? g[a + F.off] : -1;
}

void psStamp(Uint8List g, int v) => saveFlag(g, 'ps', v);
int psStampGet(Uint8List g) => saveFlagGet(g, 'ps');

/// 1.7.6 PS_DL2: the TamaEmu run state (emu/src/emu/state.c: header at saveOff, PackBits of Emu and the screen from
/// saveOff + 0x1000) keeps the P's save in its RAM and writes it back over the flash. The stamp byte goes in there too:
/// the RAM copy is found as the place that matches the flash save best. Returns false if there is no run state.
bool psSessStamp(Uint8List img, int saveOff, Uint8List save, int v, [String dev = 'ps']) {
  final FL_ = saveFlags[dev];
  if (FL_ == null) return false;
  int u(int o) => _u32s(img, o);
  if (u(saveOff) != 0x53584D50 || u(saveOff + 4) != 3) return false;
  final bytes = u(saveOff + 16), secs = u(saveOff + 20);
  if (bytes > 0x4F000) return false;
  final src = _sub(img, saveOff + 0x1000, saveOff + 0x1000 + bytes), raw = <int>[];
  for (var i = 0; i < src.length;) {
    final c = src[i++];
    if ((c & 0x80) != 0) {
      final n = c - 0x80 + 3, b = i < src.length ? src[i] : 0;
      i++;
      for (var k = 0; k < n; k++) {
        raw.add(b);
      }
    } else {
      for (var k = 0; k <= c; k++) {
        raw.add(i < src.length ? src[i] : 0);
        i++;
      }
    }
  }
  const GRAM = 128 * 128 * 2;
  final el = raw.length - GRAM;
  if (el < 0x2000) return false;
  final emu = Uint8List.fromList(raw.sublist(0, el)), L = math.min(FL_.len, save.length);
  var best = -1, bs = 0;
  for (var o = 0; o + L <= emu.length; o += 4) {
    if (save.isEmpty || emu[o] != save[0]) continue;
    var n = 0;
    for (var k = 0; k < L; k += 2) {
      if (emu[o + k] == save[k]) n++;
    }
    if (n > bs) {
      bs = n;
      best = o;
    }
  }
  if (best < 0 || bs < (L >> 1) * 0.8) return false;
  if (emu[best + FL_.off] == v) return true;
  emu[best + FL_.off] = v;
  void enc(List<int> p, List<int> out) {
    var i = 0;
    while (i < p.length) {
      var r = 1;
      while (i + r < p.length && r < 130 && p[i + r] == p[i]) {
        r++;
      }
      if (r >= 3) {
        out..add(0x80 + r - 3)..add(p[i]);
        i += r;
        continue;
      }
      final s0 = i;
      var l = 0;
      while (i < p.length && l < 128) {
        var q = 1;
        while (i + q < p.length && q < 3 && p[i + q] == p[i]) {
          q++;
        }
        if (q >= 3) break;
        i++;
        l++;
      }
      out.add(l - 1);
      for (var k = 0; k < l; k++) {
        out.add(p[s0 + k]);
      }
    }
  }

  final out = <int>[];
  enc(emu, out);
  enc(raw.sublist(el), out);
  final ns = (out.length / 0x1000).ceil();
  if (ns > 0x4F) return false;
  _fill(img, 0xFF, saveOff + 0x1000, saveOff + 0x1000 + math.max(secs, ns) * 0x1000);
  _set(img, out, saveOff + 0x1000);
  w32(img, saveOff + 16, out.length);
  w32(img, saveOff + 20, ns);
  w32(img, saveOff + 24, (u(saveOff) ^ u(saveOff + 4) ^ u(saveOff + 8) ^ u(saveOff + 12) ^ out.length ^ ns) & 0xFFFFFFFF);
  return true;
}

/// Put a game into a given slot (replaces what is there). Returns the new firmware.
Uint8List dlcPut(Uint8List g, Uint8List rec, int slot) {
  if (g.length < 0x7B0000) throw EmuError('only for the 8 MB firmware');
  final out = _grow(g);
  final o = _GAME_BASE + slot * _GAME_SIZE;
  _fill(out, 0xFF, o, o + _GAME_SIZE);
  _set(out, rec, o);
  return out;
}

// ------------------------------------------------------------ T7Emu (V7, 6502)
/*
 * T7Emu (1.4.0): the V7 core of the T7Emu app (after asterick/tamago, BSD) as a second
 * emulator. Same launcher and program place as TamaEmu (only one of them), settings block
 * "PMX7" at 0x140 of the program. Layout: the ROM (Tama-Go 640 KB, Friends 768 KB) at 0x940000, the figures right
 * behind it (trailing zero bytes cut off, the core reads them as zero anyway), up to
 * 0xD40000. Save area at 0x0C0000: session (4 KB), the pet's EEPROM in two slots from 0x0C1000, settings at 0x0C5000.
 */
const int t7Magic = 0x37584D50;
const int _T7_ROM_SIZE = 0xA0000, _T7_FIG_MAX = 16, _T7_EE = 0xC1000, _T7_EE_END = 0xC6000; // EEPROM slots, then the settings sector
/* V1Emu (1.6.8): the first Tamagotchis and the Digital Monster (E0C6S46/48, TamaLIB core). Program 64 KB, session 4 KB, ROM. */
const int v1Magic = 0x31584D50; // "PMX1"
V1App? v1Embedded() => emuBinaries?.v1 == null ? null : V1App(emuBinaries!.v1!, emuBinaries!.v3);
/* 1.6.9: V3Emu, the Tamagotchi Connection V3 (Sunplus SPLB32, core from BrickEmuPy by azya52, CC0). It has the settings
 * block of V1Emu (same magic and layout), so the Studio handles it as a V1Emu; the program is picked by the ROM. */
Uint8List? gbEmbedded() => emuBinaries?.gb;
/* 1.6.9 test36: GBEmu (Game Boy, DMG). Settings block "PMXG" at 0x140: magic, version, ROM, its length, save (4 KB settings,
 * then the cartridge RAM up to 32 KB), flags (bit 0 English, bit 1 wheel the other way round), name (16), keys (12 bytes). */
const int gbMagic = 0x47584D50; // "PMXG"
/// keys[i] = Game Boy buttons (1 A, 2 B, 4 SELECT, 8 START, 16 RIGHT, 32 LEFT, 64 UP, 128 DOWN) for the Paradise input i:
/// 0 A, 1 B, 2 C, 3 wheel press, 4 wheel up, 5 wheel down, 6 A+C, 7 B+C, 8 A+B
const List<int> gbKeysDefault = [32, 2, 16, 1, 64, 128, 8, 0, 0]; // test37: A left, C right; B+C free (run to the right), SELECT in the device's settings
/// A Game Boy ROM: 32 KB to 2 MB, size code at 0x148 matching, header checksum at 0x14D right. Colour-only games are refused.
bool gbDetect(Uint8List? r) {
  if (r == null || r.length < 0x8000 || r.length > 0x200000 || (r.length & 0x7FFF) != 0) return false;
  if (r[0x148] > 6 || (0x8000 << r[0x148]) != r.length) return false;
  var x = 0;
  for (var i = 0x134; i <= 0x14C; i++) {
    x = (x - r[i] - 1) & 255;
  }
  return x == r[0x14D];
}

bool gbColorOnly(Uint8List r) => _at(r, 0x143) == 0xC0;
/* 1.7.2 GBCEmu: games with the colour flag (0x80 or 0xC0) get the Game Boy Color program (gbc/gbc.bin, flags bit 3); its
 * save area is 96 KB (the whole Game Boy Color does not fit the 28 KB of a Game Boy state). Over 1 MB (the cached window)
 * the game is stored in pages of 1 MB, each bank 0 and 63 switchable banks (flags bit 2). */
const bool _GBC_ON = true;
Uint8List? gbcEmbedded() => emuBinaries?.gbc;
bool gbIsColor(Uint8List r) => _GBC_ON && r.length > 0x143 && (r[0x143] & 0x80) != 0;
int _gbSaveLen(bool color) => color ? 0x18000 : 0x10000;
const int _GB_PAGE_BANKS = 63;
Uint8List? _gbPage(Uint8List rom) {
  if (rom.length <= 0x100000 || rom.length % _GB_BANK != 0) return null;
  final n = rom.length ~/ _GB_BANK;
  final pages = ((n - 1) / _GB_PAGE_BANKS).ceil(), out = _ff(pages * 0x100000);
  for (var p = 0; p < pages; p++) {
    _set(out, _sub(rom, 0, _GB_BANK), p * 0x100000);
    for (var k = 0; k < _GB_PAGE_BANKS; k++) {
      final b = 1 + p * _GB_PAGE_BANKS + k;
      if (b >= n) break;
      _set(out, _sub(rom, b * _GB_BANK, (b + 1) * _GB_BANK), p * 0x100000 + (k + 1) * _GB_BANK);
    }
  }
  return out;
}

Uint8List _gbUnpage(Uint8List st, int banks) {
  final out = Uint8List(banks * _GB_BANK);
  _set(out, _sub(st, 0, _GB_BANK), 0);
  for (var b = 1; b < banks; b++) {
    final p = (b - 1) ~/ _GB_PAGE_BANKS, k = (b - 1) % _GB_PAGE_BANKS;
    _set(out, _sub(st, p * 0x100000 + (k + 1) * _GB_BANK, p * 0x100000 + (k + 2) * _GB_BANK), b * _GB_BANK);
  }
  return out;
}

/// A Game Boy game as it goes to the flash: rom, banks (flags bits 16..31, 0: whole), paged.
class GbStored {
  GbStored(this.rom, this.banks, [this.paged = false]);
  final Uint8List rom;
  final int banks;
  final bool paged;
}

/* what goes to the flash: { rom, banks (flags bits 16..31), paged } */
GbStored _gbStore(Uint8List rom) {
  if (gbIsColor(rom) && rom.length > 0x100000) return GbStored(_gbPage(rom)!, rom.length ~/ _GB_BANK, true);
  final tr = gbTrim(rom);
  return GbStored(tr.rom, tr.banks, false);
}

String gbTitle(Uint8List r) {
  final s = StringBuffer();
  for (var i = 0x134; i < 0x144; i++) {
    final c = _at(r, i);
    if (c <= 0 || c > 0x7E) break;
    if (c >= 0x20) s.writeCharCode(c);
  }
  final t = s.toString().trim().toUpperCase();
  return t.isEmpty ? 'GAME BOY' : t;
}

/* 1.7.1 GB_TRIM: banks at the end of a game that are all the same (Pokémon Red/Blue: 18 banks of zeros, 288 KB) are
 * stored once; the program reads every bank behind it from that one (flags bits 16..31: the game's bank count). The
 * switchable bank is looked up when the game switches it, not on every read, so the game runs as fast as before. */
const bool _GB_TRIM = true;
const int _GB_BANK = 0x4000;
GbStored gbTrim(Uint8List rom) {
  if (!_GB_TRIM || rom.length % _GB_BANK != 0) return GbStored(rom, 0);
  final n = rom.length ~/ _GB_BANK;
  if (n < 8 || n > 0xFFFF) return GbStored(rom, 0);
  bool same(int i, int j) => _eqAt(rom, i * _GB_BANK, rom, j * _GB_BANK, _GB_BANK);
  var l = n - 1;
  while (l > 1 && same(l - 1, n - 1)) {
    l--;
  }
  if (n - 1 - l < 4) return GbStored(rom, 0); // less than 64 KB: kept whole
  return GbStored(_sub(rom, 0, (l + 1) * _GB_BANK), n);
}

/* the whole game again from a stored one (flags bits 16..31) */
Uint8List gbUntrim(Uint8List rom, int flags) {
  final n = (flags & 0xFFFFFFFF) >> 16;
  if (n == 0 || rom.isEmpty || rom.length % _GB_BANK != 0) return rom;
  final have = rom.length ~/ _GB_BANK;
  if (n <= have) return rom;
  final out = Uint8List(n * _GB_BANK);
  _set(out, rom, 0);
  final last = _sub(rom, rom.length - _GB_BANK);
  for (var i = have; i < n; i++) {
    _set(out, last, i * _GB_BANK);
  }
  return out;
}

void _name15(Uint8List a, int at, String nm, [int max = 15]) {
  _fill(a, 0, at, at + 16);
  for (var i = 0; i < nm.length && i < max; i++) {
    a[at + i] = nm.codeUnitAt(i) & 255;
  }
}

void _gbCfgWrite(Uint8List a, int c, Extra x, int romOff, int saveOff, int flags, GbStored? tr) {
  w32(a, c + 4, 1);
  w32(a, c + 8, romOff);
  w32(a, c + 12, tr != null ? tr.rom.length : x.rom!.length);
  w32(a, c + 16, saveOff);
  w32(a, c + 20, (flags & (1 | _NOSESS)) | (x.inv ? 2 : 0) | (tr != null && tr.paged ? 4 : 0) | (gbIsColor(x.rom!) ? 8 : 0) | (tr != null && tr.banks != 0 ? (tr.banks << 16) & 0xFFFFFFFF : 0));
  _name15(a, c + 24, gbTitle(x.rom!));
  final k = (x.keys != null && x.keys!.length == 9) ? x.keys! : gbKeysDefault;
  _fill(a, 0, c + 40, c + 52);
  for (var i = 0; i < 9; i++) {
    a[c + 40 + i] = k[i] & 255;
  }
}

/* 1.6.10 test2 SMSEmu (Sega Master System). Settings block "PMXS" at 0x140, laid out as GBEmu's: magic, version, ROM, its
 * length, save (4 KB settings, then the cartridge RAM, 32 KB), flags (bit 0 English, bit 1 wheel the other way round),
 * name (16, from the file name), keys (12 bytes). */
Uint8List? smsEmbedded() => emuBinaries?.sms;
const int smsMagic = 0x53584D50; // "PMXS"
/// keys[i] = Master System buttons (1 up, 2 down, 4 left, 8 right, 16 button 1, 32 button 2, 64 pause) for the Paradise
/// input i: 0 A, 1 B, 2 C, 3 wheel press, 4 wheel up, 5 wheel down, 6 A+C, 7 B+C, 8 A+B
const List<int> smsKeysDefault = [4, 16, 8, 32, 1, 2, 64, 0, 0];

/// "TMR SEGA" header at 0x7FF0, 0x3FF0 or 0x1FF0 (a 512 byte copier header in front is allowed): (off, region)
(int, int)? _smsHead(Uint8List r) {
  final o0 = (r.length & 0x3FFF) == 512 ? 512 : 0;
  for (final h in const [0x7FF0, 0x3FF0, 0x1FF0]) {
    final o = o0 + h;
    if (o + 16 > r.length) continue;
    if (_str(Uint8List.sublistView(r, o, o + 8)) == 'TMR SEGA') return (o, r[o + 15] >> 4);
  }
  return null;
}

/// A Master System or Game Gear ROM: 8 KB to 1 MB; by its header, or (some games have none) by the file name ending
/// .sms or .gg
bool smsDetect(Uint8List? r, [String? name]) {
  if (r == null) return false;
  final n = (r.length & 0x3FFF) == 512 ? r.length - 512 : r.length;
  if (n < 0x2000 || n > 0x100000 || (n & 0x1FFF) != 0) return false;
  final h = _smsHead(r);
  if (h != null) return h.$2 >= 3 && h.$2 <= 7; // 3 SMS Japan, 4 SMS export, 5..7 Game Gear
  return RegExp(r'\.(sms|gg)$', caseSensitive: false).hasMatch(name ?? '');
}

/// 1.6.11 test2: Game Gear (header region 5..7, or a file ending .gg)
bool smsGameGear(Uint8List r, [String? name]) {
  final h = _smsHead(r);
  return h != null ? h.$2 >= 5 && h.$2 <= 7 : RegExp(r'\.gg$', caseSensitive: false).hasMatch(name ?? '');
}

String _titleBase(String? fname) => (fname ?? '').replaceFirst(RegExp(r'\.[^.]*$'), '').replaceFirst(RegExp(r'[(\[].*$'), '').replaceAll(RegExp(r"[^A-Za-z0-9 !'&.-]"), ' ');
String _slice15(String s) => s.length > 15 ? s.substring(0, 15) : s;

/// a short name from the file name: without brackets and the ending, upper case, at most 15 letters
String smsTitle(String? fname) {
  var s = _titleBase(fname).toUpperCase();
  s = s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty && !const ['IN', 'OF', 'THE', 'AND', 'STARRING'].contains(w)).join(' ');
  s = _slice15(s).trim();
  return s.isEmpty ? 'MASTER SYSTEM' : s;
}

void _smsCfgWrite(Uint8List a, int c, Extra x, int romOff, int saveOff, int flags) {
  w32(a, c + 4, 1);
  w32(a, c + 8, romOff);
  w32(a, c + 12, x.rom!.length);
  w32(a, c + 16, saveOff);
  w32(a, c + 20, (flags & (1 | _NOSESS)) | (x.inv ? 2 : 0) | (x.gg ? 4 : 0));
  _name15(a, c + 24, _or(x.title, 'MASTER SYSTEM'));
  final k = (x.keys != null && x.keys!.length == 9) ? x.keys! : smsKeysDefault;
  _fill(a, 0, c + 40, c + 52);
  for (var i = 0; i < 9; i++) {
    a[c + 40 + i] = k[i] & 255;
  }
}

String _or(String? s, String d) => s == null || s.isEmpty ? d : s;

/* 1.7.3 PokeMiniEmu (Pokemon mini, core PokeMini by JustBurn, GPL). Settings block "PMXP" at 0x140: magic, version, the
 * game, its length, save (64 KB: 4 KB settings, 8 KB EEPROM, the state up to 36 KB, an own BIOS at +0xC000), flags
 * (bit 0 English, bit 1 wheel the other way round, bit 2 own BIOS), name (16), keys (12 x u16), place of the BIOS.
 * Without an own BIOS the program takes PokeMini's free one. */
Uint8List? pmEmbedded() => emuBinaries?.pm;
const int pmMagic = 0x50584D50; // "PMXP"
/// keys[i] = Pokemon mini buttons (1 A, 2 B, 4 C, 8 up, 16 down, 32 left, 64 right, 128 power, 256 shake) for the
/// Paradise input i: 0 A, 1 B, 2 C, 3 wheel press, 4 wheel up, 5 wheel down, 6 A+C, 7 B+C, 8 A+B
const List<int> pmKeysDefault = [32, 2, 64, 1, 8, 16, 4, 0, 256];

/// a Pokemon mini game (.min): "MN" at 0x2100, up to 1 MB (the cached window of the Paradise)
bool pmDetect(Uint8List? r) => r != null && r.length >= 0x2200 && r.length <= 0x100000 && r[0x2100] == 0x4D && r[0x2101] == 0x4E;
bool pmTooBig(Uint8List? r) => r != null && r.length > 0x100000 && r.length <= 0x200000 && r[0x2100] == 0x4D && r[0x2101] == 0x4E;

/// the Pokemon mini's BIOS (4 KB, starts with its jump table)
bool pmBiosDetect(Uint8List? r) => r != null && r.length == 0x1000 && r[0] == 0x9A && r[1] == 0x00;

/// a short name from the file name: without brackets, "Pokemon" and the ending, upper case, at most 15 letters
String pmTitle(String? fname) {
  var s = _titleBase(fname).toUpperCase();
  s = s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty && !const ['POKEMON', 'THE', 'OF'].contains(w)).join(' ');
  s = _slice15(s).trim();
  return s.isEmpty ? 'POKEMON MINI' : s;
}

const int pmSave = 0x10000, pmBiosAt = 0xC000;
void _pmCfgWrite(Uint8List a, int c, Extra x, int romOff, int saveOff, int flags) {
  final own = x.bios != null && pmBiosDetect(x.bios);
  w32(a, c + 4, 1);
  w32(a, c + 8, romOff);
  w32(a, c + 12, x.rom!.length);
  w32(a, c + 16, saveOff);
  w32(a, c + 20, (flags & (1 | _NOSESS)) | (x.inv ? 2 : 0) | (own ? 4 : 0));
  _name15(a, c + 24, _or(x.title, 'POKEMON MINI'));
  final k = (x.keys != null && x.keys!.length == 9) ? x.keys! : pmKeysDefault;
  _fill(a, 0, c + 40, c + 64);
  for (var i = 0; i < 9; i++) {
    a[c + 40 + 2 * i] = k[i] & 255;
    a[c + 41 + 2 * i] = (k[i] >> 8) & 255;
  }
  w32(a, c + 64, own ? saveOff + pmBiosAt : 0);
}

/* 1.7.3 ArduboyEmu (own ATmega32U4 emulation). Settings block "ABXP" at 0x140: magic, version, the game, its length,
 * save, flags (bit 0 English, bit 1 wheel the other way round), name (16), keys (12 bytes). The game lies at the start
 * of its own 64 KB block (the base of the cached window), the save (16 KB: 4 KB settings, 4 KB EEPROM (1 KB used),
 * 8 KB state) at +0x8000 in the same block; the program has a 64 KB block of its own. */
Uint8List? abEmbedded() => emuBinaries?.ab;
const int abMagic = 0x50584241; // "ABXP"
/// keys[i] = Arduboy buttons (1 up, 2 down, 4 left, 8 right, 16 A, 32 B) for the Paradise input i: 0 A, 1 B, 2 C,
/// 3 wheel press, 4 wheel up, 5 wheel down, 6 A+C, 7 B+C, 8 A+B
const List<int> abKeysDefault = [4, 32, 8, 16, 1, 2, 0, 0, 0];
const int abSave = 0x4000, _AB_SAVE_AT = 0x8000, abMax = 0x8000;

/// parseInt(s, 16) of JS as a double (NaN when there is no digit).
double _parseHex(String s) {
  var i = 0;
  while (i < s.length && RegExp(r'\s').hasMatch(s[i])) {
    i++;
  }
  var neg = false;
  if (i < s.length && (s[i] == '+' || s[i] == '-')) {
    neg = s[i] == '-';
    i++;
  }
  if (i + 1 < s.length && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X')) i += 2;
  var v = 0.0, any = false;
  for (; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final d = c >= 0x30 && c <= 0x39
        ? c - 0x30
        : c >= 0x41 && c <= 0x46
            ? c - 0x37
            : c >= 0x61 && c <= 0x66
                ? c - 0x57
                : -1;
    if (d < 0) break;
    v = v * 16 + d;
    any = true;
  }
  if (!any) return double.nan;
  return neg ? -v : v;
}

String _jsSlice(String s, int a, int e) {
  if (a > s.length) a = s.length;
  if (e > s.length) e = s.length;
  return e > a ? s.substring(a, e) : '';
}

/// JS ToInt32 of a double.
int _toInt32(double v) {
  if (v.isNaN || v.isInfinite) return 0;
  return v.truncate().toSigned(32);
}

/// an Arduboy game from its .hex (Intel HEX text, a String or its bytes): the program (up to 32 KB) or null
Uint8List? abHex(Object data) {
  final txt = data is String ? data : latin1.decode(data as Uint8List);
  if (!RegExp(r'^\s*:[0-9A-Fa-f]{10}').hasMatch(txt)) return null;
  final b = _ff(abMax);
  var top = 0.0, hi = 0;
  var any = false;
  for (final raw in txt.split(RegExp(r'\r?\n'))) {
    final l = raw.trim();
    if (l.isEmpty) continue;
    if (l[0] != ':' || l.length < 11) return null;
    final n = _parseHex(_jsSlice(l, 1, 3)), ad = _parseHex(_jsSlice(l, 3, 7)), ty = _parseHex(_jsSlice(l, 7, 9));
    if (l.length < 11 + 2 * n) return null;
    var sum = 0.0;
    for (var i = 1; i < 11 + 2 * n; i += 2) {
      sum += _parseHex(_jsSlice(l, i, i + 2));
    }
    if ((_toInt32(sum) & 255) != 0) return null;
    if (ty == 0) {
      for (var i = 0; i < n; i++) {
        final a = hi + ad + i;
        if (a >= abMax) return null;
        final v = _parseHex(_jsSlice(l, 9 + 2 * i, 11 + 2 * i));
        if (!a.isNaN && a >= 0 && a == a.truncateToDouble()) b[a.toInt()] = _toInt32(v) & 255;
        top = math.max(top, a + 1); // (NaN stays NaN, as Math.max)
        any = true;
      }
    } else if (ty == 1) {
      break;
    } else if (ty == 2) {
      hi = (_toInt32(_parseHex(_jsSlice(l, 9, 13))) << 4).toSigned(32);
    } else if (ty == 4) {
      hi = (_toInt32(_parseHex(_jsSlice(l, 9, 13))) << 16).toSigned(32);
    }
  }
  if (!any) return null;
  return _slice(b, 0, (_toInt32(top + 1)) & ~1);
}

/// a short name from the file name: upper case, at most 15 letters
String abTitle(String? fname) {
  final s = _titleBase(fname).replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
  final t = _slice15(s).trim();
  return t.isEmpty ? 'ARDUBOY' : t;
}

void _abCfgWrite(Uint8List a, int c, Extra x, int romOff, int saveOff, int flags) {
  w32(a, c + 4, 1);
  w32(a, c + 8, romOff);
  w32(a, c + 12, x.rom!.length);
  w32(a, c + 16, saveOff);
  w32(a, c + 20, (flags & (1 | _NOSESS)) | (x.inv ? 2 : 0));
  _name15(a, c + 24, _or(x.title, 'ARDUBOY'));
  final k = (x.keys != null && x.keys!.length == 9) ? x.keys! : abKeysDefault;
  _fill(a, 0, c + 40, c + 52);
  for (var i = 0; i < 9; i++) {
    a[c + 40 + i] = k[i] & 255;
  }
}

String _cfgName(Uint8List rom, int c) {
  final s = StringBuffer();
  for (var i = 0; i < 15; i++) {
    final v = rom[c + 24 + i];
    if (v == 0) break;
    s.writeCharCode(v);
  }
  return s.toString();
}

/* 1.6.10 test1 Wolfenstein 3D (Wolf4SDL, GPL): the data pack (wolf.js, built from the user's game
 * files) first, then the program (128 KB: the PRAM part and the part it copies to RAM itself), then the save (64 KB:
 * 4 KB settings, the saved game). Settings block "PMXW" at 0x140: magic, version, pack, its length, save, flags
 * (bit 0 English, bit 1 wheel the other way round), name (16), keys fire, forward, back, use, hold key (masks A 1,
 * B 2, C 4, wheel press 8), run with forward twice, degrees per wheel step, 0, then the program's own place. */
Uint8List? wolfEmbedded() => emuBinaries?.wolf;
// 1.6.11 test2: Spear of Destiny, the same program built for SOD (wolf/src, SOD=1); its pack has flags bit 1
Uint8List? wolfSodEmbedded() => emuBinaries?.wolfsod;
bool wolfSod(Uint8List? p) => p != null && p.length > 64 && (u32(p, 8) & 2) != 0;
const int wolfMagic = 0x57584D50; // "PMXW"
const Map<String, Object> wolfKeysDefault = {'fire': 1, 'fwd': 2, 'back': 4, 'use': 8, 'mod': 4, 'run': true, 'invert': true, 'turn': 15}; // 1.6.10 test1: wheel reversed by default
bool wolfPackOk(Uint8List? p) => p != null && p.length > 64 && p[0] == 0x57 && p[1] == 0x33 && p[2] == 0x44 && p[3] == 0x50;

/// What a Wolf3D data pack holds.
class WolfInfo {
  WolfInfo(this.shareware, this.sod, this.episodes, this.maps);
  final bool shareware, sod;
  final int episodes, maps;
}

WolfInfo? wolfInfo(Uint8List? p) => wolfPackOk(p) ? WolfInfo((u32(p!, 8) & 1) != 0, (u32(p, 8) & 2) != 0, u32(p, 60), u32(p, 28)) : null;

/// JS truthiness of a key value (bool or number).
bool _truthy(Object? v) => v is bool ? v : (v is num ? v != 0 : v != null);
int _keyInt(Object? v) => v is bool ? (v ? 1 : 0) : (v is num ? v.toInt() : 0);

void _wolfCfgWrite(Uint8List a, int c, Extra x, int packOff, int saveOff, int progOff, int flags) {
  final k = <String, Object>{...wolfKeysDefault, ...?x.keyMap};
  w32(a, c + 4, 1);
  w32(a, c + 8, packOff);
  w32(a, c + 12, x.pack!.length);
  w32(a, c + 16, saveOff);
  w32(a, c + 20, (flags & 1) | (_truthy(k['invert']) ? 2 : 0));
  _name15(a, c + 24, wolfSod(x.pack) ? 'SPEAR OF DESTINY' : 'WOLFENSTEIN 3D', 16);
  a[c + 40] = _keyInt(k['fire']) & 255;
  a[c + 41] = _keyInt(k['fwd']) & 255;
  a[c + 42] = _keyInt(k['back']) & 255;
  a[c + 43] = _keyInt(k['use']) & 255;
  a[c + 44] = _keyInt(k['mod']) & 255;
  a[c + 45] = _truthy(k['run']) ? 1 : 0;
  a[c + 46] = _keyInt(k['turn']) & 255;
  a[c + 47] = 0;
  w32(a, c + 48, progOff);
}

Map<String, Object> _wolfKeysRead(Uint8List rom, int c) => {
      'fire': rom[c + 40],
      'fwd': rom[c + 41],
      'back': rom[c + 42],
      'use': rom[c + 43],
      'mod': rom[c + 44],
      'run': rom[c + 45] != 0,
      'invert': (u32(rom, c + 20) & 2) != 0,
      'turn': rom[c + 46] != 0 ? rom[c + 46] : 15,
    };

Uint8List? v3Embedded() => emuBinaries?.v3;

/// ROM of the Connection V3: 512 KB, the 6502 vectors (NMI, reset, IRQ) at 0x7FFA in the top half of the address space
bool v3Detect(Uint8List? r) {
  if (r == null || r.length != 0x80000) return false;
  int v(int o) => r[o] | (r[o + 1] << 8);
  return v(0x7FFA) >= 0xC000 && v(0x7FFC) >= 0xC000 && v(0x7FFE) >= 0xC000;
}

/// the program for this V1Emu ROM: V3Emu for a V3 ROM
Uint8List? _v1App(Uint8List? r, V1App? app) => v3Detect(r) ? (app?.v3 ?? v3Embedded()) : app?.app;

/// ROM of an E0C6S4x toy: 12 KB or 16 KB of 12-bit words (two bytes each, high byte first, top nibble 0)
bool v1Detect(Uint8List? r) {
  if (v3Detect(r)) return true;
  if (r == null || (r.length != 0x3000 && r.length != 0x4000)) return false;
  for (var i = 0; i < r.length; i += 2) {
    if (r[i] > 0x0F) return false;
  }
  return true;
}

const Map<int, String> _V1_NAMES = {
  0x1A03E02A: 'TAMA P1', 0xF0A58E57: 'TAMA P2', 0xD1BF093B: 'ANGEL', 0x02E0C792: 'GENJIN', 0x4E0B9922: 'MORINO', //
  0x5E1091E3: 'TAMAOTCH', 0x0809B7FA: 'UMINO', 0xDFEA1952: 'YASASHII', 0x58200E73: 'DIGIMON V1', 0x55DF2A89: 'DIGIMON V2', 0xD32D442C: 'DIGIMON V3', //
  0xEF932FA1: 'TAMA P1 EN', // test31: the English P1 (tama.bin), same program as the Japanese one apart from its texts   // 1.6.9 test24: Digimon V3
  /* 1.7.6 V1_MOTHRA: Mosuratchi (Mothra). Lights one segment per menu icon like Umino (found on the PC: pressing A
   * through the menu lights 8, 17, 18, 19, 39, 38, 37, then 28 = call). With the P1 table only the first icon and the
   * call showed. Its keys come by interrupt (V1Emu V1_KMASK_ALL), its clock is set from the Paradise (V1_CLK12). */
  0x9EBAAAF8: 'MOTHRA',
};
const bool _V1_MOTHRA = true;
/* V1Emu settings block (at 0x140 of its image): ROM, save (session 4 KB, device settings 4 KB), flags, name, icons */
/* 1.6.8: toys whose LCD sits the other way round (checked on the host with every known ROM: Digimon V1/V2 and Yasashii) */
/* 1.7.2 test28: these light each menu icon with one segment (V1Emu flag bit 8, core hw.c thw_iconseg) */
const List<String> _V1_ICONSEG = ['UMINO', 'GENJIN', 'TAMAOTCH', 'MOTHRA'];
bool _v1Turned(Uint8List rom) {
  final n = v1Name(rom);
  return n.startsWith('DIGIMON') || n == 'YASASHII';
}

int _v1FlagBits(Uint8List rom) {
  final nm = v1Name(rom);
  return (v1Clock(rom) ? 8 : 0) | 16 | (_v1Turned(rom) ? 32 : 0) | (nm.startsWith('DIGIMON') ? 64 : 0) | (nm == 'YASASHII' ? 128 : 0) | (_V1_ICONSEG.contains(nm) ? 256 : 0) | (_V1_MOTHRA && nm == 'MOTHRA' ? 512 : 0);
}

void _v1CfgWrite(Uint8List a, int c, Uint8List rom, int romOff, int saveOff, int flags) {
  w32(a, c + 4, 1);
  w32(a, c + 8, romOff);
  w32(a, c + 12, rom.length);
  w32(a, c + 16, saveOff);
  // 1.7.6 bit 9: Mothra's clock (12 h at 0x1A, set with B, A, C)   // bit 7 (test31): Yasashii, segment n is column n
  // bit 6: Digimon (clock at RAM 0x1A, 12 h, set with B and C; own icon segments, keys by interrupt, one-shot beeps)
  // bit 1 clock, bit 3: V1Emu knows the toy's clock, bit 4: bit 1 is meant, bit 5: LCD turned (Digimon)
  w32(a, c + 20, (flags & (3 | _NOSESS)) | _v1FlagBits(rom));
  _name15(a, c + 24, v1Name(rom));
  // a turned LCD lights place 7 - i for the toy's icon i: the P set goes in reversed then (Yasashii)
  _v1IconsWrite(a, c, rom);
}

void _v1IconsWrite(Uint8List a, int c, Uint8List rom) {
  final nm = v1Name(rom);
  final set = _V1_ICONS[nm] ??
      (nm.startsWith('DIGIMON')
          ? _V1_ICONS['DIGIMON']!
          : _v1Turned(rom)
              ? _V1_ICONS['P']!.reversed.toList()
              : _V1_ICONS['P']!);
  w32(a, c + 40, 1);
  for (var i = 0; i < set.length; i++) {
    for (var r = 0; r < set[i].length; r++) {
      final v = set[i][r];
      a[c + 44 + i * 32 + r * 2] = v & 255;
      a[c + 45 + i * 32 + r * 2] = v >> 8;
    }
  }
}

/// 1.6.8: V1Emu as the main program (A and C, start when switched on): image at 0x0A0000, ROM at 0x940000,
/// session and settings at 0x0C0000. The session stays when the same ROM was in before.
Uint8List v1Patch(Uint8List rom, Uint8List v1rom, V1App? app0, Uint8List stubTpl, {String? lang, bool? clock}) {
  if (!v1Detect(v1rom)) throw EmuError('not a V1 ROM');
  final app = _v1App(v1rom, app0);
  if (app == null) throw EmuError('V3Emu missing');
  if (_assetEnd(rom) > 0x830000) throw EmuError('the character data reaches 0x${_assetEnd(rom).toRadixString(16)}, the emulator needs 0x830000 onwards');
  final old = v1FromRom(rom), same = old != null && old.length == v1rom.length && _eqAt(old, 0, v1rom, 0, old.length);
  final oldTama = u32(rom, _APP_OFF + 0x140) == _PMXC, bigOld = oldTama && u32(rom, _APP_OFF + 0x148) == _BIG_OFF;
  final out = installApp(rom, app, stubTpl);
  if (bigOld) _fill(out, 0xFF, _BIG_OFF, _BIG_END);
  _fill(out, 0xFF, _GUEST_OFF, _GUEST_END);
  _set(out, v1rom, _GUEST_OFF);
  const c = _APP_OFF + 0x140;
  if (u32(out, c) != v1Magic) throw EmuError('settings block missing in the program');
  _v1CfgWrite(out, c, v1rom, _GUEST_OFF, _SAVE_OFF, (lang == 'en' ? 1 : 0) | (clock == false ? 0 : 2));
  if (!same) _fill(out, 0xFF, _SAVE_OFF, _SAVE_OFF + 0x1000); // the settings of the device (second 4 KB) stay
  _fill(out, 0xFF, _SAVE_OFF + 0x2000, _SAVE_END);
  return out;
}

/// The V1 ROM of V1Emu as the main program, or null.
Uint8List? v1FromRom(Uint8List rom, [int base = _APP_OFF]) {
  if (u32(rom, base + 0x140) != v1Magic) return null;
  final o = u32(rom, base + 0x148), n = u32(rom, base + 0x14C);
  return o + n <= rom.length && (n == 0x3000 || n == 0x4000 || n == 0x80000) ? _slice(rom, o, o + n) : null;
}

/// Newer V1Emu program as the main program: the settings block stays. null if nothing to do.
Uint8List? v1Upgrade(Uint8List rom, V1App? app0) {
  if (u32(rom, _APP_OFF + 0x140) != v1Magic) return null;
  final app = _v1App(v1FromRom(rom), app0);
  if (app == null) return null;
  final a = _copy(app);
  if (u32(a, 0x140) != v1Magic) return null;
  _set(a, _sub(rom, _APP_OFF + 0x140, _APP_OFF + 0x140 + 300), 0x140);
  const fa = 0x140 + 20;
  final f = u32(a, fa);
  if ((f & 16) == 0) w32(a, fa, f | 2 | 16);
  final r = v1FromRom(rom);
  if (r != null) {
    final nm = v1Name(r);
    if (nm.startsWith('DIGIMON')) {
      w32(a, fa, u32(a, fa) | 32 | 64 | 8); // LCD turned
    } else if (_v1Turned(r)) {
      w32(a, fa, u32(a, fa) | 32);
    }
    _v1IconsWrite(a, 0x140, r);
    if (nm == 'YASASHII') w32(a, fa, u32(a, fa) | 128); // test31: segment = column
    if (_V1_ICONSEG.contains(nm)) w32(a, fa, u32(a, fa) | 256); // 1.7.2 test28: one segment per menu icon
    if (_V1_MOTHRA && nm == 'MOTHRA') w32(a, fa, u32(a, fa) | 512); // 1.7.6: Mothra's clock
    // test31: a newly known ROM (tama.bin) gets its name and clock
    _name15(a, 0x140 + 24, nm);
    if (v1Clock(r)) w32(a, fa, u32(a, fa) | 8);
  }
  if (_sameProgram(rom, a)) return null;
  final out = _copy(rom);
  _fill(out, 0x00, _APP_OFF, _APP_OFF + _APP_MAX);
  _set(out, a, _APP_OFF);
  return out;
}

/* 1.6.8: toys whose clock V1Emu sets (RAM nibble 0x10, see v1/src/app/main.c) */
const List<String> _V1_CLOCK = ['TAMA P1', 'TAMA P1 EN', 'TAMA P2', 'ANGEL', 'MORINO', 'DIGIMON V1', 'DIGIMON V2', 'DIGIMON V3', 'TAMA V3', 'MOTHRA']; // 1.6.9: V3Emu (V3_CLOCK); 1.7.6: Mothra
bool v1Clock(Uint8List r) => _V1_CLOCK.contains(v1Name(r));
String v1Name(Uint8List r) {
  if (v3Detect(r)) return 'TAMA V3';
  var h = 2166136261;
  for (final x in r) {
    h = ((h ^ x) * 16777619) & 0xFFFFFFFF;
  }
  return _V1_NAMES[h] ?? (r.length == 0x3000 ? 'TAMA 46' : 'TAMA 48');
}

T7App? t7Embedded() => emuBinaries?.t7 == null ? null : T7App(emuBinaries!.t7!, emuBinaries!.t7x);
/* 1.6.12 test2: second part of T7Emu (t7x.bin, the translator for the JIT) in the save area at +0x8000; the program runs without it */
const int _T7X_OFF = 0x8000, _T7X_MAX = 0x8000;
void _t7XWrite(Uint8List out, int saveOff, T7App? app) {
  if (app == null || app.x == null || app.x!.length > _T7X_MAX) return;
  _fill(out, 0xFF, saveOff + _T7X_OFF, saveOff + _T7X_OFF + _T7X_MAX);
  _set(out, app.x!, saveOff + _T7X_OFF);
}

bool _t7XSame(Uint8List rom, int saveOff, T7App? app) {
  if (app == null || app.x == null) return true;
  final x = app.x!;
  for (var i = 0; i < x.length; i++) {
    if (_at(rom, saveOff + _T7X_OFF + i) != x[i]) return false;
  }
  return true;
}

/// V7 ROM: Tama-Go (640 KB, reset vector in the static part at 0x3FFC) or Tamagotchi Friends
/// (768 KB, 16 KB more in front: reset vector at 0x7FFC, nothing at 0x3FFC). 'go', 'friends' or null.
const int _T7_FRIENDS_SIZE = 0xC0000;
String? t7Kind(Uint8List? b) {
  if (b == null) return null;
  int v(int o) => b[o] | (b[o + 1] << 8);
  if (b.length == _T7_ROM_SIZE && v(0x3FFC) >= 0xC000) return 'go';
  if (b.length == _T7_FRIENDS_SIZE && v(0x3FFC) == 0 && v(0x7FFC) >= 0xC000) return 'friends';
  return null;
}

bool t7Detect(Uint8List? b) => t7Kind(b) != null;

/// Figure: "AA 55" at 1 and at 0x11.
bool t7FigDetect(Uint8List? b) => b != null && b.length >= 0x40 && b[1] == 0xAA && b[2] == 0x55 && b[0x11] == 0xAA && b[0x12] == 0x55;
/* Figure data as stored: dumps of the whole chip (the "full" figures, 4 MB) hold the 1 MB of the figure
 * four times (the address wraps) and a few bytes of text from the dump tool behind; one copy is enough.
 * Then the zeros at the end are cut. */
Uint8List t7FigData(Uint8List b) {
  var n = b.length, p = 1;
  while (p * 2 <= n) {
    p *= 2;
  }
  if (n - p <= 64 && p >= 0x40000) n = p; // dump tool text behind the chip
  bool same(int h) {
    for (var i = 1; i < h; i++) {
      if (b[i] != b[h + i]) return false;
    }
    return true;
  }

  while (n >= 0x80000 && (n & (n - 1)) == 0 && same(n ~/ 2)) {
    n ~/= 2;
  }
  var e = n;
  while (e > 0 && b[e - 1] == 0) {
    e--;
  }
  return _slice(b, 0, math.max(e, 0x40));
}

Uint8List _t7Trim(Uint8List b) => t7FigData(b);

/// Name for the menu on the device from the file name: "(03)_Tama-Go_Mametchi.bin" -> "Mametchi".
String t7FigName(String? file) {
  var n = (file ?? '').split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.[^.]*$'), '');
  n = n.replaceFirst(RegExp(r'^\(\d+\)[_ -]*'), '').replaceFirst(RegExp(r'^tama[-_ ]?go[_ -]*', caseSensitive: false), '').replaceFirst(RegExp(r'[_ -]*figure$', caseSensitive: false), ' Full').replaceAll('_', ' ');
  n = n.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
  return _slice15(n.isEmpty ? 'Figur' : n);
}

/// A figure of an installed T7Emu: place, length, name.
class T7FigAt {
  T7FigAt(this.off, this.len, this.name);
  final int off, len;
  final String name;
}

/// A figure for T7Emu: file name and data.
class T7Fig {
  T7Fig(this.name, this.data);
  final String name;
  final Uint8List data;
}

/// Settings of an installed T7Emu.
class T7Cfg {
  T7Cfg(this.version, this.romOff, this.romLen, this.saveOff, this.figs, this.flags);
  final int version, romOff, romLen, saveOff, flags;
  final List<T7FigAt> figs;
}

T7Cfg? t7Cfg(Uint8List rom, [int base = _APP_OFF]) {
  if (_u32s(rom, base + 0x140) != t7Magic) return null;
  final c = base + 0x140, n = math.min(u32(rom, c + 20), _T7_FIG_MAX), figs = <T7FigAt>[];
  for (var i = 0; i < n; i++) {
    final f = c + 24 + i * 24;
    final name = StringBuffer();
    for (var k = 0; k < 16 && rom[f + 8 + k] != 0; k++) {
      name.writeCharCode(rom[f + 8 + k]);
    }
    figs.add(T7FigAt(u32(rom, f), u32(rom, f + 4), name.toString()));
  }
  return T7Cfg(u32(rom, c + 4), u32(rom, c + 8), u32(rom, c + 12), u32(rom, c + 16), figs, u32(rom, c + 24 + _T7_FIG_MAX * 24));
}

/* 1.6.11 test2: T7Emu builds up to 1.6.8 (and early 1.6.9 tests) could write the pet's save 2 bytes off; their own
 * check then failed and after a battery change the game started anew. Known builds by length and FNV-1a over the
 * program from 0x800 (the settings block in front differs per install); also a save slot already written off. */
const List<List<int>> _T7_SHIFT_BUILDS = [
  [45856, 0xdfbdc8e8], [48612, 0xc123d5d6], [48612, 0x7880cbf2], [49792, 0xe8560e2d], [49532, 0x71dd1b4a], [51760, 0x91ab1388], //
  [52976, 0xac37ab35], [53056, 0x74031b17], [54440, 0x16007a7e], [57404, 0xc8392ba4], [57984, 0xc27ec6ad], [58244, 0x6c7b9978], //
  [58300, 0x51abf5c5], [58580, 0x53c0e0bd], [59008, 0xad615a75], [59856, 0xd768658e], [59680, 0xa74ff62c],
];
int _fnv1a(Uint8List b, int a, int e) {
  var h = 0x811c9dc5;
  for (var i = a; i < e; i++) {
    h = ((h ^ (i < b.length ? b[i] : 0)) * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

bool _t7EeShifted(Uint8List rom, int ee) {
  for (final at in [ee, ee + 0x2000]) {
    if (at + 0x2000 > rom.length || u32(rom, at) != 0x45453754) continue;
    var s = 0x7E7E;
    for (var i = 0; i < 4096; i++) {
      s = (s * 31 + rom[at + 0x1000 + i]) & 0xFFFFFFFF;
    }
    if (s == u32(rom, at + 12)) continue;
    var s2 = 0x7E7E;
    for (var i = 2; i < 4096; i++) {
      s2 = (s2 * 31 + rom[at + 0x1000 + i]) & 0xFFFFFFFF;
    }
    if (((((s2 * 31) & 0xFFFFFFFF) * 31) & 0xFFFFFFFF) == u32(rom, at + 12)) return true;
  }
  return false;
}

/// Is the T7Emu at base one that can lose the pet's save (old build, or a save already written off)?
bool t7Outdated(Uint8List rom, [int base = _APP_OFF]) {
  final c = t7Cfg(rom, base);
  if (c == null) return false;
  for (final e in _T7_SHIFT_BUILDS) {
    if (base + e[0] <= rom.length && _fnv1a(rom, base + 0x800, base + e[0]) == e[1]) return true;
  }
  // a save written off counts only while the program is not the current one (the current one reads and rewrites it)
  final cur = t7Embedded()?.app;
  if (cur != null && _fnv1a(rom, base + 0x800, base + cur.length) == _fnv1a(cur, 0x800, cur.length)) return false;
  return _t7EeShifted(rom, c.saveOff + 0x1000);
}

/// What is installed (ROM and figures), as input for t7Patch again (to add or remove figures).
class T7Installed {
  T7Installed(this.rom, this.figs);
  final Uint8List rom;
  final List<T7Fig> figs;
}

T7Installed? t7FromRom(Uint8List rom) {
  final c = t7Cfg(rom);
  if (c == null) return null;
  return T7Installed(_slice(rom, c.romOff, c.romOff + c.romLen), [for (final f in c.figs) T7Fig(f.name, _slice(rom, f.off, f.off + f.len))]);
}

/// Room the figures may still use (bytes), for the Studio's display.
int t7Room(List<T7Fig> figs, [int romLen = _T7_ROM_SIZE]) {
  var a = _GUEST_OFF + romLen;
  for (final f in figs) {
    a = (a + f.data.length + 0xFFF) & ~0xFFF;
  }
  return _GUEST_END - a;
}

/// Install T7Emu. rom: 16 MB Paradise image, t7rom: 640 KB V7 ROM, figs: [{name, data}],
/// app: t7.bin, stubTpl: launcher. lang 'en' for English texts on the device. Returns a new image.
Uint8List t7Patch(Uint8List rom, Uint8List t7rom, List<T7Fig> figs, T7App app, Uint8List stubTpl, {String? lang, bool? clock}) {
  if (!t7Detect(t7rom)) throw EmuError('not a V7 ROM (Tama-Go 640 KB or Tamagotchi Friends 768 KB)');
  if (t7Kind(t7rom) == 'friends') figs = []; // Friends has no figure port
  if (figs.length > _T7_FIG_MAX) throw EmuError('at most $_T7_FIG_MAX figures');
  if (_assetEnd(rom) > 0x830000) throw EmuError('the character data reaches 0x${_assetEnd(rom).toRadixString(16)}, the emulator needs 0x830000 onwards');
  final oldT7 = t7Cfg(rom), oldTama = u32(rom, _APP_OFF + 0x140) == _PMXC;
  var sameRom = false;
  if (oldT7 != null && oldT7.romLen == t7rom.length) {
    final s = _sub(rom, oldT7.romOff, oldT7.romOff + oldT7.romLen);
    sameRom = true;
    for (var i = 0; i < s.length; i++) {
      if (s[i] != t7rom[i]) {
        sameRom = false;
        break;
      }
    }
  }
  final bigOld = oldTama && u32(rom, _APP_OFF + 0x148) == _BIG_OFF;
  final out = installApp(rom, app.app, stubTpl);
  if (installedOrigs(rom, sceneTable(rom)) == null && !_isFF(rom, _GUEST_OFF, _GUEST_END - _GUEST_OFF)) throw EmuError('area 0x940000 is in use');
  if (bigOld) _fill(out, 0xFF, _BIG_OFF, _BIG_END);
  _fill(out, 0xFF, _GUEST_OFF, _GUEST_END);
  _set(out, t7rom, _GUEST_OFF);
  var at = _GUEST_OFF + t7rom.length;
  final list = <T7FigAt>[];
  for (final f in figs) {
    final d = _t7Trim(f.data);
    if (at + d.length > _GUEST_END) throw EmuError('no room for figure ${f.name}');
    _set(out, d, at);
    list.add(T7FigAt(at, d.length, t7FigName(f.name)));
    at = (at + d.length + 0xFFF) & ~0xFFF;
  }
  const c = _APP_OFF + 0x140;
  if (u32(out, c) != t7Magic) throw EmuError('settings block missing in the program');
  w32(out, c + 4, 1);
  w32(out, c + 8, _GUEST_OFF);
  w32(out, c + 12, t7rom.length);
  w32(out, c + 16, _SAVE_OFF);
  w32(out, c + 20, list.length);
  _fill(out, 0, c + 24, c + 24 + _T7_FIG_MAX * 24);
  for (var i = 0; i < list.length; i++) {
    final f = list[i], o = c + 24 + i * 24;
    w32(out, o, f.off);
    w32(out, o + 4, f.len);
    for (var k = 0; k < f.name.length; k++) {
      out[o + 8 + k] = f.name.codeUnitAt(k) & 255;
    }
  }
  w32(out, c + 24 + _T7_FIG_MAX * 24, (lang == 'en' ? 1 : 0) | (clock == false ? 0 : 2));
  // save area: the pet's EEPROM stays when the same ROM was in before, the session only with the same figures
  var sameFigs = sameRom && oldT7!.figs.length == list.length;
  if (sameFigs) {
    for (var i = 0; i < list.length; i++) {
      if (oldT7.figs[i].len != list[i].len || oldT7.figs[i].off != list[i].off) sameFigs = false;
    }
  }
  if (!sameRom) {
    _fill(out, 0xFF, _SAVE_OFF, _SAVE_END);
  } else {
    _fill(out, 0xFF, _T7_EE_END, _SAVE_END);
    if (!sameFigs) _fill(out, 0xFF, _SAVE_OFF, _T7_EE);
  }
  _t7XWrite(out, _SAVE_OFF, app);
  return out;
}

/// Local time when writing to the device, for the first time setting in the game (T7Emu fills
/// it in). counter: the device's seconds counter, date: now. Returns a new image.
Uint8List t7Wall(Uint8List rom, int counter, DateTime date) {
  if (u32(rom, _APP_OFF + 0x140) != t7Magic) return rom;
  final out = _copy(rom);
  const c = _APP_OFF + 0x140 + 24 + _T7_FIG_MAX * 24 + 4;
  _wall(out, c, counter, date);
  return out;
}

void _wall(Uint8List out, int c, int counter, DateTime date) {
  w32(out, c, counter & 0xFFFFFFFF);
  w32(out, c + 4, date.hour * 3600 + date.minute * 60 + date.second);
  w32(out, c + 8, ((date.year << 16) | (date.month << 8) | date.day) & 0xFFFFFFFF);
}

/// Newer T7 program into a ROM that already has T7Emu: settings stay. null if nothing to do.
Uint8List? t7Upgrade(Uint8List rom, T7App app) {
  if (u32(rom, _APP_OFF + 0x140) != t7Magic) return null;
  final a = _copy(app.app);
  if (u32(a, 0x140) != t7Magic) return null;
  const n = 24 + _T7_FIG_MAX * 24 + 4;
  _set(a, _sub(rom, _APP_OFF + 0x140, _APP_OFF + 0x140 + n), 0x140);
  final same = _sameProgram(rom, a);
  final so = u32(rom, _APP_OFF + 0x150);
  if (same && _t7XSame(rom, so, app)) return null;
  final out = _copy(rom);
  _fill(out, 0x00, _APP_OFF, _APP_OFF + _APP_MAX);
  _set(out, a, _APP_OFF);
  _t7XWrite(out, so, app);
  return out;
}

// ------------------------------------------------------------ T18Emu (Meets/On, TG18, ARM7)
/*
 * T18Emu (1.5.0): the TG18 core (from T18Emu) with a translator from ARM/Thumb to Cortex-M3 code.
 * Same launcher and program place as TamaEmu and T7Emu (only one of them). Settings block "PMX8"
 * at 0x140 of the program. Since 1.5.1 the program has two parts: t18.bin (PRAM, copied by the
 * launcher from 0x0A0000) and t18x.bin (code run from the flash window, at T18_XIP_OFF).
 * The 8 MB firmware is stored in 64 KB blocks in free blocks of the Paradise flash, from the top
 * down (from 0xF00000, then from 0xD40000 downwards), so the bottom (from 0x830000) stays free for
 * the field saves of the menu. Empty blocks are left out. Behind them up to T18_SPARE_WANT spares
 * for the blocks the firmware writes (its save data: 6 blocks after the first start).
 * Save area at 0x0C0000: block map, clock note, session (see t18/src/app/t18app.h).
 */
const int t18Magic = 0x38584D50, t18SaveLen = 0x24000;
const int _T18_SPARE_MAX = 64, _T18_SPARE_MIN = 6, _T18_SPARE_WANT = 10, _T18_SPARE_GROW = 15; // GROW (test29): spares added in a start device, at most 15 (the sector pool counts to 254)
/* 1.7.2 SPARE_NO_RESCUE: more spares for T18Emu never take the rescue start's block (0xFF0000), also when it is still empty */
const bool _SPARE_NO_RESCUE = true;
const int t18XipOff = 0xF0000;
const int _T18_XIP_MAX = 0x10000, _T18_XIP_MAGIC = 0x58383154;
/* Hot window (1.6.6): the device's cached flash window shows 1 MB. With 0xF00000..0xFFFFFF free the
 * program moves it there (flag 4) and needs its flash part a second time at T18_XIP_HOT; the blocks
 * with the firmware's code (the same in all known TG18 firmwares) and two busy picture blocks go into
 * the rest of that MB. */
const int _T18_XIP_HOT = 0xFDF000, _T18F_HOTWIN = 4;
// 1.6.6 test11 (T18_HOT_V2): the blocks the TG18 firmware reads most (measured over please wait, egg and pet with
// its calls): code 0x12..0x16, 0x1A, 0x00 and the picture data 0x3F, 0x4A, 0x32, 0x40 (pet), 0x18, 0x19, 0x3B (egg).
// The first list had 0x01, 0x1B, 0x17 (hardly read) and 0x5E, 0x63 (empty in the firmware: never placed) instead.
const bool _T18_HOT_V2 = true;
const int _T18F_HOT2 = 16; // 8 was the list of test10
const List<int> _T18_HOT_GUEST = [0x12, 0x14, 0x15, 0x13, 0x1A, 0x00, 0x16, 0x3F, 0x4A, 0x32, 0x18, 0x19, 0x3B, 0x40];
const List<int> _T18_HOT_SLOTS = [0xFF, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8, 0xF7, 0xF6, 0xF5, 0xF4, 0xF3, 0xF2, 0xF1, 0xF0];
const List<(int, int)> _T18_AREAS = [(0x830000, 0xD40000), (0xF00000, 0x1000000)];
/* 1.6.13 test13 (RESCUE_RES): the top 64 KB (0xFF0000) stay free for the rescue start (flash.js); an installation that
 * already has a block there keeps it (its save belongs to that layout) */
const bool _RESCUE_RES = true;
const int _RESCUE_BLK = 0xFF;

/// The program: PRAM part, with the flash part as .xip
T18App? t18Embedded() {
  final b = emuBinaries;
  if (b?.t18 == null || b?.t18x == null) return null;
  return T18App(b!.t18!, b.t18x);
}

bool _t18XipOk(T18App? app) => app != null && app.xip != null && app.xip!.length >= 8 && app.xip!.length <= _T18_XIP_MAX && u32(app.xip!, 0) == _T18_XIP_MAGIC;

/// TG18 firmware: 8 MB, "SPII" header, entry 0x2000000C.
bool t18Detect(Uint8List? b) => b != null && b.length == 0x800000 && b[0] == 0x53 && b[1] == 0x50 && b[2] == 0x49 && b[3] == 0x49 && u32(b, 4) == 0x2000000C;

/// Addresses the core needs: idle counter, soft RTC, DMA table, the game's Param block.
class T18Addrs {
  T18Addrs(this.idle, this.soft, this.dma, this.param);
  final int idle, soft, dma, param;
}

/// Addresses the core needs (same searches as tg18_init in t18soc.c): idle counter, soft RTC, DMA table.
T18Addrs t18Addrs(Uint8List fw) {
  final n = fw.length >> 2;
  final w = Endian.host == Endian.little ? Uint32List.sublistView(fw.offsetInBytes % 4 == 0 ? fw : _copy(fw), 0, n * 4) : Uint32List.fromList([for (var i = 0; i < n; i++) u32(fw, i * 4)]);
  final cnt = <int, int>{};
  var best = 0, bestc = 0;
  for (var i = 0; i + 8 < n; i++) {
    final v = w[i];
    if (v < 0xF8000000 || v >= 0xF8020000) continue;
    var h1 = false, h2 = false;
    for (var k = 1; k < 8; k++) {
      final x = w[i + k];
      if (x == v + 1) h1 = true;
      if (x == v + 2) h2 = true;
    }
    if (!h1 || !h2) continue;
    if (!cnt.containsKey(v)) {
      if (cnt.length == 64) continue;
      cnt[v] = 0;
    }
    final c = cnt[v]! + 1;
    cnt[v] = c;
    if (c > bestc) {
      bestc = c;
      best = v;
    }
  }
  final idle = bestc >= 40 ? (best - 0x0F) & 0xFFFFFFFF : 0;
  var soft = 0;
  for (var i = 0; i + 8 <= fw.length && i < 0x20000; i += 4) {
    final a1 = u32(fw, i + 4);
    if (u32(fw, i) == 0xC0040000 && a1 >= 0xF8008000 && a1 < 0xF8010000 && a1 != 0xF800128C && (a1 & 3) == 0) {
      soft = a1;
      break;
    }
  }
  var dma = 0;
  for (var i = 0; i + 12 <= fw.length && i < 0x400000; i += 4) {
    if (u32(fw, i) != 0xD0300000) continue;
    final a2 = u32(fw, i + 8);
    if (u32(fw, i + 4) == 0x3210 && a2 >= 0xF8000000 && a2 < 0xF8020000) {
      dma = a2;
      break;
    }
  }
  return T18Addrs(idle, soft, dma, _t18Param(fw));
}

/// 1.6.8 (test47): the game's Param block in the SRAM (grow up). The literal pool of DispYobidashiIconInit holds it right
/// before the address of its debug text (as the Android T18Emu finds it); checked against its table for all 9 firmwares.
int _t18Param(Uint8List fw) {
  final pat = 'DispYobidashiIconInit() pYobi'.codeUnits;
  var s = -1;
  final p0 = pat[0];
  outer:
  for (var i = 0; i + pat.length <= fw.length; i++) {
    if (fw[i] != p0) continue;
    for (var k = 1; k < pat.length; k++) {
      if (fw[i + k] != pat[k]) continue outer;
    }
    s = i;
    break;
  }
  if (s < 0) return 0;
  while (s > 0 && fw[s - 1] != 0) {
    s--;
  }
  final addr = (0x20000000 + s) & 0xFFFFFFFF;
  final a0 = addr & 255, a1 = (addr >> 8) & 255, a2 = (addr >> 16) & 255, a3 = (addr >> 24) & 255;
  for (var p = 4; p + 4 <= fw.length; p += 1) {
    if (fw[p] == a0 && fw[p + 1] == a1 && fw[p + 2] == a2 && fw[p + 3] == a3) {
      final v = u32(fw, p - 4);
      return v >= 0xF800C000 && v <= 0xF800F000 ? v : 0;
    }
  }
  return 0;
}

void _t18ParamSet(Uint8List out, int c, Uint8List fw) {
  final pa = _t18Param(fw);
  w32(out, c + 428, pa);
  w32(out, c + 432, pa == 0xF800D8B4 ? 1 : 0); // Sanrio: Flowertchi
}

/// Settings of an installed T18Emu: block map (128 guest blocks, 0xFFFF none), spare blocks.
class T18Cfg {
  T18Cfg(this.version, this.saveOff, this.map, this.spare, this.flags);
  final int version, saveOff, flags;
  final List<int> map, spare;
}

T18Cfg? t18Cfg(Uint8List rom, [int base = _APP_OFF]) {
  final c = base + 0x140;
  if (_u32s(rom, c) != t18Magic) return null;
  final map = <int>[], spare = <int>[], nspare = math.min(u32(rom, c + 12), _T18_SPARE_MAX);
  for (var i = 0; i < 128; i++) {
    map.add(rom[c + 16 + 2 * i] | (rom[c + 17 + 2 * i] << 8));
  }
  for (var i = 0; i < nspare; i++) {
    spare.add(rom[c + 272 + 2 * i] | (rom[c + 273 + 2 * i] << 8));
  }
  return T18Cfg(u32(rom, c + 4), u32(rom, c + 8), map, spare, u32(rom, c + 400));
}

/// An installed T18Emu gives its blocks back (before another emulator or DOOM goes in).
void _freeT18(Uint8List out) {
  final c = t18Cfg(out);
  if (c == null) return;
  for (final b in [...c.map, ...c.spare]) {
    if (b != 0xFFFF) _fill(out, 0xFF, b << 16, (b + 1) << 16);
  }
  if ((c.flags & _T18F_HOTWIN) != 0) _fill(out, 0xFF, 0xFD0000, 0xFF0000);
  _fill(out, 0xFF, _SAVE_OFF, _SAVE_END);
}

/// ID page of the edition (0xD49000, Tropical/Glacier 0xD29000): the Paradise's save follows it
/* 1.7.6 NEON_APPS: Neon Planets (ID page 0xD85000, ID 7 with its own footer): programs in the menu between the end of its
 * pictures and its ID page (up to 0xD80000), not only up to 0xD40000 */
const bool _DOOM_LAUNCH = true, _NEON_HI = true, _NEON_APPS = true;
const int _NEON_ID = 0xD85000, _NEON_TOP = 0xD80000;
bool neonRom(Uint8List? rom) {
  if (!_NEON_APPS || rom == null || rom.length < _NEON_ID + 0x1000 || u32(rom, _NEON_ID) != 7) return false;
  final k = u32(rom, _NEON_ID + 0xFF8);
  return ((k + 7) & 0xFFFFFFFF) == 0x99431749 && u32(rom, _NEON_ID + 0xFFC) == (~k & 0xFFFFFFFF);
}

int _idPageOf(Uint8List rom) {
  if (_clean) return 0xFF0000;
  if (neonRom(rom)) return _NEON_ID;
  final k = u32(rom, 0xD29000), v = u32(rom, 0xD49000);
  return (k == 5 || k == 6)
      ? 0xD29000
      : v >= 1 && v <= 6
          ? 0xD49000
          : 0xD29000; // 1.7.3 test11: Tropical/Glacier first
}

/// Free 64 KB blocks for the firmware: empty, behind the character data.
List<int> t18Free(Uint8List rom, [bool launch = false]) {
  final from = _clean ? 0x10000 : math.max(launch ? 0x200000 : 0x830000, _and32(_assetEnd(rom) + 0xFFFF, ~0xFFFF)), list = <int>[]; // launcher ROM (1.6.8): all room behind the setup pictures
  final areas = _clean
      ? [(from, 0xFF0000)]
      : launch
          ? [(from, neonRom(rom) ? _NEON_TOP : math.min(0xD40000, _idPageOf(rom))), _T18_AREAS[1]]
          : _T18_AREAS;
  for (final (a, e) in areas) {
    for (var o = math.max(a, a < 0xF00000 ? from : a); o < e; o += 0x10000) {
      if (_isFF(rom, o, 0x10000)) list.add(o >> 16);
    }
  }
  _sort<int>(list, (x, y) => y - x); // from the top down: the bottom stays free for the field saves
  return list;
}

/// Lowest flash offset T18Emu uses below 0xF00000 (the field saves of the menu end there); 0 = none
int t18Low(Uint8List rom) {
  final c = t18Cfg(rom);
  if (c == null) return 0;
  final b = [...c.map, ...c.spare].where((x) => x != 0xFFFF && x < 0xF0).toList();
  return b.isNotEmpty ? b.reduce(math.min) << 16 : 0xD40000;
}

/// Result of t18Patch.
class T18PatchResult {
  T18PatchResult(this.rom, this.blocks, this.spares, this.hot);
  final Uint8List rom;
  final int blocks, spares;
  final bool hot;
}

/// Install T18Emu. rom: 16 MB Paradise image, fw: 8 MB TG18 firmware, app: t18.bin (with its flash part), stubTpl: launcher.
/// lang 'en'. Returns { rom, blocks, spares }.
T18PatchResult t18Patch(Uint8List rom, Uint8List fw, T18App app, Uint8List? stubTpl,
    {String? lang, bool? clock, bool launch = false, bool extra = false, EmuOpt? opt, bool noResv = false, bool nosess = false, bool? hotWindow, bool holes = false, int? spares}) {
  if (!t18Detect(fw)) throw EmuError('not a TG18 firmware (8 MB)');
  if (rom.length != 0x1000000) throw EmuError('the Paradise image must be 16 MB');
  // extra (1.6.8): placed as an extra program (appsPlace); the program at 0x0A0000 is someone else's
  final old = extra ? null : t18Cfg(rom), oldTama = !extra && u32(rom, _APP_OFF + 0x140) == _PMXC, oldT7 = !extra && u32(rom, _APP_OFF + 0x140) == t7Magic;
  final work = _copy(rom);
  // what an earlier emulator used becomes free again
  if (old != null) {
    for (final b in old.map) {
      if (b != 0xFFFF) _fill(work, 0xFF, b << 16, (b + 1) << 16);
    }
    for (final b in old.spare) {
      _fill(work, 0xFF, b << 16, (b + 1) << 16);
    }
    if ((old.flags & _T18F_HOTWIN) != 0) _fill(work, 0xFF, 0xFD0000, 0xFF0000);
  }
  if (oldTama || oldT7) {
    _fill(work, 0xFF, _GUEST_OFF, _GUEST_END);
    if (oldTama && u32(rom, _APP_OFF + 0x148) == _BIG_OFF) _fill(work, 0xFF, _BIG_OFF, _BIG_END);
  }
  var used = <int>[];
  for (var i = 0; i < 128; i++) {
    if (!_isFF(fw, i << 16, 0x10000)) used.add(i);
  }
  var free = t18Free(work, launch);
  final resv = _RESCUE_RES && !noResv && !(old != null && (old.map.contains(_RESCUE_BLK) || old.spare.contains(_RESCUE_BLK)));
  if (resv) free = free.where((b) => b != _RESCUE_BLK).toList();
  if (free.length < used.length + _T18_SPARE_MIN) throw EmuError('not enough room: the firmware needs ${used.length + _T18_SPARE_MIN} blocks of 64 KB, ${free.length} are free');
  // hot window: the whole MB at 0xF00000 free and still room enough without 0xFD/0xFE
  var hot = hotWindow != false && free.length - 2 >= used.length + _T18_SPARE_MIN;
  if (hot) {
    for (var i = 0; i < (resv ? 15 : 16); i++) {
      if (!free.contains(0xF0 + i)) {
        hot = false;
        break;
      }
    }
  }
  final hotSlots = resv ? _T18_HOT_SLOTS.where((b) => b != _RESCUE_BLK).toList() : _T18_HOT_SLOTS;
  if (hot) {
    final rest = free.where((b) => b < 0xF0).toList();
    free = [...hotSlots, ...rest];
    final u0 = used;
    used = [..._T18_HOT_GUEST.where((g) => u0.contains(g)), ...u0.where((g) => !_T18_HOT_GUEST.contains(g))];
  }
  if (holes) {
    // test25: the smallest gaps first; the largest free run stays for a TamaEmu in the menu (it needs one piece)
    final nh = hot ? hotSlots.length : 0, rest = free.sublist(math.min(nh, free.length)), set = rest.toSet();
    int run(int b) {
      var lo = b, hi = b;
      while (set.contains(lo - 1)) {
        lo--;
      }
      while (set.contains(hi + 1)) {
        hi++;
      }
      return hi - lo + 1;
    }

    final rs = [for (final b in rest) (run(b), b)];
    _sort(rs, (x, y) => x.$1 != y.$1 ? x.$1 - y.$1 : y.$2 - x.$2);
    free = [...free.sublist(0, math.min(nh, free.length)), for (final x in rs) x.$2];
  }
  final Uint8List out;
  if (extra) {
    out = _copy(work);
    _fill(out, 0x00, _APP_OFF, _APP_OFF + _APP_MAX);
    _set(out, app.app, _APP_OFF);
  } else {
    out = installApp(work, app.app, stubTpl!);
  }
  final map = List<int>.filled(128, 0xFFFF);
  for (var k = 0; k < used.length; k++) {
    final g = used[k], b = free[k];
    map[g] = b;
    out.setRange(b << 16, (b + 1) << 16, fw, g << 16);
  }
  // spares: up to T18_SPARE_WANT, but 4 blocks (256 KB) stay free for the menu's field saves if possible
  final nsp = math.max(_T18_SPARE_MIN, math.min((spares != null && spares != 0) ? spares : _T18_SPARE_WANT, free.length - used.length - 4)); // test25: spares (fewer when the rest does not fit)
  final spare = free.sublist(used.length, math.min(used.length + nsp, free.length));
  const c = _APP_OFF + 0x140;
  if (u32(out, c) != t18Magic) throw EmuError('settings block missing in the program');
  final ad = t18Addrs(fw);
  w32(out, c + 4, 1);
  w32(out, c + 8, _SAVE_OFF);
  w32(out, c + 12, spare.length);
  for (var i = 0; i < 128; i++) {
    out[c + 16 + 2 * i] = map[i] & 255;
    out[c + 17 + 2 * i] = map[i] >> 8;
  }
  _fill(out, 0xFF, c + 272, c + 272 + 2 * _T18_SPARE_MAX);
  for (var i = 0; i < spare.length; i++) {
    out[c + 272 + 2 * i] = spare[i] & 255;
    out[c + 273 + 2 * i] = spare[i] >> 8;
  }
  w32(out, c + 404, ad.idle);
  w32(out, c + 408, ad.soft);
  w32(out, c + 412, ad.dma);
  w32(out, c + 428, ad.param);
  w32(out, c + 432, ad.param == 0xF800D8B4 ? 1 : 0);
  w32(out, c + 416, 0);
  w32(out, c + 420, 0);
  w32(out, c + 424, 0);
  // save area: block map, clock note and session belong to this firmware
  // (the stored map sector points at the blocks: same places needed, not only the same firmware)
  var same = old != null && old.spare.length == spare.length;
  if (same) {
    for (var i = 0; i < 128 && same; i++) {
      if (old.map[i] != map[i]) same = false;
    }
    for (var i = 0; i < spare.length && same; i++) {
      if (old.spare[i] != spare[i]) same = false;
    }
    for (final g in used) {
      if (!same) break;
      final s = _sub(rom, old.map[g] << 16, (old.map[g] + 1) << 16);
      for (var k = 0; k < s.length; k++) {
        if (s[k] != fw[(g << 16) + k]) {
          same = false;
          break;
        }
      }
    }
  }
  if (!same) {
    _fill(out, 0xFF, _SAVE_OFF, _SAVE_END);
  } else {
    _set(out, _sub(rom, _SAVE_OFF, _SAVE_OFF + t18SaveLen), _SAVE_OFF); // (installApp cleared it)
  }
  w32(out, c + 400, _optBits(opt) | (lang == 'en' ? 1 : 0) | (clock == false ? 0 : 2) | (nosess ? _NOSESS : 0) | (hot ? _T18F_HOTWIN | (_T18_HOT_V2 ? _T18F_HOT2 : 0) : 0));
  _t18PutXip(out, app);
  return T18PatchResult(out, used.length, spare.length, hot);
}

/*
 * T18Emu items (1.6.8, test47): MyMeets records ("TAMAGO" files, e.g. tg18_as15003_1.txt) into the TG18 save, as the
 * Android T18Emu does it (Inhalte.kt, TamaSatz.kt; every number there was measured on the device). The save partition
 * starts at guest flash 0x5E0000 (0x220000 bytes). Areas with fixed slot size; a slot shows on the device only with
 * its record AND its counter (92 counters of 2 bits from 0x21E053: at most 3 pieces). The active room: record at
 * 0x0F0000 and the choice byte 0x21E070 = 0 (8 = built-in room). Tamapoints u16 at 0x21E020.
 */
const int _T18I_PART = 0x5E0000, _T18I_CNT = 0x21E053, _T18I_PTS = 0x21E020, _T18I_WP = 0x0F0000, _T18I_WPLEN = 0x4000, _T18I_WPSEL = 0x21E070;
/// 1.7.6 T18_DL: games and destinations (MyMeets/WebMeets, e.g. Magic Hut): two slots of 64 KB at 0x130000 and 0x140000
/// (flash 0x710000/0x720000). The firmware lists a slot when its first word is not 0xFFFFFFFF (0x2012EABE) and shows it at
/// the end of TRAVEL TO OTHER TOWN; visiting copies it to 0x7F0000 and runs it (0x2012EC86). Measured on Fairy (ref).
const bool _T18_DL = true;
const List<int> _T18I_DL = [0x130000, 0x140000];
const int _T18I_DLLEN = 0x10000;

class _T18Area {
  const _T18Area(this.key, this.base, this.step, this.n, this.idx0, this.arts, this.basic);
  final String key;
  final int base, step, n, idx0;
  final List<String> arts;
  final List<int> basic;
}

const List<_T18Area> _T18I_AREAS = [
  _T18Area('food', 0x050000, 0x800, 22, 0, ['meal', 'snack'], [0, 1]),
  _T18Area('item', 0x0A0000, 0x2000, 24, 53, ['item'], [0]),
  _T18Area('acc', 0x060000, 0x2000, 16, 37, ['acc'], []),
];
int _be16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
String _t18iArt(int z) {
  switch (z & 0xFFFFFFFF) {
    case 0x81010101:
      return 'meal';
    case 0x81010102:
      return 'snack';
    case 0x81042A01:
    case 0x81042A03:
      return 'item';
    case 0x81023400:
    case 0x81023500:
      return 'acc';
    case 0x81071F00:
      return 'room';
  }
  if (_T18_DL && (z >> 24) == 0x94) return ((z >> 8) & 0xFF) == 0x5B ? 'game' : 'place'; // 1.7.6 T18_DL: downloaded games and destinations
  if ((z >> 16) == 0x8101) return (z & 0xFF) == 1 ? 'meal' : 'snack'; // derived, not measured (Android T18Emu)
  return '';
}

Rgba? _t18iPics(Uint8List b, int at) {
  if (b.length < at + 2) return null;
  final cnt = _be16(b, at);
  if (cnt < 1 || cnt > 32) return null;
  final p = at + 2;
  if (p + 8 > b.length) return null;
  final ln = _be16(b, p), w = b[p + 2], h = b[p + 3], nf = b[p + 4];
  if (w == 0 || h == 0 || nf == 0 || p + 2 + ln > b.length) return null;
  final np = (w * h) >> 1, pd = p + 2 + ln - np, te = p + 8 + 2 * nf;
  if (pd < te || pd - te > 4) return null;
  final rgba = Uint8List(w * h * 4);
  int at8(int i) => i >= 0 && i < b.length ? b[i] : 0;
  for (var i = 0; i < w * h; i++) {
    final by = at8(pd + (i >> 1)), n = (i & 1) != 0 ? by >> 4 : by & 15;
    if (n >= nf) continue;
    final v = (at8(p + 8 + 2 * n) << 8) | at8(p + 9 + 2 * n), bl = (v >> 11) & 31, gr = (v >> 5) & 63, rt = v & 31; // BGR565
    if (n == 0 && bl == 0 && rt == 0 && gr == 63) continue; // pure green: see-through
    rgba[i * 4] = _clamp8(rt * 255 / 31);
    rgba[i * 4 + 1] = _clamp8(gr * 255 / 63);
    rgba[i * 4 + 2] = _clamp8(bl * 255 / 31);
    rgba[i * 4 + 3] = 255;
  }
  return Rgba(w, h, rgba);
}

/// A TAMAGO record of the TG18: name, kind, catalogue number, price, first picture.
class T18Record {
  T18Record(this.bytes, this.file, this.name, this.readable, this.art, this.target, this.cat, this.price, this.pic, this.model);
  final Uint8List bytes;
  final String file, name, art, model;
  final bool readable;
  final int target, cat, price;
  final Rgba? pic;
}

/// A TAMAGO record: name, kind, catalogue number, price, first picture. null if it is none.
T18Record? _t18iRecord(Uint8List? b) {
  if (b == null || b.length < 0x100 || _str(Uint8List.sublistView(b, 0, 6)) != 'TAMAGO') return null;
  final fileB = StringBuffer();
  for (var i = 0; i < 20; i++) {
    final c = b[52 + i];
    if (c == 0) break;
    if (c >= 32 && c < 127) fileB.writeCharCode(c);
  }
  final file = fileB.toString();
  var name = '', unk = 0;
  for (var i = 0; i < 12; i++) {
    final v = _be16(b, 94 + 2 * i);
    if (v == 0) break;
    final n = v & 0xFF;
    if (n >= 0xE0 && n <= 0xF9) {
      name += String.fromCharCode(65 + n - 0xE0);
    } else if (n >= 0xC6 && n <= 0xCF) {
      name += String.fromCharCode(48 + n - 0xC6);
    } else if (n == 0x6C) {
      name += ' ';
    } else if (n == 0x63 && _T18_DL) {
      name += '★';
    } else {
      unk++;
      name += '?';
    }
  }
  name = name.trim();
  final readable = name.isNotEmpty && unk * 2 <= name.length;
  final z = ((_be16(b, 78) << 16) | _be16(b, 80)) & 0xFFFFFFFF;
  var pic = _t18iPics(b, 0x200);
  if (pic == null && b.length > 0x202) pic = _t18iPics(b, 0x202 + _be16(b, 0x200)); // accessories: a block of its own first
  return T18Record(b, file, readable ? name : file, readable, _t18iArt(z), z, _be16(b, 90), _be16(b, 118), pic, file.split('_')[0].toLowerCase());
}

/// All TAMAGO records in a file (several can be in one).
List<T18Record> t18iScan(Uint8List b) {
  final out = <T18Record>[];
  for (var a = 0; a + 0x60 <= b.length; a++) {
    if (b[a] != 0x54 || b[a + 1] != 0x41 || b[a + 2] != 0x4D || b[a + 3] != 0x41 || b[a + 4] != 0x47 || b[a + 5] != 0x4F || b[a + 6] != 0) continue;
    final dl = _T18_DL && b[a + 0x4E] == 0x94;
    if (b[a + 0x4E] != 0x81 && !dl) continue;
    var len = ((b[a + 0x48] << 24) | (b[a + 0x49] << 16) | (b[a + 0x4A] << 8) | b[a + 0x4B]) & 0xFFFFFFFF;
    if (len < 0x60 || len > 0x1F000 || a + len > b.length) continue;
    var sum = 0;
    for (var i = a; i < a + len - 2; i++) {
      sum = (sum + b[i]) & 0xFFFF;
    }
    if (sum != _be16(b, a + len - 2)) {
      if (!dl || len > _T18I_DLLEN - 2) continue;
      // games and destinations: the sum may sit behind the length (Magic Hut), or not match at all (potion); the code starts at 0xB0
      final e = a + 0xB1 < b.length ? _be16(b, a + 0xB0) : 0;
      if (e < 0x200 || e >= len) continue;
      if (a + len + 2 <= b.length) len += 2;
    }
    final r = _t18iRecord(_slice(b, a, a + len));
    if (r != null) {
      out.add(r);
      a += len - 1;
    }
  }
  return out;
}

int _t18iCount(Uint8List fw, int idx) {
  final v = fw[_T18I_PART + _T18I_CNT + (idx >> 2)];
  return (v >> ((idx & 3) * 2)) & 3;
}

void _t18iSetCount(Uint8List fw, int idx, int c) {
  final o = _T18I_PART + _T18I_CNT + (idx >> 2), s = (idx & 3) * 2;
  fw[o] = ((fw[o] & ~(3 << s)) | ((math.max(0, math.min(3, c)) & 3) << s)) & 255;
}

/// The save exists (the game has run once): the Param block at 0x21E000 is filled
bool _t18iHasSave(Uint8List fw) {
  const o = _T18I_PART + 0x21E000;
  for (var i = 0; i < 0x60; i++) {
    if (fw[o + i] != 0xFF && fw[o + i] != 0) return true;
  }
  return false;
}

/// A slot of an item area of the TG18 save.
class T18Slot {
  T18Slot(this.n, this.rec, this.count, this.basic);
  final int n, count;
  final T18Record? rec;
  final bool basic;
}

/// An item area (food, item, acc, dl) with its slots.
class T18ItemArea {
  T18ItemArea(this.key, this.slots, this.free, {this.noCount = false});
  final String key;
  final List<T18Slot> slots;
  final int free;
  final bool noCount;
}

/// Result of t18Items.
class T18Items {
  T18Items(this.areas, this.room, this.points, this.save);
  final List<T18ItemArea> areas;
  final T18Record? room;
  final int points;
  final bool save;
}

/// Every area with its slots (a slot counts only with record and counter); the room and the Tamapoints.
T18Items t18Items(Uint8List fw) {
  final areas = <T18ItemArea>[];
  for (final A in _T18I_AREAS) {
    final slots = <T18Slot>[];
    for (var n = 0; n < A.n; n++) {
      final o = _T18I_PART + A.base + n * A.step, cnt = _t18iCount(fw, A.idx0 + n);
      final rec = fw[o] == 0x54 ? _t18iRecord(_slice(fw, o, o + A.step)) : null;
      final basic = A.basic.contains(n) && rec != null && rec.cat >= 10000 && rec.cat <= 14999; // the start items: always there
      slots.add(T18Slot(n, rec != null && cnt > 0 && !basic ? rec : null, cnt, basic));
    }
    areas.add(T18ItemArea(A.key, slots, slots.where((x) => x.rec == null && !x.basic).length));
  }
  if (_T18_DL) {
    final slots = <T18Slot>[];
    for (var n = 0; n < _T18I_DL.length; n++) {
      final o = _T18I_PART + _T18I_DL[n];
      final rec = fw[o] == 0x54 ? _t18iRecord(_slice(fw, o, o + _T18I_DLLEN)) : null;
      slots.add(T18Slot(n, rec, 0, false));
    }
    areas.add(T18ItemArea('dl', slots, slots.where((x) => x.rec == null).length, noCount: true));
  }
  const wo = _T18I_PART + _T18I_WP;
  final room = fw[wo] == 0x54 && fw[_T18I_PART + _T18I_WPSEL] == 0 ? _t18iRecord(_slice(fw, wo, wo + _T18I_WPLEN)) : null;
  return T18Items(areas, room, fw[_T18I_PART + _T18I_PTS] | (fw[_T18I_PART + _T18I_PTS + 1] << 8), _t18iHasSave(fw));
}

/// Put a record in: the first free slot of its area (count 1..3), a room becomes the active room.
/// Returns (area, slot) or throws.
(String, int) t18ItemAdd(Uint8List fw, T18Record rec, [int count = 1]) {
  if (!_t18iHasSave(fw)) throw EmuError('no save yet');
  if (rec.art == 'room') {
    if (rec.bytes.length > _T18I_WPLEN) throw EmuError('record too large');
    const o = _T18I_PART + _T18I_WP;
    _fill(fw, 0xFF, o, o + _T18I_WPLEN);
    _set(fw, rec.bytes, o);
    fw[_T18I_PART + _T18I_WPSEL] = 0;
    return ('room', 0);
  }
  if (_T18_DL && (rec.art == 'place' || rec.art == 'game')) {
    if (rec.bytes.length > _T18I_DLLEN) throw EmuError('record too large');
    int cat(int o) => _be16(fw, o + 0x5A);
    final at = [for (final b in _T18I_DL) _T18I_PART + b];
    var n = at.indexWhere((o) => fw[o] == 0x54 && cat(o) == rec.cat); // the same one again: replace it
    if (n < 0) n = at.indexWhere((o) => fw[o] != 0x54 && fw[o] == 0xFF);
    if (n < 0) throw EmuError('full');
    _fill(fw, 0xFF, at[n], at[n] + _T18I_DLLEN);
    _set(fw, rec.bytes, at[n]);
    return ('dl', n);
  }
  _T18Area? A;
  for (final x in _T18I_AREAS) {
    if (x.arts.contains(rec.art)) {
      A = x;
      break;
    }
  }
  if (A == null) throw EmuError('unknown kind');
  if (rec.bytes.length > A.step) throw EmuError('record too large');
  final key = A.key;
  final it = t18Items(fw).areas.firstWhere((x) => x.key == key);
  T18Slot? s;
  for (final x in it.slots) {
    if (x.rec == null && !x.basic) {
      s = x;
      break;
    }
  }
  if (s == null) throw EmuError('full');
  final o = _T18I_PART + A.base + s.n * A.step;
  _fill(fw, 0xFF, o, o + A.step);
  _set(fw, rec.bytes, o);
  _t18iSetCount(fw, A.idx0 + s.n, count != 0 ? count : 1);
  return (A.key, s.n);
}

void t18ItemDel(Uint8List fw, String key, int n) {
  if (_T18_DL && key == 'dl') {
    final o = _T18I_PART + _T18I_DL[n];
    _fill(fw, 0xFF, o, o + _T18I_DLLEN);
    return;
  }
  final A = _T18I_AREAS.firstWhere((x) => x.key == key);
  final o = _T18I_PART + A.base + n * A.step;
  _fill(fw, 0xFF, o, o + A.step);
  _t18iSetCount(fw, A.idx0 + n, 0);
}

void t18ItemCount(Uint8List fw, String key, int n, int c) {
  final A = _T18I_AREAS.firstWhere((x) => x.key == key);
  if (fw[_T18I_PART + A.base + n * A.step] == 0x54) _t18iSetCount(fw, A.idx0 + n, c);
}

void t18RoomReset(Uint8List fw) {
  const o = _T18I_PART + _T18I_WP;
  _fill(fw, 0xFF, o, o + _T18I_WPLEN);
  fw[_T18I_PART + _T18I_WPSEL] = 8;
}

void t18Points(Uint8List fw, int v) {
  v = math.max(0, math.min(65535, v.toSigned(32)));
  fw[_T18I_PART + _T18I_PTS] = v & 0xFF;
  fw[_T18I_PART + _T18I_PTS + 1] = v >> 8;
}

/*
 * 1.6.8 (test47): changed sectors of the guest flash (items) into an installed T18Emu, the way the device keeps them:
 * a mapped block (save map "T8MP" or the settings) gets them in place; a sector of an empty block goes to its entry
 * of the sector table ("T8SS", T18_SEC_SPARE) or a new pool sector (spare block k >> 4, sector k & 15; spare blocks
 * used whole are skipped). The layout stays, only the running state (session) is dropped: the game starts from its
 * own save. Throws when there is no room.
 */
Uint8List t18RomWriteGuest(Uint8List rom, Uint8List fw, [int base = _APP_OFF]) {
  final c = t18Cfg(rom, base);
  if (c == null) throw EmuError('T18Emu not installed');
  final out = _copy(rom), so = c.saveOff;
  const SROWS = 19;
  final SOFF = so + 4 + 256 + _T18_SPARE_MAX;
  final old = t18FromRom(rom, base);
  if (old == null) throw EmuError('T18Emu not complete');
  var map = c.map;
  final used = List<int>.filled(_T18_SPARE_MAX, 0);
  final hasMap = _u32s(out, so) == 0x504D3854;
  if (hasMap) {
    map = [];
    for (var i = 0; i < 128; i++) {
      map.add(out[so + 4 + 2 * i] | (out[so + 5 + 2 * i] << 8));
    }
    for (var i = 0; i < _T18_SPARE_MAX; i++) {
      used[i] = out[so + 4 + 256 + i];
    }
  }
  final idx = Uint8List(128), rows = [for (var r = 0; r < SROWS; r++) Uint8List(16)];
  if (hasMap && u32(out, SOFF) == 0x53533854) {
    for (var i = 0; i < 128; i++) {
      idx[i] = out[SOFF + 4 + i] <= SROWS ? out[SOFF + 4 + i] : 0;
    }
    for (var r = 0; r < SROWS; r++) {
      _set(rows[r], _sub(out, SOFF + 132 + 16 * r, SOFF + 148 + 16 * r), 0);
    }
  }
  final inUse = <int>{};
  for (var r = 0; r < SROWS; r++) {
    if (idx.contains(r + 1)) {
      for (final k in rows[r]) {
        if (k != 0) inUse.add(k - 1);
      }
    }
  }
  var tables = false;
  for (var sec = 0; sec < 0x800000; sec += 0x1000) {
    if (_eqAt(fw, sec, old, sec, 0x1000)) continue;
    final b = sec >> 16, s = (sec >> 12) & 15, data = _sub(fw, sec, sec + 0x1000);
    if (map[b] != 0xFFFF) {
      _set(out, data, (map[b] << 16) | (s << 12));
      continue;
    }
    var i = idx[b];
    if (i == 0) {
      var r = 0;
      while (r < SROWS && idx.contains(r + 1)) {
        r++;
      }
      if (r >= SROWS) throw EmuError('no room for more save data');
      idx[b] = i = r + 1;
      rows[r].fillRange(0, 16, 0);
      tables = true;
    }
    var k = rows[i - 1][s];
    if (k == 0) {
      var p = -1;
      for (var q = 0; q < math.min(c.spare.length * 16, 254); q++) {
        if (used[q >> 4] == 0 && !inUse.contains(q)) {
          p = q;
          break;
        }
      }
      if (p < 0) throw EmuError('no room for more save data');
      inUse.add(p);
      rows[i - 1][s] = k = p + 1;
      tables = true;
    }
    k--;
    final sb = (k >> 4) < c.spare.length ? c.spare[k >> 4] : 0;
    _set(out, data, ((sb << 16) | ((k & 15) << 12)).toSigned(32));
  }
  if (tables) {
    if (!hasMap) {
      _fill(out, 0xFF, so, so + 0x1000);
      w32(out, so, 0x504D3854);
      for (var j = 0; j < map.length; j++) {
        out[so + 4 + 2 * j] = map[j] & 255;
        out[so + 5 + 2 * j] = map[j] >> 8;
      }
      for (var j = 0; j < _T18_SPARE_MAX; j++) {
        out[so + 4 + 256 + j] = used[j];
      }
    }
    w32(out, SOFF, 0x53533854);
    _set(out, idx, SOFF + 4);
    for (var r = 0; r < SROWS; r++) {
      _set(out, rows[r], SOFF + 132 + 16 * r);
    }
  }
  _fill(out, 0xFF, so + 0x2000, so + 0x3000); // session header: the game starts from its own save
  return out;
}

/*
 * 1.6.8 (test47): pictures for "grow up" on the device, from the user's own files (the Studio has none). One per adult,
 * 64x64 with up to 256 colours, at 0x0E4000 behind the T18 save area ("T8PI": magic, count, then per picture: id,
 * 3 bytes 0, 256 colours RGB565, 4096 indices). The settings get its place at +436.
 */
const int _T18_PIC_OFF = 0xE4000, _T18_PIC_END = 0xF0000, _T18_PIC_SZ = 4 + 512 + 4096;
const List<(int, String)> t18Adults = [
  (16, 'Mametchi'), (17, 'Kuchipatchi'), (20, 'Kikitchi'), (25, 'Kuromametchi'), (24, 'Gozarutchi'), (19, 'Lovelitchi'), //
  (23, 'Nijifuwatchi'), (35, 'Pompomtchi'), (18, 'Memetchi'), (22, 'Watawatatchi'), (21, 'Flowertchi'),
];
int t18AdultFind(String name) {
  final n = name.toLowerCase().replaceFirst(RegExp(r'\.[a-z]+$'), '').replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (RegExp(r'^\d+$').hasMatch(n)) {
    final id = double.parse(n);
    return t18Adults.any((a) => a.$1 == id) ? id.toInt() : -1;
  }
  for (final (id, nm) in t18Adults) {
    if (n.contains(nm.toLowerCase())) return id;
  }
  return -1;
}

/// an image (any size) to 64x64, palette of up to 256 RGB565 colours
Uint8List t18PicMake(Rgba img) {
  final px = Uint16List(64 * 64);
  int at(int o) => o >= 0 && o < img.data.length ? img.data[o] : 0;
  for (var y = 0; y < 64; y++) {
    for (var x = 0; x < 64; x++) {
      final x0 = x * img.w ~/ 64, x1 = math.max(x0 + 1, (x + 1) * img.w ~/ 64), y0 = y * img.h ~/ 64, y1 = math.max(y0 + 1, (y + 1) * img.h ~/ 64);
      var r = 0, g = 0, b = 0, n = 0;
      for (var yy = y0; yy < y1; yy++) {
        for (var xx = x0; xx < x1; xx++) {
          final o = (yy * img.w + xx) * 4;
          r += at(o);
          g += at(o + 1);
          b += at(o + 2);
          n++;
        }
      }
      r ~/= n;
      g ~/= n;
      b ~/= n;
      px[y * 64 + x] = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
    }
  }
  for (final m in const [0xFFFF, 0xF79E, 0xE71C, 0xC618]) {
    final pal = <int, int>{};
    var ok = true;
    for (final v in px) {
      final c = v & m;
      if (!pal.containsKey(c)) {
        if (pal.length == 256) {
          ok = false;
          break;
        }
        pal[c] = pal.length;
      }
    }
    if (!ok) continue;
    final out = Uint8List(_T18_PIC_SZ - 4);
    pal.forEach((c, i) {
      out[2 * i] = c & 255;
      out[2 * i + 1] = c >> 8;
    });
    for (var i = 0; i < 4096; i++) {
      out[512 + i] = pal[px[i] & m]!;
    }
    return out;
  }
  throw EmuError('too many colours');
}

/// pictures (Map id -> 4608 bytes from t18PicMake) into the ROM of an installed T18Emu (main program)
Uint8List t18PicsWrite(Uint8List rom, Map<int, Uint8List> pics) {
  const c = _APP_OFF + 0x140;
  if (u32(rom, c) != t18Magic) return rom;
  final out = _copy(rom);
  _fill(out, 0xFF, _T18_PIC_OFF, _T18_PIC_END);
  final sanrio = (u32(rom, c + 432) & 1) != 0;
  final ids = t18Adults.map((a) => a.$1).where((id) => pics.containsKey(id) && id != (sanrio ? 35 : 21)).take(10).toList();
  if (ids.isEmpty) {
    w32(out, c + 436, 0);
    return out;
  }
  w32(out, _T18_PIC_OFF, 0x49503854);
  w32(out, _T18_PIC_OFF + 4, ids.length);
  for (var k = 0; k < ids.length; k++) {
    final o = _T18_PIC_OFF + 16 + k * _T18_PIC_SZ;
    _fill(out, 0, o, o + 4);
    out[o] = ids[k];
    _set(out, pics[ids[k]]!, o + 4);
  }
  w32(out, c + 436, _T18_PIC_OFF);
  return out;
}

Map<int, Uint8List> t18PicsRead(Uint8List rom) {
  final m = <int, Uint8List>{};
  if (u32(rom, _APP_OFF + 0x140) != t18Magic || u32(rom, _T18_PIC_OFF) != 0x49503854) return m;
  final n = math.min(u32(rom, _T18_PIC_OFF + 4), 10);
  for (var k = 0; k < n; k++) {
    final o = _T18_PIC_OFF + 16 + k * _T18_PIC_SZ;
    m[rom[o]] = _slice(rom, o + 4, o + _T18_PIC_SZ);
  }
  return m;
}

/// for showing: RGBA of a stored picture
Rgba t18PicRgba(Uint8List p) {
  final rgba = Uint8List(64 * 64 * 4);
  for (var i = 0; i < 4096; i++) {
    final k = p[512 + i], v = p[2 * k] | (p[2 * k + 1] << 8);
    rgba[4 * i] = _clamp8((v >> 11) * 255 / 31);
    rgba[4 * i + 1] = _clamp8(((v >> 5) & 63) * 255 / 63);
    rgba[4 * i + 2] = _clamp8((v & 31) * 255 / 31);
    rgba[4 * i + 3] = 255;
  }
  return Rgba(64, 64, rgba);
}

/// The flash part of the program at T18_XIP_OFF
void _t18PutXip(Uint8List out, T18App? app) {
  if (!_t18XipOk(app)) throw EmuError('T18Emu program incomplete (flash part missing)');
  _fill(out, 0xFF, t18XipOff, t18XipOff + _T18_XIP_MAX);
  _set(out, app!.xip!, t18XipOff);
  if (u32(out, _APP_OFF + 0x140) == t18Magic && (u32(out, _APP_OFF + 0x140 + 400) & _T18F_HOTWIN) != 0) {
    _fill(out, 0xFF, 0xFD0000, 0xFF0000);
    _set(out, app.xip!, _T18_XIP_HOT);
  }
}

/// Newer T18 program into a ROM that already has T18Emu: settings (block map) stay. null if nothing to do.
/// Before 1.5.1 the clock switch did not exist: it is switched on then.
Uint8List? t18Upgrade(Uint8List rom, T18App app, [Uint8List? stubTpl]) {
  if (u32(rom, _APP_OFF + 0x140) != t18Magic) return null;
  // 1.6.6: a ROM without the hot window gets it when there is room. The firmware comes from the ROM as the
  // device last saw it (the block map in the save area holds the blocks the firmware wrote), so the pet stays;
  // only the running session starts anew.
  // test10: a hot window with the first block list gets the new one (same way, the pet stays)
  final fl0 = u32(rom, _APP_OFF + 0x140 + 400);
  if (stubTpl != null && ((fl0 & _T18F_HOTWIN) == 0 || (_T18_HOT_V2 && (fl0 & _T18F_HOT2) == 0))) {
    final fw = t18FromRom(rom);
    if (fw != null) {
      final fl = u32(rom, _APP_OFF + 0x140 + 400);
      try {
        final r = t18Patch(rom, fw, app, stubTpl, lang: (fl & 1) != 0 ? 'en' : 'de', clock: (fl & 2) != 0);
        if (r.hot) return r.rom;
      } catch (_) {
        /* stays as it is */
      }
    }
  }
  final a = _copy(app.app);
  if (u32(a, 0x140) != t18Magic) return null;
  _set(a, _sub(rom, _APP_OFF + 0x140, _APP_OFF + 0x140 + 428), 0x140);
  {
    final fw = t18FromRom(rom);
    if (fw != null) _t18ParamSet(a, 0x140, fw); // test47: the Param block (grow up)
  }
  final hotw = (u32(rom, _APP_OFF + 0x140 + 400) & _T18F_HOTWIN) != 0;
  final xipSame = _t18XipOk(app) && _eqAt(rom, t18XipOff, app.xip!, 0, app.xip!.length) && (!hotw || _eqAt(rom, _T18_XIP_HOT, app.xip!, 0, app.xip!.length));
  if (!xipSame) a[0x140 + 400] |= 2;
  if (xipSame && _sameProgram(rom, a)) return null;
  final out = _copy(rom);
  _fill(out, 0x00, _APP_OFF, _APP_OFF + _APP_MAX);
  _set(out, a, _APP_OFF);
  _t18PutXip(out, app);
  return out;
}

/// The TG18 firmware as the ROM holds it: the block map of the save area (blocks the firmware wrote)
/// or the one of the settings. null if it is not complete.
Uint8List? t18FromRom(Uint8List rom, [int base = _APP_OFF]) {
  final c = t18Cfg(rom, base);
  if (c == null) return null;
  var map = c.map;
  var own = false;
  final so = c.saveOff;
  if (so + 0x1000 <= rom.length && u32(rom, so) == 0x504D3854) {
    own = true;
    map = [];
    for (var i = 0; i < 128; i++) {
      map.add(rom[so + 4 + 2 * i] | (rom[so + 5 + 2 * i] << 8));
    }
  }
  final fw = _ff(0x800000);
  for (var g = 0; g < 128; g++) {
    final b = map[g];
    if (b != 0xFFFF && b < 0x100) _set(fw, _sub(rom, b << 16, (b + 1) << 16), g << 16);
  }
  // test45 (T18_SEC_SPARE): single 4 KB sectors of empty guest blocks from the spare blocks ("T8SS" behind the map)
  final o = so + 4 + 256 + _T18_SPARE_MAX;
  if (own && o + 132 + 16 * 19 <= rom.length && u32(rom, o) == 0x53533854) {
    for (var g = 0; g < 128; g++) {
      final i = rom[o + 4 + g];
      if (i == 0 || i > 19 || map[g] != 0xFFFF) continue;
      for (var sct = 0; sct < 16; sct++) {
        var k = rom[o + 132 + 16 * (i - 1) + sct];
        if (k == 0) continue;
        k--;
        if ((k >> 4) >= c.spare.length) continue;
        final b = c.spare[k >> 4];
        if (b == 0xFFFF) continue;
        final p = (b << 16) | ((k & 15) << 12);
        _set(fw, _sub(rom, p, p + 0x1000), (g << 16) | (sct << 12));
      }
    }
  }
  return t18Detect(fw) ? fw : null;
}

/*
 * More programs (1.6.0): besides the program at 0x0A0000 (started by A+C or by the menu) the menu can
 * start more programs, each a full 64 KB PRAM image somewhere in the flash (started through the stub
 * entry at +0x0C). For now: T7Emu with its own ROM (Tama-Go or Friends), no figures. Placed from the
 * top of the emulator area (0xD40000) down, each in its own block: image (64 KB), save (24 KB), ROM.
 * The menu lists them (settings block version 5, see feld.js).
 */
const int appxMax = 12, t7xSave = 0x6000; // 1.6.8: 12 (menu version 8)

/// Volume, brightness and screen-off time of TamaEmu and T18Emu.
class EmuOpt {
  const EmuOpt({this.vol = 0, this.dim = 0, this.off = 0});
  final int vol, dim, off;
}

/// An extra program for the menu (appsPlace) or one read back (appsRead).
/// T7Emu: rom (+ figs); 'v1': rom; 'tama': guest, dev; 't18': fw; 'gb', 'sms', 'pm', 'ab': rom; 'wolf': pack;
/// 'doom': mcu.
class Extra {
  Extra({this.kind, this.rom, this.guest, this.dev, this.fw, this.pack, this.mcu, this.figs, this.keys, this.keyMap, this.save, this.bios, this.title, this.name,
      this.inv = false, this.gg = false, this.clock, this.nfc, this.sess, this.opt, this.packed = false, this.lzAll = false, this.lzExtra, this.keepOff, this.items = false,
      this.region, this.size, this.ep, this.d2 = false, this.off = 0, this.saveOff = 0});
  String? kind;
  Uint8List? rom; // T7Emu, V1Emu, V3Emu, Game Boy, Master System, Pokemon mini, Arduboy: the ROM or game
  Uint8List? guest; // TamaEmu: the colour Tama firmware
  String? dev; // TamaEmu: 'pc', 'idl', 'ps', '4u', '4u-plain'
  Uint8List? fw; // T18Emu: the TG18 firmware
  Uint8List? pack; // Wolf3D: the data pack
  Uint8List? mcu; // DOOM: the converted WAD
  List<T7Fig>? figs; // T7Emu
  List<int>? keys; // gb, sms, pm, ab: 9 key masks
  Map<String, Object>? keyMap; // wolf, doom: the keys by name (JS: keys)
  Uint8List? save, bios;
  String? title, name;
  bool inv, gg;
  bool? clock, nfc, sess;
  EmuOpt? opt;
  bool packed; // TamaEmu: "Pack the firmware" (JS: pack)
  bool lzAll; // tests only
  List<int>? lzExtra; // tests only
  int? keepOff; // T18Emu: an installed one stays where it is
  bool items; // T18Emu (keepOff): write the changed guest sectors (items)
  int? region, size; // DOOM
  Object? ep; // DOOM: episode ('all', a number)
  bool d2; // DOOM II
  int off, saveOff; // from appsRead
}

String t7XName(Uint8List? rom) => t7Kind(rom) == 'friends' ? 'FRIENDS' : 'TAMA-GO';

/// Reserved by the program at 0x0A0000 although empty (spares): [from, to) ranges.
List<(int, int)> appReserved(Uint8List rom) {
  final r = <(int, int)>[], m = _u32s(rom, _APP_OFF + 0x140);
  if (m == t18Magic) {
    final c = t18Cfg(rom)!;
    for (final b in [...c.map, ...c.spare]) {
      if (b != 0xFFFF) r.add((b << 16, (b + 1) << 16));
    }
    if ((c.flags & _T18F_HOTWIN) != 0) r.add((0xFD0000, 0xFF0000));
  }
  if (m == _PMXC && u32(rom, _APP_OFF + 0x144) >= 3) {
    final g = u32(rom, _APP_OFF + 0x148);
    r.add((g, math.max(g, u32(rom, _APP_OFF + 0x140 + 152))));
  }
  // 1.6.8: the save areas behind the program (empty until used)
  if (m == _PMXC) r.add((_SAVE_OFF, _SAVE_END));
  if (m == t7Magic) r.add((_SAVE_OFF, _SAVE_OFF + 0x6000));
  if (m == v1Magic) r.add((_SAVE_OFF, _SAVE_OFF + 0x2000));
  if (m == t18Magic) r.addAll([(_SAVE_OFF, _SAVE_OFF + t18SaveLen), (t18XipOff, t18XipOff + _T18_XIP_MAX), (_T18_PIC_OFF, _T18_PIC_END)]);
  return r;
}

/*
 * 1.6.8: besides T7Emu the extra programs can be TamaEmu (a colour Tama firmware) and T18Emu (one only, its
 * flash part has a fixed place at T18_XIP_OFF). An extra is { rom } (T7), { kind: 'tama', guest, dev } or
 * { kind: 't18', fw }. Each brings its own 64 KB image (settings block inside) and its own save area:
 *   T7Emu:   image, save (64 KB, 24 KB used), ROM                      (one piece, as before)
 *   TamaEmu: packed firmware with room for spare pages (256 KB aligned, it is the base of the cached
 *            window), then image and run state (320 KB, like 0x0C0000..0x110000)
 *   T18Emu:  firmware blocks anywhere (block map), image, save (T18_SAVE_LEN)
 */
const int _TX_STATE = 0x50000, _TX_SPARE = 0x90000, _T18X_SAVE = (t18SaveLen + 0xFFFF) & ~0xFFFF;
const Map<String, String> _TX_NAMES = {'pc': 'PLUS COLOR', 'idl': 'ID L', 'ps': 'PS', '4u': '4U+', '4u-plain': '4U'};
/* GUEST_SPARSE: the room for spare pages grows by the firmware's own pages (the pool for the guest's writes stays as it
 * was, 64 pages at most) */
int _txSpare(PackedGuest pk, int? txs) {
  final t = (txs != null && txs != 0) ? txs : _TX_SPARE, np = pk.pages.length;
  return np != 0 ? math.max(t, math.min(t + (np << 13), 0x84000)) : t;
}

String extraKind(Extra x) => (x.kind != null && x.kind!.isNotEmpty) ? x.kind! : (v1Detect(x.rom) ? 'v1' : 't7');

/// DOOM_FREE: room of DOOM in the menu: program with its part and save (64 KB aligned), WAD with the level data behind
class DoomParts {
  DoomParts(this.prog, this.wad);
  final int prog, wad;
}

DoomParts doomParts(Extra x, [int? xipLen]) {
  int page(int n) => (n + 0xFFF) & ~0xFFF;
  int blk(int n) => (n + 0xFFFF) & ~0xFFFF;
  final n = x.mcu != null ? x.mcu!.length : ((x.size != null && x.size != 0) ? x.size! : 0x300000);
  return DoomParts(blk(0x10000 + page((xipLen != null && xipLen != 0) ? xipLen : 0x3A000) + _DOOM_SAVE + (_DOOM_CMAP ? 0x3000 : 0)), blk(page(4 + n) + _doomRegion(x)));
}

/* 1.6.8: iD L versions by their reset vector (all run as iD L): Japanese 1.0, English, 15th anniversary, Princess Spacy */
const Map<int, String> _IDL_NAMES = {0x024CA8FE: 'ID L JP', 0x024CA942: 'ID L JP', 0x024CAA72: 'ID L', 0x024BD18A: 'ID L 15TH', 0x024C14F6: 'ID L SPACY'};
String tamaName(Uint8List? guest, String? dev) {
  if (dev == 'idl' && guest != null && guest.length >= 0x400004) {
    final n = _IDL_NAMES[u32(guest, 0x400000)];
    if (n != null) return n;
  }
  if (dev == 'pc' && _idFirmware(guest)) return 'ID'; // 1.7.4 test2
  return _TX_NAMES[dev] ?? 'TAMAEMU';
}

String extraName(Extra x) {
  final k = extraKind(x);
  switch (k) {
    case 'doom':
      if (x.title != null && x.title!.isNotEmpty) return x.title!;
      final ep = x.ep;
      if (ep != null && ep != 0 && ep != '' && ep != false && ep != 'all') return 'DOOM E$ep';
      if (x.d2) return 'DOOM II';
      return x.name != null && x.name!.isNotEmpty && RegExp(r"^[A-Z0-9 .'!-]{1,16}$").hasMatch(x.name!) ? x.name! : 'DOOM';
    case 'tama':
      return tamaName(x.guest, x.dev);
    case 't18':
      return 'TAMA MEETS';
    case 'v1':
      return v1Name(x.rom!);
    case 'gb':
      return gbTitle(x.rom!);
    case 'sms':
      return _or(x.title, 'MASTER SYSTEM');
    case 'pm':
      return _or(x.title, 'POKEMON MINI');
    case 'ab':
      return _or(x.title, 'ARDUBOY');
    case 'wolf':
      return wolfSod(x.pack) ? 'SPEAR OF DESTINY' : 'WOLFENSTEIN 3D';
    default:
      return t7XName(x.rom);
  }
}

/// Rough flash use of an extra (for the overview)
const bool _SIZE_CACHE = true;
final Expando<Map<String, Object>> _sizeCache = Expando();
int extraSize(Extra x, [int? txs]) {
  final k = extraKind(x);
  if (k == 'tama') {
    // 1.7.2 SIZE_CACHE: packing takes up to half a second; the firmware arrays are new ones whenever they change
    final ck = '${txs ?? 0}:${x.dev}${x.packed ? ':z' : ''}', hit = _SIZE_CACHE && x.guest != null ? _sizeCache[x.guest!] : null;
    if (hit != null && hit[ck] != null) return hit[ck]! as int;
    // TAMA_RAW (test18): the size as it goes in when there is room (unpacked)
    var n = 0;
    try {
      final pk = packGuest(x.guest!, x.dev!,
          sparse: true, lz: guestLz && (packOpt ? x.packed || (!packAsk && tamaNeedsLz(x.guest!, x.dev!, menuRoom ? menuRoomLen : null)) : !_TAMA_RAW), room: menuRoom ? menuRoomLen : null);
      n = ((pk.blob.length + _txSpare(pk, txs) + 0xFFFF) & ~0xFFFF) + 0x10000 + _TX_STATE;
    } catch (_) {
      n = 0;
    }
    if (_SIZE_CACHE && x.guest != null) {
      final m = hit ?? <String, Object>{};
      m[ck] = n;
      _sizeCache[x.guest!] = m;
    }
    return n;
  }
  if (k == 'v1') return v3Detect(x.rom) ? 0x92000 : 0x12000 + x.rom!.length;
  if (k == 'gb') return ((_gbStore(x.rom!).rom.length + 0xFFFF) & ~0xFFFF) + 0x10000 + _gbSaveLen(gbIsColor(x.rom!));
  if (k == 'sms') return ((x.rom!.length + 0xFFFF) & ~0xFFFF) + 0x20000;
  if (k == 'pm') return ((x.rom!.length + 0xFFFF) & ~0xFFFF) + 0x10000 + pmSave;
  if (k == 'ab') return 0x20000;
  if (k == 'wolf') return ((x.pack!.length + 0xFFFF) & ~0xFFFF) + 0x30000;
  if (k == 'doom') {
    final p = doomParts(x);
    return p.prog + p.wad;
  }
  if (k == 't18') {
    var n = 0;
    for (var i = 0; i < 128; i++) {
      if (!_isFF(x.fw!, i << 16, 0x10000)) n++;
    }
    return (n + _T18_SPARE_WANT) * 0x10000 + 0x10000 + _T18X_SAVE;
  }
  var n = 0x20000 + ((x.rom!.length + 0xFFFF) & ~0xFFFF);
  for (final f in x.figs ?? const <T7Fig>[]) {
    n += (f.data.length + 0xFFF) & ~0xFFF;
  }
  return n;
}

/// Result of appsPlace: the new image, the programs for the menu (in the order of the extras), the lowest
/// offset used, the flash app's address (dl, 0: none) and the room left.
class AppsPlaced {
  AppsPlaced(this.rom, this.list, this.low, this.dl, this.freeKB);
  final Uint8List rom;
  final List<AppEntry> list;
  final int low, dl, freeKB;
}

/// Put the extra programs into rom. app: the embedded programs.
/// launch (launcher ROM: anywhere free behind the setup pictures), keep: more [from, to)
/// ranges that must stay free (DOOM's data area). Returns { rom, list: [{ src, name, off }], low }.
/* 1.6.10 test3 APPS_PACK: start device: the biggest programs first, each into the highest gap that fits (before: one
 * after the other below the lowest one, gaps above stayed empty); Game Boy and Master System games apart from their
 * program. The list keeps its order. */
const bool _APPS_PACK = true;
/* test13: the rescue block (0xFF0000) is kept free only when everything fits without it */
/* test15: no longer only when it fits: the block is the write protection, the Studio does not write without it */
/* 1.7.3 test18 TAMA_RAW, test20 PACK_OPT: a TamaEmu goes in unpacked unless its option "pack" (x.packed) is on (Bernd: iD L
 * slow in the restaurant, its pictures sat in packed 1 KB parts that the device unpacks on every read). When the
 * programs do not fit, the error says whether packing a TamaEmu could help (e.packHint). */
const bool _TAMA_RAW = true, packOpt = true, _DOOM_TOP = true;
AppsPlaced appsPlace(Uint8List rom, List<Extra> extras, EmuApps app,
    {bool clean = false, bool launch = false, List<(int, int)>? keep, String? lang, bool? clock, bool? nfc, bool noClock = false, int? txSpare, bool noResv = false, bool doomTop = false,
    Uint8List? dlApp, bool? t18More, bool tamaRaw = false}) {
  _clean = clean;
  AppsPlaced go(bool top) => _appsPlace0(rom, extras, app,
      clean: clean, launch: launch, keep: keep, lang: lang, clock: clock, nfc: nfc, noClock: noClock, txSpare: txSpare, noResv: noResv, doomTop: top, dlApp: dlApp, t18More: t18More, tamaRaw: tamaRaw);
  try {
    try {
      return go(doomTop);
    } catch (e) {
      // 1.7.3 test21 DOOM_TOP: the WADs from the top down, one after the other (the 4 MB rule can split the room)
      if (!(_DOOM_TOP && e is EmuError && e.room && clean && !doomTop && extras.where((x) => extraKind(x) == 'doom').length > 1)) rethrow;
      try {
        return go(true);
      } catch (_) {
        throw e;
      }
    }
  } on EmuError catch (e) {
    if (e.room && extras.any((x) => extraKind(x) == 'tama' && !x.packed)) e.packHint = true;
    rethrow;
  } finally {
    _clean = false;
  }
}

AppsPlaced _appsPlace0(Uint8List rom, List<Extra> extras, EmuApps apps,
    {required bool clean, required bool launch, List<(int, int)>? keep, String? lang, bool? clock, bool? nfc, required bool noClock, int? txSpare, required bool noResv, required bool doomTop,
    Uint8List? dlApp, bool? t18More, required bool tamaRaw}) {
  final out = _copy(rom), list = <AppEntry>[], listXi = <int>[], res = [...appReserved(out), ...?keep];
  if (extras.length > appxMax) throw EmuError('at most $appxMax more programs');
  var top = _GUEST_END;
  // launcher ROM (1.6.8): anywhere free between the setup pictures and 0xD40000, from the top down
  final floor = clean
      ? 0x10000
      : launch
          ? math.max(0x200000, _and32(_assetEnd(out) + 0xFFFF, ~0xFFFF))
          : _GUEST_OFF;
  final neon = !clean && neonRom(out);
  final ceil = clean
      ? 0xFF0000
      : neon
          ? _NEON_TOP
          : launch
              ? math.min(_GUEST_END, _idPageOf(out))
              : _GUEST_END; // never into the Paradise's save (Tropical/Glacier: from 0xD29000)
  if (launch || neon) top = ceil;
  bool taken(int at, int size) {
    for (final (a, b) in res) {
      if (a < at + size && b > at) return true;
    }
    return false;
  }

  bool fits(int at, int size) => at >= floor && at + size <= ceil && _isFF(out, at, size) && !taken(at, size);
  int find(int size, int align) {
    var at = ((_APPS_PACK && launch ? ceil : top) - size) & ~(align - 1);
    if (launch || (_NEON_HI && neon) || align > 0x10000) {
      while (at >= floor && !fits(at, size)) {
        at -= align;
      }
    }
    return fits(at, size) ? at : -1;
  }

  // start device (1.6.8): the Paradise never writes behind its save (0xF00000..0xFFFFFF); without T18Emu (it takes that
  // MB itself) programs that fit go there first
  // NEON_HI: Neon Planets has no field saves, the MB behind its save is free for programs also without a start device
  final hiOk = (launch || (_NEON_HI && neon)) && !clean && !extras.any((x) => extraKind(x) == 't18') && u32(out, _APP_OFF + 0x140) != t18Magic;
  final hiEnd = _RESCUE_RES && !noResv ? _RESCUE_BLK << 16 : 0x1000000; // test13: the rescue start's block stays free
  bool fitsHi(int at, int size) => at >= 0xF00000 && at + size <= hiEnd && _isFF(out, at, size) && !taken(at, size);
  int findHi(int size, int align) {
    if (!hiOk) return -1;
    var at = (hiEnd - size) & ~(align - 1);
    while (at >= 0xF00000 && !fitsHi(at, size)) {
      at -= align;
    }
    return fitsHi(at, size) ? at : -1;
  }

  (int, bool) place(int size, int align) {
    final h = findHi(size, align);
    return h >= 0 ? (h, true) : (find(size, align), false);
  }

  // DOOM_LINK: linked DOOM entries after the entries they point into
  final dLinks = _DOOM_LINK && clean ? doomLinks(extras) : <Extra, DoomLink>{};
  final wadAt = <Extra, int>{};
  final kept = <Extra>{};
  late final Set<int> left;

  // 1.6.8: no room: how much is missing for this program and the ones after it (not just the name of the one that hit it)
  int freeKB() {
    var n = 0;
    for (var a = floor; a + 0x10000 <= ceil; a += 0x10000) {
      if (fits(a, 0x10000)) n++;
    }
    if (hiOk) {
      for (var a = 0xF00000; a < hiEnd; a += 0x10000) {
        if (fitsHi(a, 0x10000)) n++;
      }
    }
    return n * 64;
  }

  EmuError noRoom(int i) {
    var need = dlApp != null ? 0x10000 : 0;
    for (var j = 0; j < extras.length; j++) {
      if (left.contains(j) && !kept.contains(extras[j])) need += extraSize(extras[j], txSpare) - (dLinks[extras[j]]?.saved ?? 0);
    }
    final short = ((need / 1024 - freeKB()) / 64).ceil() * 64, miss = math.max(64, short);
    // 1.7.3 test13: frag: the room adds up, but not in pieces big enough (DOOM episodes need up to 8 MB in one window)
    return EmuError('no room: about $miss KB missing', room: true, missing: miss, frag: short <= 0);
  }

  // test2: an installed T18Emu (keepOff) stays where it is: its save grows while it runs, so placing it anew may no
  // longer fit. Its blocks are taken first; the program, its settings and the items are renewed in place below.
  for (final x in extras) {
    if (extraKind(x) != 't18' || x.keepOff == null || !_t18XipOk(apps.t18)) continue;
    final c = t18Cfg(out, x.keepOff!);
    if (c == null) continue;
    kept.add(x);
    for (final b in [...c.map, ...c.spare]) {
      if (b != 0xFFFF) res.add((b << 16, (b + 1) << 16));
    }
    res.add((t18XipOff, t18XipOff + _T18_XIP_MAX));
    if ((c.flags & _T18F_HOTWIN) != 0) res.add((0xFD0000, 0xFF0000));
    res.addAll([(x.keepOff!, x.keepOff! + 0x10000), (c.saveOff, c.saveOff + _T18X_SAVE)]);
  }
  final pack = _APPS_PACK && launch;
  var order = [for (var i = 0; i < extras.length; i++) i];
  if (pack) {
    _sort<int>(order, (a, b) {
      final ka = (kept.contains(extras[b]) ? 1 : 0) - (kept.contains(extras[a]) ? 1 : 0);
      if (ka != 0) return ka;
      final s = extraSize(extras[b]) - extraSize(extras[a]);
      return s != 0 ? s : a - b;
    });
  }
  if (dLinks.isNotEmpty) {
    final late_ = order.where((i) => dLinks.containsKey(extras[i])).toList();
    order = [...order.where((i) => !dLinks.containsKey(extras[i])), ...late_];
  }
  left = order.toSet();
  for (final xi in order) {
    final x = extras[xi];
    final k = extraKind(x), name = k == 'wolf' && wolfSod(x.pack) ? 'WOLF3D SPEAR' : extraName(x); // 1.6.11 test2: 12 characters in the menu
    // 1.6.8: clock and NFC per program (x.clock / x.nfc), otherwise the common setting
    // 1.7.3 test7: noClock (clean ROM, clock not set at the start): no program takes the Paradise's clock; x.sess false:
    // no session on leaving (flags bit 12, SESS_FLAG in the programs)
    final clk = !noClock && (x.clock != null ? x.clock != false : clock != false), nfcOn = x.nfc != null ? x.nfc != false : nfc != false;
    final flags = (lang == 'en' ? 1 : 0) | (clk ? 2 : 0) | (nfcOn ? 0 : 4) | _optBits(x.opt) | (x.sess == false ? _NOSESS : 0) | (k == 'tama' && _idFirmware(x.guest) ? _ID_STRAP : 0);
    if (k != 't7' && k != 'v1' && k != 'gb' && k != 'sms' && k != 'pm' && k != 'ab' && k != 'wolf' && !launch) throw EmuError('$name: only in a start device');
    if (k == 't7') {
      if (!t7Detect(x.rom)) throw EmuError('not a V7 ROM');
      if (apps.t7 == null) throw EmuError('T7Emu missing');
      // 1.6.8: figures for the further T7Emus as well (behind the ROM, 4 KB aligned)
      final figs = t7Kind(x.rom) == 'friends' ? <(Uint8List, String)>[] : [for (final f in (x.figs ?? const <T7Fig>[]).take(_T7_FIG_MAX)) (_t7Trim(f.data), t7FigName(f.name))];
      var figLen = 0;
      for (final f in figs) {
        figLen += (f.$1.length + 0xFFF) & ~0xFFF;
      }
      final size = 0x20000 + ((x.rom!.length + 0xFFF) & ~0xFFF) + figLen;
      final pl = place((size + 0xFFFF) & ~0xFFFF, 0x10000), at = pl.$1;
      if (at < 0) throw noRoom(xi);
      final a = Uint8List(0x10000);
      _set(a, apps.t7!.app, 0);
      const c = 0x140;
      if (u32(a, c) != t7Magic) throw EmuError('settings block missing in the program');
      w32(a, c + 4, 1);
      w32(a, c + 8, at + 0x20000);
      w32(a, c + 12, x.rom!.length);
      w32(a, c + 16, at + 0x10000);
      w32(a, c + 20, figs.length);
      _fill(a, 0, c + 24, c + 24 + _T7_FIG_MAX * 24);
      _set(out, x.rom!, at + 0x20000);
      var fo = at + 0x20000 + ((x.rom!.length + 0xFFF) & ~0xFFF);
      for (var i = 0; i < figs.length; i++) {
        final f = figs[i], o = c + 24 + i * 24;
        _set(out, f.$1, fo);
        w32(a, o, fo);
        w32(a, o + 4, f.$1.length);
        for (var q = 0; q < f.$2.length && q < 15; q++) {
          a[o + 8 + q] = f.$2.codeUnitAt(q) & 255;
        }
        fo += (f.$1.length + 0xFFF) & ~0xFFF;
      }
      w32(a, c + 24 + _T7_FIG_MAX * 24, flags);
      _set(out, a, at);
      _t7XWrite(out, at + 0x10000, apps.t7);
      list.add(AppEntry(_xip(at), name, at));
      res.add((at, at + size));
      if (!pl.$2) top = math.min(top, at);
    } else if (k == 'gb' || k == 'sms' || k == 'pm' || k == 'ab') {
      // 1.6.9 test36 GBEmu: the ROM first (64 KB aligned, the base of the cached window), then program, settings, cartridge RAM
      // 1.6.10 test2 SMSEmu: as GBEmu; 1.7.3 PokeMiniEmu: as SMSEmu
      // 1.7.3 ArduboyEmu: the game with its save in one 64 KB block (the base of the cached window), the program apart
      final Uint8List? prog;
      final int magic, ra, tail; // ra: room of the game, tail: program with its save
      GbStored? tr;
      if (k == 'gb') {
        final color = gbIsColor(x.rom!);
        prog = color ? (apps.gbc ?? gbcEmbedded()) : (apps.gb ?? gbEmbedded());
        if (prog == null) throw EmuError(color ? 'GBCEmu missing' : 'GBEmu missing');
        tr = _gbStore(x.rom!);
        ra = (tr.rom.length + 0xFFFF) & ~0xFFFF;
        tail = 0x10000 + _gbSaveLen(color);
        magic = gbMagic;
      } else if (k == 'sms') {
        prog = apps.sms ?? smsEmbedded();
        if (prog == null) throw EmuError('SMSEmu missing');
        ra = (x.rom!.length + 0xFFFF) & ~0xFFFF;
        tail = 0x20000;
        magic = smsMagic;
      } else if (k == 'pm') {
        prog = apps.pm ?? pmEmbedded();
        if (prog == null) throw EmuError('PokeMiniEmu missing');
        ra = (x.rom!.length + 0xFFFF) & ~0xFFFF;
        tail = 0x10000 + pmSave;
        magic = pmMagic;
      } else {
        prog = apps.ab ?? abEmbedded();
        if (prog == null) throw EmuError('ArduboyEmu missing');
        if (x.rom == null || x.rom!.length > abMax) throw EmuError('$name: too big');
        ra = 0x10000;
        tail = 0x10000;
        magic = abMagic;
      }
      final size = ra + tail;
      (int, bool) pl;
      int at, po;
      if (pack) {
        // test3: the game and the program (with its save) each where there is room
        pl = place(ra, 0x10000);
        at = pl.$1;
        if (at < 0) throw noRoom(xi);
        res.add((at, at + ra));
        if (!pl.$2) top = math.min(top, at);
        final p2 = place(tail, 0x10000);
        po = p2.$1;
        if (po < 0) throw noRoom(xi);
        res.add((po, po + tail));
        if (!p2.$2) top = math.min(top, po);
      } else {
        pl = place(size, 0x10000);
        at = pl.$1;
        if (at < 0) throw noRoom(xi);
        po = at + ra;
      }
      final a = Uint8List(0x10000);
      _set(a, prog, 0);
      const c = 0x140;
      if (u32(a, c) != magic) throw EmuError('settings block missing in the program');
      final sv = x.save != null && x.save!.isNotEmpty ? x.save : null;
      if (k == 'gb') {
        final sl = tail - 0x10000;
        _gbCfgWrite(a, c, x, at, po + 0x10000, flags, tr);
        _set(out, tr!.rom, at);
        _set(out, a, po);
        if (sv != null) {
          final s = _ff(sl);
          _set(s, _sub(sv, 0, sl), 0);
          _set(out, s, po + 0x10000);
        } else {
          _fill(out, 0xFF, po + 0x10000, po + 0x10000 + sl);
        }
      } else if (k == 'sms') {
        _smsCfgWrite(a, c, x, at, po + 0x10000, flags);
        _set(out, x.rom!, at);
        _set(out, a, po);
        if (sv != null) {
          final s = _ff(0x10000);
          _set(s, _sub(sv, 0, 0x10000), 0);
          _set(out, s, po + 0x10000);
        } else {
          _fill(out, 0xFF, po + 0x10000, po + 0x20000);
        }
      } else if (k == 'pm') {
        _pmCfgWrite(a, c, x, at, po + 0x10000, flags);
        _set(out, x.rom!, at);
        _set(out, a, po);
        final s = _ff(pmSave);
        if (sv != null) _set(s, _sub(sv, 0, pmBiosAt), 0);
        if (x.bios != null && pmBiosDetect(x.bios)) _set(s, x.bios!, pmBiosAt);
        _set(out, s, po + 0x10000);
      } else {
        _abCfgWrite(a, c, x, at, at + _AB_SAVE_AT, flags);
        _fill(out, 0xFF, at, at + 0x10000);
        _set(out, x.rom!, at);
        _set(out, a, po);
        final s = _ff(abSave);
        if (sv != null) _set(s, _sub(sv, 0, abSave), 0);
        _set(out, s, at + _AB_SAVE_AT);
      }
      list.add(AppEntry(_xip(po), name, po));
      if (!pack) {
        res.add((at, at + size));
        if (!pl.$2) top = math.min(top, at);
      }
    } else if (k == 'doom') {
      // 1.7.2 test3 DOOM_FREE: anywhere. The program part runs at XIP 0x100A0000 (the window follows it: code at 0x0A0000 or
      // above), the packed flash pointers reach two 4 MB windows (WAD and level data inside 8 MB from a 4 MB boundary)
      // 1.7.6 DOOM_LAUNCH: also in a start device whose firmware leaves no room at 0x0A0000 (Tropical/Glacier, Neon Planets)
      if (!clean && !(_DOOM_LAUNCH && launch)) throw EmuError('DOOM goes into the menu only without the Paradise');
      final dm = apps.doom;
      if (dm == null) throw EmuError('DOOM program missing');
      if (x.mcu == null) throw EmuError('DOOM: WAD not converted');
      final lk = dLinks[x], mcu = lk != null ? lk.mcu : x.mcu!; // DOOM_LINK
      if (dm.app.length > 0x10000) throw EmuError('DOOM program too big');
      int page(int n) => (n + 0xFFF) & ~0xFFF;
      final parts = doomParts(Extra(kind: 'doom', mcu: mcu, region: x.region, size: x.size), dm.xip.length);
      // 1.7.3 test12 (several episodes): the WAD first, at a 4 MB boundary or ending on one where possible (the 8 MB
      // window then wastes nothing between two WADs), else top down as before; then the program part anywhere
      // test13: the level data (DOOM_REGION) may also lie apart from the WAD, anywhere in the same 8 MB window (the clean
      // ROM keeps 0xEFD000..0xF00000: a big episode then fits below it, its level data above it)
      final wadOnly = _DOOM_PKREG ? page(4 + mcu.length) : (page(4 + mcu.length) + 0xFFFF) & ~0xFFFF; // test15: the WAD on a 4 KB page (DOOM II only just fits)
      var w = -1, rg = -1;
      final RG = _doomRegion(x);
      bool tryW(int a) {
        if (a < floor || !fits(a, wadOnly)) return false;
        final B = a & ~0x3FFFFF;
        if (!_DOOM_PKREG && a + wadOnly > B + 0x800000) return false;
        if (fits(a, parts.wad)) {
          w = a;
          rg = page(a + 4 + mcu.length);
          return true;
        }
        // test15 DOOM_PKREG: the level data anywhere (it only has to stay inside the 8 MB from its own 4 MB boundary)
        final lo = _DOOM_PKREG ? floor : math.max(B, floor), hi = _DOOM_PKREG ? ceil : math.min(ceil, B + 0x800000);
        for (var r = (hi - RG) & ~0xFFF; r >= lo; r -= 0x1000) {
          if (r < a + wadOnly && r + RG > a) continue;
          if (_DOOM_PKREG && r + RG > (r & ~0x3FFFFF) + 0x800000) continue;
          if (fits(r, RG)) {
            w = a;
            rg = r;
            return true;
          }
        }
        return false;
      }

      if (!doomTop) {
        for (var b = 0xC00000; b >= 0 && w < 0; b -= 0x400000) {
          if (!tryW(b)) {
            final e = (b + 0x400000 - wadOnly) & ~0xFFFF;
            if (e >= 0) tryW(e);
          }
        }
      }
      for (var a = (ceil - wadOnly) & ~0xFFFF; w < 0 && a >= floor; a -= 0x10000) {
        tryW(a);
      }
      if (_DOOM_PKREG) {
        for (var a = (ceil - wadOnly) & ~0xFFF; w < 0 && a >= floor; a -= 0x1000) {
          tryW(a);
        }
      }
      if (w < 0) throw noRoom(xi);
      final wrs = rg == page(w + 4 + mcu.length) ? [(w, w + parts.wad)] : [(w, w + wadOnly), (rg, rg + RG)];
      res.addAll(wrs);
      var at = -1;
      for (var a = (ceil - parts.prog) & ~0xFFFF; a >= math.max(floor, 0x90000); a -= 0x10000) {
        if (fits(a, parts.prog)) {
          at = a;
          break;
        }
      }
      if (at < 0) {
        res.removeRange(res.length - wrs.length, res.length);
        throw noRoom(xi);
      }
      res.add((at, at + parts.prog));
      final a = Uint8List(0x10000);
      _set(a, dm.app, 0);
      final c = _pdmcAt(a, 0);
      if (c < 0 || u32(a, c + 4) < 2) throw EmuError('settings block missing in DOOM');
      final code = at + 0x10000, save = code + page(dm.xip.length), region = rg, cmo = save + _DOOM_SAVE, cmap = _DOOM_CMAP && u32(a, c + 4) >= 3 ? _doomCmap(x.mcu!) : null;
      // 1.7.6 DOOM_CMAP_AT: cmap_off is the 19th word of the settings block (c + 72, after run_dbl at 68); c + 76 lay behind
      // the block, on the first instruction of the program (para_mailbox): DOOM in the menu hung or drew wrongly
      if (cmap != null) w32(a, c + (_DOOM_CMAP_AT ? 72 : 76), cmo);
      w32(a, c + 8, w + 4);
      w32(a, c + 12, mcu.length);
      w32(a, c + 16, region);
      w32(a, c + 20, RG);
      w32(a, c + 24, save);
      w32(a, c + 28, code);
      if (x.keyMap != null) {
        _DOOM_KEY_AT.forEach((kk, o) {
          final v = x.keyMap![kk];
          if (v != null) w32(a, c + o, _keyInt(v) & 0xFFFFFFFF);
        });
      }
      _fill(out, 0xFF, at, at + parts.prog);
      _set(out, a, at);
      _set(out, dm.xip, code);
      if (x.save != null && x.save!.isNotEmpty) _set(out, _sub(x.save!, 0, _DOOM_SAVE), save);
      if (cmap != null) _set(out, cmap, cmo);
      for (final (p0, p1) in wrs) {
        _fill(out, 0xFF, p0, p1);
      }
      w32(out, w, mcu.length);
      _set(out, mcu, w + 4);
      wadAt[x] = w + 4;
      if (lk != null) {
        // DOOM_LINK: the shared lumps point into the WADs placed before; c+12 reaches over them when they lie above
        var hi = w + 4 + mcu.length;
        for (final (d, bx, bp) in lk.refs) {
          final ba = wadAt[bx];
          if (ba == null) throw EmuError('DOOM: linked WAD missing');
          w32(out, w + 4 + d, (ba + bp - (w + 4)) & 0xFFFFFFFF);
          if (ba > w) hi = math.max(hi, ba + bx.mcu!.length);
        }
        w32(out, at + c + 12, hi - (w + 4));
      }
      list.add(AppEntry(_xip(at), name, at));
      top = math.min(top, math.min(at, math.min(w, rg)));
    } else if (k == 'wolf') {
      // 1.6.10 test1 Wolf3D: the pack first (64 KB aligned, the base of the cached window), then the program (128 KB), the save
      final sod = wolfSod(x.pack), w = sod ? (apps.wolfsod ?? wolfSodEmbedded()) : (apps.wolf ?? wolfEmbedded());
      if (w == null) throw EmuError('${sod ? 'Spear of Destiny' : 'Wolf3D'} program missing');
      if (!wolfPackOk(x.pack)) throw EmuError('Wolf3D data missing');
      if (w.length > 0x20000) throw EmuError('Wolf3D program too big');
      final pa = (x.pack!.length + 0xFFFF) & ~0xFFFF, size = pa + 0x30000, pl = place(size, 0x10000), at = pl.$1;
      if (at < 0) throw noRoom(xi);
      final a = _ff(0x20000);
      _set(a, w, 0);
      const c = 0x140;
      final po = at + pa;
      if (u32(a, c) != wolfMagic) throw EmuError('settings block missing in the program');
      _wolfCfgWrite(a, c, x, at, po + 0x20000, po, flags);
      _fill(out, 0xFF, at, at + pa);
      _set(out, x.pack!, at);
      _set(out, a, po);
      if (x.save != null && x.save!.isNotEmpty) {
        final sv = _ff(0x10000);
        _set(sv, _sub(x.save!, 0, 0x10000), 0);
        _set(out, sv, po + 0x20000);
      } else {
        _fill(out, 0xFF, po + 0x20000, po + 0x30000);
      }
      list.add(AppEntry(_xip(po), name, po));
      res.add((at, at + size));
      if (!pl.$2) top = math.min(top, at);
    } else if (k == 'v1' && v3Detect(x.rom)) {
      // 1.6.9 V3Emu: the ROM first (64 KB aligned, the base of the cached window), then program, session, settings
      final v3 = apps.v3 ?? apps.v1?.v3 ?? v3Embedded();
      if (v3 == null) throw EmuError('V3Emu missing');
      const size = 0x92000;
      final pl = place(size, 0x10000), at = pl.$1;
      if (at < 0) throw noRoom(xi);
      final a = Uint8List(0x10000);
      _set(a, v3, 0);
      const c = 0x140;
      final po = at + 0x80000;
      if (u32(a, c) != v1Magic) throw EmuError('settings block missing in the program');
      _v1CfgWrite(a, c, x.rom!, at, po + 0x10000, flags);
      for (var i = 0; i < 16; i++) {
        a[c + 24 + i] = i < name.length ? name.codeUnitAt(i) & 255 : 0;
      }
      _set(out, x.rom!, at);
      _set(out, a, po);
      _fill(out, 0xFF, po + 0x10000, po + 0x12000);
      list.add(AppEntry(_xip(po), name, po));
      res.add((at, at + size));
      if (!pl.$2) top = math.min(top, at);
    } else if (k == 'v1') {
      if (apps.v1 == null) throw EmuError('V1Emu missing');
      final size = 0x12000 + ((x.rom!.length + 0xFFF) & ~0xFFF); // program, session 4 KB, settings 4 KB, ROM
      final pl = place(size, 0x1000), at = pl.$1;
      if (at < 0) throw noRoom(xi);
      final a = Uint8List(0x10000);
      _set(a, apps.v1!.app, 0);
      const c = 0x140;
      if (u32(a, c) != v1Magic) throw EmuError('settings block missing in the program');
      _v1CfgWrite(a, c, x.rom!, at + 0x12000, at + 0x10000, flags);
      for (var i = 0; i < 16; i++) {
        a[c + 24 + i] = i < name.length ? name.codeUnitAt(i) & 255 : 0;
      }
      _set(out, a, at);
      _fill(out, 0xFF, at + 0x10000, at + 0x12000);
      _set(out, x.rom!, at + 0x12000);
      list.add(AppEntry(_xip(at), name, at));
      res.add((at, at + size));
      if (!pl.$2) top = math.min(top, at);
    } else if (k == 'tama') {
      if (apps.tama == null) throw EmuError('TamaEmu missing');
      final tama = apps.tama!;
      const mroom = menuRoom ? menuRoomLen : null;
      if (packAsk && packOpt && !x.packed && guestLz && tamaLzCan(tama) && tamaNeedsLz(x.guest!, x.dev!, mroom)) throw EmuError('${extraName(x)} only fits packed', needPack: true, prog: extraName(x));
      final lzCan = guestLz && tamaLzCan(tama) && (packOpt ? x.packed || (!packAsk && tamaNeedsLz(x.guest!, x.dev!, mroom)) : !tamaRaw);
      final memo = _SIZE_CACHE && !x.lzAll && x.lzExtra == null ? (_sizeCache[x.guest!] ?? <String, Object>{}) : null, mk = 'pk:${x.dev}:$lzCan'; // SIZE_CACHE: trial builds pack only once
      final pk = (memo?[mk] as PackedGuest?) ?? packGuest(x.guest!, x.dev!, sparse: true, lz: lzCan, lzAll: x.lzAll, lzExtra: x.lzExtra, room: mroom);
      final map = pk.map, blob = pk.blob, pages = pk.pages;
      if (memo != null && memo[mk] == null) {
        memo[mk] = pk;
        _sizeCache[x.guest!] = memo;
      }
      final gLen = (blob.length + _txSpare(pk, txSpare) + 0xFFFF) & ~0xFFFF, size = gLen + 0x10000 + _TX_STATE; // test25: txSpare (less room for spare pages when tight, as the main TamaEmu)
      final pl = place(size, 0x40000), gOff = pl.$1;
      if (gOff < 0) throw noRoom(xi);
      final gEnd = gOff + gLen, img = gEnd, st = gEnd + 0x10000;
      _set(out, blob, gOff);
      if (pages.isNotEmpty) _putPages(out, gOff, gEnd, blob.length, pages);
      final a = Uint8List(tama.length > 0x10000 ? 0 : 0x10000);
      _set(a, tama, 0);
      var ci = -1;
      for (var i = 0; i + 4 <= a.length; i += 4) {
        if (u32(a, i) == _PMXC) {
          ci = i;
          break;
        }
      }
      if (ci < 0 || u32(a, ci + 156) != 0) throw EmuError('settings block missing in the program');
      w32(a, ci + 4, 4);
      w32(a, ci + 8, gOff);
      w32(a, ci + 12, blob.length);
      w32(a, ci + 16, st);
      w32(a, ci + 20, devices[x.dev]!.kind);
      _set(a, map, ci + 24);
      w32(a, ci + 152, gEnd);
      w32(a, ci + 156, flags);
      if (lzCan) {
        // GUEST_LZ: version 5, the table of the packed blocks
        w32(a, ci + 4, 5);
        w32(a, ci + 160, pk.lzOff != null ? gOff + pk.lzOff! : 0);
      }
      _set(out, a, img);
      list.add(AppEntry(_xip(img), name, img));
      res.add((gOff, gOff + size));
      if (!pl.$2) top = math.min(top, gOff);
    } else if (k == 't18' && kept.contains(x)) {
      final off = x.keepOff!, a = Uint8List(0x10000);
      final t18 = apps.t18!;
      _set(a, t18.app, 0);
      if (u32(a, 0x140) != t18Magic) throw EmuError('settings block missing in the program');
      // its block map, spares and save place stay (up to +400); the addresses come from its firmware again (an older
      // program had code where +428.. is now: test2 copied that and grow up wrote into nowhere)
      _set(a, _sub(out, off + 0x140, off + 0x140 + 400), 0x140);
      final hot = u32(out, off + 0x140 + 400) & (_T18F_HOTWIN | _T18F_HOT2), ad = t18Addrs(x.fw!);
      w32(a, 0x140 + 404, ad.idle);
      w32(a, 0x140 + 408, ad.soft);
      w32(a, 0x140 + 412, ad.dma);
      w32(a, 0x140 + 416, 0);
      w32(a, 0x140 + 420, 0);
      w32(a, 0x140 + 424, 0);
      w32(a, 0x140 + 428, ad.param);
      w32(a, 0x140 + 432, ad.param == 0xF800D8B4 ? 1 : 0);
      w32(a, 0x140 + 436, 0);
      w32(a, 0x140 + 400, hot | _optBits(x.opt) | (lang == 'en' ? 1 : 0) | (clk ? 2 : 0) | (x.sess == false ? _NOSESS : 0));
      _set(out, a, off);
      _fill(out, 0xFF, t18XipOff, t18XipOff + _T18_XIP_MAX);
      _set(out, t18.xip!, t18XipOff);
      if ((hot & _T18F_HOTWIN) != 0) {
        _fill(out, 0xFF, 0xFD0000, 0xFF0000);
        _set(out, t18.xip!, _T18_XIP_HOT);
      }
      if (x.items) _set(out, t18RomWriteGuest(out, x.fw!, off), 0);
      list.add(AppEntry(_xip(off), name, off));
    } else if (k == 't18') {
      if (!_t18XipOk(apps.t18)) throw EmuError('T18Emu missing');
      if (u32(out, _APP_OFF + 0x140) == t18Magic || list.any((l) => u32(out, l.off + 0x140) == t18Magic)) throw EmuError('only one T18Emu');
      if (taken(t18XipOff, _T18_XIP_MAX) || !_isFF(out, t18XipOff, _T18_XIP_MAX)) throw EmuError('T18Emu needs the area at 0x0F0000, the main program uses it: choose T18Emu in the Emulator tab');
      // T18Emu's own placement in a scratch copy where everything taken is not empty
      final work = _copy(out);
      for (final (a, b) in res) {
        _fill(work, 0, math.max(0, a), math.min(work.length, b));
      }
      final img = find(0x10000 + _T18X_SAVE, 0x10000);
      if (img < 0) throw noRoom(xi);
      _fill(work, 0, img, img + 0x10000 + _T18X_SAVE);
      final r = t18Patch(work, x.fw!, apps.t18!, null, lang: lang, clock: clk, launch: true, extra: true, opt: x.opt, noResv: noResv, nosess: x.sess == false);
      final w2 = r.rom;
      const c = _APP_OFF + 0x140;
      final a = _slice(w2, _APP_OFF, _APP_OFF + 0x10000);
      w32(a, 0x140 + 8, img + 0x10000); // its own save area
      final blocks = <int>[];
      for (var i = 0; i < 128; i++) {
        final b = w2[c + 16 + 2 * i] | (w2[c + 17 + 2 * i] << 8);
        if (b != 0xFFFF) blocks.add(b);
      }
      final ns = math.min(u32(w2, c + 12), _T18_SPARE_MAX);
      for (var i = 0; i < ns; i++) {
        blocks.add(w2[c + 272 + 2 * i] | (w2[c + 273 + 2 * i] << 8));
      }
      for (final b in blocks) {
        _set(out, _sub(w2, b << 16, (b + 1) << 16), b << 16);
        res.add((b << 16, (b + 1) << 16));
      }
      _set(out, _sub(w2, t18XipOff, t18XipOff + _T18_XIP_MAX), t18XipOff);
      res.add((t18XipOff, t18XipOff + _T18_XIP_MAX));
      if ((u32(w2, c + 400) & _T18F_HOTWIN) != 0) {
        _set(out, _sub(w2, 0xFD0000, 0xFF0000), 0xFD0000);
        res.add((0xFD0000, 0xFF0000));
      }
      _fill(out, 0xFF, img + 0x10000, img + 0x10000 + _T18X_SAVE);
      _set(out, a, img);
      list.add(AppEntry(_xip(img), name, img));
      res.add((img, img + 0x10000 + _T18X_SAVE));
      top = math.min(top, img);
    } else {
      throw EmuError('unknown program');
    }
    listXi.add(xi);
    left.remove(xi);
  }
  {
    final ix = [for (var i = 0; i < list.length; i++) i];
    _sort<int>(ix, (a, b) => listXi[a] - listXi[b]);
    final sorted = [for (final i in ix) list[i]];
    list
      ..clear()
      ..addAll(sorted);
  }
  // start device (1.6.8): the flash app as its own 64 KB image (menu entry DOWNLOAD)
  var dl = 0;
  if (dlApp != null) {
    if (dlApp.length > 0x10000) throw EmuError('flash app too big');
    final pl = place(0x10000, 0x10000), at = pl.$1;
    if (at < 0) throw noRoom(extras.length);
    _fill(out, 0x00, at, at + 0x10000);
    _set(out, dlApp, at);
    dl = _xip(at);
    res.add((at, at + 0x10000));
    if (!pl.$2) top = math.min(top, at);
  }
  // test29: T18Emu gets more spares where there is room, also an installed one (they are only added behind its
  // spares, so its save stays valid). With 6 the firmware's save filled them while growing up and its writes got lost.
  if (t18More != false) {
    for (final l in list) {
      final c = l.off + 0x140;
      if (u32(out, c) != t18Magic) continue;
      final ns = math.min(u32(out, c + 12), _T18_SPARE_MAX);
      if (ns >= _T18_SPARE_GROW) continue;
      final cand = t18Free(out, launch).where((b) => !taken(b << 16, 0x10000) && !(_SPARE_NO_RESCUE && _RESCUE_RES && !noResv && b == _RESCUE_BLK)).toList(); // 1.7.2: never the rescue start's block
      final add = math.min(_T18_SPARE_GROW - ns, cand.length - 4);
      for (var i = 0; i < add; i++) {
        final b = cand[i];
        out[c + 272 + 2 * (ns + i)] = b & 255;
        out[c + 273 + 2 * (ns + i)] = b >> 8;
        res.add((b << 16, (b + 1) << 16));
        if (b < 0xF0) top = math.min(top, b << 16);
      }
      if (add > 0) w32(out, c + 12, ns + add);
    }
  }
  // test17 ROOM_REAL: the room really left (empty 64 KB blocks a program may use), for the overview
  var free = 0;
  for (var a = floor; a + 0x10000 <= ceil; a += 0x10000) {
    if (fits(a, 0x10000)) free++;
  }
  if (launch) {
    for (var a = 0xF00000; a < hiEnd; a += 0x10000) {
      if (fitsHi(a, 0x10000)) free++;
    }
  }
  return AppsPlaced(out, list, top, dl, free * 64);
}

/* 1.7.2 test3 DOOM_FREE: DOOM as a program of the menu in a ROM without the Paradise. Its settings block (PDMC) holds
 * the places of the WAD, the level data, the save and the program part; nothing is fixed any more. */
const int _PDMC = 0x434D4450, _DOOM_REGION = 0xA8000, _DOOM_SAVE = 0x2000;
const bool _DOOM_CMAP_AT = true;
/* 1.7.3 test15 DOOM_PKREG: the DOOM program takes its packed-pointer windows from the level data, not from the WAD: the WAD
 * may be anywhere and bigger than 8 MB (a whole DOOM.WAD as one entry). That needs more level data room: the lists of
 * the whole WAD come first in it (x.region, set by the Studio). */
const bool _DOOM_PKREG = true;
/* 1.7.3 test17 DOOM_CMAP: a copy of the WAD's COLORMAP (8.5 KB) behind the save in the program part: the DOOM program reads it
 * through its cached window instead of keeping it in RAM (that RAM goes to big maps like Sigil and DOOM II MAP29) */
const bool _DOOM_CMAP = true;
String _lumpName(Uint8List m, int at) {
  final s = StringBuffer();
  for (var k = 0; k < 8; k++) {
    final ch = m[at + k];
    if (ch == 0) break;
    s.writeCharCode(ch);
  }
  return s.toString();
}

Uint8List? _doomCmap(Uint8List mcu) {
  final n = _u32s(mcu, 4), dir = _u32s(mcu, 8);
  for (var i = 0; i < n && dir + 16 * i + 16 <= mcu.length; i++) {
    if (_lumpName(mcu, dir + 16 * i + 8) == 'COLORMAP') {
      final o = u32(mcu, dir + 16 * i), l = u32(mcu, dir + 16 * i + 4);
      return l >= 34 * 256 && o + l <= mcu.length ? _sub(mcu, o, o + 34 * 256) : null;
    }
  }
  return null;
}

int _doomRegion(Extra? x) => _DOOM_PKREG && x != null && x.region != null && x.region != 0 ? x.region! : _DOOM_REGION;
/* 1.7.3 test21 DOOM_LINK: DOOM entries in the menu share identical lumps (pictures, sounds, textures). A linked entry keeps
 * its own directory, but such a lump points into the WAD of another entry (the engine reads a lump at WAD + filepos, any
 * address in the flash works). Sigil then needs about its own size instead of its own copy of DOOM. Read back, a linked
 * WAD is made whole again (doomUnlink) and linked anew when placed. */
const bool doomLink = true;
const bool _DOOM_LINK = doomLink;
const int _LINK_MIN = 0x40000;

class _Lump {
  _Lump(this.i, this.pos, this.size, this.at);
  final int i, pos, size, at; // pos: signed (a linked lump may point in front of its WAD)
}

List<_Lump> _doomDir(Uint8List m) {
  final n = _u32s(m, 4), d = _u32s(m, 8), r = <_Lump>[];
  for (var i = 0; i < n && d + 16 * i + 16 <= m.length; i++) {
    r.add(_Lump(i, u32(m, d + 16 * i).toSigned(32), u32(m, d + 16 * i + 4), d + 16 * i));
  }
  return r;
}

String _lumpKey(Uint8List m, int pos, int size) {
  var h = 0x811C9DC5;
  for (var k = 0; k < size; k += 7) {
    h = ((h ^ m[pos + k]) * 16777619) & 0xFFFFFFFF;
  }
  return '$size:$h';
}

/// A linked WAD: its data, the lumps that point into other WADs (place of the directory entry, base entry, place in
/// the base WAD), the bytes saved.
class DoomLink {
  DoomLink(this.mcu, this.refs, this.saved);
  final Uint8List mcu;
  final List<(int, Extra, int)> refs;
  final int saved;
}

/// Linked WAD of mcu against bases [(x, mcu)]: { mcu, refs: [[dirAt, base x, base pos]], saved } or null
DoomLink? _doomLinkOne(Uint8List mcu, List<Extra> bases) {
  final idx = <String, (Extra, int)>{};
  for (final b in bases) {
    final bm = b.mcu!;
    for (final l in _doomDir(bm)) {
      if (l.size >= 256 && l.pos >= 0 && l.pos + l.size <= bm.length) {
        final k = _lumpKey(bm, l.pos, l.size);
        idx.putIfAbsent(k, () => (b, l.pos));
      }
    }
  }
  final dir = _doomDir(mcu), refs = <(int, Extra, int)>[], keep = <_Lump>[];
  var saved = 0;
  for (final l in dir) {
    (Extra, int)? hit;
    if (l.size >= 256 && l.pos >= 0 && l.pos + l.size <= mcu.length) {
      final h = idx[_lumpKey(mcu, l.pos, l.size)];
      if (h != null && _eqAt(h.$1.mcu!, h.$2, mcu, l.pos, l.size)) hit = h;
    }
    if (hit != null) {
      refs.add((l.i, hit.$1, hit.$2));
      saved += l.size;
    } else {
      keep.add(l);
    }
  }
  if (saved < _LINK_MIN) return null;
  var len = 12;
  final posOf = <int, int>{};
  for (final l in keep) {
    if (l.size == 0) continue;
    len = (len + 3) & ~3;
    posOf[l.i] = len;
    len += l.size;
  }
  len = (len + 3) & ~3;
  final dirAt = len, out = Uint8List(dirAt + 16 * dir.length);
  _set(out, _sub(mcu, 0, 4), 0);
  w32(out, 4, dir.length);
  w32(out, 8, dirAt);
  for (final l in dir) {
    final o = dirAt + 16 * l.i;
    _set(out, _sub(mcu, l.at, l.at + 16), o);
    final p = posOf[l.i];
    if (p != null) {
      _set(out, _sub(mcu, l.pos, l.pos + l.size), p);
      w32(out, o, p);
    } else if (l.size == 0) {
      w32(out, o, 0);
    }
  }
  return DoomLink(out, [for (final (i, x, p) in refs) (dirAt + 16 * i, x, p)], saved);
}

/// DOOM entries of one build: which ones are linked to which (the biggest ones are bases). Map x -> link
Map<Extra, DoomLink> doomLinks(List<Extra> extras) {
  final ds = extras.where((x) => extraKind(x) == 'doom' && x.mcu != null).toList(), bases = <Extra>[], links = <Extra, DoomLink>{};
  _sort<Extra>(ds, (a, b) => b.mcu!.length - a.mcu!.length);
  for (final x in ds) {
    final lk = bases.isNotEmpty ? _doomLinkOne(x.mcu!, bases) : null;
    if (lk != null) {
      links[x] = lk;
    } else {
      bases.add(x);
    }
  }
  return links;
}

/// A linked WAD read back from the ROM, whole again (lumps that point outside it are copied in)
Uint8List doomUnlink(Uint8List rom, int wad, Uint8List mcu) {
  final dir = _doomDir(mcu);
  if (!dir.any((l) => l.size != 0 && (l.pos < 0 || l.pos + l.size > mcu.length))) return mcu;
  final parts = <(_Lump, int, Uint8List)>[];
  var len = 12;
  for (final l in dir) {
    if (l.size == 0) continue;
    final a = wad + l.pos;
    final src = l.pos >= 0 && l.pos + l.size <= mcu.length
        ? _sub(mcu, l.pos, l.pos + l.size)
        : a >= 0 && a + l.size <= rom.length
            ? _sub(rom, a, a + l.size)
            : Uint8List(l.size);
    len = (len + 3) & ~3;
    parts.add((l, len, src));
    len += l.size;
  }
  len = (len + 3) & ~3;
  final out = Uint8List(len + 16 * dir.length);
  _set(out, _sub(mcu, 0, 4), 0);
  w32(out, 4, dir.length);
  w32(out, 8, len);
  for (final l in dir) {
    _set(out, _sub(mcu, l.at, l.at + 16), len + 16 * l.i);
    if (l.size == 0) w32(out, len + 16 * l.i, 0);
  }
  for (final (l, p, src) in parts) {
    _set(out, src, p);
    w32(out, len + 16 * l.i, p);
  }
  return out;
}

int _pdmcAt(Uint8List rom, int off) {
  for (var i = 0x140; i < 0x400; i += 4) {
    if (_u32s(rom, off + i) == _PDMC) return off + i;
  }
  return -1;
}

/// Settings of an extra program at off: kind and what belongs to it (0 / empty where the kind has none).
class ExtraCfg {
  ExtraCfg(this.kind, {this.romOff = 0, this.romLen = 0, this.saveOff = 0, this.cfg = 0, this.regionOff = 0, this.regionLen = 0, this.codeOff = 0, this.version = 0,
      this.map = const [], this.spare = const [], this.flags = 0, this.dev, this.guestOff = 0, this.guestSize = 0, this.spareEnd = 0, this.lzOff = 0});
  final String kind;
  final int romOff, romLen, saveOff; // t7, v1, gb, sms, pm, ab, wolf, doom (WAD with its length word)
  final int cfg, regionOff, regionLen, codeOff; // doom
  final int version, flags; // t18
  final List<int> map; // t18: block map (u16), tama: block map (bytes)
  final List<int> spare; // t18
  final String? dev; // tama
  final int guestOff, guestSize, spareEnd, lzOff; // tama
}

ExtraCfg? doomCfg(Uint8List rom, int off) {
  if (_u32s(rom, off + 0x140) != _PMXC) return null;
  final c = _pdmcAt(rom, off);
  if (c < 0) return null;
  final wad = u32(rom, c + 8);
  var len = u32(rom, c + 12);
  if (_DOOM_LINK && wad >= 4 && wad <= rom.length) {
    // DOOM_LINK: c+12 may reach over the linked WADs
    final lw = u32(rom, wad - 4);
    if (lw != 0 && lw < len) len = lw;
  }
  if (len == 0 || wad < 4 || wad + len > rom.length) return null;
  return ExtraCfg('doom', cfg: c, romOff: wad - 4, romLen: len + 4, regionOff: u32(rom, c + 16), regionLen: u32(rom, c + 20), saveOff: u32(rom, c + 24), codeOff: u32(rom, c + 28));
}

const Map<String, int> _DOOM_KEY_AT = {'invert': 44, 'fire': 48, 'fwd': 52, 'back': 56, 'use': 60, 'mod': 64, 'run': 68};
Map<String, Object> _doomKeysOf(Uint8List rom, int c) => {
      for (final e in _DOOM_KEY_AT.entries) e.key: e.key == 'run' || e.key == 'invert' ? u32(rom, c + e.value) != 0 : u32(rom, c + e.value),
    };

ExtraCfg? extraCfg(Uint8List rom, int off) {
  final m = _u32s(rom, off + 0x140);
  if (m == _PMXC) {
    final d = doomCfg(rom, off);
    if (d != null) return d;
  }
  ExtraCfg? plain(String kind) {
    final ro = u32(rom, off + 0x148), rl = u32(rom, off + 0x14C);
    return ro + rl <= rom.length ? ExtraCfg(kind, romOff: ro, romLen: rl, saveOff: u32(rom, off + 0x150)) : null;
  }

  if (m == t7Magic) return plain('t7');
  if (m == t18Magic) {
    final c = t18Cfg(rom, off)!;
    return ExtraCfg('t18', version: c.version, saveOff: c.saveOff, map: c.map, spare: c.spare, flags: c.flags);
  }
  if (m == gbMagic) return plain('gb');
  if (m == smsMagic) return plain('sms');
  if (m == abMagic) return plain('ab');
  if (m == pmMagic) return plain('pm');
  if (m == wolfMagic) return plain('wolf');
  if (m == v1Magic) return plain('v1');
  if (m == _PMXC && u32(rom, off + 0x144) >= 3) {
    final gOff = u32(rom, off + 0x148), gLen = u32(rom, off + 0x14C), saveOff = u32(rom, off + 0x150), kind = u32(rom, off + 0x154);
    String? dev;
    for (final e in devices.entries) {
      if (e.value.kind == kind) {
        dev = e.key;
        break;
      }
    }
    return dev != null
        ? ExtraCfg('tama', dev: dev, guestOff: gOff, guestSize: gLen, saveOff: saveOff, map: _slice(rom, off + 0x158, off + 0x1D8), spareEnd: u32(rom, off + 0x140 + 152), lzOff: u32(rom, off + 0x144) >= 5 ? u32(rom, off + 0x140 + 160) : 0)
        : null;
  }
  return null;
}

/* test25 HI_ORPHAN: start device: blocks behind the Paradise's save (0xF00000..0xFEFFFF) that no program uses any more
 * (left there by an earlier removal; they kept T18Emu from its fast window there) become free again. Used: what the
 * program at 0x0A0000 reserves, the programs still listed (keep: their offsets) with all their parts, the menu (menuOff). */
Uint8List hiFree(Uint8List rom, List<int>? keep, [int menuOff = 0]) {
  final used = <int>{};
  void mark(int a, int b) {
    for (var o = a & ~0xFFFF; o < b; o += 0x10000) {
      used.add(o >> 16);
    }
  }

  for (final (a, b) in appReserved(rom)) {
    mark(a, b);
  }
  mark(_APP_OFF, _APP_OFF + 0x10000);
  if (menuOff != 0) mark(menuOff, menuOff + 0x10000);
  final progs = [...?keep];
  if (u32(rom, _APP_OFF + 0x140) != 0xFFFFFFFF) progs.add(_APP_OFF); // the program at 0x0A0000 with all its parts too
  for (final off in progs) {
    final c = extraCfg(rom, off);
    if (c == null) {
      if (off == _APP_OFF && !_isFF(rom, _APP_OFF + 0x140, 4) && u32(rom, _APP_OFF + 0x140) != t18Magic) return rom; // unknown: leave everything
      continue;
    }
    mark(off, off + 0x10000);
    if (c.kind == 't18') {
      for (final b in [...c.map, ...c.spare]) {
        if (b != 0xFFFF) used.add(b);
      }
      mark(c.saveOff, c.saveOff + _T18X_SAVE);
      if ((c.flags & _T18F_HOTWIN) != 0) mark(0xFD0000, 0xFF0000);
    } else if (c.kind == 'tama') {
      mark(c.guestOff, c.spareEnd);
      mark(off, off + 0x10000 + _TX_STATE);
    } else if (c.kind == 't7') {
      mark(c.romOff, c.romOff + c.romLen);
      mark(c.saveOff, c.saveOff + 0x10000);
      mark(off, off + 0x20000);
      final tc = t7Cfg(rom, off);
      if (tc != null) {
        for (final f in tc.figs) {
          mark(f.off, f.off + f.len);
        }
      }
    } else {
      mark(c.romOff, c.romOff + c.romLen);
      mark(c.saveOff, c.saveOff + 0x10000);
      mark(off, off + 0x20000);
    }
  }
  var out = rom;
  for (var b = 0xF0; b < _RESCUE_BLK; b++) {
    if (!used.contains(b) && !_isFF(out, b << 16, 0x10000)) {
      if (identical(out, rom)) out = _copy(rom);
      _fill(out, 0xFF, b << 16, (b + 1) << 16);
    }
  }
  return out;
}

/// Free what the extra programs listed (their offsets: from appsRead, appsPlace) use.
Uint8List appsClear(Uint8List rom, Iterable<int>? old) {
  final out = _copy(rom);
  for (final off in old ?? const <int>[]) {
    final c = extraCfg(out, off);
    if (c == null) continue;
    if (c.kind == 't7') {
      var e = off + 0x20000 + ((c.romLen + 0xFFFF) & ~0xFFFF);
      final tc = t7Cfg(out, off);
      if (tc != null) {
        for (final f in tc.figs) {
          e = math.max(e, (f.off + f.len + 0xFFF) & ~0xFFF);
        }
      }
      _fill(out, 0xFF, off, e);
    } else if (c.kind == 'v1') {
      // 1.6.9: V3Emu has its ROM in front
      _fill(out, 0xFF, off, off + 0x12000);
      _fill(out, 0xFF, c.romOff, c.romOff + ((c.romLen + 0xFFF) & ~0xFFF));
    } else if (c.kind == 'gb' || c.kind == 'sms') {
      // test3: may lie apart
      _fill(out, 0xFF, c.romOff, c.romOff + ((c.romLen + 0xFFFF) & ~0xFFFF));
      _fill(out, 0xFF, off, off + 0x10000);
      _fill(out, 0xFF, c.saveOff, c.saveOff + (c.kind == 'gb' ? _gbSaveLen((u32(out, off + 0x140 + 20) & 8) != 0) : 0x10000));
    } else if (c.kind == 'ab') {
      _fill(out, 0xFF, c.romOff, c.romOff + 0x10000);
      _fill(out, 0xFF, off, off + 0x10000);
    } else if (c.kind == 'pm') {
      _fill(out, 0xFF, c.romOff, c.romOff + ((c.romLen + 0xFFFF) & ~0xFFFF));
      _fill(out, 0xFF, off, off + 0x10000);
      _fill(out, 0xFF, c.saveOff, c.saveOff + pmSave);
    } else if (c.kind == 'wolf') {
      _fill(out, 0xFF, c.romOff, c.saveOff + 0x10000);
    } else if (c.kind == 'tama') {
      _fill(out, 0xFF, c.guestOff, c.spareEnd);
      _fill(out, 0xFF, off, off + 0x10000 + _TX_STATE);
    } else if (c.kind == 't18') {
      for (final b in [...c.map, ...c.spare]) {
        if (b != 0xFFFF) _fill(out, 0xFF, b << 16, (b + 1) << 16);
      }
      if ((c.flags & _T18F_HOTWIN) != 0) _fill(out, 0xFF, 0xFD0000, 0xFF0000);
      _fill(out, 0xFF, t18XipOff, t18XipOff + _T18_XIP_MAX);
      _fill(out, 0xFF, off, off + 0x10000);
      if (c.saveOff == off + 0x10000) _fill(out, 0xFF, c.saveOff, c.saveOff + _T18X_SAVE);
    }
  }
  return out;
}

/// The extra programs of a ROM, from the menu's list ([{ src, name }]): the sources again, as appsPlace takes them.
List<Extra> appsRead(Uint8List rom, List<AppEntry>? apps) {
  final out = <Extra>[];
  const c0 = 0x140;
  for (final e in apps ?? const <AppEntry>[]) {
    final off = e.src - 0x10000000 + _XIP_DEC;
    if (off < 0 || off + 0x10000 > rom.length) continue;
    final c = extraCfg(rom, off);
    if (c == null) continue;
    List<int> keys9() => _sub(rom, off + c0 + 40, off + c0 + 49).toList();
    if (c.kind == 'doom') {
      final m = _slice(rom, c.romOff + 4, c.romOff + c.romLen);
      out.add(Extra(
          kind: 'doom',
          mcu: _DOOM_LINK ? doomUnlink(rom, c.romOff + 4, m) : m,
          keyMap: _doomKeysOf(rom, c.cfg),
          save: _slice(rom, c.saveOff, c.saveOff + _DOOM_SAVE),
          name: e.name,
          off: off,
          saveOff: c.saveOff,
          region: _DOOM_PKREG && c.regionLen > _DOOM_REGION && c.regionLen <= 0x400000 ? c.regionLen : null));
      continue;
    }
    if (c.kind == 't7') {
      final tc = t7Cfg(rom, off);
      out.add(Extra(
          rom: _slice(rom, c.romOff, c.romOff + c.romLen),
          figs: tc != null ? [for (final f in tc.figs) T7Fig(f.name, _slice(rom, f.off, f.off + f.len))] : [],
          name: e.name,
          off: off,
          saveOff: c.saveOff,
          clock: tc == null || (tc.flags & 2) != 0));
    } else if (c.kind == 'v1') {
      // bit 4: the clock bit is meant (test26..28 lost it): else on
      final fl = u32(rom, off + c0 + 20);
      out.add(Extra(kind: 'v1', rom: _slice(rom, c.romOff, c.romOff + c.romLen), name: e.name, off: off, saveOff: c.saveOff, clock: (fl & 16) != 0 ? (fl & 2) != 0 : true));
    } else if (c.kind == 'gb') {
      final fl = u32(rom, off + c0 + 20), st = _slice(rom, c.romOff, c.romOff + c.romLen);
      out.add(Extra(
          kind: 'gb',
          rom: (fl & 4) != 0 ? _gbUnpage(st, fl >> 16) : gbUntrim(st, fl),
          name: e.name,
          off: off,
          saveOff: c.saveOff,
          keys: keys9(),
          inv: (fl & 2) != 0,
          save: _slice(rom, c.saveOff, c.saveOff + _gbSaveLen((fl & 8) != 0))));
    } else if (c.kind == 'sms') {
      final fl = u32(rom, off + c0 + 20);
      out.add(Extra(
          kind: 'sms',
          rom: _slice(rom, c.romOff, c.romOff + c.romLen),
          title: _or(_cfgName(rom, off + c0), 'MASTER SYSTEM'),
          gg: (fl & 4) != 0,
          name: e.name,
          off: off,
          saveOff: c.saveOff,
          keys: keys9(),
          inv: (fl & 2) != 0,
          save: _slice(rom, c.saveOff, c.saveOff + 0x10000)));
    } else if (c.kind == 'ab') {
      out.add(Extra(
          kind: 'ab',
          rom: _slice(rom, c.romOff, c.romOff + c.romLen),
          title: _or(_cfgName(rom, off + c0), 'ARDUBOY'),
          name: e.name,
          off: off,
          saveOff: c.saveOff,
          keys: keys9(),
          inv: (u32(rom, off + c0 + 20) & 2) != 0,
          save: _slice(rom, c.saveOff, c.saveOff + abSave)));
    } else if (c.kind == 'pm') {
      final fl = u32(rom, off + c0 + 20), ks = <int>[];
      for (var q = 0; q < 9; q++) {
        ks.add(rom[off + c0 + 40 + 2 * q] | (rom[off + c0 + 41 + 2 * q] << 8));
      }
      out.add(Extra(
          kind: 'pm',
          rom: _slice(rom, c.romOff, c.romOff + c.romLen),
          title: _or(_cfgName(rom, off + c0), 'POKEMON MINI'),
          name: e.name,
          off: off,
          saveOff: c.saveOff,
          keys: ks,
          inv: (fl & 2) != 0,
          save: _slice(rom, c.saveOff, c.saveOff + pmBiosAt),
          bios: (fl & 4) != 0 ? _slice(rom, c.saveOff + pmBiosAt, c.saveOff + pmBiosAt + 0x1000) : null));
    } else if (c.kind == 'wolf') {
      out.add(Extra(kind: 'wolf', pack: _slice(rom, c.romOff, c.romOff + c.romLen), name: e.name, off: off, saveOff: c.saveOff, keyMap: _wolfKeysRead(rom, off + c0), save: _slice(rom, c.saveOff, c.saveOff + 0x10000)));
    } else if (c.kind == 'tama') {
      final g = _ff(devices[c.dev]!.size);
      for (var b = 0; b < (g.length >> 16); b++) {
        var k = c.map[b];
        if (k == 0xFF) continue;
        if (k == 0xFE) k = b;
        _set(g, _sub(rom, c.guestOff + (k << 16), c.guestOff + (k << 16) + 0x10000), b << 16);
      }
      if (c.lzOff != 0 && c.lzOff + 512 <= rom.length) lzUnpack((a, n) => _sub(rom, c.lzOff + a, c.lzOff + a + n), g); // GUEST_LZ
      _guestPagesIn(rom, c, g);
      final fl = u32(rom, off + c0 + 156);
      out.add(Extra(kind: 'tama', dev: c.dev, guest: g, name: e.name, off: off, saveOff: c.saveOff, clock: (fl & 2) != 0, nfc: (fl & 4) == 0, opt: _optOf(fl), packed: c.lzOff != 0)); // test20 PACK_OPT
    } else if (c.kind == 't18') {
      final fw = t18FromRom(rom, off);
      if (fw != null) out.add(Extra(kind: 't18', fw: fw, name: e.name, off: off, saveOff: c.saveOff, clock: (u32(rom, off + c0 + 400) & 2) != 0, opt: _optOf(u32(rom, off + c0 + 400))));
    }
  }
  for (final x in out) {
    // 1.7.3 test7
    final fo = _sessFlagsAt(rom, x.off, extraKind(x));
    if (fo != 0) x.sess = (u32(rom, fo) & _NOSESS) == 0;
  }
  return out;
}

/// Where a program's flags word lies (for NOSESS), 0: none.
int _sessFlagsAt(Uint8List rom, int off, String k) {
  final c = off + 0x140;
  if (k == 'tama') return c + 156;
  if (k == 't18') return c + 400;
  if (k == 't7') return c + 24 + _T7_FIG_MAX * 24;
  if (k == 'v1' || k == 'gb' || k == 'sms' || k == 'pm' || k == 'ab') return c + 20;
  return 0;
}

/// Clock switch of all three emulators (1.5.1): at every start the guest clock is set to the Paradise's time,
/// nothing is caught up (true), or the old way (false). null: no emulator, or a TamaEmu program too old.
int _emuClockAt(Uint8List rom) {
  final m = u32(rom, _APP_OFF + 0x140);
  if (m == t18Magic) return _APP_OFF + 0x140 + 400;
  if (m == t7Magic) return _APP_OFF + 0x140 + 24 + _T7_FIG_MAX * 24;
  if (m == _PMXC && u32(rom, _APP_OFF + 0x144) >= 4) return _APP_OFF + 0x140 + 156;
  return -1;
}

/// 1.7.3 test7: "remember where you left off" of the main program at 0x0A0000 (false: flags bit 12). null: none.
int _emuSessAt(Uint8List rom) {
  final a = _emuClockAt(rom);
  return a >= 0
      ? a
      : u32(rom, _APP_OFF + 0x140) == v1Magic
          ? _APP_OFF + 0x140 + 20
          : -1;
}

bool? emuSessGet(Uint8List rom) {
  final a = _emuSessAt(rom);
  return a < 0 ? null : (u32(rom, a) & _NOSESS) == 0;
}

Uint8List emuSessSet(Uint8List rom, bool on) {
  final a = _emuSessAt(rom);
  if (a < 0 || ((u32(rom, a) & _NOSESS) == 0) == on) return rom;
  final out = _copy(rom);
  w32(out, a, (u32(out, a) & ~_NOSESS) | (on ? 0 : _NOSESS));
  return out;
}

/* 1.6.8: TamaEmu and T18Emu: volume (0 normal, 1 quiet, 2 loud, 3 off), brightness (0 100 %, 1 75, 2 50, 3 25 %),
 * screen off after (0 like the toy, 1..7 = 10 s, 20 s, 30 s, 1, 2, 5, 10 min) in the flags, bits 16-17, 18-19, 20-22 */
const int _OPT_MASK = 0xF7F0000;
const int _NOSESS = 0x1000; // 1.7.3 test7: flags bit 12 of the programs: no session on leaving, only the game's own save
// 1.6.8 (test45): dim = light step 0..10 (OPT_LV: 100, 5, 10, 20 .. 90 %), bits 24-27 = step + 1; 0 there = the old bits 18-19
const List<int> optLv = [100, 5, 10, 20, 30, 40, 50, 60, 70, 80, 90];
const List<int> _OPT_OLD = [0, 8, 6, 3];
int _optBits(EmuOpt? o) => o != null ? ((o.vol & 3) << 16) | (o.dim != 0 ? ((o.dim.remainder(11) + 1) << 24) : 0) | ((o.off & 7) << 20) : 0;
EmuOpt _optOf(int f) {
  final n = (f >> 24) & 15;
  return EmuOpt(vol: (f >> 16) & 3, dim: n != 0 && n <= 11 ? n - 1 : _OPT_OLD[(f >> 18) & 3], off: (f >> 20) & 7);
}

EmuOpt? emuOptGet(Uint8List rom) {
  final m = u32(rom, _APP_OFF + 0x140);
  if (m != t18Magic && m != _PMXC) return null;
  final a = _emuClockAt(rom);
  return a < 0 ? null : _optOf(u32(rom, a));
}

Uint8List emuOptSet(Uint8List rom, EmuOpt? o) {
  final m = u32(rom, _APP_OFF + 0x140);
  if (m != t18Magic && m != _PMXC) return rom;
  final a = _emuClockAt(rom);
  if (a < 0) return rom;
  final out = _copy(rom);
  w32(out, a, (u32(out, a) & ~_OPT_MASK) | _optBits(o));
  return out;
}

bool? emuClockGet(Uint8List rom) {
  final a = _emuClockAt(rom);
  return a < 0 ? null : (u32(rom, a) & 2) != 0;
}

/// 4U/4U+ (1.6.8): NFC chip stand-in on (true, default) or off (flags bit 2). null without a 4U TamaEmu.
bool? emuNfcGet(Uint8List rom) {
  if (u32(rom, _APP_OFF + 0x140) != _PMXC || u32(rom, _APP_OFF + 0x144) < 4) return null;
  final k = u32(rom, _APP_OFF + 0x140 + 20);
  if (k != 3 && k != 4) return null;
  return (u32(rom, _APP_OFF + 0x140 + 156) & 4) == 0;
}

Uint8List emuNfcSet(Uint8List rom, bool on) {
  if (emuNfcGet(rom) == null || emuNfcGet(rom) == on) return rom;
  final out = _copy(rom);
  const a = _APP_OFF + 0x140 + 156;
  w32(out, a, (u32(out, a) & ~4) | (on ? 0 : 4));
  return out;
}

Uint8List emuClockSet(Uint8List rom, bool on) {
  final a = _emuClockAt(rom);
  if (a < 0 || ((u32(rom, a) & 2) != 0) == on) return rom;
  final out = _copy(rom);
  w32(out, a, (u32(out, a) & ~2) | (on ? 2 : 0));
  return out;
}

/// Clock switch of T18Emu: at every start the Paradise's time (true) or the game time caught up (false).
bool? t18ClockGet(Uint8List rom) => u32(rom, _APP_OFF + 0x140) == t18Magic ? (u32(rom, _APP_OFF + 0x140 + 400) & 2) != 0 : null;
Uint8List t18ClockSet(Uint8List rom, bool on) {
  if (u32(rom, _APP_OFF + 0x140) != t18Magic) return rom;
  final out = _copy(rom);
  const c = _APP_OFF + 0x140 + 400;
  w32(out, c, (u32(out, c) & ~2) | (on ? 2 : 0));
  return out;
}

/// Local time when writing to the device (first start without a clock note).
Uint8List t18Wall(Uint8List rom, int counter, DateTime date) {
  if (u32(rom, _APP_OFF + 0x140) != t18Magic) return rom;
  final out = _copy(rom);
  _wall(out, _APP_OFF + 0x140 + 416, counter, date);
  return out;
}

/* MAIN_LZ: packing of the main TamaEmu as emuPatch does it (for room and hints in the Studio) */
/// 1.7.6 SAVE_PACK_ASK: does this firmware (with its save) fit as the main program only packed?
bool mainNeedsPack(Uint8List g, String dev, [Uint8List? app]) {
  try {
    _mainPick(g, dev, app ?? embedded()?.app, false);
    return false;
  } catch (e) {
    return e is EmuError && e.needPack;
  }
}

PackedGuest packMain(Uint8List g, String dev, [Uint8List? app, bool pack = false]) {
  PackedGuest pk;
  try {
    pk = _mainPick(g, dev, app ?? embedded()?.app, pack);
  } catch (_) {
    pk = packGuest(g, dev, lz: true);
  }
  final r = PackedGuest(map: pk.map, blob: pk.blob, lzOff: pk.lzOff, lzBlocks: pk.lzBlocks, blocks: pk.blocks, big: pk.big || _GUEST_OFF + pk.blob.length + _SPARE_MIN > _GUEST_END, pages: pk.pages);
  r.raw = pk.raw;
  r.few = pk.few;
  return r;
}

/* 1.7.3 test19 MAIN_RAW, test20: the main TamaEmu goes in unpacked unless "pack" is chosen (as in the menu). Unpacked it
 * needs a few spare pages for the firmware's own writes: with fewer than 6 (a P's with its VDP set: 3) the Studio asks
 * to pack it (e.needPack) instead of building a device that may hang. */
/* 1.7.3 test21 MAIN_FEW: 6 spare pages were too few: items and download content need many more (a VDP set about 35).
 * Unpacked a P's keeps 19, an iD L 31, a 4U+ 27. Below MAIN_FEW_MIN the Studio now packs only as many of the cold
 * blocks as needed (those that pack best first), the rest stays unpacked. */
const bool _MAIN_FEW = true;
const int _MAIN_RAW_MIN = _MAIN_FEW ? 40 : 6;
int _mainSpare(PackedGuest r) {
  final big = r.big || _GUEST_OFF + r.blob.length + _SPARE_MIN > _GUEST_END, gEnd = big ? _BIG_END : _GUEST_END, gOff = big ? _BIG_OFF : _GUEST_OFF;
  final lo = (gOff + r.blob.length + 0x1FFF) & ~0x1FFF;
  return math.min(64, ((gEnd & ~0x1FFF) - (lo + 0x2000)) >> 13) - r.pages.length;
}

PackedGuest _mainPick(Uint8List g, String dev, Uint8List? app, bool pack) {
  final lz = _MAIN_LZ && app != null && tamaLzCan(app);
  if (lz && pack) return packGuest(g, dev, lz: true);
  PackedGuest r;
  try {
    r = packGuest(g, dev);
  } catch (_) {
    // BIG_LZ: only fits packed
    if (_BIG_LZ && lz && packAsk) throw EmuError('this firmware only fits packed', needPack: true);
    rethrow;
  }
  if (lz && _mainSpare(r) < _MAIN_RAW_MIN) {
    if (_MAIN_FEW && _LZ_WARM[dev] != null) {
      final G = _ff(devices[dev]!.size);
      _set(G, _sub(g, 0, math.min(g.length, G.length)), 0);
      final cand = <(int, int)>[];
      for (var b = 0; b < (G.length >> 16); b++) {
        if (r.map[b] != 0xFF && _lzOk(dev, b)) cand.add((b, lzPack(G, [b]).length));
      }
      _sort(cand, (x, y) => x.$2 != y.$2 ? x.$2 - y.$2 : x.$1 - y.$1);
      final only = <int>[];
      for (final c in cand) {
        only.add(c.$1);
        final q = packGuest(g, dev, lz: true, lzOnly: List.of(only));
        if (_mainSpare(q) >= _MAIN_RAW_MIN) return q..few = only.length;
      }
    }
    throw EmuError('unpacked this firmware leaves too few spare pages, pack it', needPack: true);
  }
  return r..raw = true;
}

/// The main TamaEmu program and the launcher template (emu.bin, stub_tpl.bin).
class EmuEmbedded {
  EmuEmbedded(this.app, this.stub);
  final Uint8List app, stub;
}

EmuEmbedded? embedded() {
  final b = emuBinaries;
  if (b?.emu == null || b?.stubTpl == null) return null;
  return EmuEmbedded(b!.emu!, b.stubTpl!);
}

// ------------------------------------------------------------ tables
// Stubs of 1.2.7 (autostart once per power-on): only read, the Studio puts in the current one
const List<String> _STUB_127 = [
  'crYA8IW4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAN/4UMAu4N/4UMAr4N/4TMAo4N/4TMAl4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACEiIiIxMzMzQURERFFVVVUt6Q9QFEgBaBRKUrEUShNoFEiDQgXQEGAR9ABvAdD/952/DUgQShNoEfTAbw/RGAxO8qFxiEID0EDyAAPO8qFzATMTYJiyWii/9IivAeAAIxNgvegPUGBHAIABQGFmZmb8DwAgQVJQQfgPACBytk/wikNI8kECGmAEItpgT/SAAdpoRCoB0AE5+tENSAAhT/SAMlD4BDtB+AQ7BDr50b/zT4+/82+PB0gAIQFgBkgBaAH04GEFShFDAWC/80+P/ufNqzQSCO0A4AztAOAEAPoF',
  'crYBTADwirjNqzQSAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAN/4UMAu4N/4UMAr4N/4TMAo4N/4TMAl4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACEiIiIxMzMzQURERFFVVVUt6Q9QFkgBaBZKUrEWShNoFkiDQgXQEGAR9ABvAdD/952/D0gSShNoEfTAbxPRGAxO8qFxiEID0EDyAAPO8qFzATMTYJiyWigH0wpMACw/9IWvcrYQ4AAjE2C96A9QYEcAgAFAYWZmZvwPACBBUlBB+A8AIAHviWdytk/wikNI8kECGmAEItpgT/SAAdpoRCoB0AE5+tEgRgAhT/SAMlD4BDtB+AQ7BDr50b/zT4+/82+PBkgAIQFgBUgBaAH04GEEShFDAWC/80+P/ucI7QDgDO0A4AQA+gU=',
];
// Menu stub of 1.6.0 to 1.6.7 (menu address at 0x148, before the launcher entry of 1.6.8)
const String _STUB_FELD_167 =
    'crYBTADworjNqzQScrYERgTxoEQE9Yg0APCYuAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAN/4UMAu4N/4UMAr4N/4TMAo4N/4TMAl4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACEiIiIxMzMzQURERFFVVVUt6Q9QH0gBaB9K2rEfSpN4w7n/I5Nwk3ijsR1KE2gdSINCDdAcSINCA9AcSABoHigG0hlIEGAR9ABvA9D/946/FUgQYA9IFkoTaBH0wG8T0RgMTvKhcYhCA9BA8gADzvKhcwEzE2CYslooB9MNTAAsP/R0r3K2F+AAIxNgvegPUGBHAAAAgAFAYWZmZhjtAOD8DwAgUE1YTFBNWFIEAwBF+A8AIAHviWdytk/wikNI8kECGmAEItpgT/SAAdpoRCoB0AE5+tEgRgAhT/SAMlD4BDtB+AQ7BDr50b/zT4+/82+PBkgAIQFgBUgBaAH04GEEShFDAWC/80+P/ucI7QDgDO0A4AQA+gU=';
// Stubs up to 1.7.2 test18 (before the B fallback to the flash app): only read
const List<String> _STUB_172 = [
  'crYA8J24AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAN/4UMAu4N/4UMAr4N/4TMAo4N/4TMAl4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACEiIiIxMzMzQURERFFVVVUt6Q9QHUgBaB1K2rEdSpN4w7n/I5Nwk3ijsRtKE2gbSINCDdAaSINCA9AaSABoHigG0hdIEGAR9ABvA9D/946/E0gQYA1IFEoTaBH0wG8P0RgMTvKhcYhCA9BA8gADzvKhcwEzE2CYsloov/R3rwHgACMTYL3oD1BgRwAAAIABQGFmZmYY7QDg/A8AIFBNWExQTVhSBAMARfgPACBytk/wikNI8kECGmAEItpgT/SAAdpoRCoB0AE5+tENSAAhT/SAMlD4BDtB+AQ7BDr50b/zT4+/82+PB0gAIQFgBkgBaAH04GEFShFDAWC/80+P/ufNqzQSCO0A4AztAOAEAPoF',
  'crYBTADwwLjNqzQScrYERgTxoEQE9Yg0APC2uAAAAABytgFMAPCwuAHviWcA8Iy4AAAAAAAAAAAAAAAAAAAAAN/4UMAu4N/4UMAr4N/4TMAo4N/4TMAl4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACEiIiIxMzMzQURERFFVVVUt6Q9QH0gBaB9K2rEfSpN4w7n/I5Nwk3ijsR1KE2gdSINCDdAcSINCA9AcSABoHigG0hlIEGAR9ABvA9D/946/FUgQYA9IFkoTaBH0wG8U0RgMTvKhcYhCA9BA8gADzvKhcwEzE2CYslooCNNf+OxAACw/9HOvcrY04AAjE2C96A9QYEcAgAFAYWZmZhjtAOD8DwAgUE1YTFBNWFIEAwBF+A8AIC3pD1ANSAGIQojSQ5KykUIQ0YGLQPLkcpFCC9NA9jMCkUIH2MGLATkMKQPScrZf+FBBBeC96A9QYEcAAADg72Bytk/wikNI8kECGmAEItpgT/SAAdpoRCoB0AE5+tEgRgAhT/SAMlD4BDtB+AQ7BDr50b/zT4+/82+PBkgAIQFgBUgBaAH04GEEShFDAWC/80+P/ucI7QDgDO0A4AQA+gU=',
];
// Stubs of 1.7.2 test19 to 1.7.3 test28 (before BFALL_NOA): only read
const List<String> _STUB_173 = [
  'crYBTADwzLjNqzQSAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAN/4UMAu4N/4UMAr4N/4TMAo4N/4TMAl4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACEiIiIxMzMzQURERFFVVVUt6Q9QMEgBaDBKE3gLu/8jE3ATeOuxEfSAbxrRLEoSaCxIgkIV0CxIAGgeKAXTK0iCQgLQKkiCQgvRKkgCaCpLmkIG0QJpKUuaQgLRcrYcRlTgHUgBaCZK2rEmSpN4w7n/I5Nwk3ijsRlKE2gZSINCDdAaSINCA9AXSABoHigG0hZIEGAR9ABvA9D/92e/E0gQYA1IGEoTaBH0wG8P0RgMTvKhcYhCA9BA8gADzvKhcwEzE2CYsloov/RQrwHgACMTYL3oD1BgRwCAAUAZ7QDg/A8AIFBNWEwEAwBFUE1YUlBNWE0A4P9gU09OSQAA/2BhZmZmGO0A4PgPACBytk/wikNI8kECGmAEItpgT/SAAdpoRCoB0AE5+tEgRgAhT/SAMlD4BDtB+AQ7BDr50b/zT4+/82+PBkgAIQFgBUgBaAH04GEEShFDAWC/80+P/ucI7QDgDO0A4AQA+gU=',
  'crYBTADw8rjNqzQScrYERgTxoEQE9Yg0APDouAAAAABytgFMAPDiuAHviWcA8L64AAAAAAAAAAAAAAAAAAAAAN/4UMAu4N/4UMAr4N/4TMAo4N/4TMAl4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACEiIiIxMzMzQURERFFVVVUt6Q9QM0gBaDNKE3gLu/8jE3ATeOuxEfSAbxrRL0oSaC9IgkIV0C9IAGgeKAXTLkiCQgLQLUiCQgvRLUgCaC1LmkIG0QJpLEuaQgLRcrYcRnrgIEgBaClK2rEpSpN4w7n/I5Nwk3ijsRxKE2gcSINCDdAdSINCA9AaSABoHigG0hlIEGAR9ABvA9D/92e/FkgQYBBIG0oTaBH0wG8U0RgMTvKhcYhCA9BA8gADzvKhcwEzE2CYslooCNNf+DhBACw/9EyvcrY/4AAjE2C96A9QYEcAAACAAUAZ7QDg/A8AIFBNWEwEAwBFUE1YUlBNWE0A4P9gU09OSQAA/2BhZmZmGO0A4PgPACAt6Q9QDUgBiEKI0kOSspFCENGBi0Dy5HKRQgvTQPYzApFCB9jBiwE5DCkD0nK2X/i0QQXgvegPUGBHAAAA4O9gcrZP8IpDSPJBAhpgBCLaYE/0gAHaaEQqAdABOfrRIEYAIU/0gDJQ+AQ7QfgEOwQ6+dG/80+Pv/NvjwZIACEBYAVIAWgB9OBhBEoRQwFgv/NPj/7nCO0A4AztAOAEAPoF',
];
/* 1.6.8: the eight LCD icons (16x16, bit 15 left; 0..3 above, 4..7 below), drawn by mameise. The P1/P2 set
 * for all toys without their own set. 1.7.3 test28: Genjintchi, Morino, Umino; 1.7.6: Mothra. */
const Map<String, List<List<int>>> _V1_ICONS = {
  'ANGEL': [
    [0x0000, 0x0000, 0x0000, 0x1C38, 0x2244, 0x4182, 0x4422, 0x500A, 0x4202, 0x2204, 0x1108, 0x0910, 0x0420, 0x0240, 0x0180, 0x0000],
    [0x0000, 0x0000, 0x0038, 0x002C, 0x0024, 0x003C, 0x0040, 0x0080, 0x0100, 0x1A00, 0x2400, 0x4A00, 0x5A00, 0x4400, 0x3800, 0x0000],
    [0x0000, 0x0100, 0x0820, 0x0000, 0x2108, 0x0280, 0x1C70, 0x0820, 0x2548, 0x06C0, 0x0440, 0x1010, 0x0000, 0x0440, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x1FF8, 0x2404, 0x4202, 0x5A03, 0x5A03, 0x5B57, 0x5AAA, 0x5A02, 0x4202, 0x2404, 0x1FF8, 0x0000, 0x0000, 0x0000],
    [0x0000, 0x0004, 0x000C, 0x0008, 0x01E0, 0x0210, 0x0788, 0x0848, 0x1030, 0x2F20, 0x30C0, 0x2640, 0x1080, 0x0F00, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0000, 0x1C3C, 0x1C44, 0x1C84, 0x0304, 0x0304, 0x0484, 0x0844, 0x1024, 0x1014, 0x100C, 0x1FFC, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0180, 0x0420, 0x0000, 0x1048, 0x00C0, 0x01C0, 0x1248, 0x0240, 0x0810, 0x03C0, 0x03C0, 0x0180, 0x0180, 0x0000],
    [0x0000, 0x0000, 0x0700, 0x0918, 0x112E, 0x2226, 0x242C, 0x3870, 0x0088, 0x0124, 0x0F4C, 0x1114, 0x1AA8, 0x0E70, 0x0C00, 0x0000],
  ],
  'DIGIMON': [
    [0x0000, 0x07E0, 0x1818, 0x2084, 0x4892, 0x8CB1, 0xA425, 0xB00D, 0x500A, 0x4402, 0x4202, 0x2104, 0x2004, 0x13C8, 0x0C30, 0x0000],
    [0x0000, 0x1800, 0x29C0, 0x4660, 0x6430, 0x1A50, 0x1188, 0x1148, 0x2A38, 0x2628, 0x2546, 0x18E2, 0x0494, 0x0318, 0x0000, 0x0000],
    [0x0800, 0x0800, 0x1C00, 0x1C08, 0x1C1C, 0x1C08, 0x1C08, 0x1CFC, 0x1C1C, 0x1C1C, 0x1C1C, 0x1C08, 0x1C14, 0x0824, 0x0022, 0x0000],
    [0x0000, 0x0000, 0x0408, 0x0E1C, 0x0408, 0x0808, 0x1CFC, 0x1C1C, 0x1F9C, 0x1C1C, 0x1C1C, 0x0808, 0x1414, 0x1224, 0x2222, 0x0000],
    [0x0000, 0x0000, 0x0000, 0x0000, 0x0300, 0x0380, 0x07C0, 0x0FE0, 0x07C0, 0x0000, 0x1FF0, 0x0FE0, 0x0000, 0x3FF8, 0x1FF0, 0x0000],
    [0x0000, 0x0240, 0x0810, 0x03C0, 0x25A4, 0x0810, 0x1008, 0x542A, 0x1428, 0x1668, 0x53CA, 0x0990, 0x0420, 0x23C4, 0x07E0, 0x0000],
    [0x0000, 0x0420, 0x0A50, 0x1188, 0x2104, 0x4202, 0x2404, 0x1808, 0x1018, 0x2024, 0x4042, 0x2084, 0x1188, 0x0A50, 0x0420, 0x0000],
    [0x0000, 0x0000, 0x0100, 0x01F0, 0x03F8, 0x07DC, 0x0FFE, 0x0FFE, 0x007E, 0x70FC, 0x01F8, 0x0BF0, 0x1000, 0x2000, 0x0000, 0x0000],
  ],
  'P': [
    [0x0000, 0x2A0C, 0x2A1C, 0x2A3C, 0x3E3C, 0x1C3C, 0x083C, 0x1C3C, 0x1C3C, 0x1C0C, 0x1C0C, 0x1C0C, 0x1C0C, 0x1C0C, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0000, 0x0240, 0x0000, 0x13C8, 0x0420, 0x2814, 0x0A50, 0x0A50, 0x2994, 0x0420, 0x13C8, 0x0000, 0x03C0, 0x0000],
    [0x0000, 0x3800, 0x4400, 0x441C, 0x443C, 0x387C, 0x00F8, 0x01F0, 0x03E0, 0x07C0, 0x1F80, 0x1F00, 0x0E00, 0x0600, 0x0000, 0x0000],
    [0x0000, 0x0020, 0x0010, 0x0128, 0x0094, 0x014A, 0x0220, 0x0410, 0x0828, 0x1840, 0x1C80, 0x1F00, 0x1E00, 0x2000, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0000, 0x1C00, 0x2200, 0x2200, 0x5218, 0x2224, 0x35E4, 0x1224, 0x1BE4, 0x0808, 0x0E38, 0x03E0, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x07E0, 0x1818, 0x2244, 0x6816, 0x6006, 0x2204, 0x2304, 0x310C, 0x1008, 0x1008, 0x0FF0, 0x0000, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0000, 0x0F80, 0x1FC0, 0x3FC2, 0x7F85, 0x7F25, 0x7E55, 0x7F15, 0x7F89, 0x3FC1, 0x1FC0, 0x0F80, 0x0000, 0x0000],
    [0x0000, 0x0E00, 0x3180, 0x2080, 0x4A40, 0x4040, 0x5170, 0x2E0C, 0x3004, 0x0E82, 0x02FA, 0x0252, 0x0104, 0x018C, 0x0070, 0x0000],
  ],
  'GENJIN': [
    [0x0000, 0x0000, 0x2000, 0x7800, 0x4F80, 0x0CFE, 0x1214, 0x3210, 0x2330, 0x3F30, 0x3F30, 0x0030, 0x0078, 0x0000, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0000, 0x3000, 0x3300, 0x77F0, 0x07F0, 0x0FF0, 0x1FC6, 0x1FDE, 0x01CC, 0x0008, 0x0000, 0x0000, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0000, 0x0220, 0x3260, 0x3840, 0x3808, 0x7F00, 0x27E4, 0x00FE, 0x2018, 0x041C, 0x0080, 0x0000, 0x0000, 0x0000],
    [0x0000, 0x0100, 0x0300, 0x0700, 0x07E0, 0x07F0, 0x01F0, 0x0FF0, 0x1FC0, 0x1F80, 0x0FFC, 0x03FE, 0x7FFE, 0x7FFE, 0x183C, 0x0000],
    [0x0000, 0x0000, 0x0200, 0x0218, 0x0000, 0x73C0, 0x0462, 0x0526, 0x0520, 0x2560, 0x60C8, 0x000C, 0x0440, 0x0440, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x1930, 0x3FFC, 0x15A8, 0x1C38, 0x1C38, 0x0000, 0x6006, 0x07E0, 0x4FF6, 0x0C30, 0x07E0, 0x0000, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0098, 0x3FE4, 0x2180, 0x1C3C, 0x1400, 0x0000, 0x4E76, 0x0FF8, 0x4E7A, 0x0C30, 0x07E0, 0x0000, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0038, 0x0D70, 0x0DE0, 0x07C0, 0x0388, 0x19BE, 0x3DBE, 0x7CE2, 0x0CC2, 0x06C0, 0x0080, 0x0000, 0x0000, 0x0000],
  ],
  'MORINO': [
    [0x0000, 0x0000, 0x0000, 0x07E0, 0x1818, 0x6184, 0x4182, 0x4002, 0x54A6, 0x34B4, 0x2004, 0x33C8, 0x1C38, 0x0000, 0x0000, 0x0000],
    [0x0000, 0x0338, 0x0370, 0x01F0, 0x0100, 0x1FFC, 0x3FCC, 0x7F98, 0x7FC8, 0x7FC8, 0x7F90, 0x7F90, 0x3FF8, 0x1FF8, 0x0E70, 0x0000],
    [0x0000, 0x0000, 0x0000, 0x03C0, 0x0660, 0x0C20, 0x0820, 0x7870, 0x0FFC, 0x3FC2, 0x600C, 0x6078, 0x3FC0, 0x0000, 0x0000, 0x0000],
    [0x0000, 0x001C, 0x0032, 0x0062, 0x0042, 0x1FC4, 0x303C, 0x6F98, 0x7A30, 0x6FA0, 0x3060, 0x3060, 0x6060, 0x3FC0, 0x0000, 0x0000],
    [0x0000, 0x0380, 0x1CE0, 0x781C, 0x7F0E, 0x41F6, 0x4E64, 0x4264, 0x6644, 0x604C, 0x6448, 0x70D8, 0x3EE0, 0x03C0, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x01FC, 0x07FE, 0x0E7C, 0x1E78, 0x1818, 0x3818, 0x3E30, 0x3E70, 0x3FE0, 0x7FC0, 0x6600, 0x0000, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0400, 0x2E00, 0x1300, 0x2190, 0x60D4, 0x2192, 0x1312, 0x2E12, 0x0432, 0x00E2, 0x008C, 0x0078, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0700, 0x7400, 0x6F00, 0x3F82, 0x3FDA, 0x7F8E, 0x7F7E, 0x7F7E, 0x3F8A, 0x3F82, 0x0F00, 0x0000, 0x0000, 0x0000],
  ],
  'UMINO': [
    [0x0000, 0x07E0, 0x0FF0, 0x1818, 0x324C, 0x6016, 0x6806, 0x6606, 0x6206, 0x63E6, 0x67E6, 0x33CC, 0x1818, 0x0FF0, 0x07E0, 0x0000],
    [0x0000, 0x0000, 0x3C00, 0x6E00, 0x4700, 0x651C, 0x39B6, 0x0FB6, 0x0536, 0x0512, 0x07BE, 0x04CC, 0x065C, 0x03F0, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0F00, 0x31E0, 0x233C, 0x6636, 0x6E42, 0x7ACE, 0x6BF2, 0x6BC2, 0x2ED2, 0x24C4, 0x1EF8, 0x03E0, 0x0000, 0x0000],
    [0x0000, 0x001C, 0x0032, 0x0062, 0x0042, 0x1FC4, 0x303C, 0x6F98, 0x7A30, 0x6FB0, 0x3060, 0x3060, 0x6060, 0x3FC0, 0x0000, 0x0000],
    [0x0000, 0x1100, 0x3FC0, 0x2C64, 0x6064, 0x4332, 0x5DA2, 0x29C0, 0x20E4, 0x6060, 0x6020, 0x2060, 0x3180, 0x0F00, 0x0000, 0x0000],
    [0x0000, 0x07C0, 0x0C60, 0x0FE0, 0x0820, 0x0FC0, 0x0D60, 0x1910, 0x1110, 0x17D0, 0x1390, 0x1110, 0x1830, 0x1FF0, 0x07C0, 0x0000],
    [0x0000, 0x0000, 0x0400, 0x2E00, 0x1300, 0x2190, 0x60DC, 0x2192, 0x1112, 0x2E12, 0x0432, 0x00E2, 0x0084, 0x0078, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0018, 0x0390, 0x07C6, 0x0F80, 0x0F80, 0x7F86, 0x7FF0, 0x3FF0, 0x3FE0, 0x3380, 0x1000, 0x0000, 0x0000, 0x0000],
  ],
  'MOTHRA': [
    [0x0000, 0x07E0, 0x0C38, 0x110C, 0x2124, 0x6526, 0x5602, 0x5812, 0x4902, 0x6106, 0x2184, 0x3188, 0x1830, 0x07E0, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0F00, 0x1986, 0x108E, 0x129C, 0x1E98, 0x0C80, 0x00B0, 0x79F8, 0x7DD8, 0x3EC0, 0x1EC0, 0x0660, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0000, 0x381C, 0x4836, 0x0000, 0x03E0, 0x0180, 0x0E70, 0x1E78, 0x1E78, 0x0E70, 0x0000, 0x0000, 0x0000, 0x0000],
    [0x0000, 0x0080, 0x0180, 0x0300, 0x07C0, 0x07E0, 0x0780, 0x0E00, 0x07E0, 0x0070, 0x0E18, 0x3F18, 0x3038, 0x3DF0, 0x1FC0, 0x0000],
    [0x0000, 0x0000, 0x0004, 0x0006, 0x0012, 0x3F1A, 0x7E7E, 0x7CF6, 0x7856, 0x7C56, 0x7F86, 0x3F84, 0x1F00, 0x0000, 0x0000, 0x0000],
    [0x0000, 0x0000, 0x0810, 0x1C38, 0x1E78, 0x1C38, 0x1818, 0x3E7C, 0x3A5C, 0x7C3E, 0x3E7C, 0x1428, 0x1428, 0x1428, 0x0000, 0x0000],
    [0x0000, 0x0100, 0x0520, 0x17E8, 0x1FF0, 0x3C34, 0x181C, 0x1818, 0x781E, 0x1838, 0x3E78, 0x07F4, 0x0BD0, 0x0240, 0x0240, 0x0000],
    [0x0000, 0x0000, 0x1110, 0x1924, 0x6D6C, 0x3118, 0x0100, 0x3FFC, 0x0380, 0x1198, 0x358C, 0x6DA2, 0x0DB0, 0x0910, 0x0000, 0x0000],
  ],
};
