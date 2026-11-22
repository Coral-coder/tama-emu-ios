// Paradise ROM assets: a native port of Paramix Studio's core.js (mameise, GPL-3.0): the ARC2
// asset archive at 0x111000, the sprite pack in it, and the sprite format (palette, RLE, LZ4,
// XOR, direct RGB565).

import 'dart:typed_data';

import 'bytes.dart';
import 'edition.dart';

const int assetBase = 0x111000;
const int _arc2Magic = 0x32435241; // "ARC2"

class Arc2 {
  Arc2(this.chk, this.length, this.ents);
  final int chk, length;
  final List<(int flags, int offset, int clen, int ulen)> ents;
}

Arc2 arc2Parse(Uint8List buf, int off) {
  if (u32(buf, off) != _arc2Magic) throw FormatException('no ARC2 archive at ${hex(off)}');
  final n = u32(buf, off + 12);
  final ents = <(int, int, int, int)>[];
  for (var i = 0; i < n; i++) {
    final e = off + 16 + 16 * i;
    ents.add((u32(buf, e), u32(buf, e + 4), u32(buf, e + 8), u32(buf, e + 12)));
  }
  return Arc2(u32(buf, off + 4), u32(buf, off + 8), ents);
}

List<Uint8List> packSplit(Uint8List pack) {
  final n = u32(pack, 0) ~/ 4;
  final offs = [for (var i = 0; i < n; i++) u32(pack, 4 * i)];
  return [for (var i = 0; i < n; i++) Uint8List.sublistView(pack, offs[i], i + 1 < n ? offs[i + 1] : pack.length)];
}

class SpriteHeader {
  SpriteHeader(Uint8List e)
      : dataLength = u32(e, 0),
        flags = e[4],
        bpp = e[5],
        numSprites = u16(e, 6),
        sw = e[8],
        sh = e[9],
        iw = e[12],
        ih = e[13],
        numPal = e[15],
        transp = u16(e, 16),
        palOffset = u16(e, 18),
        pixOffset = u16(e, 20);
  final int dataLength, flags, bpp, numSprites, sw, sh, iw, ih, numPal, transp, palOffset, pixOffset;
  int get width => sw * (iw < 1 ? 1 : iw);
  int get height => sh * (ih < 1 ? 1 : ih);
}

const int _fTransp = 0x04, _fLz4 = 0x08, _fRleByte = 0x20, _fRleWord = 0x40, _fXor = 0x80;
const Map<int, int> _bits = {0: 1, 1: 2, 2: 4, 3: 8};

Uint8List _rleDecode(Uint8List d, bool word) {
  final out = BytesBuilder(copy: false);
  var i = 0;
  if (!word) {
    while (i < d.length) {
      final c = d[i++];
      if (c == 0) break;
      if ((c & 0x80) != 0) {
        final n = c & 0x7f;
        out.add(d.sublist(i, (i + n).clamp(0, d.length)));
        i += n;
      } else {
        final v = i < d.length ? d[i++] : 0;
        out.add(List.filled(c, v));
      }
    }
  } else {
    while (i + 4 <= d.length) {
      final c = u32(d, i);
      i += 4;
      if (c == 0) break;
      if ((c & 0x80000000) != 0) {
        final n = (c & 0x0fffffff) * 4;
        out.add(d.sublist(i, (i + n).clamp(0, d.length)));
        i += n;
      } else {
        final w = d.sublist(i, i + 4);
        for (var r = 0; r < c; r++) {
          out.add(w);
        }
        i += 4;
      }
    }
  }
  return out.toBytes();
}

