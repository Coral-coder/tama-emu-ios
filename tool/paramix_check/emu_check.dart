// Check of lib/paramix/emu_build.dart against third_party/paramix-studio/src/emu.js (the original).
// DUMPS=<folder with water.bin ...> dart run tool/paramix_check/emu_check.dart
// Prints one line per case: "<case name> <sha256 or value>", the same lines as tool/paramix_check/emu.js.
// The guest firmware and the games are synthetic (seeded xorshift32, with the headers the detection looks for).

// ignore_for_file: avoid_print, non_constant_identifier_names

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tama_tools/paramix/emu_build.dart' as E;
import 'package:tama_tools/paramix/emu_build.dart' show Extra, EmuOpt, EmuApps, T7App, T18App, V1App, DoomApp, T7Fig, AppEntry, EmuError;
import 'package:tama_tools/paramix/sprites.dart' show Rgba;

late final String ps;
Uint8List bin(String f) => File('$ps/$f').readAsBytesSync();

class Bins {
  late final Uint8List emu = bin('emu/emu.bin'), stub = bin('emu/stub_tpl.bin'), t7 = bin('t7/t7.bin'), t7x = bin('t7/t7x.bin'), t18 = bin('t18/t18.bin'), t18x = bin('t18/t18x.bin');
  late final Uint8List v1 = bin('v1/v1.bin'), v3 = bin('v3/v3.bin'), gb = bin('gb/gb.bin'), gbc = bin('gb/gbc.bin'), sms = bin('sms/sms.bin'), pm = bin('pm/pm.bin'), ab = bin('ab/ab.bin');
  late final Uint8List wolf = bin('wolf/wolf.bin'), wolfsod = bin('wolf/wolfsod.bin'), doomApp = bin('doom/doomf_app.bin'), doomXip = bin('doom/doomf_xip.bin');
}

final B = Bins();
final lines = <String>[];
String sha(List<int> b) => sha256.convert(b).toString();
String H(Uint8List? b) => b == null ? 'null' : '${b.length}:${sha(b)}';
void out(String n, Object? v) => lines.add('$n $v');
void T(String n, Object? Function() f) {
  try {
    out(n, f());
  } on EmuError catch (e) {
    out(n, 'ERR ${e.message}${e.needPack ? ' needPack' : ''}${e.room ? ' room${e.frag ? ' frag' : ''}' : ''}${e.packHint ? ' packHint' : ''}${e.prog != null ? ' prog=${e.prog}' : ''}');
  } on StateError catch (e) {
    out(n, 'ERR ${e.message}');
  } on FormatException catch (e) {
    out(n, 'ERR ${e.message}');
  } catch (e) {
    out(n, 'ERR INTERNAL');
  }
}

String msg(Object e) => e is StateError ? e.message : (e is FormatException ? e.message : 'INTERNAL $e');
String bo(bool? v) => v == null ? '-' : (v ? '1' : '0');
String hx(int? v) => v == null ? '-' : (v & 0xFFFFFFFF).toRadixString(16);
int u32(Uint8List b, int o) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) & 0xFFFFFFFF;
void w32(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
  b[o + 2] = (v >> 16) & 255;
  b[o + 3] = (v >> 24) & 255;
}

void asc(Uint8List b, int o, String s) {
  for (var i = 0; i < s.length; i++) {
    b[o + i] = s.codeUnitAt(i);
  }
}

bool eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List cp(Uint8List b) => Uint8List.fromList(b);
Uint8List sub(Uint8List b, int a, [int? e]) => Uint8List.sublistView(b, math.min(a, b.length), math.min(e ?? b.length, b.length));
Uint8List ffs(int n) => Uint8List(n)..fillRange(0, n, 0xFF);
void fill(Uint8List b, int v, int a, [int? e]) => b.fillRange(a, e ?? b.length, v);
bool allFF(Uint8List b, int a, int e) {
  for (var i = a; i < e; i++) {
    if (b[i] != 0xFF) return false;
  }
  return true;
}

// ------------------------------------------------------------ synthetic inputs
int Function() rng(int seed) {
  var x = seed & 0xFFFFFFFF;
  if (x == 0) x = 1;
  return () {
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    return x;
  };
}

void fillRnd(Uint8List b, int off, int len, int seed) {
  final r = rng(seed);
  for (var i = 0; i < len; i++) {
    b[off + i] = r() & 255;
  }
}

void fillPat(Uint8List b, int off, int len, int seed) {
  for (var i = 0; i < len; i++) {
    b[off + i] = ((i >> 5) * 13 + (i & 7) * seed) & 255;
  }
}

Uint8List rndBytes(int n, int seed) {
  final b = Uint8List(n);
  fillRnd(b, 0, n, seed);
  return b;
}

const VEC = {'idl': 0x024CAA72, 'ps': 0x024FDFE6, '4u': 0x024F6256, '4u-plain': 0x024C680A};
Uint8List tamaFw(String dev, int pct, int seed) {
  final size = dev == 'pc' ? 0x400000 : 0x800000, g = ffs(size), r = rng(seed);
  for (var b = 0; b < size >> 16; b++) {
    final v = r();
    if (v % 100 >= pct) continue;
    final t = (v >> 8) % 5, o = b << 16;
    if (t == 0) {
      fillRnd(g, o, 0x10000, v);
    } else if (t == 1) {
      fillPat(g, o, 0x10000, v & 63);
    } else if (t == 2) {
      fillRnd(g, o + ((v >> 12) & 7) * 0x2000, 0x2000, v);
    } else if (t == 3) {
      fillRnd(g, o, 0x2000, v);
      fillPat(g, o + 0xC000, 0x1000, 5);
    } else {
      fillPat(g, o, 0x8000, v & 31);
      fillRnd(g, o + 0x8000, 0x4000, v);
    }
  }
  if (dev == 'pc') {
    w32(g, 0, 0xC01234);
  } else {
    w32(g, 0x400000, VEC[dev]!);
  }
  return g;
}

void utf16(Uint8List b, int o, String s) {
  for (var i = 0; i < s.length; i++) {
    b[o + 2 * i] = s.codeUnitAt(i);
    b[o + 2 * i + 1] = 0;
  }
}

Uint8List dlcRec(int len, int t, int c, int f, int fam, String name, String file, int seed, [int tail = 0]) {
  final b = rndBytes(len + tail, seed);
  asc(b, 0, 'TAMAGO');
  fill(b, 0, 6, 0x4C);
  for (var i = 0; i < name.length; i++) {
    b[6 + 2 * i] = 0;
    b[7 + 2 * i] = name.codeUnitAt(i);
  }
  asc(b, 0x34, file);
  b[0x48] = (len >> 24) & 255;
  b[0x49] = (len >> 16) & 255;
  b[0x4A] = (len >> 8) & 255;
  b[0x4B] = len & 255;
  b[0x4E] = t;
  b[0x50] = c;
  b[0x51] = f;
  if (len > 0x100) b[0xFF] = fam;
  var s = 0;
  for (var i = 0; i < len - 2; i++) {
    s += b[i];
  }
  b[len - 2] = (s >> 8) & 255;
  b[len - 1] = s & 255;
  return b;
}

Uint8List t7Rom(bool friends, int seed) {
  final b = rndBytes(friends ? 0xC0000 : 0xA0000, seed);
  if (friends) {
    b[0x3FFC] = 0;
    b[0x3FFD] = 0;
    b[0x7FFC] = 0x34;
    b[0x7FFD] = 0xC1;
  } else {
    b[0x3FFC] = 0x00;
    b[0x3FFD] = 0xC0;
  }
  return b;
}

Uint8List t7Fig(int len, int used, int seed) {
  final b = Uint8List(len);
  fillRnd(b, 0, used, seed);
  b[1] = 0xAA;
  b[2] = 0x55;
  b[0x11] = 0xAA;
  b[0x12] = 0x55;
  b[used - 1] = 0x77;
  return b;
}

Uint8List t7FigFull(int seed) {
  final one = t7Fig(0x100000, 0x30000, seed), b = Uint8List(0x400000 + 20);
  for (var k = 0; k < 4; k++) {
    b.setAll(k * 0x100000, one);
  }
  asc(b, 0x400000, 'dumped by a tool');
  return b;
}

Uint8List v1Rom(int len, int seed) {
  final b = rndBytes(len, seed);
  for (var i = 0; i < len; i += 2) {
    b[i] &= 0x0F;
  }
  return b;
}

Uint8List v3Rom(int seed) {
  final b = rndBytes(0x80000, seed);
  for (final o in [0x7FFA, 0x7FFC, 0x7FFE]) {
    b[o] = 0x10;
    b[o + 1] = 0xC0 + (o & 3);
  }
  return b;
}

Uint8List gbRom(int code, int color, String title, int seed, [int trimBanks = 0]) {
  final len = 0x8000 << code, b = rndBytes(len, seed);
  if (trimBanks != 0) fill(b, 0, len - trimBanks * 0x4000);
  fill(b, 0, 0x134, 0x150);
  asc(b, 0x134, title);
  b[0x143] = color;
  b[0x148] = code;
  var x = 0;
  for (var i = 0x134; i <= 0x14C; i++) {
    x = (x - b[i] - 1) & 255;
  }
  b[0x14D] = x;
  return b;
}

Uint8List smsRom(int len, int region, int seed, [bool copier = false]) {
  final b = rndBytes(len + (copier ? 512 : 0), seed), o = (copier ? 512 : 0) + (len >= 0x8000 ? 0x7FF0 : 0x1FF0);
  if (region >= 0) {
    asc(b, o, 'TMR SEGA');
    b[o + 15] = (region << 4) | 0x0C;
  }
  return b;
}

Uint8List pmRom(int len, int seed) {
  final b = rndBytes(len, seed);
  b[0x2100] = 0x4D;
  b[0x2101] = 0x4E;
  return b;
}

Uint8List pmBios(int seed) {
  final b = rndBytes(0x1000, seed);
  b[0] = 0x9A;
  b[1] = 0;
  return b;
}

String hex2(int v) => v.toRadixString(16).toUpperCase().padLeft(2, '0');
String abHexText(Uint8List data, String eol) {
  final t = StringBuffer();
  for (var a = 0; a < data.length; a += 16) {
    final n = math.min(16, data.length - a);
    final l = StringBuffer(':${hex2(n)}${hex2(a >> 8)}${hex2(a & 255)}00');
    var s = n + (a >> 8) + (a & 255);
    for (var i = 0; i < n; i++) {
      l.write(hex2(data[a + i]));
      s += data[a + i];
    }
    t.write('$l${hex2((-s) & 255)}$eol');
  }
  return '$t:00000001FF$eol';
}

Uint8List wolfPack(int len, int flags, int seed) {
  final b = rndBytes(len, seed);
  asc(b, 0, 'W3DP');
  w32(b, 8, flags);
  w32(b, 28, 10 + (flags & 3));
  w32(b, 60, 1 + flags);
  return b;
}

Uint8List doomWad(List<(String, Uint8List)> lumps) {
  var len = 12;
  final pos = <int>[];
  for (final l in lumps) {
    len = (len + 3) & ~3;
    pos.add(len);
    len += l.$2.length;
  }
  len = (len + 3) & ~3;
  final b = Uint8List(len + 16 * lumps.length);
  asc(b, 0, 'MCUW');
  w32(b, 4, lumps.length);
  w32(b, 8, len);
  for (var i = 0; i < lumps.length; i++) {
    final l = lumps[i];
    b.setAll(pos[i], l.$2);
    w32(b, len + 16 * i, l.$2.isNotEmpty ? pos[i] : 0);
    w32(b, len + 16 * i + 4, l.$2.length);
    asc(b, len + 16 * i + 8, l.$1);
  }
  return b;
}

Uint8List t18Fw(int seed, bool sanrio, int pct) {
  final g = ffs(0x800000), r = rng(seed);
  for (var b = 0; b < 128; b++) {
    final v = r();
    if (b < 2 || b == 0x12 || b == 0x40 || v % 100 < pct) {
      if ((v & 0x100) != 0) {
        fillRnd(g, b << 16, 0x10000, v);
      } else {
        fillPat(g, b << 16, 0x10000, v & 63);
      }
    }
  }
  fill(g, 0xFF, 0x5E0000, 0x800000);
  asc(g, 0, 'SPII');
  w32(g, 4, 0x2000000C);
  for (var k = 0; k < 45; k++) {
    final o = 0x2000 + k * 0x40;
    w32(g, o, 0xF8001230);
    w32(g, o + 8, 0xF8001231);
    w32(g, o + 20, 0xF8001232);
  }
  for (var k = 0; k < 9; k++) {
    final o = 0x4000 + k * 0x40;
    w32(g, o, 0xF8004440);
    w32(g, o + 4, 0xF8004441);
    w32(g, o + 8, 0xF8004442);
  }
  w32(g, 0x1000, 0xC0040000);
  w32(g, 0x1004, 0xF8009004);
  w32(g, 0x30000, 0xD0300000);
  w32(g, 0x30004, 0x3210);
  w32(g, 0x30008, 0xF8010020);
  g[0x120000 + 0x4F] = 0;
  asc(g, 0x120050, 'DispYobidashiIconInit() pYobi=%x');
  g[0x120050 + 32] = 0;
  w32(g, 0x121000, sanrio ? 0xF800D8B4 : 0xF800D100);
  w32(g, 0x121004, 0x20120050);
  fillRnd(g, 0x5E0000 + 0x21E000, 0x40, seed + 5);
  g[0x5E0000 + 0x21E020] = 0x39;
  g[0x5E0000 + 0x21E021] = 0x05;
  g[0x5E0000 + 0x21E070] = 8;
  for (var i = 0; i < 24; i++) {
    g[0x5E0000 + 0x21E053 + i] = 0;
  }
  return g;
}

