// Paramix Studio core, the rest: a native port of the parts of Paramix Studio's src/core.js
// (mameise, GPL-3.0-or-later) that sprites.dart and sprite_edit.dart do not have: the opened ROM
// (files, entries, character groups), the full sprite decoder and encoder with their options,
// launcher ROM, sheets, character cards (DIM, TamaSma), eye layers, number test pictures, ZIP,
// fields and texts.
//
// Names as in core.js. Three functions exist in a smaller form in sprites.dart / sprite_edit.dart
// under the JS name, so the full ports are called spriteDecodeAll (JS spriteDecode),
// spriteEncodeOpts (JS spriteEncode with opts) and buildRomCtx (JS buildRom with a ctx).
//
// Format references: github.com/GMMan/tama-para-research (formats/archive.md,
// formats/sprites.md). Everything else measured on the editions.

// ignore_for_file: constant_identifier_names, non_constant_identifier_names

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';
import 'sprite_edit.dart';
import 'sprites.dart';

export 'bytes.dart' show crc32;
export 'sprite_edit.dart' show rleEncode, lz4Encode, rgbTo565, rgb565ToRgb;
export 'sprites.dart' show Arc2, Rgba, arc2Parse, packSplit;

const int ASSET_BASE = assetBase; // ARC2 root in flash (all editions)
const int _arc2Magic = 0x32435241; // "ARC2"
const Map<int, String> EDITIONS = {1: 'Land', 2: 'Water', 3: 'Sky', 4: 'Jade Forest', 5: 'Tropical', 6: 'Glacier', 7: 'Tropical/Glacier', 8: 'Neon Planets'};

// ------------------------------------------------------------------ helpers
// reads past the end give 0, as a JS typed array does inside | and <<
int _b(Uint8List b, int o) => o >= 0 && o < b.length ? b[o] : 0;
int _u16(Uint8List b, int o) => _b(b, o) | (_b(b, o + 1) << 8);
int _u32(Uint8List b, int o) => (_b(b, o) | (_b(b, o + 1) << 8) | (_b(b, o + 2) << 16) | (_b(b, o + 3) << 24)) & 0xFFFFFFFF;
int _s8(int v) => (v & 0x80) != 0 ? v - 256 : v;
int _imax(int a, int b) => a > b ? a : b;
int _imin(int a, int b) => a < b ? a : b;

// from core.js: w16, w32 (values are cut to their bytes)
void _w16(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
}

void _w32(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = (v >> 8) & 255;
  b[o + 2] = (v >> 16) & 255;
  b[o + 3] = (v >> 24) & 255;
}

// Uint8Array.slice / subarray: negative positions count from the end, everything is clamped
int _rel(int v, int n) => v < 0 ? _imax(n + v, 0) : _imin(v, n);
Uint8List _view(Uint8List b, int a, int z) {
  final s = _rel(a, b.length), e = _rel(z, b.length);
  return Uint8List.sublistView(b, s, e < s ? s : e);
}

Uint8List _slice(Uint8List b, int a, int z) => Uint8List.fromList(_view(b, a, z));

// from core.js: concat
Uint8List _concat(List<Uint8List> parts) {
  var n = 0;
  for (final p in parts) {
    n += p.length;
  }
  final out = Uint8List(n);
  var o = 0;
  for (final p in parts) {
    out.setAll(o, p);
    o += p.length;
  }
  return out;
}

