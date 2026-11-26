// Synthetic guest firmware and games for tool/paramix_check/compose_check.dart: the generators of
// tool/paramix_check/emu_check.dart (seeded xorshift32, with the headers the detection looks for), unchanged.
// tool/paramix_check/compose_syn.js has the same ones for compose.js.

// ignore_for_file: non_constant_identifier_names, constant_identifier_names

import 'dart:math' as math;
import 'dart:typed_data';

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

Uint8List ffs(int n) => Uint8List(n)..fillRange(0, n, 0xFF);
void fill(Uint8List b, int v, int a, [int? e]) => b.fillRange(a, e ?? b.length, v);

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