Uint8List t18Rec(int len, int target, int cat, int price, String name, String file, int seed, bool pic) {
  final b = rndBytes(len, seed);
  asc(b, 0, 'TAMAGO');
  fill(b, 0, 6, 0x100);
  asc(b, 52, file);
  b[0x48] = 0;
  b[0x49] = (len >> 16) & 255;
  b[0x4A] = (len >> 8) & 255;
  b[0x4B] = len & 255;
  b[78] = (target >> 24) & 255;
  b[79] = (target >> 16) & 255;
  b[80] = (target >> 8) & 255;
  b[81] = target & 255;
  b[90] = cat >> 8;
  b[91] = cat & 255;
  b[118] = price >> 8;
  b[119] = price & 255;
  for (var i = 0; i < name.length && i < 12; i++) {
    final ch = name.codeUnitAt(i);
    b[94 + 2 * i] = 0;
    b[95 + 2 * i] = ch == 32
        ? 0x6C
        : ch == 42
            ? 0x63
            : ch >= 65 && ch <= 90
                ? 0xE0 + ch - 65
                : ch >= 48 && ch <= 57
                    ? 0xC6 + ch - 48
                    : 0x11;
  }
  if (pic && len >= 0x240) {
    const p = 0x202;
    b[0x200] = 0;
    b[0x201] = 1;
    b[p] = 0;
    b[p + 1] = 46;
    b[p + 2] = 8;
    b[p + 3] = 8;
    b[p + 4] = 4;
    b[p + 5] = 0;
    b[p + 6] = 0;
    b[p + 7] = 0;
    const pal = [0x07E0, 0xF800, 0x001F, 0x8410];
    for (var i = 0; i < 4; i++) {
      b[p + 8 + 2 * i] = pal[i] >> 8;
      b[p + 9 + 2 * i] = pal[i] & 255;
    }
    for (var i = 0; i < 32; i++) {
      b[p + 16 + i] = ((i * 7 + seed) & 3) | ((((i >> 2) + seed) & 3) << 4);
    }
  }
  if ((target >> 24) == 0x94) {
    b[0xB0] = 0x02;
    b[0xB1] = 0x40;
  }
  var s = 0;
  for (var i = 0; i < len - 2; i++) {
    s = (s + b[i]) & 0xFFFF;
  }
  b[len - 2] = s >> 8;
  b[len - 1] = s & 255;
  return b;
}

Rgba image(int w, int h, int mode, int seed) {
  final rgba = Uint8List(w * h * 4), r = rng(seed);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4, v = r();
      if (mode == 0) {
        rgba[o] = (x >> 3) * 40 & 255;
        rgba[o + 1] = (y >> 3) * 30 & 255;
        rgba[o + 2] = 128;
      } else if (mode == 1) {
        rgba[o] = v & 255;
        rgba[o + 1] = (v >> 8) & 0xF0;
        rgba[o + 2] = (v >> 16) & 0xC0;
      } else {
        rgba[o] = v & 255;
        rgba[o + 1] = (v >> 8) & 255;
        rgba[o + 2] = (v >> 16) & 255;
      }
      rgba[o + 3] = 255;
    }
  }
  return Rgba(w, h, rgba);
}

// ------------------------------------------------------------ what a result looks like
String pkStr(E.PackedGuest p) =>
    'blocks=${p.blocks} big=${bo(p.big)} lzOff=${hx(p.lzOff)} lzBlocks=${p.lzBlocks ?? '-'} raw=${bo(p.raw)} few=${p.few ?? '-'} pages=${p.pages.map((x) => '${x.v.toRadixString(16)}:${sha(x.data).substring(0, 8)}').join(',')} map=${sha(p.map)} blob=${H(p.blob)}';
String cfgStr(E.ExtraCfg? c) {
  if (c == null) return 'null';
  final plain = c.kind != 't18' && c.kind != 'tama';
  return '${c.kind} rom=${plain ? hx(c.romOff) : '-'}+${plain ? hx(c.romLen) : '-'} save=${hx(c.saveOff)}'
      '${c.kind == 'doom' ? ' cfg=${hx(c.cfg)} region=${hx(c.regionOff)}+${hx(c.regionLen)} code=${hx(c.codeOff)}' : ''}'
      '${c.kind == 't18' ? ' v=${c.version} flags=${hx(c.flags)} map=${c.map.map((v) => v.toRadixString(16)).join('.')} spare=${c.spare.map((v) => v.toRadixString(16)).join('.')}' : ''}'
      '${c.kind == 'tama' ? ' dev=${c.dev} guest=${hx(c.guestOff)}+${hx(c.guestSize)} spareEnd=${hx(c.spareEnd)} lzOff=${hx(c.lzOff)} map=${sha(c.map)}' : ''}';
}

String optStr(EmuOpt? o) => o == null ? '-' : '${o.vol}/${o.dim}/${o.off}';
String keysStr(Object? k) {
  if (k == null) return '-';
  if (k is List<int>) return k.join('.');
  final m = k as Map<String, Object>;
  return (m.keys.toList()..sort()).map((n) => '$n=${m[n] is bool ? bo(m[n] as bool) : m[n]}').join(',');
}

String xStr(Extra x) {
  final k = x.kind;
  return 'kind=${E.extraKind(x)} name=${x.name} off=${hx(x.off)} saveOff=${hx(x.saveOff)} clock=${bo(x.clock)} nfc=${bo(x.nfc)} sess=${bo(x.sess)} opt=${optStr(x.opt)} dev=${x.dev ?? '-'} pack=${bo(k == 'tama' ? x.packed : null)}'
      ' title=${x.title == null || x.title!.isEmpty ? '-' : x.title} gg=${bo(k == 'sms' ? x.gg : null)} inv=${bo(k == 'gb' || k == 'sms' || k == 'ab' || k == 'pm' ? x.inv : null)} keys=${keysStr(x.keys ?? x.keyMap)} region=${hx(x.region)} figs=${x.figs != null ? x.figs!.map((f) => '${f.name}:${H(f.data)}').join(',') : '-'}'
      ' data=${H(dataOf(x))} save=${H(x.save)} bios=${H(x.bios)}';
}

Uint8List? dataOf(Extra x) => x.rom ?? x.guest ?? x.fw ?? (x.kind == 'wolf' ? x.pack : null) ?? x.mcu;
Uint8List anyOf(Extra x) => (x.guest ?? x.fw ?? x.mcu ?? x.rom ?? x.pack)!;
String placedStr(E.AppsPlaced r) => 'low=${hx(r.low)} dl=${hx(r.dl)} freeKB=${r.freeKB} list=${r.list.map((l) => '${l.name}@${hx(l.off)}/${hx(l.src)}').join(',')} rom=${sha(r.rom)}';
String recStr(E.T18Record? r) => r == null
    ? 'null'
    : 'file=${r.file} name=${r.name} readable=${bo(r.readable)} art=${r.art} target=${hx(r.target)} cat=${r.cat} price=${r.price} model=${r.model} pic=${r.pic != null ? '${r.pic!.w}x${r.pic!.h}:${sha(r.pic!.data)}' : '-'} bytes=${H(r.bytes)}';
String itemsStr(E.T18Items it) =>
    'save=${bo(it.save)} points=${it.points} room=${it.room != null ? it.room!.name : '-'} ${it.areas.map((a) => '${a.key}(free=${a.free} noCount=${bo(a.noCount)}:${a.slots.map((s) => '${s.n}${s.rec != null ? '=${s.rec!.name}' : ''}x${s.count}${s.basic ? 'b' : ''}').join(',')})').join(' ')}';
String resStr(List<(int, int)> r) => r.map((x) => '${hx(x.$1)}-${hx(x.$2)}').join(',');

List<(int, Uint8List)> get stubs => [(0xB0000, B.stub)];
T7App t7app() => T7App(cp(B.t7), B.t7x);
T18App t18app() => T18App(cp(B.t18), B.t18x);
V1App v1app() => V1App(cp(B.v1), B.v3);
EmuApps APPS() => EmuApps(t7: t7app(), tama: B.emu, t18: t18app(), v1: v1app(), doom: DoomApp(B.doomApp, B.doomXip));

Extra xt(Uint8List rom, {List<T7Fig>? figs, bool? clock, bool? sess}) => Extra(rom: rom, figs: figs, clock: clock, sess: sess);
Extra tama(Uint8List g, String dev, {bool pack = false, EmuOpt? opt, bool? nfc, bool? sess, bool? clock, bool lzAll = false, List<int>? lzExtra}) =>
    Extra(kind: 'tama', guest: g, dev: dev, packed: pack, opt: opt, nfc: nfc, sess: sess, clock: clock, lzAll: lzAll, lzExtra: lzExtra);
Extra dx(Uint8List? mcu, {String? title, Object? ep, bool d2 = false, String? name, int? region, int? size, Map<String, Object>? keys, Uint8List? save}) =>
    Extra(kind: 'doom', mcu: mcu, title: title, ep: ep, d2: d2, name: name, region: region, size: size, keyMap: keys, save: save);

class Syn {
  final fws = <String, Uint8List>{};
  late Uint8List go, fr, figA, figB, figFull, v46, v48, v3, gb32, gb256, gbTrim, gbc1m, gbc2m, gbcTrim, sms1, gg, smsNo, smsCop, pm1, pmS, bios, abData, abOdd, wolf, sod, wolfSh, fw18, fw18s, fw18big, wadA, wadB, wadC;
  final pics = <String, Uint8List>{};
  late Uint8List Function(String) trec, recOf;
  late E.T18Record Function(String) sc;
}

