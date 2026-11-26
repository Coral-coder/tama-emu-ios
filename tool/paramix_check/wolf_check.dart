// Check of lib/paramix/wolf.dart against third_party/paramix-studio/src/wolf.js (the original).
// dart run tool/paramix_check/wolf_check.dart        (no dumps needed)
// Prints one line per case: "<case name> <value or sha256>", the same lines as tool/paramix_check/wolf.js.
// No game files: the sets are synthetic (seeded xorshift32) with the structure the module reads: VSWAP page table,
// MAPHEAD/GAMEMAPS, AUDIOHED/AUDIOT, a Huffman dictionary (every byte coded by its 8 bits) with VGAHEAD/VGAGRAPH.

// ignore_for_file: avoid_print, non_constant_identifier_names, library_prefixes, constant_identifier_names

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tama_tools/paramix/wolf.dart' as W;

final lines = <String>[];
String sha(List<int> b) => sha256.convert(b).toString();
String H(Uint8List? b) => b == null ? 'null' : '${b.length}:${sha(b)}';
void out(String n, Object? v) => lines.add('$n $v');
void T(String n, Object? Function() f) {
  try {
    out(n, f());
  } on StateError catch (e) {
    out(n, 'ERR ${e.message}');
  } on FormatException catch (e) {
    out(n, 'ERR ${e.message}');
  } catch (e) {
    out(n, 'ERR INTERNAL');
  }
}

void w16(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
}

void w24(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
  b[o + 2] = (v >> 16) & 255;
}

void w32(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
  b[o + 2] = (v >> 16) & 255;
  b[o + 3] = (v >> 24) & 255;
}

// ------------------------------------------------------------ synthetic game files
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

Uint8List rnd(int Function() r, int n, [int mask = 255]) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r() & mask;
  }
  return b;
}

Uint8List cat(List<Uint8List> parts) {
  final o = BytesBuilder(copy: false);
  for (final p in parts) {
    o.add(p);
  }
  return o.toBytes();
}

int rev8(int v) {
  var o = 0;
  for (var k = 0; k < 8; k++) {
    if ((v & (1 << k)) != 0) o |= 0x80 >> k;
  }
  return o;
}

/* the dictionary: a full tree, node 254 is the root, the node at heap place h (1..255) is 255 - h; a byte is its 8 bits */
Uint8List dict(int extra) {
  final d = Uint8List(1020 + extra);
  for (var h = 1; h <= 255; h++) {
    for (var s = 0; s < 2; s++) {
      final c = 2 * h + s;
      w16(d, 4 * (255 - h) + 2 * s, c >= 256 ? c - 256 : 256 + (255 - c));
    }
  }
  return d;
}

Uint8List huff(Uint8List d) => Uint8List.fromList([for (final v in d) rev8(v)]);

class Opt {
  const Opt(this.ext, this.seed, this.chunks, this.maps,
      {this.walls = 0, this.sounds = 0, this.badWall = 0, this.headExtra = 0, this.shortHead = false, this.audioBad = false, this.cutMaps = false, this.noPal = false, this.shortPal = false, this.splitTitle = false, this.noTitle2 = false, this.name});
  final String ext;
  final int seed, chunks, maps, walls, sounds, badWall, headExtra;
  final bool shortHead, audioBad, cutMaps, noPal, shortPal, splitTitle, noTitle2;
  final String Function(String)? name;
}

