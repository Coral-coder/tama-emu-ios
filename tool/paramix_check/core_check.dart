// Checks lib/paramix/core_more.dart against Paramix Studio's core.js: prints the same lines as
// tool/paramix_check/core.js (one per case: <case name> <sha256 or value>).
// DUMPS=<folder with water.bin ...> dart run tool/paramix_check/core_check.dart
// ignore_for_file: non_constant_identifier_names
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tama_tools/paramix/core_more.dart';

const eds = ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon'];
String sha(Object b) => sha256.convert(b is String ? utf8.encode(b) : b as List<int>).toString();
void out(String n, Object? v) => stdout.writeln('$n $v');
void w16(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
}

void w32(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
  b[o + 2] = (v >> 16) & 255;
  b[o + 3] = (v >> 24) & 255;
}

int Function() rng(int seed) {
  var s = seed & 0xFFFFFFFF;
  return () {
    s = (s * 1103515245 + 12345) & 0xFFFFFFFF;
    return (s >> 16) & 255;
  };
}

// the JS check prints err:range for a RangeError or TypeError, else the message
String errOf(Object e) {
  if (e is RangeError) return 'err:range';
  if (e is StateError) return 'err:${e.message}';
  if (e is FormatException) return 'err:${e.message}';
  return 'err:range';
}

String err(Object? Function() f) {
  try {
    return '${f()}';
  } catch (e) {
    return errOf(e);
  }
}

String js(Object? v) => jsonEncode(v);
String J(Object? v) => sha(jsonEncode(v));

class H {
  final _sink = AccumulatorSink<Digest>();
  late final ByteConversionSink _in = sha256.startChunkedConversion(_sink);
  H s(Object? x) {
    _in.add(utf8.encode('$x\n'));
    return this;
  }

  H b(TypedData x) {
    final t = Uint8List(4);
    w32(t, 0, x.lengthInBytes ~/ x.elementSizeInBytes);
    _in.add(t);
    _in.add(x.buffer.asUint8List(x.offsetInBytes, x.lengthInBytes));
    return this;
  }

  H img(Rgba i) => s('${i.w}x${i.h}').b(i.data);
  H imgs(List<Rgba> l) {
    s(l.length);
    for (final i in l) {
      img(i);
    }
    return this;
  }

  String get hex {
    _in.close();
    return _sink.events.single.toString();
  }
}

class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];
  @override
  void add(T event) => events.add(event);
  @override
  void close() {}
}

String imgSha(Rgba i) => (H()..img(i)).hex;
String imgsSha(List<Rgba> l) => (H()..imgs(l)).hex;
Rgba img(int w, int h, List<int> Function(int x, int y) fn) {
  final d = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = fn(x, y);
      for (var k = 0; k < 4; k++) {
        final v = c[k];
        d[(y * w + x) * 4 + k] = v < 0 ? 0 : (v > 255 ? 255 : v); // Uint8ClampedArray
      }
    }
  }
  return Rgba(w, h, d);
}

List<Rgba> perturb(List<Rgba> subs, int seed) {
  final r = rng(seed);
  return [
    for (final s in subs)
      () {
        final d = Uint8List.fromList(s.data);
        for (var i = 0; i < d.length; i += 4) {
          final q = r();
          if (q < 48) {
            d[i] = (d[i] + r()) & 255;
            d[i + 1] ^= r() & 31;
          } else if (q < 52) {
            d[i + 3] = 0;
          } else if (q < 56) {
            d[i + 3] = 255;
          }
        }
        return Rgba(s.w, s.h, d);
      }()
  ];
}

List<Rgba> perturbFew(List<Rgba> subs, int seed) {
  final r = rng(seed);
  return [
    for (final s in subs)
      () {
        final d = Uint8List.fromList(s.data);
        for (var i = 0; i < d.length; i += 4) {
          final q = r();
          if (q < 48) {
            d[i] = (r() & 3) * 80;
            d[i + 1] = (r() & 1) * 200;
            d[i + 2] &= 0xC0;
          } else if (q < 52) {
            d[i + 3] = 0;
          } else if (q < 56) {
            d[i + 3] = 255;
          }
        }
        return Rgba(s.w, s.h, d);
      }()
  ];
}

int colours(List<Rgba> subs) {
  final m = <int>{};
  for (final s in subs) {
    for (var i = 0; i < s.data.length; i += 4) {
      if (s.data[i + 3] >= 128) m.add((s.data[i] << 16) | (s.data[i + 1] << 8) | s.data[i + 2]);
    }
  }
  return m.length;
}

String decSha(Uint8List e, [int palSet = 0]) => err(() {
      final d = spriteDecodeAll(e, palSet), h = H();
      h.s(js(d.header)).s(js(d.palettes)).s('${d.width}x${d.height}').s(d.cells.length);
      for (final c in d.cells) {
        h.b(c as TypedData);
      }
      h.imgs(d.subs);
      return h.hex;
    });

Uint8List ff(int n, [int v = 0xFF]) => Uint8List(n)..fillRange(0, n, v);
Uint8List cp(Uint8List b) => Uint8List.fromList(b);
Uint8List sub(Uint8List b, int a, [int? z]) => Uint8List.sublistView(b, a < 0 ? 0 : (a > b.length ? b.length : a), z == null ? b.length : (z > b.length ? b.length : z));
Uint8List words(List<int> ws) {
  final b = Uint8List(ws.length * 2);
  for (var i = 0; i < ws.length; i++) {
    w16(b, 2 * i, ws[i]);
  }
  return b;
}

Uint8List fakeSprite(int w, int h, int n, int seed) {
  final subs = [
    for (var i = 0; i < n; i++) img(w, h, (x, y) => ((x + y + i + seed) % 7 == 0) ? [0, 0, 0, 0] : [(x * 9 + seed * 40) & 255, (y * 7) & 255, (i * 30) & 255, 255])
  ];
  final orig = Uint8List(24 + 32 + 8 * n);
  orig[5] = 2;
  orig[6] = n;
  orig[8] = w;
  orig[9] = h;
  orig[12] = 1;
  orig[13] = 1;
  orig[14] = 0x11;
  orig[15] = 1;
  orig[4] = 0xa7;
  orig[18] = 24;
  orig[20] = 56;
  return spriteEncodeOpts(orig, subs);
}

const shapes = [
  [64, 64, 20],
  [64, 32, 20],
  [64, 32, 18],
  [32, 32, 24],
  [32, 16, 14],
  [32, 16, 14]
];
Uint8List fakeRom() {
  final parts = [for (var i = 0; i < 6; i++) fakeSprite(16, 16, 2, i)];
  final egg = [fakeSprite(32, 32, 5, 1), fakeSprite(16, 16, 1, 2), fakeSprite(16, 16, 1, 3), fakeSprite(64, 64, 5, 4), fakeSprite(16, 16, 1, 5), fakeSprite(16, 16, 1, 6)];
  final entries = [
    ...parts,
    ...egg,
    for (var k = 0; k < 6; k++) fakeSprite(shapes[k][0], shapes[k][1], shapes[k][2], 10 + k),
    for (var k = 0; k < 6; k++) fakeSprite(shapes[k][0], shapes[k][1], shapes[k][2], 20 + k),
  ];
  final pack = packJoin(entries);
  final root = arc2Build([
    ff(64, 7),
    pack,
    arc2Build([Uint8List(10)])
  ]);
  final rom = ff(0x1000000);
  rom.setAll(0, 'SONIXDEV'.codeUnits);
  rom.setAll(ASSET_BASE, root);
  final verPage = (ASSET_BASE + root.length + 0x200000) & ~0xfff;
  rom.setAll(verPage, [1, 0, 0, 0]);
  return rom;
}

