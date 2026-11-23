// Writing pictures back into a Paradise ROM: a native port of Paramix Studio's core.js encoder
// (mameise, GPL-3.0): RLE / LZ4 cell packing, the sprite re-encoder (keeping each picture's own
// palettes, or direct RGB565), the sprite pack and the ARC2 archive, and the ROM rebuild with its
// checks.

import 'dart:typed_data';

import 'bytes.dart';
import 'sprites.dart';

const int _arc2Magic = 0x32435241;
const int _fTransp = 0x04, _fLz4 = 0x08, _fRleByte = 0x20, _fRleWord = 0x40, _fXor = 0x80;
const Map<int, int> _bits = {0: 1, 1: 2, 2: 4, 3: 8};

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

int rgbTo565(int r, int g, int b) => (((r * 31 + 127) ~/ 255) << 11) | (((g * 63 + 127) ~/ 255) << 5) | ((b * 31 + 127) ~/ 255);
List<int> rgb565ToRgb(int v) => [((v >> 11) & 31) * 255 ~/ 31, ((v >> 5) & 63) * 255 ~/ 63, (v & 31) * 255 ~/ 31];

Uint8List rleEncode(List<int> data) {
  final out = <int>[];
  final lit = <int>[];
  void flush() {
    while (lit.isNotEmpty) {
      final n = lit.length < 127 ? lit.length : 127;
      out.add(0x80 | n);
      out.addAll(lit.sublist(0, n));
      lit.removeRange(0, n);
    }
  }

  var i = 0;
  while (i < data.length) {
    var j = i;
    while (j < data.length && data[j] == data[i] && j - i < 127) {
      j++;
    }
    final run = j - i;
    if (run >= 3) {
      flush();
      out.addAll([run, data[i]]);
    } else {
      for (var k = i; k < j; k++) {
        lit.add(data[k]);
      }
    }
    i = j;
  }
  flush();
  out.add(0);
  return Uint8List.fromList(out);
}

/// LZ4 block (greedy), keeping the end rules: the last 5 bytes are literals, no match in the last 12.
Uint8List lz4Encode(Uint8List src) {
  final n = src.length, out = <int>[], head = <int, List<int>>{};
  void emit(int litStart, int litEnd, int off, int ml) {
    final lit = litEnd - litStart, ln = lit >= 15 ? 15 : lit, mn = ml == 0 ? 0 : (ml - 4 >= 15 ? 15 : ml - 4);
    out.add((ln << 4) | mn);
    if (lit >= 15) {
      var r = lit - 15;
      while (r >= 255) {
        out.add(255);
        r -= 255;
      }
      out.add(r);
    }
    for (var k = litStart; k < litEnd; k++) {
      out.add(src[k]);
    }
    if (ml != 0) {
      out.addAll([off & 255, off >> 8]);
      if (ml - 4 >= 15) {
        var r = ml - 4 - 15;
        while (r >= 255) {
          out.add(255);
          r -= 255;
        }
        out.add(r);
      }
    }
  }

  int key(int i) => src[i] | (src[i + 1] << 8) | (src[i + 2] << 16) | (src[i + 3] << 24);
  var i = 0, anchor = 0;
  final lim = n - 12, mend = n - 5;
  while (i < lim) {
    final k = key(i);
    final list = head[k];
    var best = 0, bo = 0;
    if (list != null) {
      for (var q = list.length - 1; q >= 0; q--) {
        final c = list[q];
        if (i - c > 0xFFFF) break;
        var ml = 0;
        while (i + ml < mend && src[c + ml] == src[i + ml]) {
          ml++;
        }
        if (ml > best) {
          best = ml;
          bo = i - c;
        }
      }
    }
    if (best >= 4) {
      for (var p = i; p < i + best && p < lim; p++) {
        (head[key(p)] ??= []).add(p);
      }
      emit(anchor, i, bo, best);
      i += best;
      anchor = i;
      continue;
    }
    (head[k] ??= []).add(i);
    i++;
  }
  emit(anchor, n, 0, 0);
  return Uint8List.fromList(out);
}