Map<String, Uint8List> gameSet(Opt o) {
  final r = rng(o.seed), f = <String, Uint8List>{};
  // VSWAP: walls, sprites, digitized sounds
  {
    final spr = o.walls != 0 ? o.walls : 6, nspr = 5, nsnd = 3, nch = spr + nspr + nsnd, head = Uint8List(6 + 6 * nch), data = <Uint8List>[];
    var pos = head.length + 7;
    data.add(rnd(r, 7));
    w16(head, 0, nch);
    w16(head, 2, spr);
    w16(head, 4, spr + nspr);
    for (var i = 0; i < nch; i++) {
      var len = i < spr ? 4096 : 40 + r() % 500, off = pos;
      if (i == 2) len = 0; // an empty wall
      if (i == 3) off = 0; // a wall without a place
      if (o.badWall != 0 && i == 1) len = o.badWall;
      if (i == spr + 1) off = 0x7FFFFF00; // a sprite behind the end of the file
      w32(head, 6 + 4 * i, off);
      w16(head, 6 + 4 * nch + 2 * i, len);
      if (off == pos && len != 0) {
        data.add(rnd(r, len));
        pos += len;
      }
    }
    f['VSWAP'] = cat([head, ...data]);
  }
  // GAMEMAPS and MAPHEAD
  {
    final n = o.maps, parts = <Uint8List>[rnd(r, 8)], mh = Uint8List(o.shortHead ? 2 + 4 * 12 : 402 + (o.seed & 3));
    var pos = 8;
    w16(mh, 0, 0xABCD);
    for (var i = 0; i < 100 && 2 + 4 * i + 4 <= mh.length; i++) {
      if (i >= n) {
        w32(mh, 2 + 4 * i, i % 3 == 0 ? 0xFFFFFFFF : 0);
        continue;
      }
      if (i == 4) {
        w32(mh, 2 + 4 * i, 0); // a map that is not there
        continue;
      }
      if (i == 7) {
        w32(mh, 2 + 4 * i, 0x7FFFFF00); // a map behind the end of the file
        continue;
      }
      final h = Uint8List(38);
      for (var p = 0; p < 3; p++) {
        var len = 10 + r() % 300;
        if (i == 1 && p == 2) len = 0;
        final d = rnd(r, len);
        w32(h, 4 * p, i == 2 && p == 1 ? 0 : pos);
        w16(h, 12 + 2 * p, len);
        parts.add(d);
        pos += len;
      }
      w16(h, 18, 64);
      w16(h, 20, 64);
      final nm = 'Wolf${1 + i ~/ 10} Map${1 + i % 10}';
      for (var k = 0; k < nm.length; k++) {
        h[22 + k] = nm.codeUnitAt(k);
      }
      w32(mh, 2 + 4 * i, pos);
      parts.add(h);
      pos += 38;
    }
    if (o.cutMaps) parts.add(rnd(r, 5));
    f['MAPHEAD'] = mh;
    f['GAMEMAPS'] = cat(parts);
  }
  // AUDIOHED and AUDIOT
  {
    final n = o.sounds != 0 ? o.sounds : 100, ah = Uint8List(4 * (n + 1)), parts = <Uint8List>[];
    var pos = 0;
    for (var i = 0; i < n; i++) {
      w32(ah, 4 * i, pos);
      final len = i % 9 == 5 ? 0 : 7 + r() % 120;
      if (len != 0) {
        parts.add(rnd(r, len));
        pos += len;
      }
    }
    w32(ah, 4 * n, pos);
    if (o.audioBad) w32(ah, 4 * 11, 0x7FFFFFFF); // a start behind the end
    f['AUDIOHED'] = ah;
    f['AUDIOT'] = cat(parts);
  }
  // VGADICT, VGAHEAD, VGAGRAPH
  {
    final n = o.chunks, head = Uint8List(3 * n + o.headExtra), parts = <Uint8List>[], npics = n - 3 - 12;
    var pos = 0;
    final st = Uint8List(4 * npics), pics = <Uint8List>[];
    for (var k = 0; k < npics; k++) {
      var w = 4 * (1 + r() % 10), h = 1 + r() % 24, len = w * h;
      final c = 3 + k;
      if (o.ext == 'SOD' && (c == 79 || c == 80)) {
        w = 64;
        h = c == 79 ? 10 : 6;
        if (o.splitTitle && c == 80) w = 60;
        len = w * h;
      }
      if (k % 23 == 9) w += 2; // a width that is no multiple of 4
      if (k % 29 == 11) w = 0;
      if (k % 31 == 13) h = -3;
      if (k % 37 == 17) len -= 3; // less data than the picture needs
      if (k % 41 == 19) len += 5;
      w16(st, 4 * k, w);
      w16(st, 4 * k + 2, h);
      pics.add(rnd(r, math.max(0, len)));
    }
    void put(int c, Uint8List d, [bool bare = false]) {
      w24(head, 3 * c, pos);
      final b = Uint8List((bare ? 0 : 4) + d.length);
      if (!bare) w32(b, 0, d.length);
      b.setAll(bare ? 0 : 4, huff(d));
      parts.add(b);
      pos += b.length;
    }

    for (var c = 0; c < n; c++) {
      if (c == 0) {
        put(c, st);
      } else if (c < 3) {
        put(c, rnd(r, 30 + r() % 50));
      } else if (c - 3 < npics) {
        if ((c - 3) % 43 == 21 || (o.noTitle2 && c == 80)) {
          w24(head, 3 * c, 0xFFFFFF);
        } else {
          put(c, pics[c - 3]);
        }
      } else if (o.ext == 'SOD' && c == 153) {
        if (o.noPal) {
          w24(head, 3 * c, 0xFFFFFF);
        } else {
          put(c, rnd(r, o.shortPal ? 700 : 768, 63));
        }
      } else if (c == n - 2) {
        put(c, rnd(r, 33), true); // a chunk without its length in front
      } else {
        put(c, rnd(r, 5 + r() % 40));
      }
    }
    f['VGAHEAD'] = head;
    f['VGADICT'] = dict(o.seed & 7);
    f['VGAGRAPH'] = cat(parts);
  }
  return {for (final k in f.keys) (o.name ?? (String s) => s)('$k.${o.ext}'): f[k]!};
}