// 1.7.3 test11: an ID page counts when its footer fits (+0xFF8 = C minus ID, +0xFFC its inverse); Tropical/Glacier
// (0xD29000) first. A Glacier was read as Land: at 0xD49000 it has its own save data (or an ID a Studio up to 1.2.11
// wrote there) whose first word can be 1..6. Without a fitting footer the first word as before.
const List<int> _edC = [0, 0x70169E2C, 0x70169E2C, 0x70169E2C, 0x849633DB, 0x96CB83B8, 0x96CB83B8];
int _edPage(Uint8List rom, int p, bool check) {
  if (p + 0x1000 > rom.length) return 0;
  final v = u32(rom, p), k = u32(rom, p + 0xFF8);
  bool foot(int c) => ((k + v) & 0xFFFFFFFF) == c && u32(rom, p + 0xFFC) == (~k & 0xFFFFFFFF);
  // 1.7.6 GEN3_ID4: Tropical/Glacier with Forest or Sky active keep the ID 4 with their own footer: edition 7
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

// 1.7.6 NEON_ED: Neon Planets (2026) keeps its ID page at 0xD85000: ID 7 with its own footer constant. Inside the Studio
// it is edition 8 (7 already stands for Tropical/Glacier with ID 4). Before, it was read as Tropical/Glacier.
const int _neonPage = 0xD85000, _neonC = 0x99431749;
bool isNeon(Uint8List rom) {
  if (rom.length < _neonPage + 0x1000) return false;
  // NEON_CLEAN: also the ID page a ROM without the Paradise keeps at 0xEFD000
  for (final p in const [_neonPage, 0xEFD000]) {
    final v = _u32(rom, p), k = _u32(rom, p + 0xFF8);
    if (v == 7 && ((k + v) & 0xFFFFFFFF) == _neonC && _u32(rom, p + 0xFFC) == (~k & 0xFFFFFFFF)) return true;
  }
  return false;
}

// from core.js: editionIdOf
int _editionIdOf(Uint8List rom) {
  if (isNeon(rom)) return 8;
  for (final p in const [0xD29000, 0xD49000, 0xEFD000]) {
    final v = _edPage(rom, p, true); // 0xEFD000: clean ROM (1.7.3 test13)
    if (v != 0) return v;
  }
  for (final p in const [0xD49000, 0xD29000]) {
    final v = p + 4 <= rom.length ? u32(rom, p) : 0;
    if (v >= 1 && v <= 6) return v;
  }
  return 0;
}

// ------------------------------------------------------------------- ARC2
int arc2Checksum(Uint8List buf, int off, int length) {
  var s = 0;
  final end = off + 16 + length;
  for (var i = off + 8; i < end; i++) {
    s = (s + _b(buf, i)) & 0xFFFFFFFF;
  }
  return s;
}

List<Uint8List> arc2Files(Uint8List buf, int off) => [for (final e in arc2Parse(buf, off).ents) _slice(buf, off + e.$2, off + e.$2 + e.$4)];

Uint8List arc2Build(List<Uint8List> files) {
  final n = files.length;
  var pos = 16 + 16 * n;
  final ents = <List<int>>[], body = <Uint8List>[];
  for (final f in files) {
    final pad = (4 - pos % 4) % 4;
    if (pad != 0) {
      body.add(Uint8List(pad));
      pos += pad;
    }
    final aligned = f.length + ((4 - f.length % 4) % 4);
    ents.add([0, pos, aligned, f.length]);
    body.add(f);
    if (aligned > f.length) body.add(Uint8List(aligned - f.length));
    pos += aligned;
  }
  final out = Uint8List(pos);
  _w32(out, 0, _arc2Magic);
  _w32(out, 8, pos - 16);
  _w32(out, 12, n);
  for (var i = 0; i < n; i++) {
    for (var k = 0; k < 4; k++) {
      _w32(out, 16 + 16 * i + 4 * k, ents[i][k]);
    }
  }
  out.setAll(16 + 16 * n, _concat(body));
  _w32(out, 4, arc2Checksum(out, 0, pos - 16));
  return out;
}

// ------------------------------------------------------------ sprite pack
Uint8List packJoin(List<Uint8List> entries) {
  final n = entries.length;
  var pos = 4 * n;
  final offs = <int>[], parts = <Uint8List>[];
  for (final e in entries) {
    final pad = (4 - pos % 4) % 4;
    if (pad != 0) {
      parts.add(Uint8List(pad));
      pos += pad;
    }
    offs.add(pos);
    parts.add(e);
    pos += e.length;
  }
  final head = Uint8List(4 * n);
  for (var i = 0; i < n; i++) {
    _w32(head, 4 * i, offs[i]);
  }
  return _concat([head, ...parts]);
}

// ----------------------------------------------------------- sprite data
/// The header of a sprite entry with every field of the JS spriteHeader (ox, oy: the anchor).
class SpriteHead {
  SpriteHead({required this.dataLength, required this.flags, required this.bpp, required this.numSprites, required this.sw, required this.sh, required this.ox, required this.oy, required this.iw, required this.ih, required this.palBpp, required this.numPal, required this.transp, required this.palOffset, required this.pixOffset});
  final int dataLength, flags, bpp, numSprites, sw, sh, ox, oy, iw, ih, palBpp, numPal, transp, palOffset, pixOffset;
  Map<String, int> toJson() => {'dataLength': dataLength, 'flags': flags, 'bpp': bpp, 'numSprites': numSprites, 'sw': sw, 'sh': sh, 'ox': ox, 'oy': oy, 'iw': iw, 'ih': ih, 'palBpp': palBpp, 'numPal': numPal, 'transp': transp, 'palOffset': palOffset, 'pixOffset': pixOffset};
}

SpriteHead spriteHeader(Uint8List e) => SpriteHead(
    dataLength: _u32(e, 0), flags: _b(e, 4), bpp: _b(e, 5), numSprites: _u16(e, 6), sw: _b(e, 8), sh: _b(e, 9), //
    ox: _s8(_b(e, 10)), oy: _s8(_b(e, 11)), iw: _b(e, 12), ih: _b(e, 13), palBpp: _b(e, 14), numPal: _b(e, 15), //
    transp: _u16(e, 16), palOffset: _u16(e, 18), pixOffset: _u16(e, 20));

const int _fTransp = 0x04, _fRleByte = 0x20, _fRleWord = 0x40, _fXor = 0x80;
const Map<int, int> _bits = {0: 1, 1: 2, 2: 4, 3: 8};

Uint8List rleDecode(Uint8List d, [bool word = false]) {
  final out = BytesBuilder(copy: false);
  var i = 0;
  if (!word) {
    while (i < d.length) {
      final c = d[i++];
      if (c == 0) break;
      if ((c & 0x80) != 0) {
        final n = c & 0x7f;
        for (var k = 0; k < n; k++) {
          out.addByte(_b(d, i + k));
        }
        i += n;
      } else {
        final v = _b(d, i++);
        for (var k = 0; k < c; k++) {
          out.addByte(v);
        }
      }
    }
  } else {
    while (i + 4 <= d.length) {
      final c = u32(d, i);
      i += 4;
      if (c == 0) break;
      if ((c & 0x80000000) != 0) {
        final n = (c & 0x0fffffff) * 4;
        for (var k = 0; k < n; k++) {
          out.addByte(_b(d, i + k));
        }
        i += n;
      } else {
        for (var r = 0; r < c; r++) {
          for (var k = 0; k < 4; k++) {
            out.addByte(_b(d, i + k));
          }
        }
        i += 4;
      }
    }
  }
  return out.toBytes();
}

// 1.7.6 LZ4_SPR: Neon Planets packs many pictures with flag 0x08 (no RLE flag): each cell is an LZ4 block (after the
// XOR with 0x53), with the same offset table as the RLE pictures. Older editions never set this bit.
const int _fLz4 = 0x08;
Uint8List lz4Decode(Uint8List d) {
  final out = <int>[];
  var i = 0;
  while (i < d.length) {
    final tok = d[i++];
    var lit = tok >> 4;
    if (lit == 15) {
      int b;
      do {
        if (i >= d.length) return Uint8List.fromList(out); // the count is cut off
        b = d[i++];
        lit += b;
      } while (b == 255 && i < d.length);
    }
    for (var k = 0; k < lit; k++) {
      out.add(_b(d, i++));
    }
    if (i + 2 > d.length) break; // the last sequence has literals only
    final off = d[i] | (d[i + 1] << 8);
    i += 2;
    var ml = tok & 15;
    if (ml == 15) {
      int b;
      do {
        if (i >= d.length) return Uint8List.fromList(out);
        b = d[i++];
        ml += b;
      } while (b == 255 && i < d.length);
    }
    ml += 4;
    if (off == 0 || off > out.length) break;
    final p = out.length - off;
    for (var k = 0; k < ml; k++) {
      out.add(out[p + k]);
    }
  }
  return Uint8List.fromList(out);
}

/// A decoded sprite entry: header, palettes (RGB565, null for direct colour), the raw index
/// cells and the composed sub-images as RGBA.
class SpriteDecoded {
  SpriteDecoded(this.header, this.palettes, this.cells, this.subs, this.width, this.height);
  final SpriteHead header;
  final List<List<int>>? palettes;
  final List<List<int>> cells;
  final List<Rgba> subs;
  final int width, height;
}

/// Decode one sprite entry (JS spriteDecode). Returns header, palettes, raw index cells and
/// composed subimages as RGBA (palette set `palSet`).
SpriteDecoded spriteDecodeAll(Uint8List e, [int palSet = 0]) {
  final h = spriteHeader(e);
  final n = h.numSprites, w = h.sw, hh = h.sh, npx = w * hh;
  final iw = _imax(1, h.iw), ih = _imax(1, h.ih);
  final cells = <List<int>>[];
  List<List<int>>? palettes;
  final direct = h.bpp >= 0x10;
  if (direct) {
    for (var s = 0; s < n; s++) {
      final c = Uint16List(npx);
      for (var k = 0; k < npx; k++) {
        c[k] = _u16(e, h.pixOffset + 2 * (s * npx + k));
      }
      cells.add(c);
    }
  } else {
    final bits = _bits[h.bpp];
    if (bits == null) throw FormatException('unknown bpp ${h.bpp}');
    final ncol = 1 << bits;
    palettes = [
      for (var p = 0; p < _imax(1, h.numPal); p++) [for (var k = 0; k < ncol; k++) _u16(e, h.palOffset + 2 * (p * ncol + k))],
    ];
    final comp = h.flags & (_fRleByte | _fRleWord), enc = (h.flags & _fXor) != 0;
    final bp = h.pixOffset, raws = <Uint8List>[];
    Uint8List cut(int a, int z) {
      final d = _slice(e, a, z);
      if (enc) {
        for (var k = 0; k < d.length; k++) {
          d[k] ^= 0x53;
        }
      }
      return d;
    }

    if (comp != 0) {
      for (var s = 0; s < n; s++) {
        var off = _u32(e, bp + 8 * s);
        final ln = _u32(e, bp + 8 * s + 4);
        final unc = (off & 0x80000000) != 0;
        off &= 0x7fffffff;
        var d = cut(bp + off, bp + off + ln);
        if (!unc) d = rleDecode(d, (h.flags & _fRleWord) != 0);
        raws.add(d);
      }
    } else if ((h.flags & _fLz4) != 0) {
      for (var s = 0; s < n; s++) {
        var off = _u32(e, bp + 8 * s);
        final ln = _u32(e, bp + 8 * s + 4);
        final unc = (off & 0x80000000) != 0;
        off &= 0x7fffffff;
        final d = cut(bp + off, bp + off + ln);
        raws.add(unc ? d : lz4Decode(d));
      }
    } else {
      final sz = (npx * bits + 7) ~/ 8;
      for (var s = 0; s < n; s++) {
        raws.add(cut(bp + s * sz, bp + (s + 1) * sz));
      }
    }
    final mask = ncol - 1;
    for (final d in raws) {
      final c = Uint8List(npx);
      for (var k = 0; k < npx; k++) {
        final bit = k * bits, byte = (bit >> 3) < d.length ? d[bit >> 3] : 0;
        c[k] = (byte >> (bit & 7)) & mask;
      }
      cells.add(c);
    }
  }
  final nsub = n ~/ (iw * ih);
  final W = w * iw, H = hh * ih, subs = <Rgba>[];
  final pal = palettes == null ? null : [for (final v in palettes[_imin(palSet, palettes.length - 1)]) rgb565ToRgb(v)];
  final transp = (h.flags & _fTransp) != 0;
  for (var si = 0; si < nsub; si++) {
    final px = Uint8List(W * H * 4);
    for (var gy = 0; gy < ih; gy++) {
      for (var gx = 0; gx < iw; gx++) {
        final c = cells[si * iw * ih + gy * iw + gx];
        for (var k = 0; k < npx; k++) {
          final v = c[k], x = gx * w + (k % w), y = gy * hh + (k ~/ w), o = (y * W + x) * 4;
          if (transp && v == h.transp) continue;
          final rgb = pal != null ? pal[v] : rgb565ToRgb(v);
          px[o] = rgb[0];
          px[o + 1] = rgb[1];
          px[o + 2] = rgb[2];
          px[o + 3] = 255;
        }
      }
    }
    subs.add(Rgba(W, H, px));
  }
  return SpriteDecoded(h, palettes, cells, subs, W, H);
}

// ------------------------------------------------------------ quantizing
// stable sort, as Array.prototype.sort
void _stableSort<T>(List<T> a, int Function(T, T) cmp) {
  if (a.length < 2) return;
  final tmp = List<T>.of(a);
  void ms(int lo, int hi) {
    if (hi - lo < 2) return;
    final mid = (lo + hi) >> 1;
    ms(lo, mid);
    ms(mid, hi);
    var i = lo, j = mid, k = lo;
    while (i < mid && j < hi) {
      tmp[k++] = cmp(a[j], a[i]) < 0 ? a[j++] : a[i++];
    }
    while (i < mid) {
      tmp[k++] = a[i++];
    }
    while (j < hi) {
      tmp[k++] = a[j++];
    }
    for (k = lo; k < hi; k++) {
      a[k] = tmp[k];
    }
  }

  ms(0, a.length);
}

// log2 as V8 has it (fdlibm e_log2.c), so that equal scores stay equal on every platform
double _log2(double x) {
  const two54 = 1.80143985094819840000e+16, ivln2hi = 1.44269504072144627571e+00, ivln2lo = 1.67517131648865118353e-10;
  const lg1 = 6.666666666666735130e-01, lg2 = 3.999999999940941908e-01, lg3 = 2.857142874366239149e-01, lg4 = 2.222219843214978396e-01;
  const lg5 = 1.818357216161805012e-01, lg6 = 1.531383769920937332e-01, lg7 = 1.479819860511658591e-01;
  final bd = ByteData(8)..setFloat64(0, x);
  var hx = bd.getInt32(0);
  final lx = bd.getUint32(4);
  var k = 0;
  if (hx < 0x00100000) {
    if (((hx & 0x7fffffff) | lx) == 0) return double.negativeInfinity;
    if (hx < 0) return double.nan;
    k -= 54;
    x *= two54;
    bd.setFloat64(0, x);
    hx = bd.getInt32(0);
  }
  if (hx >= 0x7ff00000) return x + x;
  if (hx == 0x3ff00000 && lx == 0) return 0;
  k += (hx >> 20) - 1023;
  hx &= 0x000fffff;
  final i = (hx + 0x95f64) & 0x100000;
  bd.setFloat64(0, x);
  bd.setInt32(0, hx | (i ^ 0x3ff00000));
  x = bd.getFloat64(0);
  k += i >> 20;
  final y = k.toDouble();
  final f = x - 1.0;
  final hfsq = 0.5 * f * f;
  final s = f / (2.0 + f), z = s * s, w = z * z;
  final t1 = w * (lg2 + w * (lg4 + w * lg6));
  final t2 = z * (lg1 + w * (lg3 + w * (lg5 + w * lg7)));
  final r = s * (hfsq + (t2 + t1));
  bd.setFloat64(0, f - hfsq);
  bd.setUint32(4, 0);
  final hi = bd.getFloat64(0);
  final lo = (f - hi) - hfsq + r;
  var valHi = hi * ivln2hi;
  var valLo = (lo + hi) * ivln2lo + lo * ivln2hi;
  final ww = y + valHi;
  valLo += (y - ww) + valHi;
  valHi = ww;
  return valLo + valHi;
}

/// Median cut with k-means refinement. pixels: list of [r,g,b].
List<List<int>> quantize(List<List<int>> pixels, int ncolors) {
  final uniq = <int, int>{};
  for (final p in pixels) {
    final k = (p[0] << 16) | (p[1] << 8) | p[2];
    uniq[k] = (uniq[k] ?? 0) + 1;
  }
  final cols = [for (final e in uniq.entries) [(e.key >> 16) & 255, (e.key >> 8) & 255, e.key & 255, e.value]];
  if (cols.length <= ncolors) return [for (final c in cols) c.sublist(0, 3)];
  final boxes = <List<List<int>>>[cols];
  while (boxes.length < ncolors) {
    var bi = -1, ch = 0;
    var best = -1.0;
    for (var i = 0; i < boxes.length; i++) {
      final b = boxes[i];
      if (b.length < 2) continue;
      for (var c = 0; c < 3; c++) {
        var lo = 255, hi = 0, sum = 0;
        for (final p in b) {
          if (p[c] < lo) lo = p[c];
          if (p[c] > hi) hi = p[c];
          sum += p[3];
        }
        final score = (hi - lo) * _log2(1.0 + sum);
        if (score > best) {
          best = score;
          bi = i;
          ch = c;
        }
      }
    }
    if (bi < 0) break;
    final b = boxes[bi];
    _stableSort<List<int>>(b, (a, c) => a[ch] - c[ch]);
    var total = 0;
    for (final p in b) {
      total += p[3];
    }
    var acc = 0, cut = 1;
    for (var i = 0; i < b.length - 1; i++) {
      acc += b[i][3];
      if (acc >= total / 2) {
        cut = i + 1;
        break;
      }
    }
    boxes
      ..removeAt(bi)
      ..insertAll(bi, [b.sublist(0, cut), b.sublist(cut)]);
  }
  var centers = <List<double>>[
    for (final b in boxes)
      () {
        var t = 0;
        final s = [0, 0, 0];
        for (final p in b) {
          t += p[3];
          for (var c = 0; c < 3; c++) {
            s[c] += p[c] * p[3];
          }
        }
        return [s[0] / t, s[1] / t, s[2] / t];
      }(),
  ];
  for (var it = 0; it < 20; it++) {
    // k-means on unique colors, weighted
    final sum = [for (final _ in centers) [0, 0, 0, 0]];
    for (final p in cols) {
      var bi = 0;
      var bd = 1e18;
      for (var i = 0; i < centers.length; i++) {
        final c = centers[i];
        final d0 = p[0] - c[0], d1 = p[1] - c[1], d2 = p[2] - c[2];
        final d = d0 * d0 + d1 * d1 + d2 * d2;
        if (d < bd) {
          bd = d;
          bi = i;
        }
      }
      final s = sum[bi];
      s[0] += p[0] * p[3];
      s[1] += p[1] * p[3];
      s[2] += p[2] * p[3];
      s[3] += p[3];
    }
    var moved = 0.0;
    final next = <List<double>>[];
    for (var i = 0; i < centers.length; i++) {
      final c = centers[i], s = sum[i];
      if (s[3] == 0) {
        next.add(c);
        continue;
      }
      final n = [s[0] / s[3], s[1] / s[3], s[2] / s[3]];
      moved += (n[0] - c[0]).abs() + (n[1] - c[1]).abs() + (n[2] - c[2]).abs();
      next.add(n);
    }
    centers = next;
    if (moved < 0.5) break;
  }
  return [
    for (final c in centers) [for (final v in c) (v + 0.5).floor()],
  ];
}

// from core.js: nearestIndex
int _nearestIndex(List<List<int>> pal, int r, int g, int b, int skip) {
  var bi = 0, bd = 1000000000000000000;
  for (var i = 0; i < pal.length; i++) {
    if (i == skip) continue;
    final c = pal[i];
    final d = (r - c[0]) * (r - c[0]) + (g - c[1]) * (g - c[1]) + (b - c[2]) * (b - c[2]);
    if (d < bd) {
      bd = d;
      bi = i;
    }
  }
  return bi;
}

// -------------------------------------------------------------- encoding
/// The options of [spriteEncodeOpts] (the opts object of the JS spriteEncode).
class SpriteOpts {
  const SpriteOpts({this.keepPalette = false, this.allowMoreColors = false, this.figure = false, this.keepLength = false});
  final bool keepPalette, allowMoreColors, figure, keepLength;
  SpriteOpts copyWith({bool? keepPalette, bool? allowMoreColors, bool? figure, bool? keepLength}) =>
      SpriteOpts(keepPalette: keepPalette ?? this.keepPalette, allowMoreColors: allowMoreColors ?? this.allowMoreColors, figure: figure ?? this.figure, keepLength: keepLength ?? this.keepLength);
}

// 1.7.3 test25 FIG_NOVAR: an own picture whose colours all exist in the original palette kept that palette, also for
// colours that sit in slots 2-7. The game recolours those per Tama (colour, field), so the small Tama on the field
// showed fewer colours or a red tint (Glacier: Icy Irukatchi, Ginjirotchi, Yukiraratchi). Those slots are left out.
// 1.7.5 FIG_QUANT2 (user: Irukatchi on Icy Irukatchi, small picture: the shine on the head had the wrong colour): the
// 8 free colours of a character picture. The outline colour no longer takes one, and with more than 8 colours the
// two closest are joined step by step (weighted by how often they occur), so a small bright spot keeps its colour.
List<List<int>> _mergeColours(List<List<int>> px, int n) {
  final m = <int, List<int>>{}; // r, g, b, n
  for (final p in px) {
    final k = (p[0] << 16) | (p[1] << 8) | p[2];
    final e = m[k];
    if (e != null) {
      e[3]++;
    } else {
      m[k] = [p[0], p[1], p[2], 1];
    }
  }
  final c = m.values.toList();
  while (c.length > n) {
    var bi = 0, bj = 1;
    var bd = double.infinity;
    for (var i = 0; i < c.length; i++) {
      for (var j = i + 1; j < c.length; j++) {
        final a = c[i], b = c[j], dr = a[0] - b[0], dg = a[1] - b[1], db = a[2] - b[2];
        final d = (2 * dr * dr + 4 * dg * dg + 3 * db * db) * (a[3] * b[3] / (a[3] + b[3]));
        if (d < bd) {
          bd = d;
          bi = i;
          bj = j;
        }
      }
    }
    final a = c[bi], b = c[bj], t = a[3] + b[3];
    // the joined colour: the more frequent one (no mixed colours that were never drawn)
    c[bi] = a[3] >= b[3] ? [a[0], a[1], a[2], t] : [b[0], b[1], b[2], t];
    c.removeAt(bj);
  }
  return [for (final e in c) e.sublist(0, 3)];
}

// from core.js: writeHeader
void _writeHeader(Uint8List b, {required int dataLength, required int flags, required int bpp, required int numSprites, required int sw, required int sh, required int ox, required int oy, required int iw, required int ih, required int palBpp, required int numPal, required int transp, required int palOffset, required int pixOffset}) {
  _w32(b, 0, dataLength);
  b[4] = flags;
  b[5] = bpp;
  _w16(b, 6, numSprites);
  b[8] = sw;
  b[9] = sh;
  b[10] = ox & 255;
  b[11] = oy & 255;
  b[12] = iw;
  b[13] = ih;
  b[14] = palBpp;
  b[15] = numPal;
  _w16(b, 16, transp);
  _w16(b, 18, palOffset);
  _w16(b, 20, pixOffset);
  _w16(b, 22, 0);
}

/// Re-encode a sprite from RGBA subimages (JS spriteEncode), keeping cell size, grid, count
/// and anchor of the original entry.
///   opts.keepPalette: map onto the original palettes (forced for sprites
///                     with more than one palette set: colour variants)
///   opts.allowMoreColors: palette sprites may go up to 8 bpp
///   opts.figure: a character part (the recoloured slots 2-7 stay unused)
///   opts.keepLength: padded to the original byte length (eye sprites)
Uint8List spriteEncodeOpts(Uint8List orig, List<Rgba> subs, [SpriteOpts opts = const SpriteOpts()]) {
  final h = spriteHeader(orig);
  final n = h.numSprites, w = h.sw, hh = h.sh, npx = w * hh;
  final iw = _imax(1, h.iw), ih = _imax(1, h.ih);
  final W = w * iw, H = hh * ih;
  if (subs.length * iw * ih != n) throw StateError('subimage count does not match');
  for (final s in subs) {
    if (s.w != W || s.h != H) throw StateError('subimage size does not match');
  }
  int cellO(int gx, int gy, int k) => ((gy * hh + (k ~/ w)) * W + gx * w + (k % w)) * 4;
  void forEachCell(void Function(int si, int gx, int gy) fn) {
    for (var si = 0; si < subs.length; si++) {
      for (var gy = 0; gy < ih; gy++) {
        for (var gx = 0; gx < iw; gx++) {
          fn(si, gx, gy);
        }
      }
    }
  }

  // direct colour: raw RGB565, uncompressed, same layout as original
  if (h.bpp >= 0x10) {
    final tr = h.transp, hasT = (h.flags & _fTransp) != 0;
    final out = Uint8List(24 + n * npx * 2);
    var s = 0;
    forEachCell((si, gx, gy) {
      final d = subs[si].data;
      for (var k = 0; k < npx; k++) {
        final o = cellO(gx, gy, k);
        var v = (hasT && d[o + 3] < 128) ? tr : rgbTo565(d[o], d[o + 1], d[o + 2]);
        if (hasT && d[o + 3] >= 128 && v == tr) v ^= 1; // keep visible pixels visible
        _w16(out, 24 + 2 * (s * npx + k), v);
      }
      s++;
    });
    _writeHeader(out, dataLength: out.length, flags: h.flags & ~(_fRleByte | _fRleWord | _fXor), bpp: 0x11, numSprites: n, sw: w, sh: hh, ox: h.ox, oy: h.oy, iw: h.iw, ih: h.ih, palBpp: 0x11, numPal: 0, transp: tr, palOffset: 24, pixOffset: 24);
    return out;
  }

  var keep = opts.keepPalette || h.numPal > 1;
  var bpp = h.bpp;
  late Uint8List palBlock;
  late int transpIdx;
  late int Function(int r, int g, int b, int a) indexOf;
  var anyTransparent = false;
  for (final s in subs) {
    for (var i = 3; i < s.data.length; i += 4) {
      if (s.data[i] < 128) {
        anyTransparent = true;
        break;
      }
    }
  }
  final origTransp = (h.flags & _fTransp) != 0;
  var figureMode = false;

  if (opts.figure && !keep) {
    // Character parts: if every colour already exists in the original palette,
    // keep it (the game's colour variants keep working). Otherwise use the
    // "fixed colour" layout: slots 2-7 are recoloured by the game per tama,
    // so they stay unused; near black goes to slot 1 (0x000C in every variant).
    final pal0 = [for (final v in spriteDecodeAll(orig).palettes![0]) rgb565ToRgb(v)];
    var fits = true;
    outer:
    for (final s in subs) {
      final d = s.data;
      for (var i = 0; i < d.length; i += 4) {
        if (d[i + 3] < 128) continue;
        var ok = false;
        for (var k = 1; k < pal0.length; k++) {
          if (k >= 2 && k <= 7) continue; // FIG_NOVAR
          final c = pal0[k];
          if ((c[0] - d[i]).abs() <= 8 && (c[1] - d[i + 1]).abs() <= 8 && (c[2] - d[i + 2]).abs() <= 8) {
            ok = true;
            break;
          }
        }
        if (!ok) {
          fits = false;
          break outer;
        }
      }
    }
    if (fits && h.bpp == 2) {
      keep = true;
    } else {
      figureMode = h.bpp == 2;
    }
  }

  if (keep) {
    final dec = spriteDecodeAll(orig);
    final pal0 = [for (final v in dec.palettes![0]) rgb565ToRgb(v)];
    transpIdx = origTransp ? h.transp : -1;
    final ncol = 1 << _bits[bpp]!;
    palBlock = _slice(orig, h.palOffset, h.palOffset + 2 * ncol * _imax(1, h.numPal));
    // FIG_NOVAR: own pictures never land in slots 2-7 (the game recolours them per Tama, on the field too)
    final pk = opts.figure ? [for (var i = 0; i < pal0.length; i++) (i >= 2 && i <= 7) ? [1000000, 1000000, 1000000] : pal0[i]] : pal0;
    final cache = <int, int>{};
    indexOf = (r, g, b, a) => (a < 128 && transpIdx >= 0) ? transpIdx : (cache[(r << 16) | (g << 8) | b] ??= _nearestIndex(pk, r, g, b, transpIdx));
  } else if (figureMode) {
    const free = [8, 9, 10, 11, 12, 13, 14, 15];
    // FIG_QUANT2: the outline colour of the game (0x000C = 0,0,98) also counts as dark (it took one of the 8 slots)
    bool dark(int r, int g, int b) => r + g + b < 90 || (r <= 8 && g <= 8 && b <= 106);
    final opaque = <List<int>>[];
    for (final s in subs) {
      final d = s.data;
      for (var i = 0; i < d.length; i += 4) {
        if (d[i + 3] >= 128 && !dark(d[i], d[i + 1], d[i + 2])) opaque.add([d[i], d[i + 1], d[i + 2]]);
      }
    }
    final pal = opaque.isEmpty ? <List<int>>[] : _mergeColours(opaque, free.length);
    transpIdx = 0;
    palBlock = Uint8List(32);
    _w16(palBlock, 0, 0x07e0);
    _w16(palBlock, 2, 0x000c);
    for (var k = 0; k < pal.length; k++) {
      _w16(palBlock, 2 * free[k], rgbTo565(pal[k][0], pal[k][1], pal[k][2]));
    }
    final cache = <int, int>{};
    indexOf = (r, g, b, a) {
      if (a < 128) return 0;
      if (dark(r, g, b) || pal.isEmpty) return 1;
      return cache[(r << 16) | (g << 8) | b] ??= free[_nearestIndex(pal, r, g, b, -1)];
    };
  } else {
    final useT = origTransp || anyTransparent;
    final opaque = <List<int>>[];
    for (final s in subs) {
      final d = s.data;
      for (var i = 0; i < d.length; i += 4) {
        if (!useT || d[i + 3] >= 128) opaque.add([d[i], d[i + 1], d[i + 2]]);
      }
    }
    var maxBits = _bits[bpp]!;
    if (opts.allowMoreColors) maxBits = _imax(maxBits, 8);
    final avail = (1 << maxBits) - (useT ? 1 : 0);
    final pal = opaque.isNotEmpty
        ? quantize(opaque, avail)
        : [
            [0, 0, 0]
          ];
    var bits = _bits[bpp]!;
    while ((1 << bits) - (useT ? 1 : 0) < pal.length && bits < 8) {
      bits *= 2;
    }
    bpp = const {1: 0, 2: 1, 4: 2, 8: 3}[bits]!;
    final ncol = 1 << bits;
    transpIdx = useT ? 0 : -1;
    final full = <List<int>>[
      if (useT) [0, 0, 0],
      ...pal,
    ];
    while (full.length < ncol) {
      full.add([0, 0, 0]);
    }
    palBlock = Uint8List(2 * ncol);
    for (var i = 0; i < full.length; i++) {
      // a palette longer than the table (more colours than 8 bpp holds) is cut, as a typed array does
      if (2 * i + 1 < palBlock.length) _w16(palBlock, 2 * i, rgbTo565(full[i][0], full[i][1], full[i][2]));
    }
    if (useT) _w16(palBlock, 0, 0x07e0); // like the originals: slot 0 holds the colour key
    final cache = <int, int>{};
    final palIdx = useT ? full.sublist(1, _imin(pal.length + 1, full.length)) : full.sublist(0, pal.length);
    indexOf = (r, g, b, a) {
      if (useT && a < 128) return 0;
      return cache[(r << 16) | (g << 8) | b] ??= _nearestIndex(palIdx, r, g, b, -1) + (useT ? 1 : 0);
    };
  }

  final bits = _bits[bpp]!, lz = (h.flags & _fLz4) != 0 && (h.flags & (_fRleByte | _fRleWord)) == 0;
  final datas = <Uint8List>[];
  forEachCell((si, gx, gy) {
    final raw = Uint8List((npx * bits + 7) ~/ 8);
    final d = subs[si].data;
    for (var k = 0; k < npx; k++) {
      final o = cellO(gx, gy, k);
      final v = indexOf(d[o], d[o + 1], d[o + 2], d[o + 3]);
      final bit = k * bits;
      raw[bit >> 3] |= v << (bit & 7);
    }
    final enc = lz ? lz4Encode(raw) : rleEncode(raw); // LZ4_SPR: same packing as the original
    for (var k = 0; k < enc.length; k++) {
      enc[k] ^= 0x53;
    }
    datas.add(enc);
  });
  final palOff = 24, pixOff = palOff + palBlock.length, tblLen = 8 * n;
  var pos = pixOff + tblLen;
  final tbl = <(int, int)>[], body = <Uint8List>[];
  for (final d in datas) {
    final pad = (4 - pos % 4) % 4;
    if (pad != 0) {
      body.add(Uint8List(pad));
      pos += pad;
    }
    tbl.add((pos - pixOff, d.length));
    body.add(d);
    pos += d.length;
  }
  // 1.7.3 test21 SPR_ALIGN: the length a multiple of 4 like every original. The playdate sends the Tama's own pictures
  // and sums them up in 32-bit words: an odd length (own pictures) made the other Paradise refuse it at about 90 %.
  pos = (pos + 3) & ~3;
  final out = Uint8List(pos);
  final useT = transpIdx >= 0;
  _writeHeader(out, dataLength: pos, flags: _fXor | (lz ? _fLz4 : _fRleByte) | 0x03 | (useT ? _fTransp : 0), bpp: bpp, numSprites: n, sw: w, sh: hh, ox: h.ox, oy: h.oy, iw: h.iw, ih: h.ih, palBpp: 0x11, numPal: keep ? _imax(1, h.numPal) : 1, transp: useT ? transpIdx : 0, palOffset: palOff, pixOffset: pixOff);
  out.setAll(palOff, palBlock);
  for (var i = 0; i < tbl.length; i++) {
    _w32(out, pixOff + 8 * i, tbl[i].$1);
    _w32(out, pixOff + 8 * i + 4, tbl[i].$2);
  }
  out.setAll(pixOff + tblLen, _concat(body));
  if (opts.keepLength) {
    // Eye sprites: the game checks their byte length (a different length makes
    // a substitute character hatch). Pad with zeros to the original length.
    if (out.length > orig.length) throw StateError('eye image too detailed: ${out.length} bytes, at most ${orig.length} allowed');
    final padded = Uint8List(orig.length)..setAll(0, out);
    _w32(padded, 0, orig.length);
    return padded;
  }
  return out;
}

/// SPR_ALIGN: a character picture with a length that is not a multiple of 4 (own pictures before 1.7.3 test21),
/// padded with zeros; null when it is fine.
Uint8List? spriteAlign(Uint8List? e) {
  if (e == null || e.length < 24) return null;
  final n = u32(e, 0);
  if ((n & 3) == 0 || n < 24 || n > e.length + 3) return null; // the stored entry may already be padded
  final out = Uint8List((n + 3) & ~3);
  out.setAll(0, _view(e, 0, _imin(n, out.length)));
  _w32(out, 0, out.length);
  return out;
}

/// Same format as `orig`, all pixels transparent.
Uint8List spriteBlank(Uint8List orig, [SpriteOpts opts = const SpriteOpts()]) {
  final d = spriteDecodeAll(orig);
  return spriteEncodeOpts(orig, [for (final s in d.subs) Rgba(s.w, s.h, Uint8List(s.w * s.h * 4))], opts);
}

/// Smallest image with the same frame (count, cell size, grid, anchor): 1 bit, all cells share one
/// run-length stream. Transparent originals stay transparent, the others become black (launcher ROM, 1.6.8).
Uint8List spriteTiny(Uint8List orig) {
  final h = spriteHeader(orig), n = h.numSprites, npx = h.sw * h.sh;
  final tr = (h.flags & _fTransp) != 0;
  final d = rleEncode(Uint8List((npx + 7) ~/ 8));
  for (var k = 0; k < d.length; k++) {
    d[k] ^= 0x53;
  }
  const palOff = 24, pixOff = palOff + 4;
  final dataOff = pixOff + 8 * n;
  final len = dataOff + d.length, pos = (len + 3) & ~3;
  final out = Uint8List(pos);
  _writeHeader(out, dataLength: pos, flags: _fXor | _fRleByte | 0x03 | (tr ? _fTransp : 0), bpp: 0, numSprites: n, sw: h.sw, sh: h.sh, ox: h.ox, oy: h.oy, iw: h.iw, ih: h.ih, palBpp: 0x11, numPal: 1, transp: 0, palOffset: palOff, pixOffset: pixOff);
  _w16(out, palOff, tr ? 0x07e0 : 0);
  _w16(out, palOff + 2, 0);
  for (var i = 0; i < n; i++) {
    _w32(out, pixOff + 8 * i, dataOff - pixOff);
    _w32(out, pixOff + 8 * i + 4, d.length);
  }
  out.setAll(dataOff, d);
  return out;
}

/// Encoding options for part k (0..5) of a character group.
SpriteOpts partOptions(int k, {bool? keepPalette, bool? allowMoreColors, bool? figure, bool? keepLength}) =>
    // as Object.assign({ figure: true, keepLength: k === 1 || k === 4 }, extra)
    SpriteOpts(keepPalette: keepPalette ?? false, allowMoreColors: allowMoreColors ?? false, figure: figure ?? true, keepLength: keepLength ?? (k == 1 || k == 4));

// ------------------------------------------------------- character groups
// One character = 6 consecutive sprites: body, eyes, mouth (large) and the same small.
class GroupPart {
  const GroupPart(this.key, this.w, this.h, this.n);
  final String key;
  final int w, h, n;
}

const List<GroupPart> GROUP_PARTS = [
  GroupPart('body', 64, 64, 20), GroupPart('eyes', 64, 32, 20), GroupPart('mouth', 64, 32, 18), //
  GroupPart('body_s', 32, 32, 24), GroupPart('eyes_s', 32, 16, 14), GroupPart('mouth_s', 32, 16, 14),
];

List<int> findGroups(List<Uint8List> entries) {
  final out = <int>[];
  for (var i = 0; i + 5 < entries.length; i++) {
    var ok = true;
    for (var k = 0; k < 6 && ok; k++) {
      final h = spriteHeader(entries[i + k]), p = GROUP_PARTS[k];
      ok = h.sw == p.w && h.sh == p.h && h.numSprites == p.n && h.bpp <= 3;
    }
    if (ok) out.add(i);
  }
  return out;
}

// Baby, child and teen share inherited eye images, adults have their own. Anchor: the eye
// image of the first adult, identical in all six editions.
const int _adultEyeCrc = 2777596871;
int _eyeSig(Uint8List e) => crc32(_concat([for (final x in spriteDecodeAll(e).subs) x.data]));

int findFirstAdult(List<Uint8List> entries, List<int> groups) {
  final sigs = <int>[];
  for (final g in groups) {
    try {
      sigs.add(_eyeSig(entries[g + 1]));
    } catch (_) {
      sigs.add(-1);
    }
  }
  final i = sigs.indexOf(_adultEyeCrc);
  if (i >= 0) return groups[i];
  var last = 0;
  for (var k = 1; k < sigs.length; k++) {
    if (sigs.indexOf(sigs[k]) != sigs.lastIndexOf(sigs[k])) last = k;
  }
  return groups[_imin(groups.length - 1, last + 1)];
}

/// Egg: small (32x32, 5 frames) at i, big (64x64, 5 frames) at i+3. -1 if not found.
int findEgg(List<Uint8List> entries) {
  for (var i = 0; i + 3 < entries.length; i++) {
    final a = spriteHeader(entries[i]), b = spriteHeader(entries[i + 3]);
    if (a.sw == 32 && a.sh == 32 && a.numSprites == 5 && b.sw == 64 && b.sh == 64 && b.numSprites == 5) return i;
  }
  return -1;
}

// ------------------------------------------------------- launcher ROM (1.6.8)
// "Start device only": the Paradise keeps its setup (language, clock, birthday, continue or reset,
// planet name), everything else becomes the smallest possible image of the same frame, so the room
// goes to the programs. Kept: every image before the first character set (screens, buttons, frames)
// and the pictures the setup and its intro showed in the Paradise emulator (Land), found by content in
// every edition.
const List<int> _launchKeepCrc = [
  0xe73bd469, 0x287aa401, 0xce0a2a87, 0x1d427953, 0x70c4b300, 0x5ebe8cc7, 0x5fe0481b, 0xb5b75196, //
  0x53ff02fb, 0x9e3c2e47, 0x1d2e4d3e, 0x786d7183, 0x7bc20923, 0xc6e5b7b7, 0xf5e876d9, 0x3a8acbb5, 0x615b997e, 0x6c829b75, //
  0xc5f0155f, 0xbff645c6, 0x4efa5d79, 0x5112672d, 0x8178c20b, 0xe56b3533, 0x0d47aefd, 0xa81e4c59, 0xfbaeefa0, 0x73b23e63,
];

Set<int> launcherKeep(RomCtx ctx) {
  final first = ctx.groups.isNotEmpty ? ctx.groups[0] : 0, crcs = _launchKeepCrc.toSet(), keep = <int>{};
  for (var i = 0; i < first; i++) {
    keep.add(i);
  }
  for (var i = 0; i < ctx.entries.length; i++) {
    if (crcs.contains(crc32(ctx.entries[i]))) keep.add(i);
  }
  return keep;
}

/// Changed entries for a launcher ROM: Map index -> tiny image (only where it saves room).
Map<int, Uint8List> launcherChanges(RomCtx ctx) {
  final keep = launcherKeep(ctx), out = <int, Uint8List>{};
  for (var i = 0; i < ctx.entries.length; i++) {
    if (keep.contains(i)) continue;
    final e = ctx.entries[i];
    final t = spriteTiny(e);
    if (t.length < e.length) out[i] = t;
  }
  return out;
}

/// Is this ROM already a launcher ROM (most images outside the kept set are tiny)?
bool isLauncher(RomCtx ctx) {
  final keep = launcherKeep(ctx);
  var n = 0, tiny = 0;
  for (var i = 0; i < ctx.entries.length; i++) {
    if (keep.contains(i)) continue;
    n++;
    final e = ctx.entries[i], h = spriteHeader(e);
    if (h.bpp == 0 && e.length <= 64 + 8 * h.numSprites) tiny++;
  }
  return n > 0 && tiny * 10 >= n * 9;
}

// ------------------------------------------------------------------ ROM
/// An opened ROM (the ctx of core.js).
class RomCtx {
  RomCtx({required this.rom, required this.root, required this.files, required this.entries, required this.groups, required this.adult, required this.egg, required this.assetEnd, required this.limit, required this.editionId, required this.edition});
  final Uint8List rom;
  final Arc2 root;
  final List<Uint8List> files; // data pack, sprite pack, texts
  final List<Uint8List> entries;
  final List<int> groups;
  final int adult, egg, assetEnd, limit, editionId;
  final String edition;
}

RomCtx openRom(Uint8List rom) {
  if (rom.length < ASSET_BASE + 16 || String.fromCharCodes(rom, 0, 8) != 'SONIXDEV') throw const FormatException('not a Paradise flash dump (SONIXDEV header missing)');
  final root = arc2Parse(rom, ASSET_BASE);
  if (root.ents.length != 3) throw FormatException('unexpected asset archive (${root.ents.length} files)');
  final files = arc2Files(rom, ASSET_BASE);
  final entries = [for (final e in packSplit(files[1])) Uint8List.fromList(e)];
  final end = ASSET_BASE + 16 + root.length;
  // free space ends at the first used 4 KB page after the assets (version page / user data)
  var limit = (end + 0xfff) & ~0xfff;
  bool page(int p) {
    for (var i = p; i < p + 0x1000 && i < rom.length; i++) {
      if (rom[i] != 0xff) return false;
    }
    return true;
  }

  while (limit < rom.length && page(limit)) {
    limit += 0x1000;
  }
  // Edition ID: on its own page (0xD49000, Tropical/Glacier 0xD29000). Previously the first
  // used page after the characters, which went wrong with DOOM or save slots next to it.
  var editionId = _editionIdOf(rom);
  if (editionId == 0) editionId = limit < rom.length ? _u32(rom, limit) : 0;
  final groups = findGroups(entries);
  return RomCtx(rom: rom, root: root, files: files, entries: entries, groups: groups, adult: groups.isNotEmpty ? findFirstAdult(entries, groups) : -1, egg: findEgg(entries), assetEnd: end, limit: limit, editionId: editionId, edition: EDITIONS[editionId] ?? 'Edition $editionId');
}

class BuiltRom {
  BuiltRom(this.rom, this.assetEnd, this.free);
  final Uint8List rom;
  final int assetEnd, free;
}

/// New ROM with replaced sprite entries (JS buildRom). `changed`: Map index -> Uint8List.
BuiltRom buildRomCtx(RomCtx ctx, Map<int, Uint8List> changed, [Uint8List? dataPack]) {
  final entries = [for (var i = 0; i < ctx.entries.length; i++) changed[i] ?? ctx.entries[i]];
  final files = [dataPack ?? ctx.files[0], packJoin(entries), ctx.files[2]];
  final root = arc2Build(files);
  final end = ASSET_BASE + root.length;
  if (end > ctx.limit) throw StateError('too big: assets would end at 0x${end.toRadixString(16)}, free space ends at 0x${ctx.limit.toRadixString(16)}');
  final out = Uint8List.fromList(ctx.rom);
  out.setAll(ASSET_BASE, root);
  if (end < ctx.assetEnd) out.fillRange(end, ctx.assetEnd, 0xff);
  verifyRom(out, changed.keys.toList());
  return BuiltRom(out, end, ctx.limit - end);
}

bool verifyRom(Uint8List rom, List<int> indices) {
  void check(int off) {
    final a = arc2Parse(rom, off);
    if (arc2Checksum(rom, off, a.length) != a.chk) throw StateError('checksum wrong at 0x${off.toRadixString(16)}');
    for (final e in a.ents) {
      if (_u32(rom, off + e.$2) == _arc2Magic) check(off + e.$2);
    }
  }

  check(ASSET_BASE);
  final entries = packSplit(arc2Files(rom, ASSET_BASE)[1]);
  for (final i in indices) {
    spriteDecodeAll(entries[i]);
  }
  return true;
}

// ------------------------------------------------------------- sheets
// Sheet of one sprite: subimages left to right, wrapping, no gaps.
class SheetLayout {
  const SheetLayout(this.cols, this.rows, this.w, this.h);
  final int cols, rows, w, h;
}

SheetLayout sheetLayout(int w, int h, int n) {
  final per = w == 0 ? n : 1280 ~/ w;
  final cols = _imax(1, _imin(n, per == 0 ? 1 : per));
  return SheetLayout(cols, (n + cols - 1) ~/ cols, w, h);
}

Rgba sheetFromSubs(List<Rgba> subs) {
  final L = sheetLayout(subs[0].w, subs[0].h, subs.length);
  final W = L.cols * L.w, H = L.rows * L.h, px = Uint8List(W * H * 4);
  for (var i = 0; i < subs.length; i++) {
    _blit(px, W, subs[i], (i % L.cols) * L.w, (i ~/ L.cols) * L.h);
  }
  return Rgba(W, H, px);
}

List<Rgba> subsFromSheet(Rgba img, int w, int h, int n) {
  final L = sheetLayout(w, h, n);
  if (img.w != L.cols * w || img.h != L.rows * h) throw StateError('sheet must be ${L.cols * w}x${L.rows * h} px, got ${img.w}x${img.h}');
  return [for (var i = 0; i < n; i++) crop(img, (i % L.cols) * w, (i ~/ L.cols) * h, w, h)];
}

// Character sheet: the 6 parts as rows, cells at fixed positions.
const int GROUP_SHEET_W = 1280, GROUP_SHEET_H = 192;
const List<int> _groupRowsY = [0, 64, 96, 128, 160, 176];

/// parts: 6 lists of subimages
Rgba groupSheet(List<List<Rgba>> parts) {
  final px = Uint8List(GROUP_SHEET_W * GROUP_SHEET_H * 4);
  for (var k = 0; k < parts.length; k++) {
    for (var i = 0; i < parts[k].length; i++) {
      _blit(px, GROUP_SHEET_W, parts[k][i], i * GROUP_PARTS[k].w, _groupRowsY[k]);
    }
  }
  return Rgba(GROUP_SHEET_W, GROUP_SHEET_H, px);
}

List<List<Rgba>> groupFromSheet(Rgba img) {
  if (img.w != GROUP_SHEET_W || img.h != GROUP_SHEET_H) throw StateError('character sheet must be ${GROUP_SHEET_W}x$GROUP_SHEET_H px, got ${img.w}x${img.h}');
  return [
    for (var k = 0; k < GROUP_PARTS.length; k++) [for (var i = 0; i < GROUP_PARTS[k].n; i++) crop(img, i * GROUP_PARTS[k].w, _groupRowsY[k], GROUP_PARTS[k].w, GROUP_PARTS[k].h)],
  ];
}

// typed array set: the source has to fit
void _set(Uint8List dst, Uint8List src, int at) {
  if (at < 0 || at + src.length > dst.length) throw RangeError('offset is out of bounds');
  dst.setAll(at, src);
}

// from core.js: blit
void _blit(Uint8List dst, int dw, Rgba s, int x0, int y0) {
  for (var y = 0; y < s.h; y++) {
    _set(dst, _view(s.data, y * s.w * 4, (y + 1) * s.w * 4), ((y0 + y) * dw + x0) * 4);
  }
}

Rgba crop(Rgba img, int x0, int y0, int w, int h) {
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    _set(px, _view(img.data, ((y0 + y) * img.w + x0) * 4, ((y0 + y) * img.w + x0 + w) * 4), y * w * 4);
  }
  return Rgba(w, h, px);
}