// ------------------------------------------------------------ cases without a dump
Syn pure() {
  final S = Syn();
  out(
      'const',
      [E.menuRoom, E.menuRoomLen, E.packOpt, E.packAsk, E.packFew, E.detectTag, E.doomLink, E.guestLz, E.smsMagic, E.abMagic, E.abSave, E.abMax, E.pmMagic, E.pmSave, E.pmBiosAt, E.wolfMagic, E.gbMagic, E.v1Magic, E.t7xSave, E.appxMax, E.t7Magic, E.t18Magic, E.t18XipOff, E.t18SaveLen, E.stubOff, E.guestOff, E.bigOff]
          .map((v) => v is bool ? bo(v) : v)
          .join(','));
  out('const.keys', '${[E.smsKeysDefault, E.abKeysDefault, E.pmKeysDefault, E.gbKeysDefault, E.optLv, E.psStampAt].map((k) => k.join('.')).join(' ')} ${keysStr(E.wolfKeysDefault)}');
  out('const.devices', E.devices.keys.map((d) => '$d:${E.devices[d]!.kind}:${E.devices[d]!.size}:${E.devices[d]!.label}:${E.devices[d]!.par}').join(','));
  out('const.saveFlag', E.saveFlags.keys.map((d) {
    final f = E.saveFlags[d]!;
    return '$d:${f.kind}:${f.at.join('.')}:${f.off}:${f.on}:${f.len}';
  }).join(','));
  out('const.adults', E.t18Adults.map((a) => '${a.$1}${a.$2}').join(','));
  out(
      'embedded',
      [E.embedded()!.app, E.embedded()!.stub, E.t7Embedded()!.app, E.t7Embedded()!.x, E.t18Embedded()!.app, E.t18Embedded()!.xip, E.v1Embedded()!.app, E.v3Embedded(), E.gbEmbedded(), E.gbcEmbedded(), E.smsEmbedded(), E.pmEmbedded(), E.abEmbedded(), E.wolfEmbedded(), E.wolfSodEmbedded()]
          .map(H)
          .join(' '));
  // LZ
  final lzIn = <(String, Uint8List)>[('empty', Uint8List(0)), ('3', rndBytes(3, 1)), ('rnd1k', rndBytes(1024, 2)), ('zero1k', Uint8List(1024)), ('ff5', ffs(5))];
  {
    final p = Uint8List(1024);
    fillPat(p, 0, 1024, 9);
    lzIn.add(('pat1k', p));
    final q = rndBytes(4096, 3);
    q.setAll(2000, cp(sub(q, 100, 900)));
    fill(q, 7, 3000, 3600);
    lzIn.add(('mix4k', q));
    final z = Uint8List(70000);
    fillPat(z, 0, 70000, 3);
    z.setAll(40000, rndBytes(300, 4));
    lzIn.add(('long70k', z));
    final hi = rndBytes(2048, 5);
    for (var i = 0; i < 2048; i++) {
      hi[i] |= 0x80;
    }
    hi.setAll(1200, cp(sub(hi, 0, 600)));
    lzIn.add(('high2k', hi));
  }
  for (final (n, d) in lzIn) {
    T('lzEnc.$n', () => H(E.lzEnc(d)));
    T('lzDec.$n', () {
      final c = E.lzEnc(d), b = E.lzDec(c, d.length);
      return '${H(b)} same=${bo(eq(b, d))}';
    });
  }
  T('lzDec.short', () => H(E.lzDec(E.lzEnc(lzIn[6].$2), 1000)));
  T('lzDec.long', () => H(E.lzDec(E.lzEnc(lzIn[5].$2), 2000)));
  {
    final g = tamaFw('idl', 40, 77), bl = [3, 5, 0x20, 0x41, 0x7F];
    T('lzPack', () => H(E.lzPack(g, bl)));
    T('lzPack.none', () => H(E.lzPack(g, [])));
    T('lzUnpack', () {
      final z = E.lzPack(g, bl), g2 = cp(g);
      for (final b in bl) {
        fill(g2, 0x11, b << 16, (b + 1) << 16);
      }
      E.lzUnpack((a, n) => sub(z, a, a + n), g2);
      return '${H(g2)} same=${bo(eq(g2, g))}';
    });
    T('lzCount', () {
      final z = E.lzPack(g, bl), r = Uint8List(0x2000 + z.length);
      r.setAll(0x2000, z);
      return '${E.lzCount(r, 0x2000)},${E.lzCount(r, 0)},${E.lzCount(r, r.length - 100)}';
    });
  }
  T('tamaLzCan', () => [B.emu, B.t7, null, Uint8List(8), B.doomApp].map((a) => bo(E.tamaLzCan(a))).join(''));
  // detection of the colour Tamas
  final fws = S.fws;
  for (final (dev, pct, seed) in [('pc', 50, 11), ('pc', 100, 12), ('idl', 40, 13), ('idl', 62, 14), ('idl', 85, 15), ('ps', 45, 16), ('ps', 70, 17), ('4u', 45, 18), ('4u', 95, 19), ('4u-plain', 42, 20), ('4u-plain', 66, 21)]) {
    fws['$dev.$pct'] = tamaFw(dev, pct, seed);
  }
  {
    final g = tamaFw('pc', 50, 22);
    asc(g, 0x123456, 'TAMAGO');
    g[0x123456 + 6] = 0;
    fws['id.50'] = g;
  }
  {
    final g = tamaFw('idl', 30, 23);
    w32(g, 0x400000, 0x02400010);
    for (var k = 0; k < 12; k++) {
      utf16(g, 0x500000 + k * 0x100, 'DL_iDN_x');
    }
    utf16(g, 0x510000, 'DL_iDL_x');
    fws['tagps.30'] = g;
  }
  {
    final g = tamaFw('idl', 30, 24);
    w32(g, 0x400000, 0x02400020);
    for (var k = 0; k < 10; k++) {
      utf16(g, 0x500000 + k * 0x100, 'DL_T4U_x');
    }
    fws['tag4u.30'] = g;
  }
  {
    final g = tamaFw('idl', 30, 25);
    w32(g, 0x400000, 0x02400030);
    for (var k = 0; k < 9; k++) {
      utf16(g, 0x500000 + k * 0x100, 'DL_iDL_x');
    }
    for (var k = 0; k < 9; k++) {
      utf16(g, 0x520000 + k * 0x100, 'DL_iDN_x');
    }
    fws['tagidl.30'] = g;
  }
  {
    final g = tamaFw('idl', 30, 26);
    w32(g, 0x400000, 0x024CA8FE);
    fws['idljp.30'] = g;
  }
  for (final k in fws.keys.toList()) {
    T('emuDetect.$k', () => E.emuDetect(fws[k]!));
    final d = k.split('.')[0];
    T('tamaName.$k', () {
      String dv;
      try {
        dv = E.emuDetect(fws[k]!);
      } catch (_) {
        dv = '?';
      }
      return '${E.tamaName(fws[k], dv)},${E.tamaName(fws[k], d)},${E.tamaName(null, 'pc')},${E.tamaName(fws[k], 'zz')}';
    });
  }
  for (final (n, g) in [
    ('short', Uint8List(0x80)),
    ('zero4', Uint8List(0x400000)),
    ('zero8', Uint8List(0x800000)),
    ('big', Uint8List(0x800001)),
    ('edge', Uint8List(0x400002)..[0x400000] = 0xFF),
    ('t7', t7Rom(false, 1))
  ]) {
    T('emuDetect.$n', () => E.emuDetect(g));
  }
  // packing
  String devOf(String k) {
    final d = k.split('.')[0];
    return d == 'id'
        ? 'pc'
        : d.startsWith('tag') || d == 'idljp'
            ? 'idl'
            : d;
  }

  final some = RegExp(r'^(pc\.50|idl\.62|ps\.70|4u\.95|id\.50)$');
  for (final k in fws.keys.toList()) {
    final g = fws[k]!, dev = devOf(k);
    final opts = <(String, E.PackedGuest Function())>[
      ('plain', () => E.packGuest(g, dev)),
      ('sparse', () => E.packGuest(g, dev, sparse: true)),
      ('lz', () => E.packGuest(g, dev, lz: true)),
      ('sparse.room', () => E.packGuest(g, dev, sparse: true, room: E.menuRoomLen)),
      ('lz.room', () => E.packGuest(g, dev, lz: true, room: E.menuRoomLen)),
      ('lz.sparse.small', () => E.packGuest(g, dev, lz: true, sparse: true, room: 0x300000)),
      ('lzAll', () => E.packGuest(g, dev, lz: true, lzAll: true, room: E.menuRoomLen)),
      ('lzExtra', () => E.packGuest(g, dev, lz: true, lzExtra: [0x40, 0x0b, 1, 2, 3], room: E.menuRoomLen)),
      ('lzOnly', () => E.packGuest(g, dev, lz: true, lzOnly: [1, 2, 3, 0x30, 0x60])),
    ];
    for (final (on, f) in opts) {
      if ((on == 'lzAll' || on == 'lzExtra' || on == 'lz.sparse.small') && !some.hasMatch(k)) continue;
      T('packGuest.$k.$on', () => pkStr(f()));
    }
    T('packMain.$k', () => pkStr(E.packMain(g, dev)));
    T('packMain.$k.pack', () => pkStr(E.packMain(g, dev, B.emu, true)));
    T('packMain.$k.t7app', () => pkStr(E.packMain(g, dev, B.t7, false)));
    T('mainNeedsPack.$k', () => bo(E.mainNeedsPack(g, dev)) + bo(E.mainNeedsPack(g, dev, B.t7)));
    T('tamaNeedsLz.$k', () => bo(E.tamaNeedsLz(g, dev)) + bo(E.tamaNeedsLz(g, dev, E.menuRoomLen)) + bo(E.tamaNeedsLz(g, dev, 0x200000)));
    T('extraSize.tama.$k', () => [E.extraSize(tama(g, dev)), E.extraSize(tama(g, dev, pack: true)), E.extraSize(tama(g, dev), 0x40000), E.extraSize(tama(g, dev))].join(','));
    T('extraName.tama.$k', () => E.extraName(tama(g, dev)));
  }
  T('packGuest.short', () => pkStr(E.packGuest(sub(fws['idl.40']!, 0, 0x123456), 'idl')));
  T('packGuest.t7dev', () => pkStr(E.packGuest(fws['pc.50']!, 't7')));
  T('packGuest.nodev', () => pkStr(E.packGuest(fws['pc.50']!, 'zz')));
  T('extraSize.tama.nodev', () => E.extraSize(tama(fws['pc.50']!, 'zz')));
  // download content
  Uint8List dlcFw(String dev, int seed, bool save) {
    final g = tamaFw(dev, 40, seed);
    fill(g, 0xFF, 0x590000, 0x7E0000);
    fill(g, 0xFF, 0xE000, 0xF000);
    if (save) {
      fillRnd(g, 0xE000, 0x4E4, seed + 1);
      fillRnd(g, 0xE4E4, 0x4E4, seed + 2);
      g[0xE000] = 1;
      g[0xE4E4] = 2;
    }
    return g;
  }

  final recDefs = <(String, int, int, int, int, int, String, String)>[
    ('meal', 0x400, 0x81, 0x02, 0x01, 1, 'DL_iDL_Meal.jpg', 'idl_meal01'), ('snackC', 0x300, 0x81, 0x0C, 0x02, 3, 'DL_iDN_Cake', 'idn_cake'), ('snackD', 0x280, 0x81, 0x0D, 0x02, 2, 'DL_T4U_Snack.JPG', 't4u_snack0123'), //
    ('wall', 0x1F00, 0x81, 0x1F, 0x00, 1, 'Wall', 'idl_wall'), ('daily', 0x7000, 0x81, 0x29, 0x00, 2, 'DL_iDN_Recipe', 'idn_rec01'), ('item', 0x1800, 0x81, 0x2A, 0x01, 3, 'DL_x_Item', 't4u_item0650'), ('item2', 0x1800, 0x81, 0x2A, 0x01, 1, 'Item two', 't4u_item0850'), //
    ('item3', 0x1000, 0x81, 0x2A, 0x01, 1, 'Item three', 't4u_item0012'), ('itemNoId', 0x1000, 0x81, 0x2A, 0x01, 2, 'Item none', 'noid'), ('bingo', 0x6000, 0x81, 0x29, 0x00, 1, 'Bingo', 't4u_b1350'), ('gasha', 0x6000, 0x81, 0x29, 0x00, 2, 'Gasha', 't4u_g99700'), //
    ('cloth', 0x3F00, 0x81, 0x33, 0x00, 2, 'Cloth', 'cloth77'), ('acc', 0x1F00, 0x81, 0x34, 0x00, 3, 'Acc', 'acc'), ('acc2', 0x2100, 0x81, 0x35, 0x00, 1, 'TooBig', 'acc2'), ('dest', 0x7F00, 0x94, 0x47, 0x02, 2, 'Dest', 'dest'), ('game', 0x7F00, 0x94, 0x5B, 0x01, 1, 'DL_iDL_Game.jpg', 'game'), //
    ('game2', 0x5000, 0x94, 0x5B, 0x02, 3, 'Game2', 'game2'), ('char', 0x7000, 0x94, 0x48, 0x03, 1, 'Char', 'char'), ('letter', 0x600, 0x81, 0x51, 0x00, 2, 'Letter', 'let'), ('letterIdl', 0x600, 0x81, 0x51, 0x00, 1, 'Letter iD L', 'let2'), ('stamp', 0x9000, 0x81, 0x52, 0x03, 2, 'Stamp', 'stamp'), //
    ('happy', 0x9000, 0x81, 0x52, 0x02, 1, 'Happy', 'happy'), ('happyPs', 0x9000, 0x81, 0x52, 0x02, 2, 'HappyPs', 'happyps'), ('meal4u', 0x500, 0x81, 0x01, 0x01, 2, 'Meal 4U', 'm4u'), ('snack4u', 0x500, 0x81, 0x01, 0x02, 3, 'Snack 4U', 's4u'), ('small', 0x80, 0x81, 0x02, 0x01, 9, 'Small', 'small'), ('none', 0x400, 0x77, 0x02, 0x01, 1, 'None', 'none'),
  ];
  final recs = <(String, Uint8List)>[];
  for (var i = 0; i < recDefs.length; i++) {
    final (n, len, t, c, f, fam, name, file) = recDefs[i];
    recs.add((n, dlcRec(len, t, c, f, fam, name, file, 100 + i)));
  }
  Uint8List recOf(String n) => recs.firstWhere((r) => r.$1 == n).$2;
  S.recOf = recOf;
  String stStr(E.DlcStore? s) => s != null ? '${s.kind}:${s.label}:${hx(s.base)}:${s.size}:${s.n}:${bo(s.one)}' : 'null';
  for (final (n, r) in recs) {
    T('dlcName.$n', () => jsonEncode(E.dlcName(r)));
    T('dlcRoute.$n', () => ['idl', 'ps', '4u', '4u-plain', 'pc', null].map((d) => stStr(d == null ? E.dlcRoute(r) : E.dlcRoute(r, d))).join(' '));
    for (final d in ['idl', 'ps', '4u', '4u-plain']) {
      T('dlcRecord.$n.$d', () => H(E.dlcRecord(r, d)));
    }
  }
  T('dlcName.short', () => jsonEncode(E.dlcName(sub(recOf('meal'), 0, 0x15))));
  T('dlcRoute.short', () => bo(E.dlcRoute(Uint8List(0x20)) != null) + bo(E.dlcRoute(Uint8List(0x20), 'ps') != null) + bo(E.dlcRoute(Uint8List(0x20), '4u') != null));
  {
    Uint8List jpg(Uint8List r, int extra) {
      final b = Uint8List(300 + r.length + extra);
      fillRnd(b, 0, 300, 5);
      for (var i = 0; i + 1 < 300; i++) {
        if (b[i] == 0xFF && b[i + 1] == 0xD9) b[i] = 0;
      }
      b[200] = 0xFF;
      b[201] = 0xD9;
      b.setAll(300, r);
      return b;
    }

    T('dlcRecord.jpg', () => H(E.dlcRecord(jpg(recOf('meal'), 0))));
    T('dlcRecord.jpg.tail', () => H(E.dlcRecord(jpg(recOf('meal'), 3))));
    T('dlcRecord.jpg.ps.tail', () => H(E.dlcRecord(jpg(recOf('snackD'), 3), 'ps')));
    T('dlcRecord.ps.tail1', () {
      final r = recOf('snackD'), b = Uint8List(r.length + 1);
      b.setAll(0, r);
      b[r.length] = 9;
      return H(E.dlcRecord(b, 'ps'));
    });
    T('dlcRecord.nodecl', () {
      final r = cp(recOf('wall'));
      r[0x49] = 0x77;
      return H(E.dlcRecord(r));
    });
    T('dlcRecord.badsum', () {
      final r = cp(recOf('wall'));
      r[0x100] ^= 1;
      return H(E.dlcRecord(r));
    });
    T('dlcRecord.none', () => H(E.dlcRecord(rndBytes(500, 6))));
    T('dlcRecord.tiny', () => H(E.dlcRecord(sub(recOf('meal'), 0, 0x40))));
  }
  for (final (dev, seed) in [('idl', 31), ('ps', 32), ('4u', 33), ('4u-plain', 34)]) {
    var g = dlcFw(dev, seed, true);
    T('dlcStores.$dev.empty', () => E.dlcStores(g).map((s) => '${s.kind}:${s.label}:${s.slots.map((x) => '${x.slot}${x.name == null ? '' : '=${x.name}'}').join('|')}').join(' '));
    T('dlcAreas.$dev', () => E.dlcAreas(dev).map((a) => '${hx(a.$1)}-${hx(a.$2)}').join(','));
    for (final (n, r0) in recs) {
      T('dlcAdd.$dev.$n', () {
        final r = E.dlcRecord(r0, dev), a = E.dlcAdd(g, r);
        g = a.guest;
        return '${a.store.kind}:${a.slot}:${bo(a.stamp)} ${H(g)} flag=${E.saveFlagGet(g, dev)}/${E.psStampGet(g)}';
      });
    }
    T('dlcAdd.$dev.again', () => H(E.dlcAdd(g, E.dlcRecord(recOf('meal'), dev)).guest));
    T('dlcAdd.$dev.raw', () {
      final a = E.dlcAdd(g, recOf('cloth'));
      return '${a.store.kind}:${a.slot}';
    });
    T('dlcStores.$dev', () => E.dlcStores(g).map((s) => '${s.kind}:${s.slots.map((x) => x.name ?? '').join('|')}').join(' '));
    T('dlcSlots.$dev', () => E.dlcSlots(g).map((x) => '${x.slot}=${x.name}').join(','));
    T('dlcPut.$dev', () => H(E.dlcPut(g, recOf('game2'), 1)));
    for (final (kind, slot) in [(0, 0), (7, 1), (11, 0), (12, 0), (9, 0), (5, 9), (99, 0), (0, -1)]) {
      T('dlcFree.$dev.$kind.$slot', () {
        final o = E.dlcFree(g, kind, slot);
        return '${H(o)} flag=${E.saveFlagGet(o, dev)}';
      });
    }
    T('dlcAdd.$dev.full', () {
      var x = g, n = 0;
      for (var i = 0; i < 30; i++) {
        final r = dlcRec(0x200, 0x81, 0x02, 0x01, 9, 'M$i', 'm$i', 300 + i);
        x = E.dlcAdd(x, r).guest;
        n++;
      }
      return n;
    });
    T('saveFlag.$dev', () {
      final x = cp(g);
      E.saveFlag(x, dev, 0x55);
      E.psStamp(x, 0x66);
      return '${H(sub(x, 0xE000, 0xF000))} ${E.saveFlagGet(x, dev)} ${E.psStampGet(x)} ${E.saveFlagGet(x, 'pc')}';
    });
  }
  T('dlc.nosave', () {
    final g = dlcFw('ps', 35, false);
    final a = E.dlcAdd(g, E.dlcRecord(recOf('stamp'), 'ps'));
    return '${a.slot} ${E.psStampGet(a.guest)} ${H(a.guest)}';
  });
  T('dlc.pc', () => '${E.dlcStores(fws['pc.50']!).length},${E.dlcSlots(fws['pc.50']!).length},${E.dlcAreas('pc').length}');
  T('dlcAdd.pc', () => H(E.dlcAdd(fws['pc.50']!, recOf('meal')).guest));
  T('dlcPut.pc', () => H(E.dlcPut(fws['pc.50']!, recOf('game'), 0)));
  T('dlcFree.pc', () => H(E.dlcFree(fws['pc.50']!, 7, 0)));
  T('dlc.unknown8', () {
    final g = ffs(0x7C0000);
    final a = E.dlcAdd(g, recOf('game'));
    return '${E.dlcStores(g).length} ${a.store.kind}:${a.slot} ${H(a.guest)} ${H(E.dlcFree(a.guest, 7, 0))}';
  });
  // the run state of TamaEmu with the stamp byte
  {
    (Uint8List, int, Uint8List, String?) mk(String? dev, int len, int at, bool hit) {
      final save = rndBytes(len, 40), emu = rndBytes(0x3000, 41), gram = Uint8List(32768);
      fillPat(gram, 0, 32768, 3);
      if (hit) emu.setAll(at, save);
      final raw = Uint8List(emu.length + gram.length);
      raw.setAll(0, emu);
      raw.setAll(emu.length, gram);
      final enc = <int>[];
      for (var i = 0; i < raw.length; i += 128) {
        final n = math.min(128, raw.length - i);
        enc.add(n - 1);
        for (var k = 0; k < n; k++) {
          enc.add(raw[i + k]);
        }
      }
      final img = ffs(0x60000);
      const so = 0x10000;
      w32(img, so, 0x53584D50);
      w32(img, so + 4, 3);
      w32(img, so + 8, 0x1234);
      w32(img, so + 12, 0x5678);
      w32(img, so + 16, enc.length);
      w32(img, so + 20, (enc.length / 0x1000).ceil() + 2);
      img.setAll(so + 0x1000, enc);
      return (img, so, save, dev);
    }

    void run(String n, (Uint8List, int, Uint8List, String?) m, int v, [void Function(Uint8List img, int so, Uint8List save)? f]) => T('psSessStamp.$n', () {
          final (img, so, save, dev) = m;
          if (f != null) f(img, so, save);
          final r = dev != null ? E.psSessStamp(img, so, save, v, dev) : E.psSessStamp(img, so, save, v);
          return '${bo(r)} ${H(img)}';
        });
    run('ps', mk('ps', 0x4E4, 0x1000, true), 0x0C);
    {
      final m = mk('ps', 0x4E4, 0x804, true);
      run('ps.default', (m.$1, m.$2, m.$3, null), 0);
    }
    run('idl', mk('idl', 0x400, 0x2000, true), 3);
    run('nohit', mk('ps', 0x4E4, 0, false), 0x0C);
    run('pc', mk('pc', 0x4E4, 0, true), 1);
    run('same', mk('ps', 0x4E4, 0x1000, true), 0x0C, (img, so, save) => E.psSessStamp(img, so, save, 0x0C, 'ps'));
    run('nomagic', mk('ps', 0x4E4, 0x1000, true), 1, (img, so, save) => img[so] = 0);
    run('version', mk('ps', 0x4E4, 0x1000, true), 1, (img, so, save) => img[so + 4] = 2);
    run('bytes', mk('ps', 0x4E4, 0x1000, true), 1, (img, so, save) => w32(img, so + 16, 0x50000));
    run('shortsave', mk('ps', 0x200, 0x1000, true), 7);
  }
  // T7
  final go = S.go = t7Rom(false, 51), fr = S.fr = t7Rom(true, 52);
  T('t7Kind', () => <Uint8List?>[go, fr, null, sub(go, 0, 100), rndBytes(0xA0000, 53), t7Rom(true, 54)..[0x3FFC] = 1, Uint8List(0xC0000)].map((b) => '${E.t7Kind(b)}${bo(E.t7Detect(b))}').join(','));
  final figA = S.figA = t7Fig(0x40000, 0x12345, 55), figB = S.figB = t7Fig(0x100000, 0x80000, 56), figFull = S.figFull = t7FigFull(57), figZero = Uint8List(0x1000);
  T('t7FigDetect', () => <Uint8List?>[figA, figFull, figZero, null, sub(figA, 0, 0x30), go].map((b) => bo(E.t7FigDetect(b))).join(''));
  for (final (n, f) in [
    ('a', figA),
    ('b', figB),
    ('full', figFull),
    ('zero', figZero),
    ('tiny', Uint8List(8)..fillRange(0, 8, 1)),
    ('pow', rndBytes(0x80000, 58)),
    ('dbl', () {
      final b = Uint8List(0x100000);
      b.setAll(0, rndBytes(0x80000, 59));
      b.setAll(0x80000, cp(sub(b, 0, 0x80000)));
      b[0x80000] ^= 0xFF;
      return b;
    }())
  ]) {
    T('t7FigData.$n', () => H(E.t7FigData(f)));
  }
  T(
      't7FigName',
      () => ['(03)_Tama-Go_Mametchi.bin', 'C:\\x\\TamaGo-Kuchipatchi Figure.bin', '/a/b/tama go_memetchi_figure', '', null, 'A very long name of a figure that goes on.bin', 'Näme_ü.bin', '(12) - tama_go__X', '...', 'noext', 'tama-go.bin']
          .map((s) => jsonEncode(E.t7FigName(s)))
          .join(','));
  T('t7Room', () => [E.t7Room([]), E.t7Room([T7Fig('', figA), T7Fig('', figB)]), E.t7Room([T7Fig('', figA)], 0xC0000)].join(','));
  T('t7XName', () => '${E.t7XName(go)},${E.t7XName(fr)},${E.t7XName(null)}');
  // V1, V3
  final v46 = S.v46 = v1Rom(0x3000, 61), v48 = S.v48 = v1Rom(0x4000, 62), v3 = S.v3 = v3Rom(63);
  T('v1Detect', () => <Uint8List?>[v46, v48, v3, null, rndBytes(0x3000, 64), sub(v46, 0, 0x2000), rndBytes(0x80000, 65)].map((b) => bo(E.v1Detect(b)) + bo(E.v3Detect(b))).join(','));
  T('v1Name', () => [v46, v48, v3, Uint8List(0x3000), Uint8List(0)].map((b) => E.v1Name(b) + bo(E.v1Clock(b))).join(','));
  // Game Boy
  final gb32 = S.gb32 = gbRom(0, 0x00, 'TETRIS', 71), gb256 = S.gb256 = gbRom(3, 0x00, 'Zelda dx\x7Fx', 72), gbTrim = S.gbTrim = gbRom(5, 0x00, 'POKEMON RED', 73, 18);
  final gbc1m = S.gbc1m = gbRom(5, 0x80, 'GOLD', 74), gbc2m = S.gbc2m = gbRom(6, 0xC0, 'CRYSTAL', 75), gbTrim3 = gbRom(4, 0x00, '', 76, 3), gbcTrim = S.gbcTrim = gbRom(4, 0x80, '  spaced  ', 77, 6);
  final gbs = [('32', gb32), ('256', gb256), ('trim', gbTrim), ('c1m', gbc1m), ('c2m', gbc2m), ('trim3', gbTrim3), ('ctrim', gbcTrim)];
  T('gbDetect', () => <Uint8List?>[...gbs.map((x) => x.$2), null, sub(gb32, 0, 0x4000), rndBytes(0x8000, 78), cp(gb32)..[0x148] = 1, rndBytes(0x400000, 79), rndBytes(0x9000, 80)].map((b) => bo(E.gbDetect(b))).join(''));
  for (final (n, r) in gbs) {
    T('gb.$n', () {
      final t = E.gbTrim(r);
      return '${bo(E.gbIsColor(r))}${bo(E.gbColorOnly(r))} ${jsonEncode(E.gbTitle(r))} trim=${t.banks}:${H(t.rom)} untrim=${H(E.gbUntrim(t.rom, (t.banks << 16) | 5))} size=${E.extraSize(Extra(kind: 'gb', rom: r))} name=${E.extraName(Extra(kind: 'gb', rom: r))}';
    });
  }
  T('gbTrim.odd', () {
    final t = E.gbTrim(rndBytes(0x21000, 81)), t2 = E.gbTrim(rndBytes(0x10000, 82));
    return '${t.banks}:${t.rom.length},${t2.banks}:${t2.rom.length}';
  });
  T('gbUntrim.edge', () => [E.gbUntrim(gb32, 0), E.gbUntrim(gb32, 1 << 16), E.gbUntrim(sub(gb32, 0, 0x4100), 9 << 16), E.gbUntrim(Uint8List(0), 9 << 16), E.gbUntrim(gb32, 300 << 16), E.gbUntrim(gb32, 4 << 16)].map((b) => b.length).join(','));
  T('gbTitle.short', () => jsonEncode(E.gbTitle(Uint8List(0x138))) + bo(E.gbIsColor(Uint8List(0x100))) + bo(E.gbColorOnly(Uint8List(0x100))));
  // Master System, Game Gear
  final sms1 = S.sms1 = smsRom(0x20000, 4, 91), smsJ = smsRom(0x8000, 3, 92), gg = S.gg = smsRom(0x40000, 6, 93), smsNo = S.smsNo = smsRom(0x10000, -1, 94), smsCop = S.smsCop = smsRom(0x20000, 4, 95, true), sms8 = smsRom(0x2000, 7, 96), smsBad = smsRom(0x20000, 2, 97);
  T(
      'smsDetect',
      () => <Uint8List?>[sms1, smsJ, gg, smsNo, smsCop, sms8, smsBad, null, rndBytes(0x1000, 98), rndBytes(0x20100, 99), rndBytes(0x200000, 90)]
          .map((b) => bo(E.smsDetect(b)) + bo(E.smsDetect(b, 'game.SMS')) + bo(E.smsDetect(b, 'x.gg')) + bo(E.smsDetect(b, 'x.bin')))
          .join(','));
  T('smsGameGear', () => [sms1, smsJ, gg, smsNo, smsCop, sms8].map((b) => bo(E.smsGameGear(b)) + bo(E.smsGameGear(b, 'a.GG')) + bo(E.smsGameGear(b, 'a.sms'))).join(','));
  final names = <String?>[
    'Sonic the Hedgehog (USA, Europe).sms', 'Alex Kidd in Miracle World [!].sms', 'Castle of Illusion Starring Mickey Mouse.sms', 'the.of.and.sms', '', null, 'Pokemon Pinball mini (Europe).min', 'POKEMON the of', 'ünïcödé gäme.gg', "It's a 'test' & more!.bin", 'a   b\tc\nd.x', //
    '(only brackets).sms', 'Arduboy_Game-v1.2.hex', '${'x' * 40}.sms', 'Fifteen letters  and more', 'line1\n(two).sms',
  ];
  T('smsTitle', () => names.map((s) => jsonEncode(E.smsTitle(s))).join(','));
  T('pmTitle', () => names.map((s) => jsonEncode(E.pmTitle(s))).join(','));
  T('abTitle', () => names.map((s) => jsonEncode(E.abTitle(s))).join(','));
  // Pokemon mini
  final pm1 = S.pm1 = pmRom(0x80000, 101), pmS = S.pmS = pmRom(0x2200, 102), pmBig = pmRom(0x180000, 103), bios = S.bios = pmBios(104);
  T('pmDetect', () => <Uint8List?>[pm1, pmS, pmBig, null, rndBytes(0x2200, 105), sub(pm1, 0, 0x2100), bios].map((b) => bo(E.pmDetect(b)) + bo(E.pmTooBig(b)) + bo(E.pmBiosDetect(b))).join(','));
  // Arduboy
  final abData = S.abData = rndBytes(0x3456, 111), abOdd = S.abOdd = rndBytes(0x1235, 112), abFull = rndBytes(0x8000, 113);
  final hexes = <(String, Object)>[
    ('crlf', abHexText(abData, '\r\n')), ('lf', abHexText(abOdd, '\n')), ('full', abHexText(abFull, '\n')), ('bytes', Uint8List.fromList(latin1.encode(abHexText(abData, '\n')))), ('toobig', abHexText(rndBytes(0x8010, 114), '\n')), ('nohex', 'hello'), ('empty', ''), //
    ('badsum', abHexText(abData, '\n').replaceFirst(':10001000', ':10001001')), ('noeof', abHexText(abData, '\n').replaceFirst(':00000001FF\n', '')), ('onlyeof', ':00000001FF\n'), ('seg', ':020000020000FC\n${abHexText(abOdd, '\n')}'), ('segbad', ':020000021000EC\n${abHexText(abOdd, '\n')}'), //
    ('lin', ':020000040000FA\n:0400100001020304E2\n:00000001FF'), ('junk', abHexText(abOdd, '\n').replaceFirst('\n', '\nrubbish\n')), ('short', ':0000000000\n:10'), ('blank', '\n\n  ${abHexText(abOdd, '\n\n')}'), ('nan', ':0000000000\n:zz00000000\n:02zzzz00AABB\n:00000001FF'), //
    ('nan2', ':0000000000\n:0200zz00AABB99\n:00000001FF'), ('lower', abHexText(abOdd, '\n').toLowerCase()),
  ];
  for (final (n, t) in hexes) {
    T('abHex.$n', () => H(E.abHex(t)));
  }
  // Wolf3D
  final wolf = S.wolf = wolfPack(0x123456, 0, 121), wolfSh = S.wolfSh = wolfPack(0x60000, 1, 122), sod = S.sod = wolfPack(0x90000, 2, 123);
  T('wolf', () => <Uint8List?>[wolf, wolfSh, sod, null, Uint8List(100), sub(wolf, 0, 60), rndBytes(200, 124)].map((p) {
        final i = E.wolfInfo(p);
        return bo(E.wolfPackOk(p)) + bo(E.wolfSod(p)) + (i != null ? '${bo(i.shareware)}${bo(i.sod)}:${i.episodes}:${i.maps}' : '-');
      }).join(','));
  // T18
  final fw18 = S.fw18 = t18Fw(131, false, 38), fw18s = S.fw18s = t18Fw(132, true, 30), fw18big = S.fw18big = t18Fw(133, false, 80);
  T('t18Detect', () => <Uint8List?>[fw18, fw18s, null, sub(fw18, 0, 0x700000), Uint8List(0x800000), fws['idl.40']].map((b) => bo(E.t18Detect(b))).join(''));
  for (final (n, f) in [('a', fw18), ('sanrio', fw18s), ('big', fw18big), ('none', fws['idl.40']!), ('small', sub(fw18, 0, 0x3000)), ('range', cp(fw18)..setAll(0x121000, [0x00, 0x10, 0x00, 0xF8])), ('unaligned', sub(fw18, 1, 0x200001))]) {
    T('t18Addrs.$n', () {
      final a = E.t18Addrs(f);
      return '${hx(a.idle)},${hx(a.soft)},${hx(a.dma)},${hx(a.param)}';
    });
  }
  final trecs = <(String, Uint8List)>[
    ('meal', t18Rec(0x400, 0x81010101, 15003, 120, 'OMURICE 2', 'tg18_as15003_1.txt', 141, true)), ('snack', t18Rec(0x300, 0x81010102, 15010, 80, 'CAKE*', 'TG18_bs15010', 142, true)), ('item', t18Rec(0x1800, 0x81042A01, 16001, 300, 'BALL', 'tg18_it', 143, true)), //
    ('item3', t18Rec(0x1000, 0x81042A03, 16002, 310, 'TOY 77', 'tg18_i3', 144, false)), ('acc', t18Rec(0x1F00, 0x81023400, 17001, 500, 'RIBBON', 'tg18_ac', 145, true)), ('acc5', t18Rec(0x400, 0x81023500, 17002, 510, 'HAT', 'tg18_a5', 146, true)), //
    ('room', t18Rec(0x3F00, 0x81071F00, 18001, 900, 'PINK ROOM', 'tg18_rm', 147, true)), ('game', t18Rec(0x8000, 0x94005B01, 19001, 0, 'MAGIC HUT', 'tg18_gm', 148, false)), ('place', t18Rec(0x4000, 0x94004702, 19002, 0, 'TOWN', 'tg18_pl', 149, false)), //
    ('derived', t18Rec(0x200, 0x81019901, 15020, 5, 'SOUP', 'x', 150, false)), ('derived2', t18Rec(0x200, 0x81019902, 15021, 5, 'TEA', 'y_z', 151, false)), ('unknown', t18Rec(0x200, 0x81990000, 1, 2, 'abc', 'unk_file', 152, false)), //
    ('basic', t18Rec(0x300, 0x81010101, 12000, 0, 'RICE', 'tg18_basic', 153, true)), ('big', t18Rec(0x2100, 0x81042A01, 16009, 1, 'BIG', 'big', 154, true)), ('unread', t18Rec(0x200, 0x81010101, 15030, 1, 'a?b!', 'unread_file', 155, false)),
  ];
  Uint8List trec(String n) => trecs.firstWhere((r) => r.$1 == n).$2;
  S.trec = trec;
  final scanFile = () {
    final parts = <Uint8List>[rndBytes(77, 160)];
    for (final (_, r) in trecs) {
      parts.add(r);
      parts.add(rndBytes(13, 161));
    }
    parts.add(cp(trec('game'))..[0x300] ^= 1);
    parts.add(Uint8List.fromList([0x12, 0x34, 0, 0]));
    parts.add(cp(trec('meal'))..[0x300] ^= 1);
    var n = 0;
    for (final p in parts) {
      n += p.length;
    }
    final b = Uint8List(n);
    var o = 0;
    for (final p in parts) {
      for (var i = 0; i + 6 < p.length && p.length < 100; i++) {
        if (p[i] == 0x54) p[i] = 0x55;
      }
      b.setAll(o, p);
      o += p.length;
    }
    return b;
  }();
  T('t18iScan', () {
    final scanned = E.t18iScan(scanFile);
    return '${scanned.length} ${scanned.map(recStr).join(' | ')}';
  });
  T('t18iScan.none', () => '${E.t18iScan(rndBytes(5000, 162)).length},${E.t18iScan(Uint8List(10)).length},${E.t18iScan(sub(trec('meal'), 0, 0x200)).length}');
  E.T18Record sc(String n) => E.t18iScan(trec(n))[0];
  S.sc = sc;
  {
    final f = cp(fw18);
    T('t18Items.empty', () => itemsStr(E.t18Items(f)));
    T('t18ItemAdd.nosave', () => E.t18ItemAdd(ffs(0x800000), sc('meal')).$2);
    for (final (n, cnt) in <(String, int?)>[('basic', 1), ('meal', 2), ('snack', 0), ('item', 3), ('item3', 9), ('acc', 1), ('acc5', null), ('room', 1), ('game', 1), ('place', 1), ('game', 1), ('derived', 1), ('derived2', 2), ('unknown', 1), ('big', 1), ('unread', 1)]) {
      T('t18ItemAdd.$n', () {
        final r = sc(n);
        final a = cnt == null ? E.t18ItemAdd(f, r) : E.t18ItemAdd(f, r, cnt);
        return '${a.$1}:${a.$2} ${H(sub(f, 0x5E0000))}';
      });
    }
    T('t18ItemAdd.dlfull', () {
      final r = E.t18iScan(t18Rec(0x1000, 0x94004702, 19009, 0, 'ISLE', 'tg18_p2', 156, false))[0];
      final a = E.t18ItemAdd(f, r);
      return '${a.$1}:${a.$2}';
    });
    T('t18Items.filled', () => itemsStr(E.t18Items(f)));
    T('t18ItemCount', () {
      E.t18ItemCount(f, 'food', 1, 3);
      E.t18ItemCount(f, 'food', 20, 2);
      E.t18ItemCount(f, 'item', 0, 7);
      E.t18ItemCount(f, 'acc', 1, -2);
      return itemsStr(E.t18Items(f));
    });
    T('t18Points', () => [0, 1234, 65535, 70000, -5, 4660].map((v) {
          E.t18Points(f, v);
          return E.t18Items(f).points;
        }).join(','));
    T('t18ItemDel', () {
      E.t18ItemDel(f, 'food', 1);
      E.t18ItemDel(f, 'acc', 0);
      E.t18ItemDel(f, 'dl', 1);
      return '${itemsStr(E.t18Items(f))} ${H(sub(f, 0x5E0000))}';
    });
    T('t18RoomReset', () {
      E.t18RoomReset(f);
      return '${itemsStr(E.t18Items(f))} ${H(sub(f, 0x5E0000))}';
    });
    T('t18ItemAdd.fill', () {
      var n = 0;
      try {
        for (var i = 0; i < 40; i++) {
          E.t18ItemAdd(f, E.t18iScan(t18Rec(0x200, 0x81010101, 15100 + i, 1, 'F$i', 'f$i', 170 + i, false))[0]);
          n++;
        }
      } on StateError catch (e) {
        return '$n ${e.message} ${itemsStr(E.t18Items(f))}';
      }
      return n;
    });
  }
  T('t18AdultFind', () => ['Mametchi.png', '16', '016.PNG', 'my_kuchipatchi-adult.jpg', 'LOVELITCHI', 'x', '', '99', '21.gif', 'pompom tchi.bmp', 'Kuro-Mametchi', '1e1', '35'].map((s) => E.t18AdultFind(s)).join(','));
  for (final (n, w, h, mode, seed) in [('blocks', 100, 80, 0, 181), ('small', 16, 16, 0, 182), ('64', 64, 64, 1, 183), ('noise', 200, 200, 1, 184), ('noise64', 64, 64, 2, 185), ('wide', 640, 10, 2, 186), ('one', 1, 1, 2, 187)]) {
    T('t18PicMake.$n', () {
      final p = E.t18PicMake(image(w, h, mode, seed));
      S.pics[n] = p;
      return '${H(p)} rgba=${sha(E.t18PicRgba(p).data)}';
    });
  }
  // DOOM
  final cmapL = rndBytes(34 * 256, 191), big1 = rndBytes(0x30000, 192), big2 = rndBytes(0x25000, 193);
  final wadA = S.wadA = doomWad([('PLAYPAL', rndBytes(768, 194)), ('COLORMAP', cmapL), ('E1M1', Uint8List(0)), ('THINGS', rndBytes(300, 195)), ('TEX1', big1), ('SND', big2), ('SMALL', rndBytes(100, 196)), ('FLAT', rndBytes(4096, 197))]);
  final wadB = S.wadB =
      doomWad([('PLAYPAL', rndBytes(768, 194)), ('COLORMAP', cmapL), ('E5M1', Uint8List(0)), ('THINGS', rndBytes(700, 198)), ('TEX1', big1), ('SND', big2), ('SMALL', rndBytes(100, 196)), ('NEW', rndBytes(0x9000, 199)), ('FLAT', rndBytes(4096, 197))]);
  final wadC = S.wadC = doomWad([('COLORMAP', rndBytes(100, 200)), ('X', rndBytes(5000, 201))]);
  T('doomLinks', () {
    final xa = dx(wadA), xb = dx(wadB), xc = dx(wadC), l = E.doomLinks([xb, xt(go), xc, xa, dx(null)]);
    return '${l.length} ${[xa, xb, xc].map((x) {
      final k = l[x];
      return k != null ? 'saved=${k.saved} mcu=${H(k.mcu)} refs=${k.refs.map((r) => '${r.$1}>${identical(r.$2, xa) ? 'a' : identical(r.$2, xb) ? 'b' : 'c'}+${r.$3}').join(',')}' : '-';
    }).join(' | ')}';
  });
  T('doomLinks.same', () {
    final xa = dx(wadA), xb = dx(cp(wadA)), l = E.doomLinks([xa, xb]);
    return '${l.length} ${l[xb] != null ? 'b:${l[xb]!.saved}:${H(l[xb]!.mcu)}' : l[xa] != null ? 'a:${l[xa]!.saved}' : '-'}';
  });
  T('doomUnlink.whole', () => bo(identical(E.doomUnlink(Uint8List(100), 4, wadA), wadA)));
  T('doomParts', () => [E.doomParts(dx(wadA)), E.doomParts(dx(wadA), 0x12345), E.doomParts(dx(null)), E.doomParts(dx(null, size: 0x123456), 1), E.doomParts(dx(wadB, region: 0x150000), B.doomXip.length)].map((p) => '${hx(p.prog)}+${hx(p.wad)}').join(','));
  T(
      'extraName',
      () => [
            dx(wadA), dx(wadA, title: 'SIGIL'), dx(wadA, ep: 2), dx(wadA, ep: 'all', d2: true), dx(wadA, name: 'MY WAD 1.9!'), dx(wadA, name: 'lower'), dx(wadA, name: 'THIS NAME IS TOO LONG'), Extra(kind: 't18'), xt(go), xt(fr), xt(v46), xt(v3), Extra(kind: 'v1', rom: v48), //
            Extra(kind: 'sms'), Extra(kind: 'sms', title: 'SONIC'), Extra(kind: 'pm'), Extra(kind: 'pm', title: 'PINBALL'), Extra(kind: 'ab'), Extra(kind: 'ab', title: 'A'), Extra(kind: 'wolf', pack: wolf), Extra(kind: 'wolf', pack: sod), Extra(kind: 'tama', dev: 'ps'),
          ].map((x) => '${E.extraKind(x)}=${E.extraName(x)}').join(','));
  T(
      'extraSize',
      () => [
            xt(go), xt(fr, figs: [T7Fig('a', figA)]), xt(go, figs: [T7Fig('a', figA), T7Fig('b', figB)]), xt(v46), xt(v48), xt(v3), Extra(kind: 'sms', rom: sms1), Extra(kind: 'sms', rom: smsCop), Extra(kind: 'pm', rom: pm1), Extra(kind: 'pm', rom: pmS), //
            Extra(kind: 'ab', rom: abData), Extra(kind: 'wolf', pack: wolf), dx(wadA), dx(wadB, region: 0x200000), dx(null), Extra(kind: 't18', fw: fw18), Extra(kind: 't18', fw: fw18big),
          ].map((x) => E.extraSize(x)).join(','));
  return S;
}