final SETS = <String, Opt>{
  'wl6': const Opt('WL6', 0x1001, 150, 60),
  'wl6b': const Opt('WL6', 0x1002, 150, 23, shortHead: true, walls: 9, sounds: 40, audioBad: true, headExtra: 2, cutMaps: true),
  'wl6apogee': Opt('WL6', 0x1003, 157, 60, name: (s) => 'C:\\games\\wolf3d\\${s.toLowerCase()}'),
  'wl1': Opt('WL1', 0x1004, 157, 10, name: (s) => '/home/x/wolf/${s[0]}${s.substring(1).toLowerCase()}'),
  'wl1b': const Opt('WL1', 0x1005, 150, 3),
  'sod': const Opt('SOD', 0x1006, 170, 21),
  'sodNoPal': const Opt('SOD', 0x1007, 170, 21, noPal: true),
  'sodShortPal': const Opt('SOD', 0x1008, 170, 20, shortPal: true, splitTitle: true),
  'sodHalf': const Opt('SOD', 0x1009, 170, 21, noTitle2: true),
  'badWall': const Opt('WL6', 0x100A, 150, 10, badWall: 16384),
  'badWall1': const Opt('WL1', 0x100B, 150, 10, badWall: 4095),
  'badHead': const Opt('WL6', 0x100C, 149, 10),
  'badHeadSod': const Opt('SOD', 0x100D, 150, 10),
  'badHead1': const Opt('WL1', 0x100E, 170, 10),
};
String setStr(W.WolfSet s) => '${s.ext} ${W.NEED.map((k) => '$k=${H(s.files[k])}').join(' ')}';
Map<String, Uint8List> without(Map<String, Uint8List> f, RegExp re) => {
  for (final k in f.keys)
    if (!re.hasMatch(k)) k: f[k]!,
};
Map<String, Uint8List> mix(List<Map<String, Uint8List>> xs) {
  final o = <String, Uint8List>{};
  for (final x in xs) {
    o.addAll(x);
  }
  return o;
}