Rgba emptyImage(int w, int h) => Rgba(w, h, Uint8List(w * h * 4));

bool sameImage(Rgba a, Rgba b) {
  if (a.w != b.w || a.h != b.h) return false;
  for (var i = 0; i < a.data.length; i += 4) {
    if (a.data[i + 3] < 128 && b.data[i + 3] < 128) continue;
    for (var k = 0; k < 4; k++) {
      if ((a.data[i + k] - b.data[i + k]).abs() > 4) return false;
    }
  }
  return true;
}

// --------------------------------------------------------------- character card
/// A character of a card: its poses (idle1, idle2, walk1 ...) as pictures.
class CardChar {
  CardChar({required this.index, this.name, required this.baby, this.stage, required this.frames});
  final int index;
  final Rgba? name; // DIM: the picture of the name
  final bool baby;
  final int? stage; // TamaSma: 2 baby, 3 child, 4 teen, 5 adult
  final Map<String, Rgba> frames;
  CardChar withFrames(Map<String, Rgba> f) => CardChar(index: index, name: name, baby: baby, stage: stage, frames: f);
}

class CardData {
  CardData(this.chars, this.eggs, [this.kind]);
  final List<CardChar> chars;
  final List<Rgba> eggs;
  final String? kind; // 'sma' for a TamaSma card
}