// ---- synthetic cards
Uint8List smaCard(int seed) {
  final r = rng(seed), raw = Uint8List(0x100000);
  const B = 0x1000;
  raw.setAll(0x10, 'BANDAINTPD'.codeUnits);
  raw.setAll(0x20, 'TAMASUMA'.codeUnits);
  w16(raw, B, 0x3232);
  w16(raw, B + 2, 2);
  w32(raw, B + 8, 0x100);
  w32(raw, B + 24, 0x8000);
  const dp = B + 0x100, sp = B + 0x8000, nSets = 5, nGroups = 4;
  final lay = <int>[], fr = <int>[];
  var nl = 0;
  for (var f = 0; f < nGroups * 53; f++) {
    final none = r() < 40, g = f ~/ 53, k = f % 53;
    if (k == 1 ? g == 3 : none) {
      fr.addAll([0xFFFF, 0]);
      continue;
    }
    final cnt = 1 + r() % 3;
    fr.addAll([nl, cnt]);
    for (var j = 0; j < cnt; j++) {
      final a = r(), b = r();
      final m = 0x400 | (b < 230 ? 0x200 : 0) | (a & 0x07) | (a & 0x30) | ((b & 1) << 8), ws = [m];
      if ((m & 1) != 0) ws.add((r() % 41 - 20) & 0xFFFF);
      if ((m & 2) != 0) ws.add((r() % 41 - 20) & 0xFFFF);
      if ((m & 4) != 0) ws.add(r() % 3);
      if ((m & 0x10) != 0) ws.add(r());
      if ((m & 0x20) != 0) ws.add(r() << 8);
      if ((m & 0x100) != 0) ws.add(r());
      if ((m & 0x200) != 0) ws.add(const [3, 1, 1, 2][r() & 3]);
      ws.add(r() < 210 ? 0x8000 | (r() % (nSets + 1)) : r());
      lay.addAll(ws);
      nl++;
    }
  }
  final chars = Uint8List(8 * 96);
  for (var i = 0; i < chars.length; i++) {
    chars[i] = r();
  }
  const types = [1, 2, 3, 4, 5, 6, 0, 5];
  for (var k = 0; k < 8; k++) {
    w16(chars, k * 96 + 2, types[k]);
    chars[k * 96 + 28] = k % 4;
  }
  final tabs = [for (var i = 0; i < 19; i++) Uint8List(0)];
  tabs[11] = chars;
  tabs[15] = words(lay);
  tabs[18] = words(fr);
  var o = 80;
  for (var i = 0; i < 20; i++) {
    w32(raw, dp + 4 * i, o ~/ 2);
    if (i < 19) {
      raw.setAll(dp + o, tabs[i]);
      o += tabs[i].length;
    }
  }
  const nSpr = 51, nCol = 96, io = 16, so = io + 6 * nSets, po = so + 8 * nSpr, xo = po + 2 * nCol;
  final four = [io, so, po, xo];
  for (var i = 0; i < 4; i++) {
    w32(raw, sp + 4 * i, four[i]);
  }
  for (var i = 0; i < nSets; i++) {
    final q = sp + io + 6 * i;
    w16(raw, q, i * 12);
    raw[q + 2] = i < 4 ? 2 : 1;
    raw[q + 3] = i < 4 ? 2 : 1;
    w16(raw, q + 4, i < 4 ? i * 4 : 20);
  }
  for (var i = 0; i < nSpr; i++) {
    final q = sp + so + 8 * i;
    w16(raw, q, i < 48 ? i : 24 + (i - 48));
    w16(raw, q + 2, (r() % 17 - 8) & 0xFFFF);
    w16(raw, q + 4, (r() % 17 - 8) & 0xFFFF);
    w16(raw, q + 6, i < 48 ? 0x51 : 0x8000);
  }
  for (var i = 0; i < nCol; i++) {
    var v = r() | (r() << 8);
    v = (i % 16 == 0 || r() < 32) ? v | 0x8000 : v & 0x7FFF;
    w16(raw, sp + po + 2 * i, v);
  }
  for (var i = 0; i < 0x2000; i++) {
    final x = i & 15, y = (i >> 4) & 15;
    raw[sp + xo + i] = (x > 2 && x < 13 && y > 1 && y < 14) ? r() : ((r() & 3) == 0 ? r() & 0x0F : 0);
  }
  return raw;
}

Uint8List dimCard(int seed) {
  final r = rng(seed), sizes = <int>[];
  const b = 0x100000;
  for (var i = 0; i < 8; i++) {
    sizes.add(2560);
  }
  sizes.add(2400);
  for (var i = 0; i < 12; i++) {
    sizes.add(7168);
  }
  sizes.add(25600);
  sizes.add(4800);
  for (var i = 0; i < 5; i++) {
    sizes.add(1536);
  }
  sizes.add(2400);
  for (var i = 0; i < 3; i++) {
    sizes.add(7168);
  }
  sizes.addAll([100, 2400, 3528, 2560]);
  final n = sizes.length, total = sizes.fold(0, (a, c) => a + c), first = 0x4c + 4 * (n + 1);
  final d = Uint8List(b + first + total);
  d.setAll(b, 'GP_SPIFI'.codeUnits);
  w32(d, b + 0x48, n);
  var o = first;
  for (var i = 0; i <= n; i++) {
    w32(d, b + 0x4c + 4 * i, o);
    if (i < n) o += sizes[i];
  }
  o = b + first;
  const pal = [0xF800, 0x001F, 0xFFFF, 0x0000, 0x8410, 0xFFE0, 0x0010, 0xFC10];
  for (final sz in sizes) {
    final blob = r() & 7;
    for (var k = 0; k < sz >> 1; k++) {
      final q = r();
      final v = q < 60
          ? 0x07e0
          : q < 200
              ? (blob * 0x1863 + 0x4208) & 0xFFFF
              : pal[r() & 7];
      w16(d, o + 2 * k, v);
    }
    o += sz;
  }
  for (var i = 0; i < d.length; i++) {
    d[i] ^= 0xff;
  }
  return d;
}

CardChar drawnChar(bool baby) {
  final W = baby ? 32 : 64, hh = baby ? 24 : 56, cx = W >> 1, cy = hh >> 1, rx = (W * 3) >> 3, ry = (hh * 3) >> 3, ex = cx - (W >> 3), ey = cy - (hh >> 3);
  Rgba mk(int dx, int dy, bool eye) => img(W, hh, (x0, y0) {
        final x = x0 - dx, y = y0 - dy;
        final q = (x - cx) * (x - cx) * ry * ry + (y - cy) * (y - cy) * rx * rx, lim = rx * rx * ry * ry;
        if (q > lim) return [0, 0, 0, 0];
        if (eye && (x - ex).abs() <= 1 && (y - ey).abs() <= 1) return x == ex && y == ey ? [10, 10, 20, 255] : [255, 255, 255, 255];
        if (eye && (x - ex).abs() <= 2 && (y - ey).abs() <= 2) return [20, 20, 30, 255];
        if (q > lim * 3 / 4) return [20, 20, 30, 255];
        return y > cy + 2 ? [230, 170, 40, 255] : [250, 200, 60, 255];
      });
  return CardChar(index: 0, baby: baby, frames: {'idle1': mk(0, 0, true), 'idle2': mk(1, 0, true), 'walk1': mk(2, 1, true), 'happy': mk(0, -1, false), 'sleep': mk(-3, 2, true), 'attack': mk(9, 0, true)});
}

String charSha(CardChar ch) {
  final h = H().s(ch.index).s(ch.baby).s(ch.stage).s(ch.name != null ? imgSha(ch.name!) : null);
  ch.frames.forEach((k, v) => h.s(k).img(v));
  return h.hex;
}

String mv(EyeMoved m) => '${m.count}:${sha(m.dataPack)}';
List<bool> optList(SpriteOpts o) => [o.keepPalette, o.allowMoreColors, o.figure, o.keepLength];
List<(int, int, int, int)> moves(List<Face> fp, List<int> Function(int i) d) => [
      for (var i = 0; i < fp.length; i++)
        for (final x in [fp[i].eye, fp[i].mouth])
          if (x != null) (x.ox!, x.oy!, d(i)[0], d(i)[1])
    ];

class Kind {
  const Kind(this.bpp, this.w, this.h, this.n, {this.pack, this.xor = false, this.transp = false, this.tr = 0, this.numPal, this.iw, this.ih, this.unc = false, this.ox = 0, this.oy = 0, this.extra = 0});
  final int bpp, w, h, n;
  final String? pack;
  final bool xor, transp, unc;
  final int tr, ox, oy, extra;
  final int? numPal, iw, ih;
  Kind withBpp(int b) => Kind(b, w, h, n, pack: pack, xor: xor, transp: transp, tr: tr, numPal: numPal, iw: iw, ih: ih, unc: unc, ox: ox, oy: oy, extra: extra);
}

RomCtx ctxOf(RomCtx base, {List<Uint8List>? files, List<int>? groups}) =>
    RomCtx(rom: base.rom, root: base.root, files: files ?? base.files, entries: base.entries, groups: groups ?? base.groups, adult: base.adult, egg: base.egg, assetEnd: base.assetEnd, limit: base.limit, editionId: base.editionId, edition: base.edition);

Future<String> fut(Future<String> Function() f) async {
  try {
    return await f();
  } catch (e) {
    return errOf(e);
  }
}