int _nearest(List<List<int>> pal, int r, int g, int b, int skip) {
  var bi = 0, bd = 1 << 62;
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

void _writeHeader(Uint8List b, {required int dataLength, required int flags, required int bpp, required int n, required SpriteHeader h, required int palBpp, required int numPal, required int transp, required int palOffset, required int pixOffset, required Uint8List orig}) {
  _w32(b, 0, dataLength);
  b[4] = flags;
  b[5] = bpp;
  _w16(b, 6, n);
  b[8] = h.sw;
  b[9] = h.sh;
  b[10] = orig[10];
  b[11] = orig[11];
  b[12] = h.iw;
  b[13] = h.ih;
  b[14] = palBpp;
  b[15] = numPal;
  _w16(b, 16, transp);
  _w16(b, 18, palOffset);
  _w16(b, 20, pixOffset);
  _w16(b, 22, 0);
}

/// The palette of a sprite (set 0) as RGB, and whether it has a transparent index (which).
(List<List<int>> palette, int transparent) spritePalette(Uint8List e) {
  final h = SpriteHeader(e);
  if (h.bpp >= 0x10) return (<List<int>>[], -1);
  final ncol = 1 << _bits[h.bpp]!;
  final pal = [for (var k = 0; k < ncol; k++) rgb565ToRgb(u16(e, h.palOffset + 2 * k))];
  return (pal, (h.flags & _fTransp) != 0 ? h.transp : -1);
}

/// Re-encodes a sprite from its pictures (RGBA, one per sub-picture, the size of the original),
/// keeping the cell size, the grid, the anchor and the original palettes (so the game's colour
/// variants keep working). Pixels take the nearest colour of the palette; transparent stays
/// transparent. Direct-colour sprites are written as RGB565.
Uint8List spriteEncode(Uint8List orig, List<Rgba> subs) {
  final h = SpriteHeader(orig);
  final n = h.numSprites, w = h.sw, hh = h.sh, npx = w * hh;
  final iw = h.iw < 1 ? 1 : h.iw, ih = h.ih < 1 ? 1 : h.ih;
  final W = w * iw, H = hh * ih;
  if (subs.length * iw * ih != n) throw ArgumentError('picture count does not match');
  for (final s in subs) {
    if (s.w != W || s.h != H) throw ArgumentError('picture size does not match');
  }
  List<int> px(int si, int gx, int gy, int k) {
    final x = gx * w + (k % w), y = gy * hh + (k ~/ w), o = (y * W + x) * 4;
    final d = subs[si].data;
    return [d[o], d[o + 1], d[o + 2], d[o + 3]];
  }

  final cells = <(int, int, int)>[];
  for (var si = 0; si < subs.length; si++) {
    for (var gy = 0; gy < ih; gy++) {
      for (var gx = 0; gx < iw; gx++) {
        cells.add((si, gx, gy));
      }
    }
  }
  final hasT = (h.flags & _fTransp) != 0;

  if (h.bpp >= 0x10) {
    final tr = h.transp;
    final out = Uint8List(24 + n * npx * 2);
    var s = 0;
    for (final (si, gx, gy) in cells) {
      for (var k = 0; k < npx; k++) {
        final p = px(si, gx, gy, k);
        var v = (hasT && p[3] < 128) ? tr : rgbTo565(p[0], p[1], p[2]);
        if (hasT && p[3] >= 128 && v == tr) v ^= 1;
        _w16(out, 24 + 2 * (s * npx + k), v);
      }
      s++;
    }
    _writeHeader(out, dataLength: out.length, flags: h.flags & ~(_fRleByte | _fRleWord | _fXor), bpp: 0x11, n: n, h: h, palBpp: 0x11, numPal: 0, transp: tr, palOffset: 24, pixOffset: 24, orig: orig);
    return out;
  }

  final bits = _bits[h.bpp]!;
  final ncol = 1 << bits;
  final (pal, transpIdx) = spritePalette(orig);
  final palBlock = Uint8List.fromList(orig.sublist(h.palOffset, h.palOffset + 2 * ncol * (h.numPal < 1 ? 1 : h.numPal)));
  final cache = <int, int>{};
  int indexOf(List<int> p) {
    if (p[3] < 128 && transpIdx >= 0) return transpIdx;
    final key = (p[0] << 16) | (p[1] << 8) | p[2];
    return cache[key] ??= _nearest(pal, p[0], p[1], p[2], transpIdx);
  }

  final lz = (h.flags & _fLz4) != 0 && (h.flags & (_fRleByte | _fRleWord)) == 0;
  final datas = <Uint8List>[];
  for (final (si, gx, gy) in cells) {
    final raw = Uint8List((npx * bits + 7) ~/ 8);
    for (var k = 0; k < npx; k++) {
      final v = indexOf(px(si, gx, gy, k));
      final bit = k * bits;
      raw[bit >> 3] |= v << (bit & 7);
    }
    final enc = lz ? lz4Encode(raw) : rleEncode(raw);
    for (var k = 0; k < enc.length; k++) {
      enc[k] ^= 0x53;
    }
    datas.add(enc);
  }
  const palOff = 24;
  final pixOff = palOff + palBlock.length, tblLen = 8 * n;
  var pos = pixOff + tblLen;
  final tbl = <(int, int)>[];
  final body = BytesBuilder(copy: false);
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
  pos = (pos + 3) & ~3; // a length in whole words, like every original (the playdate sums words)
  final out = Uint8List(pos);
  final useT = transpIdx >= 0;
  _writeHeader(out,
      dataLength: pos,
      flags: _fXor | (lz ? _fLz4 : _fRleByte) | 0x03 | (useT ? _fTransp : 0),
      bpp: h.bpp,
      n: n,
      h: h,
      palBpp: 0x11,
      numPal: h.numPal < 1 ? 1 : h.numPal,
      transp: useT ? transpIdx : 0,
      palOffset: palOff,
      pixOffset: pixOff,
      orig: orig);
  out.setAll(palOff, palBlock);
  for (var i = 0; i < tbl.length; i++) {
    _w32(out, pixOff + 8 * i, tbl[i].$1);
    _w32(out, pixOff + 8 * i + 4, tbl[i].$2);
  }
  out.setAll(pixOff + tblLen, body.takeBytes());
  // the game checks the length of some pictures (eyes): never shorter than the original
  if (out.length < orig.length) {
    final padded = Uint8List(orig.length)..setAll(0, out);
    _w32(padded, 0, orig.length);
    return padded;
  }
  return out;
}

/// Every sub-picture of a sprite as RGBA.
List<Rgba> spritePictures(Uint8List e) {
  final h = SpriteHeader(e);
  final per = (h.iw < 1 ? 1 : h.iw) * (h.ih < 1 ? 1 : h.ih);
  return [for (var s = 0; s < h.numSprites ~/ per; s++) spriteDecode(e, sub: s)];
}

Uint8List _packJoin(List<Uint8List> entries) {
  final n = entries.length;
  var pos = 4 * n;
  final offs = <int>[];
  final parts = BytesBuilder(copy: false);
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
  return (BytesBuilder(copy: false)
        ..add(head)
        ..add(parts.takeBytes()))
      .takeBytes();
}

int _arc2Checksum(Uint8List buf, int off, int length) {
  var s = 0;
  final end = off + 16 + length;
  for (var i = off + 8; i < end; i++) {
    s = (s + buf[i]) & 0xFFFFFFFF;
  }
  return s;
}

Uint8List _arc2Build(List<Uint8List> files) {
  final n = files.length;
  var pos = 16 + 16 * n;
  final ents = <List<int>>[];
  final body = BytesBuilder(copy: false);
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
  out.setAll(16 + 16 * n, body.takeBytes());
  _w32(out, 4, _arc2Checksum(out, 0, pos - 16));
  return out;
}

/// A new ROM with some pictures replaced ([changed]: entry index → encoded sprite). Checked as
/// Paramix does: the archive's checksums and each changed picture decoding again.
Uint8List buildRom(Uint8List rom, Map<int, Uint8List> changed) {
  final root = arc2Parse(rom, assetBase);
  final files = [
    for (final e in root.ents) Uint8List.fromList(rom.sublist(assetBase + e.$2, assetBase + e.$2 + e.$4)),
  ];
  final entries = packSplit(files[1]);
  final assetEnd = assetBase + 16 + root.length;
  var limit = (assetEnd + 0xfff) & ~0xfff;
  bool free(int p) {
    for (var i = p; i < p + 0x1000 && i < rom.length; i++) {
      if (rom[i] != 0xff) return false;
    }
    return true;
  }

  while (limit < rom.length && free(limit)) {
    limit += 0x1000;
  }
  final newEntries = [for (var i = 0; i < entries.length; i++) changed[i] ?? entries[i]];
  final arc = _arc2Build([files[0], _packJoin(newEntries), files[2]]);
  final end = assetBase + arc.length;
  if (end > limit) throw StateError('the pictures no longer fit: they would end at 0x${end.toRadixString(16)}, the free space ends at 0x${limit.toRadixString(16)}');
  final out = Uint8List.fromList(rom);
  out.setAll(assetBase, arc);
  if (end < assetEnd) out.fillRange(end, assetEnd, 0xff);
  // checks
  final a = arc2Parse(out, assetBase);
  if (_arc2Checksum(out, assetBase, a.length) != a.chk) throw StateError('archive checksum wrong');
  final check = ParadiseAssets.open(out);
  for (final i in changed.keys) {
    spriteDecode(check.entries[i]);
  }
  return out;
}