const Map<int, List<int>> _dimDims = {
  3528: [42, 42], 25600: [80, 160], 2560: [32, 40], 2400: [80, 15], 4800: [160, 15], 1536: [32, 24], 7168: [64, 56], //
};
const List<String> _dimPoses = ['idle1', 'idle2', 'walk1', 'walk2', 'run1', 'run2', 'train1', 'train2', 'happy', 'sleep', 'attack', 'dodge'];
const List<String> _dimBabyPoses = ['idle1', 'idle2', 'happy', 'attack', 'sleep'];

CardData dimLoad(Uint8List raw) {
  final d = Uint8List(raw.length);
  for (var i = 0; i < raw.length; i++) {
    d[i] = raw[i] ^ 0xff;
  }
  const b = 0x100000;
  if (String.fromCharCodes(_view(d, b, b + 8)) != 'GP_SPIFI') throw const FormatException('no sprite package');
  final n = _u32(d, b + 0x48), offs = <int>[];
  for (var i = 0; i <= n; i++) {
    offs.add(_u32(d, b + 0x4c + 4 * i));
  }
  final sprites = <Rgba?>[];
  for (var i = 0; i < n; i++) {
    final dims = _dimDims[offs[i + 1] - offs[i]];
    if (dims == null) {
      sprites.add(null);
      continue;
    }
    final w = dims[0], h = dims[1], o = b + offs[i], px = Uint8List(w * h * 4);
    for (var k = 0; k < w * h; k++) {
      final v = _u16(d, o + 2 * k);
      if (v == 0x07e0) continue;
      final c = rgb565ToRgb(v);
      px[4 * k] = c[0];
      px[4 * k + 1] = c[1];
      px[4 * k + 2] = c[2];
      px[4 * k + 3] = 255;
    }
    sprites.add(Rgba(w, h, px));
  }
  bool isSize(Rgba? s, int w, int h) => s != null && s.w == w && s.h == h;
  final chars = <CardChar>[];
  var i = 0;
  while (i < n) {
    final s = sprites[i];
    if (isSize(s, 80, 15) || isSize(s, 160, 15)) {
      var j = i + 1;
      final frames = <Rgba>[];
      while (j < n && (isSize(sprites[j], 32, 24) || isSize(sprites[j], 64, 56))) {
        frames.add(sprites[j++]!);
      }
      if (j < n && isSize(sprites[j], 80, 160)) j++;
      final baby = frames.isNotEmpty && frames[0].w == 32;
      final poses = baby ? _dimBabyPoses : _dimPoses, f = <String, Rgba>{};
      for (var k = 0; k < frames.length; k++) {
        if (k < poses.length) f[poses[k]] = frames[k];
      }
      if (frames.isNotEmpty) chars.add(CardChar(index: chars.length, name: s, baby: baby, frames: f));
      i = j;
    } else {
      i++;
    }
  }
  final eggs = [
    for (final s in sprites.take(24))
      if (isSize(s, 32, 40)) s!,
  ];
  return CardData(chars, eggs);
}

// ------------------------------------------------------------ TamaSma cards (1.6.8)
// Character cards of the Tamagotchi Smart (1 or 2 MB). Header at 0x10 "BANDAINTPD...TAMASUMA"; at 0x1000 the list
// of packs (u16 0x3232, u16 count, then 16 bytes each: offset at +8, size at +16, from 0x1000). Pack 0: data (20
// tables, offsets in u16 units), pack 1: pictures (offsets of image sets, sprites, colours, pixels).
// Image set: first sprite u16, width and height in sprites u8 u8, first colour / 4 u16. Sprite: pixel index u16,
// x and y offset i16 (centre), properties u16 (bits 0-1 bpp 2/4/6/8, 4-5 width 8..64, 6-7 height, 15 four times).
// Pixels MSB first, index * sprite bytes. Colours 15 bit, bit 15 = transparent.
// Characters (table 11, 96 bytes): id, type (1 egg, 2 baby, 3 child, 4 teen, 5 adult, 6 other), frame group at +28.
// Frame groups (table 18): 53 frames of 4 bytes (first layer, count; 0xFFFF = none). Layers (table 15): a mask of
// which u16 follow (bit 0 x, 1 y, 2 sub-image, 4, 5, 8 unknown, 9 type, 10 image id). Image ids with bit 15 are
// on the card (low byte = image set), others are in the toy (accessories): left out. Type 3 body, 1 face.
bool smaDetect(Uint8List raw) => raw.length >= 0x1100 && String.fromCharCodes(raw, 0x10, 0x1A) == 'BANDAINTPD' && String.fromCharCodes(raw, 0x20, 0x28) == 'TAMASUMA';