void main() {
  out('NEED', W.NEED.join(','));
  final G = <String, Map<String, Uint8List>>{for (final n in SETS.keys) n: gameSet(SETS[n]!)};
  for (final n in SETS.keys) {
    final g0 = G[n]!;
    out('files.$n', g0.keys.map((k) => '$k=${H(g0[k])}').join(' '));
    T('pickSet.$n', () => setStr(W.pickSet(g0)));
    T('build.$n', () {
      final r = W.build(g0);
      return '${H(r.pack)} ${r.ext} maps=${r.maps} episodes=${r.episodes} sod=${r.sod}';
    });
    T('readGraph.$n', () {
      final s = W.pickSet(g0).files, g = W.readGraph(s['VGAHEAD']!, s['VGADICT']!, s['VGAGRAPH']!), o = <Object>[g.nchunks];
      for (final c in [0, 1, 2, 3, 24, 46, 79, 80, 100, g.nchunks - 1, g.nchunks, g.nchunks + 5]) {
        o.add('$c=${H(g.chunk(c))}');
      }
      o.addAll(['bare=${H(g.chunk(g.nchunks - 2, 33))}', 'part=${H(g.chunk(5, 3))}', 'none=${H(g.chunk(5, 0))}']);
      return o.join(' ');
    });
  }
  // several sets at once, incomplete sets, other files
  final wl6 = G['wl6']!, wl6b = G['wl6b']!, wl1b = G['wl1b']!, sod = G['sod']!, v = wl6['VSWAP.WL6']!;
  T('pick.all', () => setStr(W.pickSet(mix([wl1b, sod, wl6]))));
  T('pick.sod+wl1', () => setStr(W.pickSet(mix([wl1b, sod]))));
  T('pick.wl6cut+wl1', () => setStr(W.pickSet(mix([without(wl6, RegExp(r'^VGA')), wl1b]))));
  T('pick.wl6cut+sod', () => setStr(W.pickSet(mix([without(wl6, RegExp(r'^AUDIOT')), sod, wl1b]))));
  T('pick.wl6cut', () => setStr(W.pickSet(without(wl6, RegExp(r'^(VGAHEAD|AUDIOT)')))));
  T('pick.wl6cut+sodcut', () => setStr(W.pickSet(mix([without(wl6, RegExp(r'^MAPHEAD')), without(sod, RegExp(r'^VSWAP'))]))));
  T('pick.sodcut+wl1cut', () => setStr(W.pickSet(mix([without(sod, RegExp(r'^(VSWAP|GAMEMAPS)')), without(wl1b, RegExp(r'^VGADICT'))]))));
  T('pick.wl1cut', () => setStr(W.pickSet(without(wl1b, RegExp(r'^(VSWAP|VGADICT|VGAGRAPH|MAPHEAD|GAMEMAPS|AUDIOHED|AUDIOT)')))));
  T('pick.none', () => setStr(W.pickSet({})));
  T('pick.others', () => setStr(W.pickSet({'README.TXT': v, 'VSWAP.WL2': v, 'VS WAP.WL6': v, 'VSWAP1.WL6': v, 'VSWAP.WL6.bak': v})));
  T('pick.twice', () => setStr(W.pickSet(mix([wl6, {'old/vswap.wl6': wl6b['VSWAP.WL6']!, 'x\\y/MapHead.Wl6': wl6b['MAPHEAD.WL6']!}]))));
  T('pick.extra', () => setStr(W.pickSet(mix([wl6, {'CONFIG.WL6': wl6b['VSWAP.WL6']!, 'VGAHEAD.WL1': G['wl1']!['/home/x/wolf/Vgahead.wl1']!}]))));
  T('build.all', () => H(W.build(mix([wl1b, sod, wl6])).pack));
  T('build.none', () => H(W.build({}).pack));
  T('build.cut', () => H(W.build(without(sod, RegExp(r'^VGAGRAPH'))).pack));
  T('build.mixed', () {
    final r = W.build(mix([wl6, {'VSWAP.WL6': wl6b['VSWAP.WL6']!, 'AUDIOT.WL6': wl6b['AUDIOT.WL6']!}]));
    return '${H(r.pack)} maps=${r.maps}';
  });
  T('build.emptyGraph', () => H(W.build(mix([wl6, {'VGAGRAPH.WL6': Uint8List(0)}])).pack));
  T('build.emptyMaps', () {
    final r = W.build(mix([wl6, {'MAPHEAD.WL6': Uint8List(0), 'AUDIOHED.WL6': Uint8List(3)}]));
    return '${H(r.pack)} maps=${r.maps} episodes=${r.episodes}';
  });
  T('build.emptySwap', () => H(W.build(mix([sod, {'VSWAP.SOD': Uint8List(0)}])).pack));
  print(lines.join('\n'));
}