// ------------------------------------------------------------ cases on a ROM image
String sn(Uint8List? x) => x != null ? sha(x) : 'null';
void settings(String n, Uint8List rom) {
  String pair(bool? g, Uint8List a, Uint8List b, bool? gb) => '${bo(g)} ${bo(identical(a, rom))}${sha(a)} ${bo(identical(b, rom))}${sha(b)} ${bo(gb)}';
  T('$n.clock', () {
    final b = E.emuClockSet(rom, false);
    return pair(E.emuClockGet(rom), E.emuClockSet(rom, true), b, E.emuClockGet(b));
  });
  T('$n.t18clock', () {
    final b = E.t18ClockSet(rom, false);
    return pair(E.t18ClockGet(rom), E.t18ClockSet(rom, true), b, E.t18ClockGet(b));
  });
  T('$n.nfc', () {
    final b = E.emuNfcSet(rom, false);
    return pair(E.emuNfcGet(rom), E.emuNfcSet(rom, true), b, E.emuNfcGet(b));
  });
  T('$n.sess', () {
    final b = E.emuSessSet(rom, false);
    return pair(E.emuSessGet(rom), E.emuSessSet(rom, true), b, E.emuSessGet(b));
  });
  T('$n.opt', () {
    final g = E.emuOptGet(rom);
    return '${optStr(g)} ${<EmuOpt?>[const EmuOpt(vol: 1, dim: 0, off: 0), const EmuOpt(vol: 3, dim: 10, off: 7), const EmuOpt(vol: 2, dim: 5, off: 3), const EmuOpt(vol: 0, dim: 11, off: 1), const EmuOpt(vol: 7, dim: 23, off: 9), null].map((o) {
      final r = E.emuOptSet(rom, o);
      return '${bo(identical(r, rom))}${sha(r).substring(0, 16)}=${optStr(E.emuOptGet(r))}';
    }).join(' ')}';
  });
  T('$n.opt.old', () {
    final a = 0xA0140 + (u32(rom, 0xA0140) == E.t18Magic ? 400 : 156), r = cp(rom);
    return [0x00040000, 0x00080000, 0x000C0000, 0x0C000000, 0x0F350000].map((f) {
      w32(r, a, f);
      return optStr(E.emuOptGet(r));
    }).join(' ');
  });
  T('$n.auto', () {
    final g = E.autoGet(rom, stubs), a = E.autoSet(rom, stubs, true), b = a != null ? E.autoSet(a, stubs, false) : null;
    return '${bo(g)} ${a != null ? sha(a) + bo(E.autoGet(a, stubs)) : 'null'} ${b != null ? sha(b) + bo(E.autoGet(b, stubs)) : 'null'} old=${bo(E.autoGetOld(rom, stubs))}${bo(a != null ? E.autoGetOld(a, stubs) : null)} off=${bo(E.autoGet(rom, [(0xB1000, B.stub), (-5, B.stub), (0xFFFFFF, B.stub)]))}${bo(E.autoGet(rom, []))}';
  });
  T('$n.reserved', () => resStr(E.appReserved(rom)));
  T('$n.cfg', () => '${cfgStr(E.extraCfg(rom, 0xA0000))} t18Low=${hx(E.t18Low(rom))} doomCfg=${cfgStr(E.doomCfg(rom, 0xA0000))}');
  const mainSrc = 0x10000000 + 0xA0000 - 0x11000;
  T('$n.read', () => E.appsRead(rom, [AppEntry(mainSrc, 'MAIN')]).map(xStr).join(' | '));
  T('$n.packed', () => E.appsPacked(rom, [AppEntry(mainSrc, ''), AppEntry(mainSrc, 'NAMED'), AppEntry(5, null), AppEntry(0x20000000, null)]).join(','));
  T('$n.hiFree', () {
    final dirty = cp(rom);
    var did = 0;
    for (var b = 0xF0; b < 0x100; b++) {
      if (allFF(dirty, b << 16, (b + 1) << 16)) {
        dirty[(b << 16) + 5] = 1;
        did++;
      }
    }
    final a = E.hiFree(rom, []), c = E.hiFree(dirty, null, 0xF30000), d = E.hiFree(dirty, [0x200000]);
    return '${bo(identical(a, rom))} $did ${bo(identical(c, dirty))}${sha(c)} ${bo(identical(d, dirty))}${sha(d)}';
  });
  T('$n.t7', () {
    final c = E.t7Cfg(rom), f = E.t7FromRom(rom);
    return '${c != null ? 'v=${c.version} rom=${hx(c.romOff)}+${hx(c.romLen)} save=${hx(c.saveOff)} flags=${hx(c.flags)} figs=${c.figs.map((x) => '${x.name}@${hx(x.off)}+${hx(x.len)}').join(',')}' : 'null'} from=${f != null ? '${H(f.rom)}/${f.figs.map((x) => '${x.name}:${H(x.data)}').join(',')}' : 'null'} outdated=${bo(E.t7Outdated(rom))}';
  });
  T('$n.t18', () {
    final c = E.t18Cfg(rom);
    return '${c != null ? 'v=${c.version} save=${hx(c.saveOff)} flags=${hx(c.flags)} map=${c.map.map((v) => v.toRadixString(16)).join('.')} spare=${c.spare.map((v) => v.toRadixString(16)).join('.')}' : 'null'} from=${H(E.t18FromRom(rom))}';
  });
  T('$n.v1', () => '${H(E.v1FromRom(rom))} ${H(E.v1FromRom(rom, 0x200000))}');
  T('$n.wall', () {
    final d = DateTime(2024, 2, 29, 23, 59, 58), a = E.t7Wall(rom, 0x123456789, d), b = E.t18Wall(rom, -1, d);
    return '${bo(identical(a, rom))}${sha(a)} ${bo(identical(b, rom))}${sha(b)}';
  });
  T('$n.origs', () {
    final t = E.sceneTable(rom), o = E.installedOrigs(rom, t);
    return o != null ? o.map(hx).join(',') : 'null';
  });
  T('$n.upgrade', () => [E.emuUpgrade(rom, B.emu), E.t7Upgrade(rom, t7app()), E.t18Upgrade(rom, t18app()), E.t18Upgrade(rom, t18app(), B.stub), E.v1Upgrade(rom, v1app())].map(sn).join(' '));
  T('$n.upgrade.old', () {
    final r = cp(rom);
    r[0xA0000 + 0x900] ^= 0x55;
    r[0xC8000 + 5] ^= 1;
    r[0xF0000 + 0x40] ^= 1;
    return [E.emuUpgrade(r, B.emu), E.t7Upgrade(r, t7app()), E.t18Upgrade(r, t18app()), E.t18Upgrade(r, t18app(), B.stub), E.v1Upgrade(r, v1app()), E.t7Upgrade(r, T7App(cp(B.t7))), E.emuUpgrade(r, B.t7), E.v1Upgrade(r, V1App(cp(B.v1)))].map(sn).join(' ');
  });
  T('$n.remove', () => sha(E.emuRemove(rom)));
}