const Map<String, int> _smaPoses = {'idle1': 1, 'idle2': 2, 'happy': 3, 'walk1': 22, 'walk2': 23, 'run1': 22, 'run2': 23, 'train1': 11, 'train2': 12, 'sleep': 1, 'attack': 11, 'dodge': 7};

class _SmaSprite {
  _SmaSprite(this.idx, this.ox, this.oy, this.bpp, this.w, this.h);
  final int idx, ox, oy, bpp, w, h;
}

class _SmaLayer {
  int x = 0, y = 0, sub = 0, type = 0, img = 0;
}

CardData smaLoad(Uint8List raw) {
  if (!smaDetect(raw)) throw const FormatException('no TamaSma card');
  final d = raw;
  const B = 0x1000;
  int s16(int o) {
    final v = _u16(d, o);
    return v > 32767 ? v - 65536 : v;
  }

  if (_u16(d, B) != 0x3232) throw const FormatException('no pack list');
  final dp = B + _u32(d, B + 8), sp = B + _u32(d, B + 24);
  final to = [for (var i = 0; i < 20; i++) dp + _u32(d, dp + 4 * i) * 2];
  // pictures
  final io = sp + _u32(d, sp), so = sp + _u32(d, sp + 4), po = sp + _u32(d, sp + 8), xo = sp + _u32(d, sp + 12);
  const dim = [8, 16, 32, 64];
  final sprites = <_SmaSprite>[];
  for (var o = so; o + 8 <= po; o += 8) {
    final pr = _u16(d, o + 6), q = pr >> 15, bpp = const [2, 4, 6, 8][pr & 3];
    final w = dim[(pr >> 4) & 3] * (q != 0 ? 4 : 1), h = dim[(pr >> 6) & 3] * (q != 0 ? 4 : 1);
    sprites.add(_SmaSprite(_u16(d, o), s16(o + 2), s16(o + 4), bpp, w, h));
  }
  final sets = <List<int>>[]; // fs, ws, hs, pal
  for (var o = io; o + 6 <= so; o += 6) {
    sets.add([_u16(d, o), _b(d, o + 2), _b(d, o + 3), _u16(d, o + 4)]);
  }
  final cache = <int, (Rgba, int, int)>{};
  (Rgba, int, int)? subimage(int si, int sub) {
    final key = si * 4096 + sub;
    final hit = cache[key];
    if (hit != null) return hit;
    if (si >= sets.length) return null;
    final st = sets[si];
    final fs = st[0], ws = st[1], hs = st[2], pal = st[3];
    if (fs >= sprites.length) return null;
    final s0 = sprites[fs];
    final W = ws * s0.w, H = hs * s0.h, img = emptyImage(W, H), first = fs + sub * ws * hs;
    for (var r = 0; r < hs; r++) {
      for (var c = 0; c < ws; c++) {
        final at = first + r * ws + c;
        if (at >= sprites.length) return null;
        final sp1 = sprites[at];
        final n = sp1.w * sp1.h * sp1.bpp ~/ 8, base = xo + sp1.idx * n;
        for (var i = 0; i < sp1.w * sp1.h; i++) {
          final bit = i * sp1.bpp;
          var v = 0;
          for (var k = 0; k < sp1.bpp; k++) {
            final b = bit + k;
            v = (v << 1) | ((_b(d, base + (b >> 3)) >> (7 - (b & 7))) & 1);
          }
          final col = _u16(d, po + 2 * (pal * 4 + v));
          if ((col >> 15) != 0) continue;
          final o = ((r * sp1.h + (i ~/ sp1.w)) * W + c * sp1.w + (i % sp1.w)) * 4;
          if (o + 4 > img.data.length) throw RangeError('offset is out of bounds');
          img.data[o] = ((col >> 10) & 31) << 3;
          img.data[o + 1] = ((col >> 5) & 31) << 3;
          img.data[o + 2] = (col & 31) << 3;
          img.data[o + 3] = 255;
        }
      }
    }
    if (first >= sprites.length) throw StateError('image set without sprites');
    final f = sprites[first];
    final res = (img, f.ox - (s0.w >> 1), f.oy - (s0.h >> 1));
    cache[key] = res;
    return res;
  }

  // frames
  final lo = to[15], ls = to[16] - to[15], layers = <_SmaLayer>[];
  for (var i = 0; i + 2 <= ls;) {
    final m = _u16(d, lo + i), L = _SmaLayer();
    for (final bit in const [0, 1, 2, 4, 5, 8, 9, 10]) {
      if ((m & (1 << bit)) == 0) continue;
      i += 2;
      switch (bit) {
        case 0:
          L.x = s16(lo + i);
        case 1:
          L.y = s16(lo + i);
        case 2:
          L.sub = _u16(d, lo + i);
        case 9:
          L.type = _u16(d, lo + i);
        case 10:
          L.img = _u16(d, lo + i);
      }
    }
    layers.add(L);
    i += 2;
  }
  final fo = to[18], fsz = to[19] - to[18], frames = <List<_SmaLayer>?>[];
  for (var k = 0; k + 4 <= fsz; k += 4) {
    final li = _u16(d, fo + k), n = _u16(d, fo + k + 2);
    frames.add(li == 0xFFFF ? null : layers.sublist(_imin(li, layers.length), _imin(li + n, layers.length)));
  }
  Rgba render(List<_SmaLayer>? f) {
    final can = emptyImage(128, 128);
    for (final L in f ?? const <_SmaLayer>[]) {
      if ((L.img & 0x8000) == 0 || (L.type != 1 && L.type != 3)) continue;
      final si = subimage(L.img & 0xFF, L.sub);
      if (si == null) continue;
      final (im, ox, oy) = si;
      final x0 = 64 + L.x + ox, y0 = 100 + L.y + oy;
      for (var y = 0; y < im.h; y++) {
        for (var x = 0; x < im.w; x++) {
          final s = (y * im.w + x) * 4;
          if (im.data[s + 3] == 0) continue;
          final X = x0 + x, Y = y0 + y;
          if (X < 0 || Y < 0 || X >= 128 || Y >= 128) continue;
          can.data.setRange((Y * 128 + X) * 4, (Y * 128 + X) * 4 + 4, im.data, s);
        }
      }
    }
    return can;
  }

  // characters
  final co = to[11], cs = to[12] - to[11], chars = <CardChar>[], eggs = <Rgba>[];
  for (var k = 0; k + 96 <= cs; k += 96) {
    final type = _u16(d, co + k + 2), grp = _u16(d, co + k + 28) & 0xFF;
    final fr = frames.sublist(_imin(grp * 53, frames.length), _imin(grp * 53 + 53, frames.length));
    if (type < 1 || type > 5 || fr.length < 2 || fr[1] == null) continue;
    final imgs = <String, Rgba>{};
    _smaPoses.forEach((p, i) {
      imgs[p] = render((i < fr.length ? fr[i] : null) ?? fr[1]);
    });
    // one box around all poses, so they keep their place to each other
    final bb = [128, 128, -1, -1];
    for (final im in imgs.values) {
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          if (im.data[(y * 128 + x) * 4 + 3] != 0) {
            bb[0] = _imin(bb[0], x);
            bb[1] = _imin(bb[1], y);
            bb[2] = _imax(bb[2], x);
            bb[3] = _imax(bb[3], y);
          }
        }
      }
    }
    if (bb[2] < 0) continue;
    final f = <String, Rgba>{for (final p in imgs.keys) p: crop(imgs[p]!, bb[0], bb[1], bb[2] - bb[0] + 1, bb[3] - bb[1] + 1)};
    if (type == 1) {
      eggs.add(place(f['idle1']!, 32, 40, 1));
      continue;
    }
    chars.add(CardChar(index: chars.length, baby: type == 2, stage: type, frames: f));
  }
  return CardData(chars, eggs, 'sma');
}

const List<String> _bodyPoseMap = ['idle1', 'idle2', 'walk1', 'happy', 'idle1', 'walk2', 'idle2', 'idle1', 'happy', 'run1', 'run2', 'attack', 'train1', 'dodge', 'sleep', 'sleep', 'train2', 'dodge', 'idle1', 'idle2'];
const List<String> _smallPoseMap = ['idle1', 'idle2', 'walk1', 'idle1', 'idle2', 'happy', 'idle1', 'idle2', 'happy', 'idle1', 'walk1', 'walk2', 'attack', 'train1', 'walk1', 'walk2', 'idle1', 'walk1', 'idle2', 'walk2', 'sleep', 'sleep', 'happy', 'happy'];
const Map<String, String> _babyFallback = {'walk1': 'idle1', 'walk2': 'idle2', 'run1': 'idle1', 'run2': 'idle2', 'train1': 'attack', 'train2': 'idle2', 'dodge': 'idle2'};
// from core.js: pose
Rgba _pose(CardChar ch, String name) => ch.frames[name] ?? ch.frames[_babyFallback[name] ?? 'idle1'] ?? ch.frames['idle1']!;

// a number into a Uint8ClampedArray: clamped, rounded to the nearest, halves to the even one
int _clamp8(double v) {
  if (v.isNaN || v <= 0) return 0;
  if (v >= 255) return 255;
  final f = v.floorToDouble(), r = v - f;
  final i = f.toInt();
  if (r < 0.5) return i;
  if (r > 0.5) return i + 1;
  return i.isEven ? i : i + 1;
}

/// Scale (nearest up, box down) and place bottom-centred on a W x H canvas.
Rgba place(Rgba img, int W, int H, num scale, [int? bottom]) {
  var s = img;
  if (scale != 1) {
    final nw = _imax(1, (img.w * scale + 0.5).floor()), nh = _imax(1, (img.h * scale + 0.5).floor()), px = Uint8List(nw * nh * 4);
    for (var y = 0; y < nh; y++) {
      for (var x = 0; x < nw; x++) {
        final x0 = (x / scale).floor(), y0 = (y / scale).floor(), x1 = _imax(x0 + 1, ((x + 1) / scale).floor()), y1 = _imax(y0 + 1, ((y + 1) / scale).floor());
        var r = 0, g = 0, b = 0, a = 0, cnt = 0;
        for (var yy = y0; yy < _imin(y1, img.h); yy++) {
          for (var xx = x0; xx < _imin(x1, img.w); xx++) {
            final o = (yy * img.w + xx) * 4;
            cnt++;
            final al = img.data[o + 3];
            a += al;
            r += img.data[o] * al;
            g += img.data[o + 1] * al;
            b += img.data[o + 2] * al;
          }
        }
        final o = (y * nw + x) * 4;
        if (cnt != 0 && a / cnt >= 110) {
          px[o] = _clamp8(r / a);
          px[o + 1] = _clamp8(g / a);
          px[o + 2] = _clamp8(b / a);
          px[o + 3] = 255;
        }
      }
    }
    s = Rgba(nw, nh, px);
  }
  if (s.w > W || s.h > H) {
    final fw = W / s.w, fh = H / s.h;
    return place(s, W, H, fw < fh ? fw : fh, bottom);
  }
  final out = emptyImage(W, H);
  _blit(out.data, W, s, (W - s.w) >> 1, (bottom ?? H) - s.h);
  return out;
}

/// Egg frames for the small and big egg sprite from a card (frames 0,1,4,6,7).
({List<Rgba> small, List<Rgba> big}) dimEggSubs(List<Rgba> eggs) {
  final pick = [for (final k in const [0, 1, 4, 6, 7]) eggs[_imin(k, eggs.length - 1)]];
  return (small: [for (final e in pick) place(e, 32, 32, 0.625, 28)], big: [for (final e in pick) place(e, 64, 64, 1.25, 54)]);
}

List<Rgba> _blank(int k) => [for (var i = 0; i < GROUP_PARTS[k].n; i++) emptyImage(GROUP_PARTS[k].w, GROUP_PARTS[k].h)];

/// 6 parts for a character group from a card character.
List<List<Rgba>> dimCharParts(CardChar ch, [num? bigScale, num? smallScale]) {
  bigScale ??= ch.baby ? 2 : 1;
  smallScale ??= ch.baby ? 1 : 0.5;
  final body = [for (final p in _bodyPoseMap) place(_pose(ch, p), 64, 64, bigScale)];
  final small = [for (final p in _smallPoseMap) place(_pose(ch, p), 32, 32, smallScale)];
  return [body, _blank(1), _blank(2), small, _blank(4), _blank(5)];
}

// ------------------------------------------------------------------ eyes
// The game draws the eyes as their own layer over the body, and also into the
// cell (deepest zoom). For a foreign character the eye is moved out of the body
// into that layer, and the layer is placed on the character's eye through the
// composite definitions in the data pack (5 x u16: sprite, flags, x, y, subimage;
// y is the bottom edge, x the centre). Expressions: open eye, closed = a line,
// '- -' (sleep) = empty. Measured in the emulator: hatch, field, zoom, cell.
const Set<int> _eyeOpen = {0, 3, 4, 5, 8, 10, 11, 12, 15, 16, 17}, _eyeEmpty = {7, 19};
const Set<int> _eyeOpenS = {0, 3, 5, 6, 9, 10, 11, 13}, _eyeEmptyS = {};
const List<List<Set<int>>> _eyeSteps = [
  [_eyeOpen, _eyeOpenS],
  [
    {0, 3, 8, 12, 15, 16},
    {0, 5, 6, 13}
  ],
  [
    {0, 12},
    {0, 5, 13}
  ],
  [
    {0},
    {5, 13}
  ],
];
double _lum(Uint8List d, int o) => (_b(d, o) * 3 + _b(d, o + 1) * 6 + _b(d, o + 2)) / 10;
int _po(Rgba img, int x, int y) => (y * img.w + x) * 4;

List<int> _skinColor(Rgba img, List<int> r) {
  final cnt = <int, int>{};
  for (var y = r[1] - 2; y <= r[3] + 2; y++) {
    for (var x = r[0] - 2; x <= r[2] + 2; x++) {
      if (x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]) continue;
      if (x < 0 || y < 0 || x >= img.w || y >= img.h) continue;
      final o = _po(img, x, y), d = img.data;
      if (d[o + 3] < 128 || _lum(d, o) <= 70) continue;
      final k = (d[o] << 16) | (d[o + 1] << 8) | d[o + 2];
      cnt[k] = (cnt[k] ?? 0) + 1;
    }
  }
  var best = 0, bk = 0;
  cnt.forEach((k, n) {
    if (n > best) {
      best = n;
      bk = k;
    }
  });
  return best != 0 ? [(bk >> 16) & 255, (bk >> 8) & 255, bk & 255] : [0, 0, 0];
}

Rgba _cloneImg(Rgba img) => Rgba(img.w, img.h, Uint8List.fromList(img.data));