Uint8List _lz4Decode(Uint8List d) {
  final out = <int>[];
  var i = 0;
  while (i < d.length) {
    final tok = d[i++];
    var lit = tok >> 4;
    if (lit == 15) {
      int b;
      do {
        b = d[i++];
        lit += b;
      } while (b == 255 && i < d.length);
    }
    for (var k = 0; k < lit; k++) {
      out.add(d[i++]);
    }
    if (i + 2 > d.length) break;
    final off = d[i] | (d[i + 1] << 8);
    i += 2;
    var ml = tok & 15;
    if (ml == 15) {
      int b;
      do {
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

int _rgb565To8(int v, int shift, int bits) {
  final m = (1 << bits) - 1;
  return ((v >> shift) & m) * 255 ~/ m;
}

/// One decoded picture as RGBA.
class Rgba {
  Rgba(this.w, this.h, this.data);
  final int w, h;
  final Uint8List data;
}

/// Decodes sub-picture [sub] of a sprite entry (palette set [palSet]).
Rgba spriteDecode(Uint8List e, {int sub = 0, int palSet = 0}) {
  final h = SpriteHeader(e);
  final n = h.numSprites, w = h.sw, hh = h.sh, npx = w * hh;
  final iw = h.iw < 1 ? 1 : h.iw, ih = h.ih < 1 ? 1 : h.ih;
  final per = iw * ih;
  final first = sub * per;
  if (first + per > n) throw RangeError('sprite has ${n ~/ per} pictures');
  final direct = h.bpp >= 0x10;
  final cells = <List<int>>[];
  List<int>? pal;
  if (direct) {
    for (var s = first; s < first + per; s++) {
      cells.add([for (var k = 0; k < npx; k++) u16(e, h.pixOffset + 2 * (s * npx + k))]);
    }
  } else {
    final bits = _bits[h.bpp];
    if (bits == null) throw FormatException('unknown bpp ${h.bpp}');
    final ncol = 1 << bits;
    final p = palSet.clamp(0, (h.numPal < 1 ? 1 : h.numPal) - 1);
    pal = [for (var k = 0; k < ncol; k++) u16(e, h.palOffset + 2 * (p * ncol + k))];
    final comp = h.flags & (_fRleByte | _fRleWord), enc = (h.flags & _fXor) != 0;
    final bp = h.pixOffset;
    final mask = ncol - 1;
    for (var s = first; s < first + per; s++) {
      Uint8List d;
      if (comp != 0 || (h.flags & _fLz4) != 0) {
        var off = u32(e, bp + 8 * s);
        final ln = u32(e, bp + 8 * s + 4);
        final unc = (off & 0x80000000) != 0;
        off &= 0x7fffffff;
        d = Uint8List.fromList(e.sublist(bp + off, bp + off + ln));
        if (enc) {
          for (var k = 0; k < d.length; k++) {
            d[k] ^= 0x53;
          }
        }
        if (!unc) d = comp != 0 ? _rleDecode(d, (h.flags & _fRleWord) != 0) : _lz4Decode(d);
      } else {
        final sz = (npx * bits + 7) ~/ 8;
        d = Uint8List.fromList(e.sublist(bp + s * sz, bp + (s + 1) * sz));
        if (enc) {
          for (var k = 0; k < d.length; k++) {
            d[k] ^= 0x53;
          }
        }
      }
      cells.add([
        for (var k = 0; k < npx; k++) ((k * bits) >> 3) < d.length ? (d[(k * bits) >> 3] >> ((k * bits) & 7)) & mask : 0,
      ]);
    }
  }
  final W = w * iw, H = hh * ih;
  final px = Uint8List(W * H * 4);
  final transp = (h.flags & _fTransp) != 0;
  for (var gy = 0; gy < ih; gy++) {
    for (var gx = 0; gx < iw; gx++) {
      final c = cells[gy * iw + gx];
      for (var k = 0; k < npx; k++) {
        final v = c[k];
        final x = gx * w + (k % w), y = gy * hh + (k ~/ w), o = (y * W + x) * 4;
        if (transp && v == h.transp) continue;
        final rgb = pal != null ? pal[v] : v;
        px[o] = _rgb565To8(rgb, 11, 5);
        px[o + 1] = _rgb565To8(rgb, 5, 6);
        px[o + 2] = _rgb565To8(rgb, 0, 5);
        px[o + 3] = 255;
      }
    }
  }
  return Rgba(W, H, px);
}

/// The sprite entries of a Paradise ROM.
class ParadiseAssets {
  ParadiseAssets._(this.rom, this.entries, this.assetEnd);
  final Uint8List rom;
  final List<Uint8List> entries;
  final int assetEnd;

  static ParadiseAssets open(Uint8List rom) {
    if (rom.length < assetBase + 16 || asciiAt(rom, 0, 8) != 'SONIXDEV') {
      throw const FormatException('not a Paradise flash dump (SONIXDEV header missing)');
    }
    final root = arc2Parse(rom, assetBase);
    if (root.ents.length != 3) throw FormatException('unexpected asset archive (${root.ents.length} files)');
    final f1 = root.ents[1];
    final pack = Uint8List.sublistView(rom, assetBase + f1.$2, assetBase + f1.$2 + f1.$4);
    return ParadiseAssets._(rom, packSplit(pack), assetBase + 16 + root.length);
  }

  SpriteHeader header(int i) => SpriteHeader(entries[i]);

  /// The 512 x 512 field maps, in ROM order (groups of 7 per field).
  List<int> fieldMaps() {
    final out = <int>[];
    for (var i = 0; i < entries.length; i++) {
      try {
        final h = header(i);
        if (h.width == 512 && h.height == 512) out.add(i);
      } catch (_) {}
    }
    return out;
  }
}

/// The cover picture of a Paradise ROM: the field map of its edition (Land's valley, Glacier's
/// snow, Neon's planets ...), taken from the ROM itself. Null when the ROM has none.
Rgba? paradiseCover(Uint8List rom) {
  final a = ParadiseAssets.open(rom);
  final maps = a.fieldMaps();
  if (maps.isEmpty) return null;
  final ed = edition(rom);
  // which group of seven maps belongs to the edition's own field
  var group = 0;
  switch (ed?.id) {
    case 2:
      group = 1; // Water
    case 3:
      group = 2; // Sky
    case 4:
      group = 3; // Jade Forest: Land, Water, Sky, Forest
    case 5:
      group = 1; // Tropical
    case 6:
      group = 2; // Glacier
    case 7:
      group = 0; // Tropical/Glacier with the Forest home
  }
  final idx = maps[(group * 7).clamp(0, maps.length - 1)];
  return spriteDecode(a.entries[idx]);
}