Future<void> main() async {
  final dumps = Platform.environment['DUMPS']!;
  // ================================================================ without a dump
  out(
      'consts',
      [
        ASSET_BASE,
        js({for (final e in EDITIONS.entries) '${e.key}': e.value}),
        js([
          for (final p in GROUP_PARTS) {'key': p.key, 'w': p.w, 'h': p.h, 'n': p.n}
        ]),
        GROUP_SHEET_W,
        GROUP_SHEET_H,
        js({for (final e in FIELD_NAMES.entries) '${e.key}': e.value}),
        js(TXT_ENC),
        EYE_V2
      ].join('|'));
  out(
      'DIM_EYE_PRESETS',
      js([
        for (final k in DIM_EYE_PRESETS.keys.toList()..sort((a, b) => int.parse(a) - int.parse(b))) [k, DIM_EYE_PRESETS[k]]
      ]));
  {
    final r = rng(1), b = Uint8List(5000);
    for (var i = 0; i < b.length; i++) {
      b[i] = r();
    }
    out('crc32', '${crc32(b)} ${crc32(sub(b, 0, 0))} ${crc32(Uint8List.fromList(utf8.encode('123456789')))}');
  }
  // RLE and LZ4
  for (var t = 0; t < 12; t++) {
    final r = rng(100 + t), n = [0, 1, 5, 13, 64, 300, 1024, 4096, 127, 128, 4000, 9000][t], b = Uint8List(n);
    for (var i = 0; i < n;) {
      final q = r();
      if (t % 3 == 0) {
        b[i++] = q;
      } else {
        final run = 1 + (r() % (t % 3 == 1 ? 9 : 400));
        for (var k = 0; k < run && i < n; k++) {
          b[i++] = q & ((t & 1) != 0 ? 255 : 3);
        }
      }
    }
    final re = rleEncode(b), le = lz4Encode(b);
    out('rle$t', '${sha(re)} ${sha(rleDecode(re, false))} ${sha(rleDecode(re)) == sha(b)}');
    out('lz4$t', '${sha(le)} ${sha(lz4Decode(le))} ${sha(lz4Decode(le)) == sha(b)}');
    out('rle$t.cut', '${sha(rleDecode(sub(re, 0, re.length >> 1)))} ${sha(rleDecode(b))}');
    out('lz4$t.cut', '${sha(lz4Decode(sub(le, 0, le.length >> 1)))} ${sha(lz4Decode(b))} ${sha(lz4Decode(sub(le, 0, le.length - 1)))}');
  }
  {
    final ws = [3, 0x11223344, 0x80000002, 1, 2, 3, 4, 5, 6, 7, 8, 2, 0xAABBCCDD, 0x80000003, 9, 9, 0, 77, 77];
    final b = Uint8List(ws.length * 4);
    for (var i = 0; i < ws.length; i++) {
      w32(b, 4 * i, ws[i]);
    }
    out('rle.word', '${sha(rleDecode(b, true))} ${sha(rleDecode(sub(b, 0, 58), true))} ${rleDecode(b, true).length}');
  }
  {
    final l = [
      Uint8List.fromList([0xF0, 255, 255, 3]),
      Uint8List.fromList([0x1F, 65, 1, 0, 255, 255]),
      Uint8List.fromList([0x10, 65, 9, 0, 0x10, 66]),
      Uint8List.fromList([0x20, 65])
    ];
    out('lz4.odd', l.map((x) => '${lz4Decode(x).length}:${sha(lz4Decode(x))}').join(' '));
  }
  // quantize
  for (var t = 0; t < 14; t++) {
    final r = rng(200 + t), n = [1, 5, 40, 300, 2000, 6000, 20000, 500, 500, 3000, 64, 1000, 4000, 12000][t], nc = [4, 4, 15, 16, 16, 255, 256, 1, 3, 8, 64, 2, 15, 31][t], px = <List<int>>[];
    for (var i = 0; i < n; i++) {
      final m = t % 4;
      if (m == 0) {
        final a = r(), b = r(), c = r();
        px.add([a, b, c]);
      } else if (m == 1) {
        final a = r() & 0xF8, b = r() & 0xE0, c = r() & 0xC0;
        px.add([a, b, c]);
      } else if (m == 2) {
        final a = r() >> 3, b = 200 + (r() & 31), c = (r() & 1) != 0 ? 255 : 0;
        px.add([a, b, c]);
      } else {
        final a = (r() % 6) * 51, b = (r() % 3) * 100, c = r() % 40;
        px.add([a, b, c]);
      }
    }
    out('quantize$t', '${quantize(px, nc).length} ${J(quantize(px, nc))}');
  }
  out(
      'textClean',
      js([
        for (final s in ['Mametchi', '  hello   world  ', 'straße', 'ünïcödé', "it's a.b&c!?/", '###', '', null, null, 'a\tb\nc', 'ﬁne ﬂow ﬀ ﬃ ﬄ ﬅ ﬆ', 'ı ſ ŉ ǰ ẖ ẗ ẘ ẙ ẚ', 'KK åéî', 'x  y', 'abc123xyz', 'TAMA-GOTCHI_42', 'µ ÿ ǆ ǅ ΐ ա և', '12345']) textClean(s)
      ]));
  out(
      'sheetLayout',
      js([
        for (final a in [
          [64, 64, 20],
          [32, 16, 14],
          [512, 512, 7],
          [1281, 5, 3],
          [1280, 2, 3],
          [640, 2, 3],
          [1, 1, 5000],
          [100, 7, 13],
          [16, 16, 0],
          [8, 8, 1]
        ])
          () {
            final l = sheetLayout(a[0], a[1], a[2]);
            return {'cols': l.cols, 'rows': l.rows, 'w': l.w, 'h': l.h};
          }()
      ]));
  out('partOptions', js([partOptions(0), partOptions(1), partOptions(2), partOptions(3), partOptions(4), partOptions(5), partOptions(1, keepPalette: true), partOptions(4, keepLength: false, figure: false), partOptions(2, allowMoreColors: true, keepLength: true)].map(optList).toList()));
  for (final a in [
    ['0123456789', 100, 20, 2],
    ['42', 32, 32, 3],
    ['7', 8, 8, 1],
    ['1000', 64, 64, 5],
    ['', 5, 5, 1],
    ['88', 4, 3, 2]
  ]) {
    out('numberImage.${a[0]}', imgSha(numberImage(a[0] as String, a[1] as int, a[2] as int, a[3] as int)));
  }
  out('numberImage.err', err(() => imgSha(numberImage('1a', 30, 30, 1))));
  // pictures
  {
    final a = img(40, 30, (x, y) => (x + y) % 5 == 0 ? [0, 0, 0, 0] : [x * 6, y * 8, (x * y) & 255, 255]), e = emptyImage(40, 30);
    final bd = cp(a.data), cd = cp(a.data);
    for (var i = 0; i < bd.length; i++) {
      if (i % 4 != 3) {
        final v = bd[i] + (i % 7 == 0 ? 4 : 0);
        bd[i] = v > 255 ? 255 : v;
      }
    }
    cd[4 * 43] ^= 0x20;
    final b = Rgba(40, 30, bd), c = Rgba(40, 30, cd);
    out('emptyImage', '${imgSha(e)} ${imgSha(emptyImage(0, 0))}');
    out('sameImage', [sameImage(a, a), sameImage(a, e), sameImage(a, b), sameImage(a, c), sameImage(e, emptyImage(40, 31)), sameImage(e, emptyImage(40, 30))].join(' '));
    out('crop', [imgSha(crop(a, 0, 0, 40, 30)), imgSha(crop(a, 5, 7, 11, 13)), imgSha(crop(a, 39, 29, 1, 1)), imgSha(crop(a, 30, 20, 20, 5)), err(() => imgSha(crop(a, 0, 28, 8, 4)))].join(' '));
    final pl = <List<num>>[
      [64, 64, 1],
      [64, 64, 2],
      [32, 32, 0.5],
      [32, 32, 0.625, 28],
      [64, 64, 1.25, 54],
      [64, 64, 1.5],
      [20, 20, 1],
      [20, 20, 3],
      [64, 64, 0.3],
      [41, 31, 1.01],
      [128, 128, 2.7, 100],
      [64, 64, 0.01],
      [16, 64, 1, 40],
      [64, 64, 1 / 3],
      [64, 64, 0.7, 60]
    ];
    Rgba pla(Rgba im, List<num> p) => place(im, p[0] as int, p[1] as int, p[2], p.length > 3 ? p[3] as int : null);
    for (var i = 0; i < pl.length; i++) {
      out('place$i', err(() => imgSha(pla(a, pl[i]))));
    }
    final soft = img(33, 27, (x, y) => [(x * 37 + y * 11) & 255, (x * 5 + y * 91) & 255, (x * y * 3) & 255, (x * 29 + y * 53) & 255]);
    for (var i = 0; i < pl.length; i++) {
      out('place.soft$i', err(() => imgSha(pla(soft, pl[i]))));
    }
    // sheets
    final subs = [for (var i = 0; i < 45; i++) img(32, 16, (x, y) => [x * 8, y * 16, i * 5, (x + i) % 3 != 0 ? 255 : 0])];
    final sh = sheetFromSubs(subs);
    out('sheetFromSubs', imgSha(sh));
    out('subsFromSheet', imgsSha(subsFromSheet(sh, 32, 16, 45)));
    out('subsFromSheet.err', '${err(() => imgsSha(subsFromSheet(sh, 32, 16, 44)))} ${err(() => imgsSha(subsFromSheet(sh, 16, 16, 45)))}');
    final parts = [
      for (var k = 0; k < 6; k++) [for (var i = 0; i < GROUP_PARTS[k].n; i++) img(GROUP_PARTS[k].w, GROUP_PARTS[k].h, (x, y) => [(x * 4 + k * 40) & 255, (y * 4 + i * 9) & 255, ((x ^ y) * 3) & 255, (x + y + i) % 4 != 0 ? 255 : 0])]
    ];
    final gs = groupSheet(parts);
    out('groupSheet', imgSha(gs));
    out('groupFromSheet', groupFromSheet(gs).map(imgsSha).join(' '));
    out('groupFromSheet.err', err(() => groupFromSheet(a).length));
  }
  // ZIP
  {
    Uint8List def(List<int> d) => Uint8List.fromList([1, d.length & 255, d.length >> 8, ~d.length & 255, (~d.length >> 8) & 255, ...d]);
    final big = Uint8List(1000);
    for (var i = 0; i < 1000; i++) {
      big[i] = (i * 7) & 255;
    }
    final files = [
      ZipFile('figur_0012.png', Uint8List.fromList([1, 2, 3])),
      ZipFile('a/b.txt', Uint8List.fromList(utf8.encode('hallo'))),
      ZipFile('dir/', Uint8List(0)),
      ZipFile('größe ü.bin', big),
      ZipFile('packed.bin', def(utf8.encode('deflated text'))),
      ZipFile('empty', Uint8List(0))
    ];
    final z = zipBuild(files);
    out('zipBuild', '${z.length} ${sha(z)} ${sha(zipBuild([]))}');
    Uint8List inf(Uint8List b) => Uint8List.fromList(ZLibDecoder(raw: true).convert(b));
    String show(List<ZipFile> l) => l.map((f) => '${f.name}:${f.data.length}:${sha(f.data)}').join(',');
    out('zipRead', show(await zipRead(z, inf)));
    final z2 = cp(z);
    var p = z2[z2.length - 6] | z2[z2.length - 5] << 8 | z2[z2.length - 4] << 16 | z2[z2.length - 3] << 24;
    for (var k = 0; k < 4; k++) {
      p += 46 + (z2[p + 28] | z2[p + 29] << 8);
    }
    z2[p + 10] = 8;
    out('zipRead.deflate', show(await zipRead(z2, (b) async => inf(b))));
    z2[p + 10] = 9;
    out('zipRead.method', await fut(() async => show(await zipRead(z2, inf))));
    out('zipRead.nozip', '${await fut(() async => show(await zipRead(Uint8List(100), inf)))} ${await fut(() async => show(await zipRead(Uint8List(5), inf)))}');
    final z3 = Uint8List(z.length + 300)..setAll(0, z);
    out('zipRead.tail', await fut(() async => show(await zipRead(z3, inf))));
  }
  // the synthetic ROM of the Studio's own unit test
  late RomCtx fake;
  {
    final rom = fakeRom(), ctx = openRom(rom);
    fake = ctx;
    out('fake.rom', sha(rom));
    out('fake.open', [ctx.editionId, ctx.edition, ctx.assetEnd, ctx.limit, ctx.entries.length, js(ctx.groups), ctx.adult, ctx.egg, isNeon(rom)].join('|'));
    out('fake.findGroups', '${js(findGroups(ctx.entries))} ${findEgg(ctx.entries)} ${findEgg(ctx.entries.sublist(7))} ${js(findGroups(ctx.entries.sublist(0, 15)))}');
    out('fake.rebuild', sha(buildRomCtx(ctx, {}).rom) == sha(rom));
    for (var i = 0; i < ctx.entries.length; i++) {
      out('fake.decode$i', decSha(ctx.entries[i]));
    }
    final g = ctx.groups[0];
    final red = img(64, 64, (x, y) => (x > 10 && x < 50 && y > 10) ? [250, 30, 40, 255] : (x == 10 ? [0, 0, 0, 255] : [0, 0, 0, 0]));
    final body = spriteEncodeOpts(ctx.entries[g], List.filled(20, red), partOptions(0));
    out('fake.body', '${sha(body)} ${decSha(body)}');
    final eyesBlank = spriteBlank(ctx.entries[g + 1], partOptions(1));
    out('fake.eyesBlank', sha(eyesBlank));
    out('fake.eyes.err', err(() => sha(spriteEncodeOpts(ctx.entries[g + 1], List.filled(20, img(64, 32, (x, y) => [(x * 37 + y * 91) & 255, (x * 13) & 255, (y * 71) & 255, 255])), partOptions(1)))));
    out('fake.encode.err', '${err(() => sha(spriteEncodeOpts(ctx.entries[g], List.filled(19, red))))} ${err(() => sha(spriteEncodeOpts(ctx.entries[g + 1], List.filled(20, red))))}');
    final b = buildRomCtx(ctx, {g: body, g + 1: eyesBlank});
    out('fake.buildRom', '${sha(b.rom)} ${b.assetEnd} ${b.free}');
    final dpNew = ff(3000, 9), b2 = buildRomCtx(ctx, {3: spriteTiny(ctx.entries[3])}, dpNew);
    out('fake.buildRom.dp', '${sha(b2.rom)} ${b2.assetEnd} ${b2.free} ${sha(openRom(b2.rom).files[0])}');
    out('fake.buildRom.big', err(() => sha(buildRomCtx(ctx, {}, Uint8List(0x300000)).rom)));
    out('fake.verifyRom', '${verifyRom(rom, [0, 5, 20])} ${err(() {
      final r2 = cp(rom);
      r2[ASSET_BASE + 40]++;
      return verifyRom(r2, []);
    })} ${err(() {
      final r2 = cp(rom);
      r2[ASSET_BASE] = 0;
      return verifyRom(r2, []);
    })}');
    out('fake.open.err', '${err(() => openRom(sub(rom, 0, 1000)).limit)} ${err(() {
      final r2 = cp(rom);
      r2[0] = 0x58;
      return openRom(r2).limit;
    })} ${err(() {
      final r2 = cp(rom);
      r2.setAll(ASSET_BASE, arc2Build([Uint8List(4), Uint8List(8)]));
      return openRom(r2).limit;
    })} ${err(() {
      final r2 = cp(rom);
      r2[ASSET_BASE + 1] = 0;
      return openRom(r2).limit;
    })}');
    out('fake.launcher', '${js(launcherKeep(ctx).toList())} ${isLauncher(ctx)} ${js(launcherChanges(ctx).keys.toList())}');
    out('fake.texts', textTablesOf(rom) == null ? 'null' : 'tables');
    out('fake.textGet', '${js(textGet(rom, 3))} ${err(() => sha(textApply(rom, {1: 'X'})))} ${identical(textApply(rom, {}), rom)} ${identical(textApply(rom, null), rom)}');
    out('fake.fields', '${js(charTable(ctx.files[0]))}${js(charGroups(ctx))}${js(fieldSets(ctx))}');
    void idp(Uint8List r2, int p, int id, int c) {
      w32(r2, p, id);
      final k = (c - id) & 0xFFFFFFFF;
      w32(r2, p + 0xFF8, k);
      w32(r2, p + 0xFFC, ~k & 0xFFFFFFFF);
    }

    const edl = [
      [0xD49000, 2, 0x70169E2C],
      [0xD49000, 4, 0x849633DB],
      [0xD29000, 6, 0x96CB83B8],
      [0xD29000, 4, 0x96CB83B8],
      [0xD85000, 7, 0x99431749],
      [0xEFD000, 7, 0x99431749],
      [0xEFD000, 3, 0x70169E2C],
      [0xEFD000, 4, 0x96CB83B8],
      [0xD49000, 5, 0x96CB83B8],
      [0xD29000, 2, 0x70169E2C],
      [0xD49000, 3, 0x12345678],
      [0xD29000, 5, 0x12345678],
      [0xD49000, 9, 0x70169E2C]
    ];
    out(
        'fake.editions',
        edl.map((e) {
          final r2 = cp(rom);
          idp(r2, e[0], e[1], e[2]);
          final x = openRom(r2);
          return '${x.editionId}:${x.edition}:${isNeon(r2)}';
        }).join(' '));
    {
      final r2 = cp(rom);
      r2.fillRange(ctx.limit, ctx.limit + 4, 0xFF);
      r2[ctx.limit + 0x1000] = 77;
      final x = openRom(r2);
      out('fake.edition.other', '${x.editionId}:${x.edition}:${x.limit}');
    }
    // sprites of every kind made by hand
    final r = rng(77);
    Uint8List mk(Kind o) {
      final direct = o.bpp >= 0x10;
      final bits = direct ? 0 : const {0: 1, 1: 2, 2: 4, 3: 8}[o.bpp]!, ncol = direct ? 0 : 1 << bits, npx = o.w * o.h, np = (o.numPal ?? 0) != 0 ? o.numPal! : 1;
      final palLen = 2 * ncol * np, cells = <Uint8List>[];
      for (var s = 0; s < o.n; s++) {
        Uint8List raw;
        if (direct) {
          raw = Uint8List(npx * 2);
          for (var i = 0; i < raw.length; i++) {
            raw[i] = r();
          }
        } else {
          raw = Uint8List((npx * bits + 7) ~/ 8);
          final q = r();
          for (var i = 0; i < raw.length; i++) {
            raw[i] = (i % 9 < 5) ? q : r();
          }
        }
        cells.add(raw);
      }
      Uint8List x53(Uint8List c) {
        if (!o.xor) return c;
        final d = cp(c);
        for (var i = 0; i < d.length; i++) {
          d[i] ^= 0x53;
        }
        return d;
      }

      List<Uint8List> body;
      List<int>? tbl;
      if (direct || o.pack == 'plain') {
        body = [for (final c in cells) x53(c)];
      } else {
        tbl = [];
        body = [];
        for (var s = 0; s < cells.length; s++) {
          final c = cells[s];
          Uint8List d;
          var unc = 0;
          if (o.pack == 'rle') {
            d = rleEncode(c);
          } else if (o.pack == 'lz4') {
            d = lz4Encode(c);
          } else {
            final wds = <int>[];
            for (var i = 0; i + 4 <= c.length; i += 4) {
              wds.addAll([0x80000001, c[i] | c[i + 1] << 8 | c[i + 2] << 16 | c[i + 3] << 24]);
            }
            wds.addAll([3, 0x01020304, 0]);
            d = Uint8List(wds.length * 4);
            for (var i = 0; i < wds.length; i++) {
              w32(d, 4 * i, wds[i]);
            }
          }
          if (o.unc && s % 2 != 0) {
            d = c;
            unc = 0x80000000;
          }
          tbl.add(unc);
          body.add(x53(d));
        }
      }
      final pixOff = 24 + palLen;
      var len = pixOff + (tbl != null ? 8 * o.n : 0);
      final offs = <int>[];
      for (final d in body) {
        offs.add(len - pixOff);
        len += d.length;
      }
      final e = Uint8List(len + o.extra);
      w32(e, 0, len);
      e[4] = (o.transp ? 4 : 0) |
          (o.pack == 'rle'
              ? 0x20
              : o.pack == 'rlew'
                  ? 0x40
                  : o.pack == 'lz4'
                      ? 0x08
                      : 0) |
          (o.xor ? 0x80 : 0) |
          3;
      e[5] = o.bpp;
      w16(e, 6, o.n);
      e[8] = o.w;
      e[9] = o.h;
      e[10] = o.ox;
      e[11] = o.oy;
      e[12] = o.iw ?? 1;
      e[13] = o.ih ?? 1;
      e[14] = 0x11;
      e[15] = direct ? 0 : (o.numPal ?? 1);
      w16(e, 16, o.tr);
      w16(e, 18, 24);
      w16(e, 20, pixOff);
      for (var i = 0; i < palLen; i++) {
        e[24 + i] = r();
      }
      for (var s = 0; s < body.length; s++) {
        if (tbl != null) {
          w32(e, pixOff + 8 * s, offs[s] | tbl[s]);
          w32(e, pixOff + 8 * s + 4, body[s].length);
        }
        e.setAll(pixOff + offs[s], body[s]);
      }
      return e;
    }

    const kinds = [
      Kind(0, 16, 16, 3, pack: 'rle', xor: true, transp: true),
      Kind(1, 12, 10, 4, pack: 'plain', xor: true),
      Kind(1, 12, 10, 4, pack: 'plain', transp: true, tr: 2),
      Kind(2, 32, 32, 6, pack: 'rle', xor: true, transp: true, numPal: 3),
      Kind(2, 16, 16, 8, pack: 'lz4', xor: true, transp: true, iw: 2, ih: 2),
      Kind(3, 24, 24, 4, pack: 'lz4', xor: true, unc: true),
      Kind(3, 20, 12, 5, pack: 'rle', unc: true, transp: true, tr: 200),
      Kind(2, 16, 8, 3, pack: 'rlew', xor: true),
      Kind(3, 8, 8, 6, pack: 'rlew', iw: 3, ih: 2, transp: true, tr: 5, numPal: 2),
      Kind(0x11, 16, 16, 4, transp: true, tr: 0x07e0, iw: 2, ih: 1),
      Kind(0x11, 10, 6, 3),
      Kind(0x10, 8, 8, 2, transp: true, tr: 0x1234, ox: 250, oy: 7),
      Kind(2, 16, 16, 5, pack: 'rle', xor: true, transp: true, iw: 2, ih: 2),
      Kind(1, 9, 7, 2, pack: 'rle', xor: true, iw: 0, ih: 0, numPal: 0, ox: 128, oy: 255),
      Kind(2, 64, 32, 20, pack: 'rle', xor: true, transp: true, extra: 4000),
      Kind(3, 16, 16, 2, pack: 'lz4', xor: true, transp: true, tr: 0, numPal: 2),
      Kind(5, 4, 4, 1, pack: 'plain'),
    ];
    for (var i = 0; i < kinds.length; i++) {
      final o = kinds[i];
      Uint8List e;
      if (o.bpp == 5) {
        e = mk(o.withBpp(2));
        e[5] = 5;
      } else {
        e = mk(o);
      }
      void P(String n, Object? v) => out('kind$i.$n', v);
      P('entry', '${e.length} ${sha(e)}');
      P('header', js(spriteHeader(e)));
      P('decode', decSha(e));
      P('decode.pal1', decSha(e, 1));
      P('decode.cut', '${decSha(sub(e, 0, e.length - 9))} ${decSha(sub(e, 0, 30))} ${decSha(sub(e, 0, 10))}');
      P('tiny', err(() {
        final t = spriteTiny(e);
        return '${sha(t)} ${decSha(t)}';
      }));
      final al = <Uint8List>[
        e,
        () {
          final x = cp(sub(e, 0, e.length - 1));
          w32(x, 0, x.length);
          return x;
        }(),
        () {
          final x = Uint8List(e.length + 2)..setAll(0, e);
          w32(x, 0, e.length + 1);
          return x;
        }(),
        sub(e, 0, 20),
        () {
          final x = cp(e);
          w32(x, 0, e.length + 6);
          return x;
        }(),
        () {
          final x = cp(e);
          w32(x, 0, 21);
          return x;
        }()
      ];
      for (var k = 0; k < al.length; k++) {
        P('align$k', err(() {
          final a = spriteAlign(al[k]);
          return a != null ? '${a.length}:${sha(a)}' : 'null';
        }));
      }
      List<Rgba> subs;
      try {
        subs = spriteDecodeAll(e).subs;
      } catch (_) {
        continue;
      }
      void enc(String n, List<Rgba> s, [SpriteOpts opts = const SpriteOpts()]) => P('encode.$n', err(() {
            final x = spriteEncodeOpts(e, s, opts);
            return '${x.length} ${sha(x)} ${decSha(x)}';
          }));
      final ps = perturb(subs, 500 + i), pf = perturbFew(subs, 600 + i);
      enc('same', subs);
      enc('keep', subs, const SpriteOpts(keepPalette: true));
      enc('more', ps, const SpriteOpts(allowMoreColors: true));
      enc('quant', ps);
      enc('keepq', ps, const SpriteOpts(keepPalette: true));
      enc('len', subs, const SpriteOpts(keepLength: true));
      enc('lenq', ps, const SpriteOpts(keepLength: true, allowMoreColors: true));
      for (var k = 0; k < 6; k++) {
        enc('part$k', subs, partOptions(k));
        enc('partq$k', pf, partOptions(k));
      }
      enc('partkeep', ps, partOptions(0, keepPalette: true));
      enc('partmany', colours(ps) <= 400 ? ps : pf, partOptions(0));
      enc('nofig', ps, partOptions(1, figure: false, keepLength: false));
      P('blank', err(() => sha(spriteBlank(e))));
      P('blank.part', err(() => sha(spriteBlank(e, partOptions(1)))));
      final blank = [for (final s in subs) emptyImage(s.w, s.h)], solid = [for (final s in subs) Rgba(s.w, s.h, ff(s.data.length))];
      final dark = [
        for (final s in subs)
          Rgba(
              s.w,
              s.h,
              Uint8List.fromList([
                for (var j = 0; j < s.data.length; j++)
                  j % 4 == 3
                      ? 255
                      : j % 4 == 2
                          ? 100
                          : 5
              ]))
      ];
      enc('blank', blank);
      enc('solid', solid);
      enc('solid.fig', solid, partOptions(0));
      enc('dark.fig', dark, partOptions(0));
      enc('blank.fig', blank, partOptions(3));
    }
  }
  // eye layers of a data pack without a layer table (the old scan), and of a small one with a table
  {
    final dp = words([0, 10, 1027, 5, 65516, 1, 11, 1539, 0, 65520, 15, 12, 1031, 0, 0, 0, 0, 0, 10, 1100, 65530, 40, 3, 7, 7, 11, 1600, 3, 9, 2, 0, 0, 0, 0, 0, 0, 10, 1027, 5, 65516, 1, 11, 1539, 0, 65520, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    out('scan.paraLayers', paraLayers(dp) == null ? 'null' : 'table');
    out('scan', [mv(hideEyes(dp, 10, 11)), mv(hideEyes(dp, 10, 11, 300)), mv(setEyeOffset(dp, 10, 11, 64, 32, 3, 9)), mv(shiftEyes(dp, 10, 11, -4, 6)), mv(shiftEyes(dp, 10, 12, 1, 1)), js(eyeFirst(dp, 10, 11)), js(eyeFirst(dp, 11, 12)), js(eyeRelGet(dp, 10, 11, 64, 32)), js(eyeRelGet(dp, 3, 4, 64, 32)), js(faceFirst(dp, 10, 11, 12)), js(facePoses(dp, 10, 11, 12))].join(' '));
    out('layersMove.raw', sha(layersMove(dp, [(6, 8, 3, -2), (-1, 8, 9, 9), (20, -1, 9, 9), (118, 300, 70000, -70000)])));
    final r = rng(31), lay = <int>[], fr = <int>[];
    var nl = 0;
    for (var f = 0; f < 60; f++) {
      if (r() < 30) {
        fr.addAll([0xFFFF, 0]);
        continue;
      }
      final cnt = 1 + r() % 4;
      fr.addAll([f == 7 ? 5000 : nl, cnt]);
      for (var j = 0; j < cnt; j++) {
        final a = r(), m = 0x400 | (a & 0x3FF), ws = [m];
        for (var b = 0; b < 10; b++) {
          if ((m & (1 << b)) != 0) {
            ws.add(b < 2
                ? (r() % 61 - 30) & 0xFFFF
                : b == 2
                    ? r() % 4
                    : r());
          }
        }
        ws.add(100 + r() % 6);
        lay.addAll(ws);
        nl++;
      }
    }
    final t = Uint8List(80 + 2 * lay.length + 2 * fr.length + 6);
    for (var i = 0; i < 20; i++) {
      w32(t, 4 * i, i <= 15 ? 40 : (i <= 18 ? 40 + lay.length : 40 + lay.length + fr.length));
    }
    for (var i = 0; i < lay.length; i++) {
      w16(t, 80 + 2 * i, lay[i]);
    }
    for (var i = 0; i < fr.length; i++) {
      w16(t, 80 + 2 * lay.length + 2 * i, fr[i]);
    }
    String layersStr(ParaLayers P) {
      final idx = Map<ParaLayer, int>.identity();
      for (var i = 0; i < P.layers.length; i++) {
        idx[P.layers[i]] = i;
      }
      return '${P.layers.length} ${P.frames.length} ${J(P.layers)} ${J([
            for (final f in P.frames) [for (final l in f) idx[l]]
          ])}';
    }

    out('table.paraLayers', layersStr(paraLayers(t)!));
    for (final c in [
      [100, 101, 102],
      [101, 100, 105],
      [103, 104, 100],
      [105, 105, 105],
      [100, 200, 101],
      [300, 100, 101]
    ]) {
      final b = c[0], e = c[1], m = c[2], fp = facePoses(t, b, e, m);
      out('table.$b.$e.$m', [js(eyeFirst(t, b, e)), js(faceFirst(t, b, e, m)), J(fp), fp.length, js(eyeRelGet(t, b, e, 64, 32)), js(eyeRelGet(t, b, e, 32, 16)), mv(shiftEyes(t, b, e, 3, -2)), mv(hideEyes(t, b, e)), mv(hideEyes(t, b, e, 77)), mv(setEyeOffset(t, b, e, 64, 32, -5, 11)), mv(setEyeOffset(t, b, e, 32, 16, 2, 3)), sha(layersMove(t, moves(fp, (i) => [i - 3, 2 * i + 1])))].join(' '));
    }
    final bad = cp(t);
    w16(bad, 80, 0x8000);
    out('table.badmask', paraLayers(bad) == null ? 'null' : 'table');
    out('table.short', [paraLayers(sub(t, 0, 60)), paraLayers(Uint8List(0)), paraLayers(sub(t, 0, t.length - 7))].map((x) => x == null ? 'null' : '${x.layers.length}/${x.frames.length}').join(' '));
    // character table and fields on a made data pack
    Uint8List mkDp(List<List<int>> recs) {
      final d = Uint8List(40 + 30 * recs.length + 8);
      w32(d, 0, 4);
      w32(d, 4, 12);
      w32(d, 8, 20);
      w32(d, 12, (40 + 30 * recs.length) ~/ 2);
      w32(d, 16, 9999);
      for (var i = 0; i < recs.length; i++) {
        for (var k = 0; k < recs[i].length; k++) {
          w16(d, 40 + 30 * i + 2 * k, recs[i][k]);
        }
      }
      return d;
    }

    final recs = [
      [0xFFFF, 0, 0, 0, 0, 0, 0, 0],
      [1000, 50, 7, 0, 0, 0, 0, 0],
      [1001, 51, 8, 1, 2, 0, 0, 1],
      [1002, 52, 9, 2, 2, 0, 0, 2],
      [1003, 51, 10, 3, 1, 0, 0, 9],
      [1004, 53, 11, 3, 1, 0, 0, 7],
      [9000, 60, 12, 0, 0, 0, 0, 3],
      [1005, 99, 13, 3, 0, 0, 0, 8],
      [1006, 52, 14, 3, 0, 0, 0, 9]
    ];
    out('charTable.made', '${js(charTable(mkDp(recs)))} ${js(charTable(mkDp(recs.sublist(1))))} ${js(charTable(sub(mkDp(recs), 0, 100)))} ${js(charTable(Uint8List(0)))}');
    RomCtx fctx(List<List<int>> rs, List<int> groups) => ctxOf(fake, files: [mkDp(rs)], groups: groups);
    out(
        'charGroups.made',
        [
          fctx(recs, [12, 18, 24, 30, 36, 42, 48]),
          fctx(recs, [12, 18, 24, 30]),
          fctx(recs, [12, 18]),
          fctx(recs.where((x) => x[0] != 1000).toList(), [12, 18, 24]),
          fctx(recs.map((x) => x[0] == 1001 ? [1001, 55, 8, 1, 2, 0, 0, 1] : x).toList(), [12, 18, 24]),
          fctx(recs.map((x) => [x[0], x[1], x[2], x[3], x[4], 0, 0, x[7] > 6 ? 2 : x[7]]).toList(), [12, 18, 24, 12, 18, 24, 12])
        ].map((c) => '${js(charGroups(c))}${js(fieldSets(c))}').join(' '));
  }
  // cards
  for (final kind in ['sma', 'sma2', 'dim', 'drawn', 'drawn.baby']) {
    final raw = kind == 'sma'
        ? smaCard(11)
        : kind == 'sma2'
            ? smaCard(12)
            : kind == 'dim'
                ? dimCard(21)
                : null;
    void P(String n, Object? v) => out('$kind.$n', v);
    CardData card;
    if (raw != null) {
      final dim = kind == 'dim';
      P('card', '${raw.length} ${sha(raw)}');
      P('detect', '${smaDetect(raw)} ${smaDetect(sub(raw, 0, 0x10FF))}');
      P('load.err', '${err(() => (dim ? smaLoad : dimLoad)(raw).chars.length)} ${err(() {
        final x = cp(raw);
        if (dim) {
          x[0x100000] ^= 1;
        } else {
          x[0x1000] ^= 1;
        }
        return (dim ? dimLoad : smaLoad)(x).chars.length;
      })} ${err(() => dimLoad(sub(raw, 0, 5000)).chars.length)}');
      card = dim ? dimLoad(raw) : smaLoad(raw);
      P('load', '${card.chars.length} ${card.eggs.length} ${card.kind ?? ''} ${imgsSha(card.eggs)} ${card.eggs.map((e) => '${e.w}x${e.h}').join(',')}');
      if (card.eggs.isNotEmpty) {
        final es = dimEggSubs(card.eggs);
        P('dimEggSubs', '${imgsSha(es.small)} ${imgsSha(es.big)}');
        final e1 = dimEggSubs(card.eggs.sublist(0, card.eggs.length < 2 ? card.eggs.length : 2));
        P('dimEggSubs.two', '${imgsSha(e1.small)} ${imgsSha(e1.big)}');
      }
      P('dimEggSubs.none', err(() => imgsSha(dimEggSubs([]).small)));
    } else {
      card = CardData([drawnChar(kind != 'drawn')], []);
    }
    for (var ci = 0; ci < card.chars.length; ci++) {
      final ch = card.chars[ci], im = ch.frames['idle1']!;
      void Q(String n, Object? v) => P('ch$ci.$n', v);
      Q('char', '${im.w}x${im.h} ${ch.frames.keys.join(',')} ${charSha(ch)}');
      Q('dimCharParts', dimCharParts(ch).map(imgsSha).join(' '));
      Q('dimCharParts.scale', '${dimCharParts(ch, 1.5, 0.75).map(imgsSha).join(' ')} ${dimCharParts(ch, 0.4, 3).map(imgsSha).join(' ')}');
      final guess = dimGuessEye(ch), pre = dimEyePreset(ch);
      Q('dimGuessEye', js(guess));
      Q('dimEyePreset', pre.known ? js(pre.rect) : 'undefined');
      final cx = im.w >> 1, cy = im.h >> 1;
      Q(
          'eyeRectAt',
          [
            [cx, cy],
            [0, 0],
            [im.w - 1, im.h - 1],
            [cx - 5, cy - 4],
            [3, cy]
          ].map((p) => js(eyeRectAt(ch, p[0], p[1]))).join(' '));
      final rects = [
        guess ?? [cx - 3, cy - 3, cx + 3, cy + 3],
        [cx - 2, cy - 6, cx + 4, cy - 1],
        [1, 1, 4, 3],
        [cx, cy, cx, cy]
      ];
      for (var ri = 0; ri < rects.length; ri++) {
        Q('eyes$ri', err(() {
          final ep = dimCharPartsWithEyes(ch, rects[ri]);
          if (ep == null) return 'null';
          String lay(EyeLayer l) => (H()
                ..imgs(l.body)
                ..imgs(l.eyes)
                ..img(l.lo)
                ..img(l.lc)
                ..img(l.em)
                ..s(js(l.off)))
              .hex;
          final r1 = [ep.parts.map(imgsSha).join(','), js(ep.eyeBig), js(ep.eyeSmall), lay(ep.big), lay(ep.small), eyeVariants(ep.big, true).map(imgsSha).join(','), eyeVariants(ep.small, false).map(imgsSha).join(',')].join(' ');
          final g = fake.groups[1];
          final encs = [for (var k = 0; k < 6; k++) colours(ep.parts[k]) > 300 ? 'skip${colours(ep.parts[k])}' : err(() => sha(spriteEncodeOpts(fake.entries[g + k], ep.parts[k], partOptions(k))))];
          final fit = [
            for (final k in [1, 4])
              () {
                var res = 'none';
                final vs = eyeVariants(k == 1 ? ep.big : ep.small, k == 1);
                for (var vi = 0; vi < vs.length; vi++) {
                  try {
                    res = '$vi:${sha(spriteEncodeOpts(fake.entries[g + k], vs[vi], partOptions(k)))}';
                    break;
                  } catch (_) {}
                }
                return res;
              }()
          ];
          return sha('$r1 ${encs.join(',')} ${fit.join(',')}');
        }));
      }
      Q('eyes.scale', err(() {
        final ep = dimCharPartsWithEyes(ch, rects[0], 0.8, 0.4);
        return ep != null ? '${ep.parts.map(imgsSha).join(',')}${js(ep.eyeBig)}${js(ep.eyeSmall)}' : 'null';
      }));
      Q('eyes.outside', err(() {
        final ep = dimCharPartsWithEyes(ch, [im.w - 2, im.h - 2, im.w + 3, im.h + 3]);
        return ep != null ? 'parts' : 'null';
      }));
      final cps = dimCharParts(ch);
      Q('encode', [for (var k = 0; k < 6; k++) colours(cps[k]) > 300 ? 'skip${colours(cps[k])}' : err(() => sha(spriteEncodeOpts(fake.entries[fake.groups[0] + k], cps[k], partOptions(k))))].join(' '));
    }
  }

  // ================================================================ every edition
  for (final name in eds) {
    final rom = File('$dumps/$name.bin').readAsBytesSync();
    void P(String n, Object? v) => out('$name.$n', v);
    final ctx = openRom(rom), dp = ctx.files[0], n = ctx.entries.length;
    P('open', [ctx.editionId, ctx.edition, ctx.assetEnd, ctx.limit, n, ctx.groups.length, J(ctx.groups), ctx.adult, ctx.egg, isNeon(rom)].join('|'));
    P('root', '${ctx.root.chk} ${ctx.root.length} ${js([
          for (final e in ctx.root.ents) {'flags': e.$1, 'offset': e.$2, 'clen': e.$3, 'ulen': e.$4}
        ])}');
    P('files', ctx.files.map((f) => '${f.length}:${sha(f)}').join(' '));
    P('arc2', '${arc2Checksum(rom, ASSET_BASE, ctx.root.length)} ${arc2Files(rom, ASSET_BASE).map(sha).join(',')} ${sha(arc2Build(ctx.files))} ${sha(arc2Build(ctx.files)) == sha(sub(rom, ASSET_BASE, ctx.assetEnd))}');
    P('pack', '${packSplit(ctx.files[1]).length} ${sha(packJoin(ctx.entries))} ${sha(packJoin(ctx.entries)) == sha(ctx.files[1])} ${(H()..imgs([for (final e in ctx.entries) Rgba(0, 0, e)])).hex}');
    P('find', '${J(findGroups(ctx.entries))} ${findEgg(ctx.entries)} ${ctx.groups.isNotEmpty ? findFirstAdult(ctx.entries, ctx.groups) : -1} ${ctx.groups.length > 3 ? findFirstAdult(ctx.entries, ctx.groups.sublist(0, 3)) : -1}');
    P('headers', J([for (final e in ctx.entries) spriteHeader(e)]));
    {
      final h = H();
      var bad = 0;
      for (final e in ctx.entries) {
        final s = decSha(e);
        if (s.startsWith('err')) bad++;
        h.s(s);
      }
      P('decode.all', '${h.hex} errors $bad');
    }
    {
      final h = H();
      var k = 0;
      for (final e in ctx.entries) {
        if (spriteHeader(e).numPal > 1) {
          k++;
          h.s(decSha(e, 1)).s(decSha(e, 7));
        }
      }
      P('decode.palsets', '$k ${h.hex}');
    }
    P('verifyRom', '${err(() => verifyRom(rom, [for (var i = 0; i < n; i++) i]))} ${err(() {
      final r2 = cp(rom);
      r2[ASSET_BASE + ctx.root.ents[2].$2 + 20] ^= 1;
      return verifyRom(r2, []);
    })} ${err(() {
      final r2 = cp(rom);
      r2[ASSET_BASE + ctx.root.ents[1].$2 + 5000] ^= 1;
      return verifyRom(r2, []);
    })}');
    {
      final b = buildRomCtx(ctx, {});
      P('rebuild', '${sha(b.rom)} ${sha(b.rom) == sha(rom)} ${b.assetEnd} ${b.free}');
    }
    {
      final ht = H(), ha = H();
      var na = 0;
      for (final e in ctx.entries) {
        ht.s(err(() => sha(spriteTiny(e))));
        final a = spriteAlign(e);
        if (a != null) na++;
        ha.s(a != null ? sha(a) : 'null');
        final x = cp(sub(e, 0, e.length - 1));
        w32(x, 0, x.length);
        final a2 = spriteAlign(x);
        ha.s(a2 != null ? sha(a2) : 'null');
      }
      P('tiny.all', ht.hex);
      P('align.all', '$na ${ha.hex}');
    }
    // encode
    {
      final step = (n + 39) ~/ 40, pick = <int, int>{};
      for (var i = 0; i < n; i += step) {
        pick[i] = -1;
      }
      var nd = 0;
      for (var i = 0; i < n && nd < 3; i++) {
        final h = spriteHeader(ctx.entries[i]);
        if (h.bpp >= 0x10 && h.sw * h.sh * h.numSprites < 100000) {
          pick[i] = -1;
          nd++;
        }
      }
      if (ctx.egg >= 0) {
        pick[ctx.egg] = -1;
        pick[ctx.egg + 3] = -1;
      }
      for (final g in [ctx.groups.length > 1 ? ctx.groups[1] : -1, ctx.adult, ctx.groups.isNotEmpty ? ctx.groups.last : -1]) {
        if (g >= 0) {
          for (var k = 0; k < 6; k++) {
            pick[g + k] = k;
          }
        }
      }
      final list = pick.keys.toList()..sort();
      P('encode.picked', '${list.length} ${J(list)}');
      for (final i in list) {
        final e = ctx.entries[i], h = spriteHeader(e), k = pick[i]!, px = h.sw * h.sh * h.numSprites;
        List<Rgba> subs;
        try {
          subs = spriteDecodeAll(e).subs;
        } catch (_) {
          P('encode$i', 'err');
          continue;
        }
        final res = <String>[];
        void enc(List<Rgba> s, [SpriteOpts opts = const SpriteOpts()]) => res.add(err(() {
              final x = spriteEncodeOpts(e, s, opts);
              return '${x.length}:${sha(x)}';
            }));
        final ps = perturb(subs, i), pf = perturbFew(subs, i + 9);
        enc(subs, const SpriteOpts(keepPalette: true));
        enc(ps, const SpriteOpts(keepPalette: true));
        enc(subs, const SpriteOpts(keepLength: true));
        res.add(err(() => sha(spriteBlank(e))));
        if (px <= 150000) {
          enc(subs);
          enc(ps);
          enc(ps, const SpriteOpts(allowMoreColors: true));
        }
        if (k >= 0) {
          enc(subs, partOptions(k));
          enc(pf, partOptions(k));
          enc(ps, partOptions(k, keepPalette: true));
          res.add(err(() => sha(spriteBlank(e, partOptions(k)))));
        }
        P('encode$i', sha(res.join(' ')));
      }
    }
    // sheets of a character group
    if (ctx.groups.isNotEmpty) {
      final g = ctx.adult, parts6 = [for (var k = 0; k < 6; k++) spriteDecodeAll(ctx.entries[g + k]).subs], sheet = groupSheet(parts6), back = groupFromSheet(sheet);
      var same = true;
      for (var k = 0; k < 6; k++) {
        for (var i = 0; i < back[k].length; i++) {
          if (!sameImage(back[k][i], parts6[k][i])) same = false;
        }
      }
      P('groupSheet', '${imgSha(sheet)} ${back.map(imgsSha).join(',')} $same');
      final ss = sheetFromSubs(parts6[3]);
      P('sheet', '${imgSha(ss)} ${imgsSha(subsFromSheet(ss, 32, 32, 24))}');
    }
    // launcher ROM
    {
      final keep = launcherKeep(ctx), ch = launcherChanges(ctx), h = H();
      ch.forEach((i, e) => h.s(i).b(e));
      P('launcher', '${keep.length} ${J(keep.toList())} ${isLauncher(ctx)} ${ch.length} ${h.hex}');
      final b = buildRomCtx(ctx, ch), c2 = openRom(b.rom);
      P('launcher.rom', '${sha(b.rom)} ${b.assetEnd} ${b.free} ${isLauncher(c2)} ${c2.groups.length} ${c2.adult} ${c2.egg} ${c2.limit} ${c2.editionId}');
    }
    // fields
    {
      final ct = charTable(dp), cg = charGroups(ctx), fsets = fieldSets(ctx);
      P('charTable', '${ct.length} ${J(ct)}');
      P('charGroups', '${cg.length} ${J(cg)}');
      P('fieldSets', '${fsets.length} ${J(fsets)} ${fsets.map((f) => '${f.type}:${f.chars.length}:${f.maps.length}:${f.overlays.length}:${f.closeups.length}').join(',')}');
      final few = ctxOf(ctx, groups: ctx.groups.sublist(0, ctx.groups.length - 2));
      P('fields.fewer', '${J(charGroups(few))} ${J(fieldSets(few))}');
    }
    // texts
    {
      final x = textTablesOf(rom)!, h = H();
      for (final t in x.tabs) {
        h.s(t.n).b(t.b).s(js(t.offs));
      }
      P('textTablesOf', '${x.off} ${x.tabs.length} ${x.tabs.map((t) => t.n).join(',')} ${h.hex}');
      final nmax = x.tabs.map((t) => t.n).reduce((a, b) => a > b ? a : b);
      final all = [for (var i = 0; i < nmax + 3; i++) textGet(rom, i)];
      final full = [
        for (var i = 0; i < all.length; i++)
          if (all[i].isNotEmpty) i
      ];
      P('textGet', '${all.length} ${full.length} ${J(all)}');
      final names = [for (final c in charGroups(ctx)) c.name];
      final ids = <int>{0, 1, 2, ...full.take(4), ...names.take(6), if (names.isNotEmpty) names.last, if (full.isNotEmpty) full.last, nmax - 1, nmax + 5}.toList();
      const texts = ['Test name 1', 'a much longer name than before, with ünïcödé & more!?', '###', 'x', "it's/9.", 'Straße', '', 'Paramix', 'ZZ TOP', 'q', 'W W', '0'];
      final edits = {for (var k = 0; k < ids.length; k++) ids[k]: texts[k % texts.length]};
      final r2 = textApply(rom, edits);
      P('textApply', '${J(ids)} ${sha(r2)} ${J([for (final id in ids) textGet(r2, id)])} ${J([for (var i = 0; i < all.length; i++) textGet(r2, i)])} ${openRom(r2).assetEnd}');
      final r3 = textApply(r2, {for (final id in ids) id: id < all.length ? all[id] : ''});
      P('textApply.back', '${sha(r3)} ${sha(r3) == sha(rom)} ${J([for (var i = 0; i < all.length; i++) textGet(r3, i)])}');
      P('textApply.none', '${identical(textApply(rom, {}), rom)} ${sha(textApply(rom, {full[0]: '###'})) == sha(rom)} ${sha(textApply(rom, {full[1]: 'solo'}))}');
      P('textApply.long', '${err(() => sha(textApply(rom, {full[0]: 'A' * 70000})))} ${err(() => sha(textApply(rom, {full[2]: 'AB ' * 3000})))}');
      P('textApply.big', err(() {
        final m = <int, String>{};
        for (final i in full) {
          m[i] = 'NAME $i ' * 400;
        }
        return sha(textApply(rom, m));
      }));
    }
    // figures: layers, faces, eyes
    {
      final L = paraLayers(dp)!, idx = Map<ParaLayer, int>.identity();
      for (var i = 0; i < L.layers.length; i++) {
        idx[L.layers[i]] = i;
      }
      P('paraLayers', '${L.layers.length} ${L.frames.length} ${J(L.layers)} ${J([
            for (final f in L.frames) [for (final l in f) idx[l]]
          ])}');
      final hs = <String, H>{};
      void add(String k, String v) => (hs[k] ??= H()).s(v);
      var cur = dp;
      for (var gi = 0; gi < ctx.groups.length; gi++) {
        final g = ctx.groups[gi];
        add('eyeFirst', '${js(eyeFirst(dp, g, g + 1))}${js(eyeFirst(dp, g + 3, g + 4))}${js(eyeFirst(dp, g, g + 2))}');
        add('faceFirst', '${js(faceFirst(dp, g, g + 1, g + 2))}${js(faceFirst(dp, g + 3, g + 4, g + 5))}');
        final fp = facePoses(dp, g, g + 1, g + 2), fps = facePoses(dp, g + 3, g + 4, g + 5);
        add('facePoses', '${fp.length} ${fps.length}${js(fp)}${js(fps)}');
        add('eyeRelGet', '${js(eyeRelGet(dp, g, g + 1, 64, 32))}${js(eyeRelGet(dp, g, g + 2, 64, 32))}${js(eyeRelGet(dp, g + 3, g + 4, 32, 16))}${js(eyeRelGet(dp, g + 3, g + 5, 32, 16))}');
        if (gi % 4 == 0) {
          add('shiftEyes', '${mv(shiftEyes(dp, g, g + 1, 2, -1))}${mv(shiftEyes(dp, g, g + 2, -3, 4))}${mv(shiftEyes(dp, g + 3, g + 4, 1, 1))}${mv(shiftEyes(dp, g + 3, g + 5, -40000, 40000))}');
          add('hideEyes', '${mv(hideEyes(dp, g, g + 1))}${mv(hideEyes(dp, g + 3, g + 4, 500))}');
          add('setEyeOffset', '${mv(setEyeOffset(dp, g, g + 1, 64, 32, 3, 5))}${mv(setEyeOffset(dp, g + 3, g + 4, 32, 16, -2, 1))}');
          add('layersMove', sha(layersMove(dp, moves([...fp, ...fps], (i) => [(i % 5) - 2, 3 - (i % 7)]))));
          cur = shiftEyes(cur, g, g + 1, 1 + gi % 3, -2).dataPack;
          cur = shiftEyes(cur, g + 3, g + 5, -1, gi % 2).dataPack;
        }
      }
      for (final k in ['eyeFirst', 'faceFirst', 'facePoses', 'eyeRelGet', 'shiftEyes', 'hideEyes', 'setEyeOffset', 'layersMove']) {
        P(k, hs[k]?.hex ?? 'none');
      }
      final b = buildRomCtx(ctx, {}, cur), c2 = openRom(b.rom), h2 = H();
      for (final g in ctx.groups) {
        h2.s('${js(eyeRelGet(c2.files[0], g, g + 1, 64, 32))}${js(eyeRelGet(c2.files[0], g + 3, g + 5, 32, 16))}');
      }
      P('eyes.rom', '${sha(cur)} ${sha(b.rom)} ${b.free} ${h2.hex}');
    }
  }
}