void _inpaint(Rgba dst, Rgba src, List<int> r) {
  final skin = _skinColor(src, r), s = src.data;
  bool ok(int o) => _b(s, o + 3) >= 128 && _lum(s, o) > 70 && (_b(s, o) - skin[0]).abs() + (_b(s, o + 1) - skin[1]).abs() + (_b(s, o + 2) - skin[2]).abs() < 120;
  for (var y = r[1]; y <= r[3]; y++) {
    for (var x = r[0]; x <= r[2]; x++) {
      if (_b(s, _po(src, x, y) + 3) < 128) continue;
      var best = -1;
      for (var d = 1; d < 12 && best < 0; d++) {
        for (final c in [
          [r[0] - d, y],
          [r[2] + d, y],
          [x, r[1] - d],
          [x, r[3] + d]
        ]) {
          final xx = c[0], yy = c[1];
          if (xx < 0 || yy < 0 || xx >= src.w || yy >= src.h) continue;
          final o = _po(src, xx, yy);
          if (ok(o)) {
            best = o;
            break;
          }
        }
      }
      final o = (y * dst.w + x) * 4;
      if (o < 0 || o + 4 > dst.data.length) continue;
      if (best >= 0) {
        dst.data[o] = s[best];
        dst.data[o + 1] = s[best + 1];
        dst.data[o + 2] = s[best + 2];
        dst.data[o + 3] = s[best + 3];
      } else {
        dst.data[o] = skin[0];
        dst.data[o + 1] = skin[1];
        dst.data[o + 2] = skin[2];
        dst.data[o + 3] = 255;
      }
    }
  }
}

List<int>? _findTemplate(Rgba img, Rgba tmpl, int ax, int ay, int radius) {
  List<int>? best;
  final a = tmpl.data, b = img.data;
  for (var dy = -radius; dy <= radius; dy++) {
    for (var dx = -radius; dx <= radius; dx++) {
      final x0 = ax + dx, y0 = ay + dy;
      if (x0 < 0 || y0 < 0 || x0 + tmpl.w > img.w || y0 + tmpl.h > img.h) continue;
      var err = 0;
      for (var y = 0; y < tmpl.h; y++) {
        for (var x = 0; x < tmpl.w; x++) {
          final p = _po(tmpl, x, y), q = _po(img, x0 + x, y0 + y);
          if (a[p + 3] < 128 && b[q + 3] < 128) continue;
          if ((a[p + 3] < 128) != (b[q + 3] < 128)) {
            err++;
            continue;
          }
          if ((a[p] - b[q]).abs() + (a[p + 1] - b[q + 1]).abs() + (a[p + 2] - b[q + 2]).abs() > 60) err++;
        }
      }
      if (best == null || err < best[2]) best = [x0, y0, err];
    }
  }
  return best;
}

Rgba _shiftImg(Rgba img, int dx, int dy) {
  if (dx == 0 && dy == 0) return img;
  final out = emptyImage(img.w, img.h);
  for (var y = 0; y < img.h; y++) {
    for (var x = 0; x < img.w; x++) {
      final xx = x + dx, yy = y + dy;
      if (xx < 0 || yy < 0 || xx >= img.w || yy >= img.h) continue;
      final o = _po(img, x, y);
      out.data.setRange((yy * img.w + xx) * 4, (yy * img.w + xx) * 4 + 4, img.data, o);
    }
  }
  return out;
}

/// Remove the eye (rect in the idle1 frame) from every pose, return frames and the eye patches.
({CardChar ch, Rgba open, Rgba closed}) _dimRemoveEye(CardChar ch, List<int> r) {
  final idle = ch.frames['idle1']!;
  final tmpl = crop(idle, r[0], r[1], r[2] - r[0] + 1, r[3] - r[1] + 1);
  final frames = <String, Rgba>{};
  ch.frames.forEach((name, im) {
    final hit = _findTemplate(im, tmpl, r[0], r[1], 6);
    var im2 = im;
    if (hit != null && hit[2] <= tmpl.w * tmpl.h * 0.25) {
      im2 = _cloneImg(im);
      _inpaint(im2, im, [hit[0], hit[1], hit[0] + tmpl.w - 1, hit[1] + tmpl.h - 1]);
      im2 = _shiftImg(im2, r[0] - hit[0], r[1] - hit[1]);
    }
    frames[name] = im2;
  });
  final skin = _skinColor(idle, r);
  final open = emptyImage(idle.w, idle.h), closed = emptyImage(idle.w, idle.h);
  final d = idle.data;
  for (var y = r[1]; y <= r[3]; y++) {
    for (var x = r[0]; x <= r[2]; x++) {
      final o = _po(idle, x, y);
      if (_b(d, o + 3) >= 128 && (d[o] - skin[0]).abs() + (d[o + 1] - skin[1]).abs() + (d[o + 2] - skin[2]).abs() > 60) open.data.setRange(o, o + 4, d, o);
    }
  }
  final mid = ((r[1] + r[3]) >> 1) + 1;
  for (var x = r[0] + 1; x < r[2]; x++) {
    final o = _po(idle, x, mid);
    if (_b(d, o + 3) >= 128) closed.data.setAll(o, const [16, 16, 24, 255]);
  }
  return (ch: ch.withFrames(frames), open: open, closed: closed);
}

/// Guess the eye: bright pixel next to dark ones in the upper part. Returns a rect or null.
List<int>? dimGuessEye(CardChar ch) {
  final im = ch.frames['idle1']!, d = im.data;
  final bb = [im.w, im.h, -1, -1];
  for (var y = 0; y < im.h; y++) {
    for (var x = 0; x < im.w; x++) {
      if (d[_po(im, x, y) + 3] >= 128) {
        bb[0] = _imin(bb[0], x);
        bb[1] = _imin(bb[1], y);
        bb[2] = _imax(bb[2], x);
        bb[3] = _imax(bb[3], y);
      }
    }
  }
  if (bb[2] < 0) return null;
  double? bestScore;
  var bx = 0, by = 0;
  for (var y = bb[1]; y < bb[1] + (bb[3] - bb[1]) * 0.6; y++) {
    for (var x = bb[0]; x <= bb[2]; x++) {
      final o = _po(im, x, y);
      if (d[o + 3] < 128 || _lum(d, o) < 200) continue;
      var dark = 0;
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          final xx = x + dx, yy = y + dy;
          if (xx < 0 || yy < 0 || xx >= im.w || yy >= im.h) continue;
          final q = _po(im, xx, yy);
          if (d[q + 3] >= 128 && _lum(d, q) < 60) dark++;
        }
      }
      final score = dark * 2 - (y - bb[1]) * 0.2;
      if (dark >= 2 && (bestScore == null || score > bestScore)) {
        bestScore = score;
        bx = x;
        by = y;
      }
    }
  }
  return bestScore != null ? eyeRectAt(ch, bx, by) : null;
}

/// Rect around the eye at (x, y): all non-skin pixels within 5 px.
List<int> eyeRectAt(CardChar ch, int x, int y) {
  final im = ch.frames['idle1']!, d = im.data;
  final skin = _skinColor(im, [x - 4, y - 4, x + 4, y + 4]);
  final r = [x, y, x, y];
  for (var yy = _imax(0, y - 5); yy <= _imin(im.h - 1, y + 5); yy++) {
    for (var xx = _imax(0, x - 5); xx <= _imin(im.w - 1, x + 5); xx++) {
      final o = _po(im, xx, yy);
      if (_b(d, o + 3) < 128) continue;
      if ((_b(d, o) - skin[0]).abs() + (_b(d, o + 1) - skin[1]).abs() + (_b(d, o + 2) - skin[2]).abs() > 60) {
        r[0] = _imin(r[0], xx);
        r[1] = _imin(r[1], yy);
        r[2] = _imax(r[2], xx);
        r[3] = _imax(r[3], yy);
      }
    }
  }
  return r;
}

/// One size of a character with its eye layer: bodies, the eye pictures of every expression, the
/// open (lo), closed (lc) and empty (em) layer and where the layer sits (off: dx, top).
class EyeLayer {
  EyeLayer(this.body, this.eyes, this.lo, this.lc, this.em, this.off);
  final List<Rgba> body, eyes;
  final Rgba lo, lc, em;
  final List<int> off;
}

class EyeParts {
  EyeParts(this.parts, this.eyeBig, this.eyeSmall, this.big, this.small);
  final List<List<Rgba>> parts;
  final List<int> eyeBig, eyeSmall;
  final EyeLayer big, small;
}

/// Character parts with eye layer. Returns parts, eyeBig [dx,top], eyeSmall [dx,top] or null.
EyeParts? dimCharPartsWithEyes(CardChar ch, List<int> rect, [num? bigScale, num? smallScale]) {
  final bs = bigScale ?? (ch.baby ? 2 : 1), ss = smallScale ?? (ch.baby ? 1 : 0.5);
  final rm = _dimRemoveEye(ch, rect);
  final idle = ch.frames['idle1']!;
  final mask = emptyImage(idle.w, idle.h);
  for (var y = rect[1]; y <= rect[3]; y++) {
    for (var x = rect[0]; x <= rect[2]; x++) {
      final o = (y * mask.w + x) * 4;
      if (o < 0 || o + 4 > mask.data.length) throw RangeError('offset is out of bounds');
      mask.data.fillRange(o, o + 4, 255);
    }
  }
  EyeLayer? one(int W, int H, int eyeH, num scale, List<String> poses, int n, Set<int> openSet, Set<int> emptySet) {
    final m = place(mask, W, H, scale);
    final bb = [W, H, -1, -1];
    for (var y = 0; y < H; y++) {
      for (var x = 0; x < W; x++) {
        if (m.data[(y * W + x) * 4 + 3] != 0) {
          bb[0] = _imin(bb[0], x);
          bb[1] = _imin(bb[1], y);
          bb[2] = _imax(bb[2], x);
          bb[3] = _imax(bb[3], y);
        }
      }
    }
    if (bb[2] < 0) return null;
    final top = _imax(0, _imin(H - eyeH, bb[1] - (eyeH >> 2)));
    var dx = ((bb[0] + bb[2] + 1) >> 1) - (W >> 1);
    if (((bb[0] - dx) & 1) != 0) dx += 1; // even start column packs better (4 bpp)
    final body = [for (final p in poses) place(_pose(rm.ch, p), W, H, scale)];
    Rgba layer(Rgba patch) => crop(_shiftImg(place(patch, W, H, scale), -dx, 0), 0, top, W, eyeH);
    final lo = layer(rm.open), lc = layer(rm.closed), em = emptyImage(W, eyeH);
    final eyes = [for (var j = 0; j < n; j++) emptySet.contains(j) ? em : (openSet.contains(j) ? lo : lc)];
    return EyeLayer(body, eyes, lo, lc, em, [dx, top]);
  }

  final big = one(64, 64, 32, bs, _bodyPoseMap, 20, _eyeOpen, _eyeEmpty);
  final small = one(32, 32, 16, ss, _smallPoseMap, 14, _eyeOpenS, _eyeEmptyS);
  if (big == null || small == null) return null;
  return EyeParts([big.body, big.eyes, _blank(2), small.body, small.eyes, _blank(5)], big.off, small.off, big, small);
}

/// Fewer open expressions until the eye sprite fits its original byte length.
List<List<Rgba>> eyeVariants(EyeLayer layer, bool isBig) {
  final n = isBig ? 20 : 14, empty = isBig ? _eyeEmpty : _eyeEmptyS;
  return [
    for (final st in _eyeSteps) [for (var j = 0; j < n; j++) empty.contains(j) ? layer.em : (st[isBig ? 0 : 1].contains(j) ? layer.lo : layer.lc)],
  ];
}

int _s16v(int v) => v > 32767 ? v - 65536 : v;

// 1.6.8 (EYE_V2): the layer table of the data pack read the way the game reads it. A layer is a mask word, then one
// word per set bit (0 x, 1 y, 2 sub-image, 3..8 other, 9 type, 10 picture), the picture comes last. x and y are the
// centre of the picture. Frames (table 18) point into it. The old scan took the word after the picture as the start
// of its fields, which are those of the next layer (eyes moved the mouth). EYE_V2 = false brings the old way back.
const bool EYE_V2 = true;

/// A layer of the data pack: mask, centre, sub-image, type, picture and where its x and y words are.
class ParaLayer {
  ParaLayer(this.m);
  final int m;
  int x = 0, y = 0, sub = 0, type = 0, img = -1, ox = -1, oy = -1;
  Map<String, int> toJson() => {'m': m, 'x': x, 'y': y, 'sub': sub, 'type': type, 'img': img, 'ox': ox, 'oy': oy};
}

class ParaLayers {
  ParaLayers(this.layers, this.frames);
  final List<ParaLayer> layers;
  final List<List<ParaLayer>> frames; // the same objects as in layers
}

ParaLayers? paraLayers(Uint8List dp) {
  int u(int o) => _u16(dp, o);
  int U(int o) => (u(o) | (u(o + 2) << 16)) & 0xFFFFFFFF;
  final to = [for (var i = 0; i < 20; i++) U(4 * i) * 2];
  final lo = to[15], le = to[16], fo = to[18], fe = to[19];
  if (!(lo < le && le <= dp.length && fo < fe && fe <= dp.length)) return null;
  final layers = <ParaLayer>[];
  for (var i = lo; i + 2 <= le;) {
    final m = u(i);
    if ((m & 0xF800) != 0) return null;
    final L = ParaLayer(m);
    for (var b = 0; b <= 10; b++) {
      if ((m & (1 << b)) == 0) continue;
      i += 2;
      if (b == 0) {
        L.x = _s16v(u(i));
        L.ox = i;
      } else if (b == 1) {
        L.y = _s16v(u(i));
        L.oy = i;
      } else if (b == 2) {
        L.sub = u(i);
      } else if (b == 9) {
        L.type = u(i);
      } else if (b == 10) {
        L.img = u(i);
      }
    }
    layers.add(L);
    i += 2;
  }
  final frames = <List<ParaLayer>>[];
  for (var k = fo; k + 4 <= fe; k += 4) {
    final li = u(k), n = u(k + 2);
    if (li != 0xFFFF && li + n <= layers.length) frames.add(layers.sublist(li, li + n));
  }
  return ParaLayers(layers, frames);
}

ParaLayer? _find(List<ParaLayer> f, int id) {
  for (final l in f) {
    if (l.img == id) return l;
  }
  return null;
}

// body and eye layer of every frame showing both (each eye layer once); null when the table cannot be read
// from core.js: eyePairs
List<(ParaLayer b, ParaLayer e)>? _eyePairs(Uint8List dp, int bodyId, int eyeId) {
  final P = paraLayers(dp);
  if (P == null) return null;
  final out = <(ParaLayer, ParaLayer)>[], seen = Set<ParaLayer>.identity();
  for (final f in P.frames) {
    final b = _find(f, bodyId), e = _find(f, eyeId);
    if (b == null || e == null || seen.contains(e) || e.ox < 0 || e.oy < 0) continue;
    seen.add(e);
    out.add((b, e));
  }
  return out;
}