typedef Opts = ({bool launch, String? lang, bool? clock, bool? nfc, bool noClock, Uint8List? dlApp, bool noResv, List<(int, int)>? keep, int? txSpare, bool? t18More, bool clean, bool doomTop});
Opts O({bool launch = false, String? lang, bool? clock, bool? nfc, bool noClock = false, Uint8List? dlApp, bool noResv = false, List<(int, int)>? keep, int? txSpare, bool? t18More, bool clean = false, bool doomTop = false}) =>
    (launch: launch, lang: lang, clock: clock, nfc: nfc, noClock: noClock, dlApp: dlApp, noResv: noResv, keep: keep, txSpare: txSpare, t18More: t18More, clean: clean, doomTop: doomTop);
E.AppsPlaced place(Uint8List rom, List<Extra> xs, EmuApps apps, Opts o, {String? lang}) => E.appsPlace(rom, xs, apps,
    launch: o.launch, lang: lang ?? o.lang, clock: o.clock, nfc: o.nfc, noClock: o.noClock, dlApp: o.dlApp, noResv: o.noResv, keep: o.keep, txSpare: o.txSpare, t18More: o.t18More, clean: o.clean, doomTop: o.doomTop);

void onRom(String ed, Uint8List rom, Syn S) {
  final gen1 = ed == 'water' || ed == 'land' || ed == 'sky', first = ed == 'water' || ed == 'jade' || ed == 'tropical' || ed == 'neon';
  T('$ed.sceneTable', () {
    final t = E.sceneTable(rom);
    return '${t.length} home=${hx(t['PSID_HOME'])} ${sha(utf8.encode((t.keys.toList()..sort()).map((k) => '$k=${t[k]}').join(',')))}';
  });
  T('$ed.neonRom', () => bo(E.neonRom(rom)) + bo(E.neonRom(null)) + bo(E.neonRom(sub(rom, 0, 0xD85000))));
  T('$ed.t18Free', () => '${E.t18Free(rom).map((v) => v.toRadixString(16)).join('.')} / ${E.t18Free(rom, true).map((v) => v.toRadixString(16)).join('.')}');
  settings('$ed.plain', rom);
  // TamaEmu as the main program
  typedef TO = ({bool pack, bool? clock, String? lang, String? device});
  TO to({bool pack = false, bool? clock, String? lang, String? device}) => (pack: pack, clock: clock, lang: lang, device: device);
  final tamaCases = gen1
      ? [
          ('pc.50', to()), ('pc.100', to(clock: false)), ('id.50', to(lang: 'en')), ('idl.40', to()), ('idl.62', to(pack: true)), ('idl.62', to()), ('idl.85', to()), ('idl.85', to(pack: true)), ('ps.45', to(lang: 'en', clock: false)), ('ps.70', to(pack: true)), //
          ('4u.45', to()), ('4u.95', to(pack: true)), ('4u-plain.42', to(device: '4u-plain')), ('4u-plain.66', to()), ('tagps.30', to()), ('idl.40', to(device: 'ps')),
        ]
      : [('pc.50', to()), ('idl.62', to(pack: true)), ('ps.45', to())];
  Uint8List? tamaRom, tamaBig, nfcRom;
  final someT = RegExp(r'^(pc\.50|idl\.62|ps\.45|4u\.45)$');
  for (final (k, o) in tamaCases) {
    if (!first && !someT.hasMatch(k)) continue;
    final n = '$ed.emuPatch.$k${o.pack ? '.pack' : ''}${o.device != null ? '.${o.device}' : ''}';
    T(n, () {
      final r = E.emuPatch(rom, S.fws[k]!, B.emu, B.stub, pack: o.pack, clock: o.clock, lang: o.lang, device: o.device);
      if (k == 'pc.50') tamaRom = r.rom;
      if (k == 'idl.62' && o.pack) tamaBig = r.rom;
      if (k == '4u.45') nfcRom = r.rom;
      return '${r.device} blocks=${r.blocks} big=${bo(r.big)} ${sha(r.rom)}';
    });
  }
  T('$ed.emuPatch.short', () => sha(E.emuPatch(sub(rom, 0, 0x800000), S.fws['pc.50']!, B.emu, B.stub).rom));
  T('$ed.emuPatch.badfw', () => sha(E.emuPatch(rom, S.go, B.emu, B.stub).rom));
  T('$ed.emuPatch.noblock', () => sha(E.emuPatch(rom, S.fws['pc.50']!, B.t7, B.stub).rom));
  T('$ed.emuPatch.badstub', () => sha(E.emuPatch(rom, S.fws['pc.50']!, B.emu, B.emu).rom));
  if (tamaRom != null) {
    final tr = tamaRom!;
    settings('$ed.tama', tr);
    T('$ed.tama.again', () {
      final r = E.emuPatch(tr, S.fws['ps.45']!, B.emu, B.stub, lang: 'en');
      return '${r.device} ${bo(r.big)} ${sha(r.rom)}';
    });
    T('$ed.tama.v1', () => sha(E.v1Patch(tr, S.v46, v1app(), B.stub)));
    T('$ed.tama.t7', () => sha(E.t7Patch(tr, S.fr, [], t7app(), B.stub)));
    T('$ed.tama.t18', () {
      final r = E.t18Patch(tr, S.fw18, t18app(), B.stub);
      return '${r.blocks},${r.spares},${bo(r.hot)} ${sha(r.rom)}';
    });
    T('$ed.tama.installApp', () => '${sha(E.installApp(tr, B.gb, B.stub))} ${sha(E.installApp(tr, B.gb, B.stub, keep: true))}');
    T('$ed.tama.upgrade.v2', () {
      final r = cp(tr);
      return [1, 2, 3, 4, 5, 6].map((v) {
        w32(r, 0xA0144, v);
        final u = E.emuUpgrade(r, B.emu);
        return u != null ? sha(u).substring(0, 16) : 'null';
      }).join(' ');
    });
  }
  if (tamaBig != null) {
    final tb = tamaBig!;
    settings('$ed.tamaBig', tb);
    T('$ed.tamaBig.again', () {
      final r = E.emuPatch(tb, S.fws['pc.50']!, B.emu, B.stub);
      return '${bo(r.big)} ${sha(r.rom)}';
    });
    T('$ed.tamaBig.t7', () => sha(E.t7Patch(tb, S.go, [], t7app(), B.stub)));
    T('$ed.tamaBig.v1', () => sha(E.v1Patch(tb, S.v3, v1app(), B.stub)));
    T('$ed.tamaBig.t18', () => sha(E.t18Patch(tb, S.fw18, t18app(), B.stub).rom));
  }
  if (nfcRom != null) settings('$ed.tama4u', nfcRom!);
  // T7Emu as the main program
  final figs = [T7Fig('(03)_Tama-Go_Mametchi.bin', S.figA), T7Fig('Full figure.bin', S.figFull)];
  Uint8List? t7Rom_;
  T('$ed.t7Patch.go', () {
    t7Rom_ = E.t7Patch(rom, S.go, figs, t7app(), B.stub, lang: 'en');
    return sha(t7Rom_!);
  });
  T('$ed.t7Patch.friends', () => sha(E.t7Patch(rom, S.fr, figs, t7app(), B.stub, clock: false)));
  T('$ed.t7Patch.nox', () => sha(E.t7Patch(rom, S.go, [], T7App(cp(B.t7)), B.stub)));
  T('$ed.t7Patch.bad', () => sha(E.t7Patch(rom, S.v46, [], t7app(), B.stub)));
  T('$ed.t7Patch.many', () => sha(E.t7Patch(rom, S.go, List.filled(17, figs[0]), t7app(), B.stub)));
  T('$ed.t7Patch.noroom', () => sha(E.t7Patch(rom, S.go, [figs[0], for (var i = 1; i <= 7; i++) T7Fig('b$i', S.figB)], t7app(), B.stub)));
  T('$ed.t7Patch.wrongapp', () => sha(E.t7Patch(rom, S.go, [], T7App(B.gb), B.stub)));
  if (t7Rom_ != null) {
    final t7r = t7Rom_!;
    settings('$ed.t7', t7r);
    final used = cp(t7r);
    fillRnd(used, 0xC0000, 0x8000, 7);
    w32(used, 0xC1000, 0x45453754);
    T('$ed.t7.again.same', () => sha(E.t7Patch(used, S.go, figs, t7app(), B.stub, lang: 'en')));
    T('$ed.t7.again.figs', () => sha(E.t7Patch(used, S.go, [figs[0]], t7app(), B.stub)));
    T('$ed.t7.again.rom', () => sha(E.t7Patch(used, S.fr, [], t7app(), B.stub)));
    T('$ed.t7.outdated', () {
      final r = cp(used);
      var s2 = 0x7E7E;
      for (var i = 2; i < 4096; i++) {
        s2 = (s2 * 31 + r[0xC2000 + i]) & 0xFFFFFFFF;
      }
      w32(r, 0xC100C, (((s2 * 31) & 0xFFFFFFFF) * 31) & 0xFFFFFFFF);
      final a = E.t7Outdated(r);
      r[0xA0900] ^= 1;
      final b = E.t7Outdated(r);
      var s = 0x7E7E;
      for (var i = 0; i < 4096; i++) {
        s = (s * 31 + r[0xC2000 + i]) & 0xFFFFFFFF;
      }
      w32(r, 0xC100C, s);
      return bo(a) + bo(b) + bo(E.t7Outdated(r)) + bo(E.t7Outdated(r, 0x200000));
    });
    T('$ed.t7.tama', () => sha(E.emuPatch(t7r, S.fws['pc.50']!, B.emu, B.stub).rom));
    T('$ed.t7.t18', () => sha(E.t18Patch(t7r, S.fw18, t18app(), B.stub).rom));
    T('$ed.t7.apps', () => placedStr(E.appsPlace(t7r, [xt(S.fr), xt(S.v46)], APPS())));
  }
  // V1Emu, V3Emu as the main program
  Uint8List? v1Rom_, v3Rom_;
  T('$ed.v1Patch.46', () {
    v1Rom_ = E.v1Patch(rom, S.v46, v1app(), B.stub, lang: 'en');
    return sha(v1Rom_!);
  });
  T('$ed.v1Patch.48', () => sha(E.v1Patch(rom, S.v48, v1app(), B.stub, clock: false)));
  T('$ed.v1Patch.v3', () {
    v3Rom_ = E.v1Patch(rom, S.v3, v1app(), B.stub);
    return sha(v3Rom_!);
  });
  T('$ed.v1Patch.v3.none', () => sha(E.v1Patch(rom, S.v3, V1App(cp(B.v1)), B.stub)));
  T('$ed.v1Patch.bad', () => sha(E.v1Patch(rom, S.go, v1app(), B.stub)));
  if (v1Rom_ != null) {
    settings('$ed.v1', v1Rom_!);
    final used = cp(v1Rom_!);
    fillRnd(used, 0xC0000, 0x3000, 8);
    T('$ed.v1.again', () => '${sha(E.v1Patch(used, S.v46, v1app(), B.stub))} ${sha(E.v1Patch(used, S.v48, v1app(), B.stub))}');
    T('$ed.v1.upgrade.flags', () {
      final r = cp(used);
      w32(r, 0xA0140 + 20, 1);
      return sn(E.v1Upgrade(r, v1app()));
    });
  }
  if (v3Rom_ != null) settings('$ed.v3', v3Rom_!);
  // T18Emu as the main program
  Uint8List? t18Rom_;
  final someP = RegExp(r'^(a|en|big)$');
  for (final (n, fw, f) in <(String, Uint8List, E.T18PatchResult Function(Uint8List))>[
    ('a', S.fw18, (fw) => E.t18Patch(rom, fw, t18app(), B.stub)),
    ('en', S.fw18s, (fw) => E.t18Patch(rom, fw, t18app(), B.stub, lang: 'en', clock: false, opt: const EmuOpt(vol: 2, dim: 4, off: 5), nosess: true)),
    ('nohot', S.fw18, (fw) => E.t18Patch(rom, fw, t18app(), B.stub, hotWindow: false)),
    ('holes', S.fw18, (fw) => E.t18Patch(rom, fw, t18app(), B.stub, holes: true, spares: 7)),
    ('holes.nohot', S.fw18s, (fw) => E.t18Patch(rom, fw, t18app(), B.stub, holes: true, hotWindow: false, noResv: true)),
    ('launch', S.fw18, (fw) => E.t18Patch(rom, fw, t18app(), B.stub, launch: true, spares: 12)),
    ('noResv', S.fw18, (fw) => E.t18Patch(rom, fw, t18app(), B.stub, noResv: true)),
    ('big', S.fw18big, (fw) => E.t18Patch(rom, fw, t18app(), B.stub)),
    ('big.launch', S.fw18big, (fw) => E.t18Patch(rom, fw, t18app(), B.stub, launch: true)),
  ]) {
    if (!first && !someP.hasMatch(n)) continue;
    T('$ed.t18Patch.$n', () {
      final r = f(fw);
      if (n == 'a') t18Rom_ = r.rom;
      return '${r.blocks},${r.spares},${bo(r.hot)} ${sha(r.rom)}';
    });
  }
  T('$ed.t18Patch.bad', () => sha(E.t18Patch(rom, S.fws['idl.40']!, t18app(), B.stub).rom));
  T('$ed.t18Patch.noxip', () => sha(E.t18Patch(rom, S.fw18, T18App(cp(B.t18)), B.stub).rom));
  T('$ed.t18Patch.short', () => sha(E.t18Patch(sub(rom, 0, 100), S.fw18, t18app(), B.stub).rom));
  if (t18Rom_ != null) {
    final tr = t18Rom_!;
    settings('$ed.t18', tr);
    T('$ed.t18.again', () {
      final used = cp(tr);
      fillRnd(used, 0xC0000, 0x24000, 9);
      w32(used, 0xC0000, 0);
      final r = E.t18Patch(used, S.fw18, t18app(), B.stub);
      return '${bo(r.hot)} ${sha(r.rom)} ${sha(E.t18Patch(used, S.fw18s, t18app(), B.stub).rom)}';
    });
    T('$ed.t18.tama', () => sha(E.emuPatch(tr, S.fws['pc.50']!, B.emu, B.stub).rom));
    T('$ed.t18.t7', () => sha(E.t7Patch(tr, S.go, [], t7app(), B.stub)));
    T('$ed.t18.installApp', () => '${sha(E.installApp(tr, B.gb, B.stub))} ${sha(E.installApp(tr, B.gb, B.stub, keep: true))}');
    T('$ed.t18.pics', () {
      final m = {16: S.pics['blocks']!, 21: S.pics['small']!, 35: S.pics['64']!, 99: S.pics['noise']!, 18: S.pics['noise']!};
      final r = E.t18PicsWrite(tr, m), back = E.t18PicsRead(r), e = E.t18PicsWrite(r, {});
      return '${sha(r)} ${back.keys.map((k) => '$k:${sha(back[k]!).substring(0, 12)}').join(',')} ${sha(e)} ${E.t18PicsRead(e).length} ${resStr(E.appReserved(r))}';
    });
    T('$ed.t18.pics.none', () => '${bo(identical(E.t18PicsWrite(rom, {}), rom))}${E.t18PicsRead(rom).length}');
    // items into the installed T18Emu
    Uint8List? g1;
    T('$ed.t18.write', () {
      final fw = E.t18FromRom(tr)!;
      E.t18ItemAdd(fw, S.sc('meal'), 2);
      E.t18ItemAdd(fw, S.sc('item'));
      E.t18ItemAdd(fw, S.sc('room'));
      E.t18ItemAdd(fw, S.sc('game'));
      E.t18Points(fw, 4321);
      g1 = E.t18RomWriteGuest(tr, fw);
      final back = E.t18FromRom(g1!)!;
      return '${sha(g1!)} same=${bo(eq(back, fw))} ${itemsStr(E.t18Items(back))}';
    });
    T('$ed.t18.write2', () {
      final fw = E.t18FromRom(g1!)!;
      E.t18ItemAdd(fw, S.sc('acc'));
      E.t18ItemDel(fw, 'food', 0);
      fillRnd(fw, 0x7D0000, 0x1000, 3);
      fillRnd(fw, 0x7D5000, 0x2000, 4);
      final g2 = E.t18RomWriteGuest(g1!, fw), back = E.t18FromRom(g2)!;
      return '${sha(g2)} same=${bo(eq(back, fw))} up=${sn(E.t18Upgrade(g2, t18app(), B.stub))}';
    });
    T('$ed.t18.write.full', () {
      final fw = E.t18FromRom(g1!)!;
      for (var b = 0x60; b < 0x7F; b++) {
        if (allFF(fw, b << 16, (b + 1) << 16)) fillRnd(fw, b << 16, 0x10000, b);
      }
      return sha(E.t18RomWriteGuest(g1!, fw));
    });
    T('$ed.t18.write.none', () => sha(E.t18RomWriteGuest(rom, S.fw18)));
    T('$ed.t18.upgrade.nohot', () {
      final r = E.t18Patch(rom, S.fw18, t18app(), B.stub, hotWindow: false).rom;
      return '${sn(E.t18Upgrade(r, t18app()))} ${sn(E.t18Upgrade(r, t18app(), B.stub))}';
    });
  }
  T('$ed.installApp', () => sha(E.installApp(rom, B.gb, B.stub)));
  T('$ed.installApp.big', () => sha(E.installApp(rom, Uint8List(0x10001), B.stub)));
  // more programs in the menu
  List<Extra> small() => [
        xt(S.v46),
        Extra(kind: 'gb', rom: S.gb32, keys: [1, 2, 4, 8, 16, 32, 64, 128, 3], inv: true, save: rndBytes(0x3000, 11)),
        Extra(kind: 'sms', rom: S.smsNo, title: 'NO HEADER', gg: true, sess: false),
        Extra(kind: 'pm', rom: S.pmS, title: 'TINY', bios: S.bios, save: rndBytes(0x10000, 12), keys: [256, 128, 64, 32, 16, 8, 4, 2, 1]),
        Extra(kind: 'ab', rom: S.abData, title: 'ARDU', save: rndBytes(0x5000, 13), clock: false),
      ];
  List<Extra> mid() => [
        xt(S.go, figs: [T7Fig('Tama-Go_Kuchipatchi.bin', S.figA)], clock: false),
        xt(S.v3),
        Extra(kind: 'wolf', pack: S.wolfSh, keyMap: {'fire': 2, 'turn': 30, 'run': false, 'invert': false}, save: rndBytes(0x8000, 14)),
        Extra(kind: 'wolf', pack: S.sod),
        Extra(kind: 'gb', rom: S.gbcTrim),
        Extra(kind: 'gb', rom: S.gb256, save: Uint8List(0)),
        Extra(kind: 'sms', rom: S.sms1, keys: [1, 2, 3], inv: true, save: rndBytes(0x20000, 15)),
        Extra(kind: 'pm', rom: S.pm1, inv: true),
        Extra(kind: 'ab', rom: S.abOdd, inv: true, keys: [9, 8, 7, 6, 5, 4, 3, 2, 1]),
        xt(S.fr, figs: [T7Fig('x', S.figA)], sess: false),
      ];
  List<Extra> bigs() => [Extra(kind: 'gb', rom: S.gbc2m), Extra(kind: 'gb', rom: S.gbTrim), Extra(kind: 'wolf', pack: S.wolf), Extra(kind: 'gb', rom: S.gbc1m)];
  final sets = <(String, List<Extra> Function(), Opts)>[
    ('small', small, O()),
    ('small.en', small, O(lang: 'en', clock: false, nfc: false, noClock: true)),
    ('small.launch', small, O(launch: true, dlApp: B.gb)),
    ('mid', mid, O()),
    ('mid.launch', mid, O(launch: true, lang: 'en', noResv: true)),
    ('bigs', bigs, O()),
    ('bigs.launch', bigs, O(launch: true)),
    ('keep', small, O(keep: [(0xC00000, 0xD40000), (0xF80000, 0x1000000)], launch: true)),
    ('thirteen', () => List.filled(13, xt(S.v46)), O()),
    ('twelve', () => [for (var i = 0; i < 12; i++) xt(S.v48)], O(launch: true)),
  ];
  final reads = <(String, E.AppsPlaced, Opts)>[];
  for (final (n, mk, o) in sets) {
    T('$ed.apps.$n', () {
      final r = place(rom, mk(), APPS(), o);
      reads.add((n, r, o));
      return placedStr(r);
    });
  }
  for (final (n, r, o) in reads) {
    T('$ed.apps.$n.read', () => E.appsRead(r.rom, [for (final l in r.list) AppEntry(l.src, l.name)]).map(xStr).join(' | '));
    T('$ed.apps.$n.cfg', () => r.list.map((l) => cfgStr(E.extraCfg(r.rom, l.off))).join(' | '));
    T('$ed.apps.$n.clear', () {
      final back = E.appsRead(r.rom, r.list), c = E.appsClear(r.rom, back.map((x) => x.off)), c1 = E.appsClear(r.rom, back.skip(1).map((x) => x.off));
      return '${sha(c)} ${sha(c1)} base=${bo(eq(c, rom))} ${sha(E.appsClear(r.rom, null))}';
    });
    T('$ed.apps.$n.again', () {
      final back = E.appsRead(r.rom, r.list);
      final r2 = place(E.appsClear(r.rom, back.map((x) => x.off)), back, APPS(), o);
      return '${placedStr(r2)} same=${bo(eq(r2.rom, r.rom))}';
    });
    T('$ed.apps.$n.hiFree', () {
      final a = E.hiFree(r.rom, r.list.map((l) => l.off).toList()), b = E.hiFree(r.rom, []);
      return '${bo(identical(a, r.rom))}${sha(a)} ${bo(identical(b, r.rom))}${sha(b)}';
    });
  }
  EmuApps full() => EmuApps(t7: t7app(), v1: v1app(), tama: B.emu, t18: t18app(), doom: DoomApp(B.doomApp, B.doomXip), gb: B.gb, gbc: B.gbc, sms: B.sms, pm: B.pm, ab: B.ab, wolf: B.wolf, wolfsod: B.wolfsod);
  final miss = <(String, Extra, void Function(EmuApps))>[
    ('t7', xt(S.go), (A) => A.t7 = null),
    ('v1', xt(S.v46), (A) => A.v1 = null),
    ('gb', Extra(kind: 'gb', rom: S.gb32), (A) => A.gb = B.t7),
    ('gbc', Extra(kind: 'gb', rom: S.gbcTrim), (A) => A.gbc = B.gb),
    ('sms', Extra(kind: 'sms', rom: S.smsNo), (A) => A.sms = B.t7),
    ('pm', Extra(kind: 'pm', rom: S.pmS), (A) => A.pm = B.t7),
    ('ab', Extra(kind: 'ab', rom: S.abOdd), (A) => A.ab = B.t7),
    ('wolf', Extra(kind: 'wolf', pack: S.wolfSh), (A) => A.wolf = Uint8List(0x20001)),
    ('sod', Extra(kind: 'wolf', pack: S.sod), (A) => A.wolfsod = B.gb),
    ('tama', tama(S.fws['pc.50']!, 'pc'), (A) => A.tama = null),
    ('tama2', tama(S.fws['pc.50']!, 'pc'), (A) => A.tama = B.t7),
    ('t18', Extra(kind: 't18', fw: S.fw18), (A) => A.t18 = T18App(cp(B.t18))),
    ('doom', dx(S.wadC), (A) => A.doom = null),
    ('doom2', dx(S.wadC), (A) => A.doom = DoomApp(B.gb, B.doomXip)),
    ('full', Extra(kind: 'ab', rom: S.abOdd), (A) {}),
  ];
  T('$ed.apps.missing', () => miss.map((m) {
        final A = full();
        m.$3(A);
        try {
          E.appsPlace(rom, [m.$2], A, launch: true);
          return '${m.$1}=ok';
        } catch (e) {
          return '${m.$1}=${msg(e)}';
        }
      }).join(' ; '));
  T('$ed.apps.bad', () {
    final cases = [
      [Extra(kind: 'zz')],
      [xt(S.gb32)],
      [Extra(kind: 'ab', rom: rndBytes(0x8001, 1))],
      [Extra(kind: 'wolf', pack: rndBytes(100, 2))],
      [tama(S.fws['pc.50']!, 'pc')],
      [Extra(kind: 't18', fw: S.fw18)],
      [dx(S.wadC)],
      [dx(null)]
    ];
    final res = <String>[];
    for (var i = 0; i < cases.length; i++) {
      try {
        E.appsPlace(rom, cases[i], APPS(), launch: i == 7);
        res.add('ok');
      } catch (e) {
        res.add(msg(e));
      }
    }
    return res.join(' ; ');
  });
  // start device: the colour Tamas, T18Emu, DOOM
  final L = O(launch: true);
  final tamaSets = <(String, List<Extra>, Opts)>[
    ('pc', [tama(S.fws['pc.50']!, 'pc', opt: const EmuOpt(vol: 1, dim: 3, off: 2))], L),
    ('id.pack', [tama(S.fws['id.50']!, 'pc', pack: true, nfc: false, sess: false), xt(S.v46)], O(launch: true, lang: 'en')),
    ('idl', [tama(S.fws['idl.40']!, 'idl')], L),
    ('idl.pack', [tama(S.fws['idl.62']!, 'idl', pack: true, clock: false)], O(launch: true, txSpare: 0x20000)),
    ('ps', [tama(S.fws['ps.45']!, 'ps'), Extra(kind: 'gb', rom: S.gb32)], L),
    ('4u.big', [tama(S.fws['4u.95']!, '4u')], L),
    ('4u.big.pack', [tama(S.fws['4u.95']!, '4u', pack: true)], L),
    ('lzAll', [tama(S.fws['pc.50']!, 'pc', pack: true, lzAll: true)], L),
    ('lzExtra', [tama(S.fws['idl.40']!, 'idl', pack: true, lzExtra: [0x0b, 0x40])], L),
    ('two', [tama(S.fws['pc.50']!, 'pc'), tama(S.fws['pc.100']!, 'pc', pack: true), Extra(kind: 'sms', rom: S.gg, gg: true)], O(launch: true, dlApp: B.gb)),
    ('t18', [Extra(kind: 't18', fw: S.fw18, opt: const EmuOpt(vol: 3, dim: 1, off: 0)), xt(S.v46)], L),
    ('t18.few', [Extra(kind: 't18', fw: S.fw18s, sess: false, clock: false)], O(launch: true, t18More: false, noResv: true, lang: 'en')),
    ('t18.two', [Extra(kind: 't18', fw: S.fw18), Extra(kind: 't18', fw: S.fw18s)], L),
    ('t18.big', [Extra(kind: 't18', fw: S.fw18big), Extra(kind: 'gb', rom: S.gb256)], L),
    ('doom', [dx(S.wadA, keys: {'fire': 4, 'run': true, 'invert': false, 'mod': 2}, save: rndBytes(0x3000, 16)), Extra(kind: 'ab', rom: S.abOdd)], L),
    ('doom.two', [dx(S.wadB, region: 0x100000), dx(S.wadA, title: 'SECOND')], L),
    ('mixed', [xt(S.v46), tama(S.fws['pc.50']!, 'pc', pack: true), Extra(kind: 't18', fw: S.fw18s), Extra(kind: 'pm', rom: S.pmS), Extra(kind: 'wolf', pack: S.wolfSh)], L),
  ];
  final reads2 = <(String, E.AppsPlaced, List<Extra>, Opts)>[];
  final someS = RegExp(r'^(pc|idl\.pack|t18|doom|mixed)$');
  for (final (n, xs, o) in tamaSets) {
    if (!first && !someS.hasMatch(n)) continue;
    T('$ed.start.$n', () {
      final r = place(rom, xs, APPS(), o);
      reads2.add((n, r, xs, o));
      return placedStr(r);
    });
  }
  for (final (n, r, xs, o) in reads2) {
    var back = <Extra>[];
    T('$ed.start.$n.read', () {
      back = E.appsRead(r.rom, r.list);
      return '${back.map(xStr).join(' | ')} same=${[for (var i = 0; i < back.length; i++) bo(eq(anyOf(back[i]), anyOf(xs[i])))].join('')}';
    });
    T('$ed.start.$n.cfg', () => '${r.list.map((l) => cfgStr(E.extraCfg(r.rom, l.off))).join(' | ')} packed=${E.appsPacked(r.rom, r.list).join(',')}');
    T('$ed.start.$n.clear', () {
      final c = E.appsClear(r.rom, back.map((x) => x.off));
      return '${sha(c)} base=${bo(eq(c, rom))}';
    });
    T('$ed.start.$n.hiFree', () {
      final a = E.hiFree(r.rom, r.list.map((l) => l.off).toList(), 0xFE0000), b = E.hiFree(r.rom, []);
      return '${bo(identical(a, r.rom))}${sha(a)} ${bo(identical(b, r.rom))}${sha(b)}';
    });
    if (n == 't18' || n == 'mixed') {
      T('$ed.start.$n.keep', () {
        final t = back.firstWhere((x) => x.kind == 't18');
        E.t18ItemAdd(t.fw!, S.sc('meal'), 3);
        E.t18ItemAdd(t.fw!, S.sc('place'));
        final cl = E.appsClear(r.rom, back.where((x) => !identical(x, t)).map((x) => x.off));
        t.keepOff = t.off;
        t.items = true;
        t.opt = const EmuOpt(vol: 1, dim: 2, off: 3);
        final r2 = place(cl, back, APPS(), o, lang: 'en'), b2 = E.appsRead(r2.rom, r2.list);
        return '${placedStr(r2)} ${b2.map(xStr).join(' | ')} items=${itemsStr(E.t18Items(b2.firstWhere((x) => x.kind == 't18').fw!))}';
      });
    }
    if (n == 'pc' || n == 'idl.pack') {
      T('$ed.start.$n.pages', () {
        final x = back[0], c = E.extraCfg(r.rom, x.off)!, img = cp(r.rom);
        final lo = (c.guestOff + c.guestSize + 0x1FFF) & ~0x1FFF, data = lo + 0x2000;
        // the device wrote two pages of an empty block and (packed) erased a packed block
        var fb = -1;
        for (var b = 1; b < 0x40; b++) {
          if (c.map[b] == 0xFF && !(c.lzOff != 0 && u32(img, c.lzOff + 4 * b) != 0)) {
            fb = b;
            break;
          }
        }
        final n0 = math.min(64, ((c.spareEnd & ~0x1FFF) - data) >> 13), vp = <int>[];
        for (var i = 0; i < 64; i++) {
          vp.add(img[lo + 16 + 2 * i] | (img[lo + 17 + 2 * i] << 8));
        }
        var fi = vp.indexOf(0xFFFF);
        if (u32(img, lo) != 0x50584D50) {
          fi = 0;
          vp.fillRange(0, 64, 0xFFFF);
          fill(img, 0xFF, lo, lo + 0x1000);
        }
        vp[fi] = fb << 3;
        vp[fi + 1] = (fb << 3) + 5;
        fillRnd(img, data + (fi << 13), 0x4000, 21);
        var gone = -1;
        if (c.lzOff != 0) {
          for (var b = 0; b < 128; b++) {
            if (u32(img, c.lzOff + 4 * b) != 0) {
              gone = b;
              break;
            }
          }
          w32(img, lo + 144 + 4 * (gone >> 5), 1 << (gone & 31));
          var gx = 0x454E4F47;
          for (var i = 0; i < 4; i++) {
            gx = (gx ^ u32(img, lo + 144 + 4 * i)) & 0xFFFFFFFF;
          }
          w32(img, lo + 160, gx);
          vp[fi + 2] = (gone << 3) + 1;
          fillRnd(img, data + ((fi + 2) << 13), 0x2000, 22);
        }
        var xx = (0x50584D50 ^ ((n0 * 0x9E3779B1) & 0xFFFFFFFF)) & 0xFFFFFFFF;
        for (var i = 0; i < 64; i++) {
          img[lo + 16 + 2 * i] = vp[i] & 255;
          img[lo + 17 + 2 * i] = vp[i] >> 8;
          xx = ((((xx << 5) | (xx >> 27)) & 0xFFFFFFFF) ^ vp[i]) & 0xFFFFFFFF;
        }
        w32(img, lo, 0x50584D50);
        w32(img, lo + 4, n0);
        w32(img, lo + 8, xx);
        final b2 = E.appsRead(img, r.list);
        return 'fb=${hx(fb)} gone=$gone ${H(b2[0].guest)} same=${bo(eq(b2[0].guest!, x.guest!))}';
      });
    }
  }
}

