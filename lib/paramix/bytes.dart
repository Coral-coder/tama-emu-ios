// Small byte helpers shared by the Paramix port (little endian, as in Paramix Studio).

import 'dart:typed_data';

int u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int u32(Uint8List b, int o) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) & 0xFFFFFFFF;

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

Uint8List le32(int v) {
  final b = Uint8List(4);
  w32(b, 0, v);
  return b;
}

Uint8List ascii(String s) => Uint8List.fromList(s.codeUnits);
String asciiAt(Uint8List b, int o, int n) => String.fromCharCodes(b.sublist(o, o + n));

bool allFF(Uint8List d, int a, int n) {
  for (var i = a; i < a + n; i++) {
    if (d[i] != 0xFF) return false;
  }
  return true;
}

String hex(int v) => '0x${v.toRadixString(16)}';

final Uint32List _crcTab = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

/// CRC-32 (zlib) of d[a, a + n).
int crc32(Uint8List d, [int a = 0, int? n]) {
  final end = a + (n ?? d.length - a);
  var c = 0xFFFFFFFF;
  for (var i = a; i < end; i++) {
    c = (c >> 8) ^ _crcTab[(c ^ d[i]) & 255];
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

int crc16(Uint8List d) {
  var c = 0;
  for (final b in d) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1;
    }
  }
  return c;
}

Uint8List cobsEncode(Uint8List d) {
  final o = Uint8List(d.length + (d.length / 254).ceil() + 3);
  var n = 1, ci = 1, code = 1;
  o[0] = 0; // leading delimiter
  o[n++] = 0;
  for (final b in d) {
    if (b != 0) {
      o[n++] = b;
      code++;
      if (code == 255) {
        o[ci] = code;
        ci = n;
        o[n++] = 0;
        code = 1;
      }
    } else {
      o[ci] = code;
      ci = n;
      o[n++] = 0;
      code = 1;
    }
  }
  o[ci] = code;
  o[n++] = 0;
  return Uint8List.sublistView(o, 0, n);
}

Uint8List cobsDecode(Uint8List f, int len) {
  final o = Uint8List(len);
  var n = 0, i = 0;
  while (i < len) {
    final code = f[i++];
    if (code == 0) continue;
    for (var k = 1; k < code && i < len; k++) {
      o[n++] = f[i++];
    }
    if (code != 255 && i < len) o[n++] = 0;
  }
  return Uint8List.sublistView(o, 0, n);
}