/// A changed data pack and how many entries were changed.
class EyeMoved {
  EyeMoved(this.dataPack, this.count);
  final Uint8List dataPack;
  final int count;
}

// from core.js: eyeMove
EyeMoved? _eyeMove(Uint8List dataPack, int bodyId, int eyeId, List<int> Function(ParaLayer b, ParaLayer e) fn) {
  final pr = _eyePairs(dataPack, bodyId, eyeId);
  if (pr == null) return null;
  final d = Uint8List.fromList(dataPack);
  for (final (b, e) in pr) {
    final v = fn(b, e);
    _w16(d, e.ox, v[0] & 0xffff);
    _w16(d, e.oy, v[1] & 0xffff);
  }
  return EyeMoved(d, pr.length);
}

// the old scan of the composite definitions (when the layer table cannot be read)
EyeMoved _eyeScan(Uint8List dataPack, int bodyId, int eyeId, List<int> Function(int Function(int) w, int i, int j) fn) {
  final d = Uint8List.fromList(dataPack);
  final n = d.length >> 1;
  var count = 0;
  int w(int i) => d[2 * i] | (d[2 * i + 1] << 8);
  for (var i = 0; i < n - 12; i++) {
    if (w(i) != bodyId || w(i + 1) < 1000 || w(i + 1) > 1600 || w(i + 4) > 40) continue;
    for (var j = i + 5; j < i + 12; j++) {
      if (w(j) == eyeId && w(j + 1) >= 1000 && w(j + 1) <= 1600) {
        final v = fn(w, i, j);
        _w16(d, 2 * (j + 2), v[0] & 0xffff);
        _w16(d, 2 * (j + 3), v[1] & 0xffff);
        count++;
        break;
      }
    }
  }
  return EyeMoved(d, count);
}

/// Hide a character's eye layer on the field: move every eye entry far off screen.
/// The eye sprite itself stays untouched, so the cell keeps the original eyes with all moods.
EyeMoved hideEyes(Uint8List dataPack, int bodyId, int eyeId, [int far = 2000]) {
  final v2 = _eyeMove(dataPack, bodyId, eyeId, (b, e) => [b.x + far, b.y - far]);
  if (v2 != null) return v2;
  return _eyeScan(dataPack, bodyId, eyeId, (w, i, j) => [_s16v(w(i + 2)) + far, _s16v(w(i + 3)) - far]);
}

/// Place the eye layer of a character at (dx, top) relative to its body in every composite definition.
EyeMoved setEyeOffset(Uint8List dataPack, int bodyId, int eyeId, int hBody, int hEye, int dx, int top) {
  // EYE_V2: same width; centres: eye top = body top + top
  final v2 = _eyeMove(dataPack, bodyId, eyeId, (b, e) => [b.x + dx, b.y - (hBody >> 1) + top + (hEye >> 1)]);
  if (v2 != null) return v2;
  return _eyeScan(dataPack, bodyId, eyeId, (w, i, j) => [_s16v(w(i + 2)) + dx, _s16v(w(i + 3)) + top - (hBody - hEye)]);
}

/// The first composite entry of a character: sub-images of body and eyes and the eye layer's
/// offset (for a preview).
class EyeFirst {
  EyeFirst(this.bs, this.es, this.dx, this.dy, [this.centred = false]);
  final int bs, es, dx, dy;
  final bool centred;
  Map<String, Object> toJson() => {'bs': bs, 'es': es, 'dx': dx, 'dy': dy, if (centred) 'centred': true};
}

EyeFirst? eyeFirst(Uint8List dataPack, int bodyId, int eyeId) {
  final pr = _eyePairs(dataPack, bodyId, eyeId);
  if (pr != null) {
    // dx, dy: top left of the eyes inside the body picture (same width; height from the caller)
    if (pr.isEmpty) return null;
    var p = pr[0];
    for (final q in pr) {
      if (q.$2.sub == 0) {
        p = q;
        break;
      }
    }
    final (b, e) = p;
    return EyeFirst(b.sub, e.sub, e.x - b.x, e.y - b.y, true);
  }
  final d = dataPack, n = d.length >> 1;
  int w(int i) => d[2 * i] | (d[2 * i + 1] << 8);
  for (var i = 0; i < n - 12; i++) {
    if (w(i) != bodyId || w(i + 1) < 1000 || w(i + 1) > 1600 || w(i + 4) > 40) continue;
    for (var j = i + 5; j < i + 12; j++) {
      if (w(j) == eyeId && w(j + 1) >= 1000 && w(j + 1) <= 1600) return EyeFirst(w(i + 4), w(j + 4), _s16v(w(j + 2)) - _s16v(w(i + 2)), _s16v(w(j + 3)) - _s16v(w(i + 3)));
    }
  }
  return null;
}

/// Eyes or mouth of a pose: sub-image, centre offset to the body, and (facePoses) where its x
/// and y words are.
class FacePart {
  FacePart(this.sub, this.dx, this.dy, [this.ox, this.oy]);
  final int sub, dx, dy;
  final int? ox, oy;
  Map<String, int> toJson() => {'sub': sub, 'dx': dx, 'dy': dy, 'ox': ?ox, 'oy': ?oy};
}

class Face {
  Face(this.bs, this.eye, this.mouth);
  final int bs;
  final FacePart? eye, mouth;
  Map<String, Object?> toJson() => {'bs': bs, 'eye': eye?.toJson(), 'mouth': mouth?.toJson()};
}

/// 1.6.8: one frame of a character for the preview: body sub-image, eyes and mouth (sub-image and centre offset to
/// the body). Prefers a frame with the eyes open (sub-image 0).
Face? faceFirst(Uint8List dataPack, int bodyId, int eyeId, int mouthId) {
  final P = paraLayers(dataPack);
  if (P == null) return null;
  Face? best;
  for (final f in P.frames) {
    final b = _find(f, bodyId), e = _find(f, eyeId);
    if (b == null || e == null) continue;
    final m = _find(f, mouthId);
    final r = Face(b.sub, FacePart(e.sub, e.x - b.x, e.y - b.y), m != null ? FacePart(m.sub, m.x - b.x, m.y - b.y) : null);
    best ??= r;
    if (e.sub == 0 && m != null && m.sub == 0) return r;
    if (e.sub == 0 && m != null && best.mouth == null) best = r;
  }
  return best;
}

/// 1.6.8: every pose of a character (frames with body and eyes; each pair of eye and mouth layers once): body
/// sub-image, eyes and mouth with sub-image, centre offset to the body and where their x and y words are (to move
/// one pose alone).
List<Face> facePoses(Uint8List dataPack, int bodyId, int eyeId, int mouthId) {
  final P = paraLayers(dataPack);
  if (P == null) return [];
  final out = <Face>[], seen = <String>{};
  FacePart? part(ParaLayer? l, ParaLayer b) => l != null && l.ox >= 0 && l.oy >= 0 ? FacePart(l.sub, l.x - b.x, l.y - b.y, l.ox, l.oy) : null;
  for (final f in P.frames) {
    final b = _find(f, bodyId), e = _find(f, eyeId);
    if (b == null || e == null) continue;
    final m = _find(f, mouthId), key = '${e.ox}:${m != null ? m.ox : -1}';
    if (!seen.add(key)) continue;
    out.add(Face(b.sub, part(e, b), part(m, b)));
  }
  return out;
}

/// move single layers: list of (ox, oy, dx, dy) (word positions from facePoses)
Uint8List layersMove(Uint8List dataPack, List<(int ox, int oy, int dx, int dy)> list) {
  final d = Uint8List.fromList(dataPack);
  int r(int o) => _s16v(_u16(d, o));
  for (final (ox, oy, dx, dy) in list) {
    if (ox < 0 || oy < 0) continue;
    if (ox + 1 < d.length) _w16(d, ox, (r(ox) + dx) & 0xffff);
    if (oy + 1 < d.length) _w16(d, oy, (r(oy) + dy) & 0xffff);
  }
  return d;
}

/// 1.6.8: where a character's eye layer sits relative to its body, as most of its composite entries have it ([x, y]
/// of the top left corners, y counted from the top of the body), or null.
List<int>? eyeRelGet(Uint8List dataPack, int bodyId, int eyeId, int hBody, int hEye) {
  final seen = <String, int>{};
  final pr = _eyePairs(dataPack, bodyId, eyeId);
  if (pr != null) {
    for (final (b, e) in pr) {
      final k = '${e.x - b.x},${e.y - b.y + ((hBody - hEye) >> 1)}';
      seen[k] = (seen[k] ?? 0) + 1;
    }
  } else {
    final d = dataPack, n = d.length >> 1;
    int w(int i) => d[2 * i] | (d[2 * i + 1] << 8);
    for (var i = 0; i < n - 12; i++) {
      if (w(i) != bodyId || w(i + 1) < 1000 || w(i + 1) > 1600 || w(i + 4) > 40) continue;
      for (var j = i + 5; j < i + 12; j++) {
        if (w(j) == eyeId && w(j + 1) >= 1000 && w(j + 1) <= 1600) {
          final k = '${_s16v(w(j + 2)) - _s16v(w(i + 2))},${_s16v(w(j + 3)) - _s16v(w(i + 3)) + hBody - hEye}';
          seen[k] = (seen[k] ?? 0) + 1;
          break;
        }
      }
    }
  }
  String? best;
  var bn = 0;
  seen.forEach((k, c) {
    if (c > bn) {
      bn = c;
      best = k;
    }
  });
  return best?.split(',').map(int.parse).toList();
}

/// 1.6.8: move a character's eye layer by (dx, dy) in every composite entry (the animation stays as it is)
EyeMoved shiftEyes(Uint8List dataPack, int bodyId, int eyeId, int dx, int dy) {
  final v2 = _eyeMove(dataPack, bodyId, eyeId, (b, e) => [e.x + dx, e.y + dy]);
  if (v2 != null) return v2;
  return _eyeScan(dataPack, bodyId, eyeId, (w, i, j) => [_s16v(w(j + 2)) + dx, _s16v(w(j + 3)) + dy]);
}

// Known eye positions (idle frame) for the first supported card, keyed by a pixel checksum of idle1.
// Characters on that card without visible eyes: null = no eye layer.
const Map<String, List<int>?> DIM_EYE_PRESETS = {
  '108888711': [14, 19, 18, 23], '116452384': [28, 8, 33, 13], '581122605': [31, 7, 36, 12], '1245232413': [19, 20, 34, 25], //
  '1336972138': [25, 36, 36, 42], '1500027408': [27, 10, 34, 16], '1848189483': [17, 23, 24, 30], '2311689890': [26, 18, 32, 24], //
  '2355390565': [29, 25, 36, 31], '2531248920': [4, 12, 17, 16], '2626563298': [4, 11, 22, 19], '2954084235': [26, 31, 31, 36], //
  '3228635844': [25, 12, 34, 17], '3828096515': [25, 10, 30, 16], '3939049875': [22, 16, 27, 22], //
  '1999209136': null, '26973819': null,
};

/// The known eye of a card character: (known: false) when the character is not in the list,
/// otherwise its rect, or null for a character without an eye layer.
({bool known, List<int>? rect}) dimEyePreset(CardChar ch) {
  final k = crc32(ch.frames['idle1']!.data).toString();
  return DIM_EYE_PRESETS.containsKey(k) ? (known: true, rect: DIM_EYE_PRESETS[k]) : (known: false, rect: null);
}

// ------------------------------------------------------------ number test
const List<String> _digits = ['111101101101111', '010110010010111', '111001111100111', '111001111001111', '101101111001001', '111100111001111', '111100111101111', '111001001001001', '111101111101111', '111101111001111'];

Rgba numberImage(String text, int w, int h, int scale) {
  final img = emptyImage(w, h);
  void set(int x, int y, int r, int g, int b) {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    final o = (y * w + x) * 4;
    img.data[o] = r;
    img.data[o + 1] = g;
    img.data[o + 2] = b;
    img.data[o + 3] = 255;
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final edge = x == 0 || y == 0 || x == w - 1 || y == h - 1;
      set(x, y, edge ? 230 : 255, edge ? 30 : 255, edge ? 30 : 255);
    }
  }
  final tw = text.length * 4 * scale - scale, x0 = (w - tw) >> 1, y0 = (h - 5 * scale) >> 1;
  for (var i = 0; i < text.length; i++) {
    final dgt = int.tryParse(text[i]);
    if (dgt == null) throw ArgumentError('not a number: $text');
    final g = _digits[dgt];
    for (var r = 0; r < 5; r++) {
      for (var c = 0; c < 3; c++) {
        if (g[r * 3 + c] == '1') {
          for (var yy = 0; yy < scale; yy++) {
            for (var xx = 0; xx < scale; xx++) {
              set(x0 + (i * 4 + c) * scale + xx, y0 + r * scale + yy, 0, 0, 0);
            }
          }
        }
      }
    }
  }
  return img;
}

// ------------------------------------------------------------------- ZIP
class ZipFile {
  ZipFile(this.name, this.data);
  final String name;
  final Uint8List data;
}

/// Minimal ZIP writer (stored).
Uint8List zipBuild(List<ZipFile> files) {
  final local = <Uint8List>[], central = <Uint8List>[];
  var off = 0;
  for (final f in files) {
    final name = Uint8List.fromList(utf8.encode(f.name)), crc = crc32(f.data);
    final lh = Uint8List(30 + name.length);
    _w32(lh, 0, 0x04034b50);
    _w16(lh, 4, 20);
    _w16(lh, 8, 0);
    _w32(lh, 14, crc);
    _w32(lh, 18, f.data.length);
    _w32(lh, 22, f.data.length);
    _w16(lh, 26, name.length);
    lh.setAll(30, name);
    final ch = Uint8List(46 + name.length);
    _w32(ch, 0, 0x02014b50);
    _w16(ch, 4, 20);
    _w16(ch, 6, 20);
    _w32(ch, 16, crc);
    _w32(ch, 20, f.data.length);
    _w32(ch, 24, f.data.length);
    _w16(ch, 28, name.length);
    _w32(ch, 42, off);
    ch.setAll(46, name);
    local
      ..add(lh)
      ..add(f.data);
    central.add(ch);
    off += lh.length + f.data.length;
  }
  final cd = _concat(central), end = Uint8List(22);
  _w32(end, 0, 0x06054b50);
  _w16(end, 8, files.length);
  _w16(end, 10, files.length);
  _w32(end, 12, cd.length);
  _w32(end, 16, off);
  return _concat([...local, cd, end]);
}