void cleanRom(Syn S) {
  final blank = ffs(0x1000000);
  final sets = <(String, List<Extra>, Opts)>[
    ('doom', [dx(S.wadA)], O(clean: true, launch: true)),
    ('doom.link', [dx(S.wadA, keys: {'fwd': 1, 'back': 2, 'use': 4, 'run': false}), dx(S.wadB, ep: 5), dx(S.wadC, name: 'TINY')], O(clean: true, launch: true, lang: 'en')),
    ('doom.top', [dx(S.wadB), dx(S.wadA)], O(clean: true, launch: true, doomTop: true)),
    (
      'all',
      [
        xt(S.go), xt(S.v46), xt(S.v3), Extra(kind: 'gb', rom: S.gbc2m), Extra(kind: 'sms', rom: S.gg), Extra(kind: 'pm', rom: S.pm1), Extra(kind: 'ab', rom: S.abData), Extra(kind: 'wolf', pack: S.wolf), tama(S.fws['idl.40']!, 'idl'), Extra(kind: 't18', fw: S.fw18), dx(S.wadA), //
        tama(S.fws['pc.50']!, 'pc', pack: true),
      ],
      O(clean: true, launch: true, dlApp: B.gb, noClock: true)
    ),
    ('tamas', [tama(S.fws['4u.95']!, '4u'), tama(S.fws['ps.45']!, 'ps', pack: true)], O(clean: true, launch: true, txSpare: 0x30000)),
    ('full', [tama(S.fws['4u.95']!, '4u', pack: true), tama(S.fws['idl.85']!, 'idl'), tama(S.fws['ps.70']!, 'ps'), tama(S.fws['idl.62']!, 'idl')], O(clean: true, launch: true)),
    (
      'full.packed',
      [tama(S.fws['4u.95']!, '4u', pack: true), tama(S.fws['idl.85']!, 'idl', pack: true), tama(S.fws['ps.70']!, 'ps', pack: true), tama(S.fws['idl.62']!, 'idl', pack: true), tama(S.fws['4u-plain.66']!, '4u-plain', pack: true)],
      O(clean: true, launch: true)
    ),
  ];
  for (final (n, xs, o) in sets) {
    E.AppsPlaced? r0;
    var back = <Extra>[];
    T('clean.$n', () {
      r0 = place(blank, xs, APPS(), o);
      return placedStr(r0!);
    });
    if (r0 == null) continue;
    final r = r0!;
    T('clean.$n.read', () {
      back = E.appsRead(r.rom, r.list);
      return '${back.map(xStr).join(' | ')} same=${[for (var i = 0; i < back.length; i++) bo(eq(anyOf(back[i]), anyOf(xs[i])))].join('')}';
    });
    T('clean.$n.cfg', () => '${r.list.map((l) => '${cfgStr(E.extraCfg(r.rom, l.off))}/${cfgStr(E.doomCfg(r.rom, l.off))}').join(' | ')} packed=${E.appsPacked(r.rom, r.list).join(',')}');
    T('clean.$n.clear', () => sha(E.appsClear(r.rom, back.map((x) => x.off))));
  }
  T('clean.noclean.doom', () => placedStr(E.appsPlace(blank, [dx(S.wadA)], APPS())));
  T('clean.t18Free', () => '${E.t18Free(blank).length},${E.t18Free(blank, true).length} ${resStr(E.appReserved(blank))} ${cfgStr(E.extraCfg(blank, 0xA0000))}');
  T('clean.sceneTable', () => E.sceneTable(blank).length);
  T('clean.hiFree', () => bo(identical(E.hiFree(blank, []), blank)));
}

void main() {
  final dumps = Platform.environment['DUMPS'];
  if (dumps == null) {
    stderr.writeln('DUMPS is not set');
    exit(2);
  }
  ps = File.fromUri(Platform.script).parent.parent.parent.uri.resolve('third_party/paramix-studio').toFilePath();
  E.emuBinaries = E.EmuBinaries(emu: B.emu, stubTpl: B.stub, t7: B.t7, t7x: B.t7x, t18: B.t18, t18x: B.t18x, v1: B.v1, v3: B.v3, gb: B.gb, gbc: B.gbc, sms: B.sms, pm: B.pm, ab: B.ab, wolf: B.wolf, wolfsod: B.wolfsod);
  final S = pure();
  for (final ed in ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon']) {
    onRom(ed, File('$dumps/$ed.bin').readAsBytesSync(), S);
  }
  cleanRom(S);
  print(lines.join('\n'));
}