/// ZIP reader. inflateRaw: gives the bytes of a deflated entry (sync or async).
Future<List<ZipFile>> zipRead(Uint8List buf, FutureOr<Uint8List> Function(Uint8List raw) inflateRaw) async {
  var eocd = -1;
  for (var i = buf.length - 22; i >= _imax(0, buf.length - 65557); i--) {
    if (_u32(buf, i) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw const FormatException('not a ZIP file');
  final n = _u16(buf, eocd + 10);
  var p = _u32(buf, eocd + 16);
  final out = <ZipFile>[];
  for (var k = 0; k < n; k++) {
    final method = _u16(buf, p + 10), csize = _u32(buf, p + 20), nlen = _u16(buf, p + 28), xlen = _u16(buf, p + 30), clen = _u16(buf, p + 32), lo = _u32(buf, p + 42);
    final name = utf8.decode(_view(buf, p + 46, p + 46 + nlen), allowMalformed: true);
    p += 46 + nlen + xlen + clen;
    if (name.endsWith('/')) continue;
    final start = lo + 30 + _u16(buf, lo + 26) + _u16(buf, lo + 28), raw = _view(buf, start, start + csize);
    if (method == 0) {
      out.add(ZipFile(name, Uint8List.fromList(raw)));
    } else if (method == 8) {
      out.add(ZipFile(name, await inflateRaw(raw)));
    } else {
      throw FormatException('unsupported ZIP compression in $name');
    }
  }
  return out;
}

// ------------------------------------------------------------- fields (worlds)
// What belongs to which field. Every edition carries complete sets of characters
// for several field types (1 Land, 2 Water, 3 Sky, 4 Forest, 5 Tropical, 6 Glacier):
// Land/Water/Sky ROMs types 1-3, Jade Forest 1-4, Tropical/Glacier all six.
// Per field: 1 child, 4 teens, 17 adults. Characters come from the character table
// of the data pack (30 byte records: id, ?, name index, stage, line, ..., field at
// word 7); the sprite groups follow the character ids in order (group 0 = fallback).
// Field maps are 7 sprites of 64x64x64 per field (Tropical/Glacier: plus 7 overlay
// sprites of 64x64x32), close-ups are 6 sprites of 64x64x4 per field type.
const Map<int, String> FIELD_NAMES = {1: 'Land', 2: 'Water', 3: 'Sky', 4: 'Forest', 5: 'Tropical', 6: 'Glacier'};

/// A record of the character table: id, graphic number, text index of the name (+1), stage,
/// line, field type; group: its first sprite entry (set by [charGroups]).
class CharRec {
  CharRec({required this.id, required this.gfx, required this.name, required this.stage, required this.line, required this.field});
  final int id, gfx, name, stage, line, field;
  int? group;
  Map<String, int> toJson() => {'id': id, 'gfx': gfx, 'name': name, 'stage': stage, 'line': line, 'field': field, 'group': ?group};
}

List<CharRec> charTable(Uint8List dp) {
  final n = _u32(dp, 0);
  for (var t = 0; t < _imin(n, 40); t++) {
    final a = _u32(dp, 4 + 4 * t) * 2, b = _u32(dp, 8 + 4 * t) * 2;
    if (b > a && b <= dp.length && (b - a) % 30 == 0 && b - a >= 60 && _u16(dp, a) == 0xFFFF && _u16(dp, a + 30) == 1000) {
      return [
        for (var o = a; o < b; o += 30) CharRec(id: _u16(dp, o), gfx: _u16(dp, o + 2), name: _u16(dp, o + 4) + 1, stage: _u16(dp, o + 6), line: _u16(dp, o + 8), field: _u16(dp, o + 14)),
      ];
    }
  }
  return [];
}

// 1.7.6 GFX_MAP: the characters with their sprite group. Up to Tropical/Glacier the groups follow the character ids in
// order. Neon Planets has more characters than groups (the children and teens of the old fields share one, some new
// adults reuse old ones): there the second word of a record (graphic number, group 0 = the one of id 1000) counts.
List<CharRec> charGroups(RomCtx ctx) {
  final all = charTable(ctx.files[0]), chars = [
    for (final c in all)
      if (c.id > 1000 && c.id < 9000) c,
  ];
  if (chars.length + 1 == ctx.groups.length) {
    for (var i = 0; i < chars.length; i++) {
      chars[i].group = ctx.groups[i + 1];
    }
    return chars;
  }
  CharRec? c0, c1;
  for (final c in all) {
    if (c.id == 1000) {
      c0 = c;
      break;
    }
  }
  for (final c in chars) {
    if (c.id == 1001) {
      c1 = c;
      break;
    }
  }
  if (c0 == null || c1 == null || c1.gfx != c0.gfx + 1) return [];
  final out = <CharRec>[];
  for (final c in chars) {
    final k = c.gfx - c0.gfx;
    if (k >= 1 && k < ctx.groups.length) {
      c.group = ctx.groups[k];
      out.add(c);
    }
  }
  return out;
}

const Map<int, String> _newTypes = {7: 'Cosmic', 8: 'New Tama', 9: 'Tama'}; // Neon Planets

class FieldSet {
  FieldSet({required this.type, required this.name, required this.chars, required this.maps, required this.overlays, required this.closeups});
  final int type;
  final String? name;
  final List<CharRec> chars;
  final List<int> maps, overlays, closeups;
  Map<String, Object?> toJson() => {'type': type, if (name != null) 'name': name, 'chars': [for (final c in chars) c.toJson()], 'maps': maps, 'overlays': overlays, 'closeups': closeups};
}

List<FieldSet> fieldSets(RomCtx ctx) {
  final chars = charGroups(ctx);
  if (chars.isEmpty) return [];
  // Neon Planets (types 7 to 9): only its own planets, each figure once; no maps or close-ups
  if (chars.any((c) => _newTypes.containsKey(c.field))) {
    return [
      for (final tp in _newTypes.keys)
        if (chars.any((c) => c.field == tp))
          () {
            final seen = <int?>{};
            return FieldSet(type: tp, name: _newTypes[tp], chars: [
              for (final c in chars)
                if (c.field == tp && seen.add(c.group)) c,
            ], maps: [], overlays: [], closeups: []);
          }(),
    ];
  }
  final types = <int>{
    for (final c in chars)
      if (c.field >= 1 && c.field <= 6) c.field,
  }.toList()
    ..sort();
  int kind(int i) {
    final h = spriteHeader(ctx.entries[i]);
    return h.sw == 64 && h.sh == 64 ? _imax(1, h.iw) * _imax(1, h.ih) : 0;
  }

  final maps = <int>[];
  for (var i = 0; i < ctx.entries.length; i++) {
    if (kind(i) == 64) maps.add(i);
  }
  // close-ups: the longest run of 64x64x4 sprites, 6 per field type
  var best0 = 0, best1 = 0;
  for (var i = 0; i < ctx.entries.length; i++) {
    if (kind(i) != 4) continue;
    var j = i;
    while (j + 1 < ctx.entries.length && kind(j + 1) == 4) {
      j++;
    }
    if (j - i + 1 > best1 - best0) {
      best0 = i;
      best1 = j + 1;
    }
    i = j;
  }
  final nClose = (best1 - best0) ~/ 6;
  final nMap = maps.length ~/ 7;
  // maps belong to the highest field types present (Tropical/Glacier: Forest, Tropical, Glacier)
  final mapTypes = types.sublist(_imax(0, types.length - nMap));
  return [
    for (final tp in types)
      () {
        final m = mapTypes.indexOf(tp), maps7 = m >= 0 ? maps.sublist(_imin(7 * m, maps.length), _imin(7 * m + 7, maps.length)) : <int>[];
        final overlays = <int>[];
        if (maps7.isNotEmpty) {
          // as the JS: the seventh map (a field with fewer has no overlays)
          if (maps7.length > 6) {
            final last = maps7[6];
            for (var j = last + 1; j < last + 8 && j < ctx.entries.length && kind(j) == 32; j++) {
              overlays.add(j);
            }
          }
        }
        final close = tp <= nClose ? [for (var k = 0; k < 6; k++) best0 + 6 * (tp - 1) + k] : <int>[];
        return FieldSet(type: tp, name: FIELD_NAMES[tp], chars: [
          for (final c in chars)
            if (c.field == tp) c,
        ], maps: maps7, overlays: overlays, closeups: close);
      }(),
  ];
}

// ------------------------------------------------------------ texts (1.6.8)
// The third file of the asset archive is an ARC2 with one text table per language (JP, EN, FR, DE, PT, ES, IT and
// two Chinese ones). A table: u16 offsets (in u16 units from the table start; the first one is the number of
// entries), then the strings, u16 glyph codes ending in 0. Names (Tamas, items, fields) are entries of it. A changed
// name goes into every table with Latin letters; the strings are laid out anew, so a name may be longer.
final Map<String, int> TXT_ENC = () {
  final m = <String, int>{};
  // key order as JS objects have it: the digits first
  for (var i = 0; i < 10; i++) {
    m['$i'] = 306 + i;
  }
  m.addAll({' ': 305, '&': 375, "'": 376, '.': 381, '!': 370, '?': 388, '/': 382});
  for (var i = 0; i < 26; i++) {
    m[String.fromCharCode(65 + i)] = 318 + i;
  }
  return Map<String, int>.unmodifiable(m);
}();
final Map<int, String> _txtDec = () {
  final m = <int, String>{};
  TXT_ENC.forEach((k, v) => m[v] = k);
  m[317] = ' ';
  return m;
}();

// String.prototype.toUpperCase for the letters that become ASCII capitals (the others are dropped anyway)
String _upper(String s) {
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    if (c >= 0x61 && c <= 0x7A) {
      b.writeCharCode(c - 32);
    } else if (c == 0xDF) {
      b.write('SS'); // ß
    } else if (c == 0x131) {
      b.write('I'); // dotless i
    } else if (c == 0x17F) {
      b.write('S'); // long s
    } else if (c == 0x149) {
      b.write('N'); // ŉ becomes ʼN
    } else if (c == 0x1F0) {
      b.write('J'); // ǰ becomes J and a caron
    } else if (c == 0x1E96) {
      b.write('H'); // ẖ ẗ ẘ ẙ ẚ: capital and a mark
    } else if (c == 0x1E97) {
      b.write('T');
    } else if (c == 0x1E98) {
      b.write('W');
    } else if (c == 0x1E99) {
      b.write('Y');
    } else if (c == 0x1E9A) {
      b.write('A');
    } else if (c >= 0xFB00 && c <= 0xFB06) {
      b.write(const ['FF', 'FI', 'FL', 'FFI', 'FFL', 'ST', 'ST'][c - 0xFB00]); // ligatures
    } else {
      b.writeCharCode(c);
    }
  }
  return b.toString();
}

/// Clean a name for the Paradise font: capitals, digits, space and . & ' ! ? / ; null if nothing is left.
String? textClean(String? s) {
  final b = StringBuffer();
  for (final c in _upper(s ?? '').codeUnits) {
    final ch = String.fromCharCode(c);
    if (TXT_ENC.containsKey(ch)) b.write(ch);
  }
  final t = b.toString().replaceAll(RegExp(r' +'), ' ').trim();
  return t.isEmpty ? null : t;
}

/// A text table: its bytes, the number of entries and their offsets (in u16 units).
class TextTable {
  TextTable(this.b, this.n, this.offs);
  final Uint8List b;
  final int n;
  final List<int> offs;
}

class TextTables {
  TextTables(this.off, this.tabs);
  final int off;
  final List<TextTable> tabs;
}

TextTables? textTablesOf(Uint8List rom) {
  final root = arc2Parse(rom, ASSET_BASE), off = ASSET_BASE + root.ents[2].$2;
  if (_u32(rom, off) != _arc2Magic) return null;
  final tabs = [
    for (final b in arc2Files(rom, off))
      () {
        final n = _u16(b, 0);
        return TextTable(b, n, [for (var i = 0; i < n; i++) _u16(b, 2 * i)]);
      }(),
  ];
  return TextTables(off, tabs);
}

// from core.js: txtWords
List<int> _txtWords(TextTable t, int i) {
  final out = <int>[];
  for (var o = 2 * t.offs[i]; o + 1 < t.b.length; o += 2) {
    final c = _u16(t.b, o);
    if (c == 0) break;
    out.add(c);
  }
  return out;
}

// Latin table: its words for LAND/WATER/SKY-like entries are capitals or accented letters
bool _txtLatin(TextTable t) {
  if (t.n < 20) return false;
  final ws = _txtWords(t, 1);
  return ws.length > 2 && ws.every((c) => (c >= 305 && c <= 470) || c == 61440);
}

TextTable? _latinOf(TextTables x) {
  for (final t in x.tabs) {
    if (_txtLatin(t)) return t;
  }
  return null;
}

/// English text i (Paradise font), '' if it has other glyphs
String textGet(Uint8List rom, int i) {
  final x = textTablesOf(rom);
  if (x == null) return '';
  final t = _latinOf(x);
  if (t == null || i >= t.n) return '';
  final s = StringBuffer();
  for (final c in _txtWords(t, i)) {
    final ch = _txtDec[c];
    if (ch == null) return '';
    s.write(ch);
  }
  return s.toString().trim();
}

/// ROM with changed texts. edits: Map text index -> name (cleaned). Throws if the archive would not fit.
Uint8List textApply(Uint8List rom, Map<int, String>? edits) {
  if (edits == null || edits.isEmpty) return rom;
  final x = textTablesOf(rom);
  if (x == null) throw StateError('text tables not found');
  final tabs = <Uint8List>[];
  for (final t in x.tabs) {
    if (!_txtLatin(t)) {
      tabs.add(t.b);
      continue;
    }
    final end = t.b.length >> 1, segs = <Uint8List>[];
    for (var i = 0; i < t.n; i++) {
      final a = t.offs[i], b = i + 1 < t.n ? t.offs[i + 1] : end;
      var seg = _view(t.b, 2 * a, 2 * b);
      final nm = edits.containsKey(i) ? textClean(edits[i]) : null;
      // only an entry that is exactly its string plus the 0 is replaced (the first and the last are not)
      if (nm != null && i > 0 && i + 1 < t.n && b == a + _txtWords(t, i).length + 1) {
        final ns = Uint8List(2 * (nm.length + 1));
        for (var k = 0; k < nm.length; k++) {
          _w16(ns, 2 * k, TXT_ENC[nm[k]]!);
        }
        seg = ns;
      }
      segs.add(seg);
    }
    var pos = t.n;
    final head = Uint8List(2 * t.n);
    for (var i = 0; i < segs.length; i++) {
      if (pos > 0xFFFF) throw StateError('text table too long');
      _w16(head, 2 * i, pos);
      pos += segs[i].length >> 1;
    }
    final out = _concat([head, ...segs]);
    tabs.add((t.b.length & 1) != 0 ? _concat([out, Uint8List(1)]) : out);
  }
  final files = arc2Files(rom, ASSET_BASE);
  files[2] = arc2Build(tabs);
  final ctx = openRom(rom), root = arc2Build(files), end = ASSET_BASE + root.length;
  if (end > ctx.limit) throw StateError('too big: assets would end at 0x${end.toRadixString(16)}');
  final out = Uint8List.fromList(rom);
  out.setAll(ASSET_BASE, root);
  if (end < ctx.assetEnd) out.fillRange(end, ctx.assetEnd, 0xff);
  verifyRom(out, []);
  return out;
}
