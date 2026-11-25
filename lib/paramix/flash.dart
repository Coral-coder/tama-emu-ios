// Read and write the Tamagotchi Paradise over a UART: a native Dart port of Paramix Studio's
// src/flash.js (mameise, GPL-3.0-or-later).
//
// Two protocols on the same serial line (460800 baud, 8N1):
//  1. App loading (the device's download screen): a PDLO file over the firmware's own transfer
//     protocol (text lines PKT/ACK/ENQ/NAK/CAN, 4 KB chunks with a SHA-256 keystream). It loads
//     Paramix's flash app into RAM; nothing is written to flash for this.
//  2. PAU1, spoken by the flash app: COBS framed packets with a CRC-32 (HELLO, READ, CRC, WRITE_*).

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'bytes.dart';
import 'edition.dart';

const int flashSize = 0x1000000, sector = 0x1000, block64 = 0x10000;
const int paradiseBaud = 460800;
const int firstUser = 0x111000;

const int cmdHello = 1, cmdRead = 5, cmdCrc = 6, cmdWriteTest = 8, cmdWriteBegin = 9, cmdWriteData = 10;
const int cmdWriteCommit = 11, cmdWriteFinish = 12, cmdWriteState = 13, cmdClockRead = 14, cmdClockSet = 15;

// Link values of the Paradise (chunk key, download token and mask), as in Paramix (two mixed tables).
const List<int> _lvA = [3, 175, 246, 44, 204, 25, 45, 199, 29, 242, 14, 63, 238, 148, 219, 113, 91, 21, 50, 246, 127, 248];
const List<int> _lvB = [11, 238, 128, 40, 225, 137, 250, 116, 146, 111, 247, 251, 126, 100, 255, 4, 18, 238, 64, 95, 162, 62];
final Uint8List _lv = () {
  final o = Uint8List(_lvA.length + _lvB.length);
  var s = 0x2C1B3C6D;
  for (var i = 0; i < o.length; i++) {
    s = ((s * 1103515245) + 12345) & 0x7fffffff;
    o[i] = ((i & 1) != 0 ? _lvB : _lvA)[i >> 1] ^ ((s >> 16) & 255);
  }
  return o;
}();
Uint8List get linkKey => Uint8List.sublistView(_lv, 0, 32);
Uint8List get _pdloToken => Uint8List.sublistView(_lv, 32, 40);
int get _pdloXor => u32(_lv, 40);
const int _imageSize = 0x10000, _chunk = 0x1000;

class FlashError implements Exception {
  FlashError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class FlashTimeout extends FlashError {
  FlashTimeout(String what) : super('timeout', 'no answer from the device ($what)');
}

class PauFrame {
  PauFrame(this.type, this.seq, this.off, this.status, this.payload);
  final int type, seq, off, status;
  final Uint8List payload;
}

/// One serial line: PAU1 frames and text lines are parsed from the same bytes.
class FlashLink {
  FlashLink(Stream<Uint8List> input, this._write) {
    _sub = input.listen(_feed);
  }

  final Future<void> Function(Uint8List) _write;
  late final StreamSubscription<Uint8List> _sub;
  final int session = Random().nextInt(0x7FFFFFFF) + 1;
  int seq = 0;
  final Uint8List _asm = Uint8List(0x10000);
  int _an = 0;
  final List<int> _line = [];
  final List<String> lines = [];
  final List<PauFrame> frames = [];
  Completer<void>? _wake;
  int rx = 0;
  final List<int> rxHead = [];

  void dispose() => _sub.cancel();

  void _feed(Uint8List d) {
    for (final b in d) {
      rx++;
      if (rxHead.length < 24) rxHead.add(b);
      if (b == 0) {
        if (_an > 0) {
          final f = _parse(cobsDecode(_asm, _an));
          if (f != null) frames.add(f);
        }
        _an = 0;
      } else if (_an < _asm.length) {
        _asm[_an++] = b;
      } else {
        _an = 0;
      }
      if (b == 10) {
        final s = String.fromCharCodes(_line).trim();
        _line.clear();
        if (s.isNotEmpty) lines.add(s);
      } else if (b != 13) {
        if (_line.length < 200 && b >= 32 && b < 127) {
          _line.add(b);
        } else {
          _line.clear();
        }
      }
    }
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  PauFrame? _parse(Uint8List d) {
    if (d.length < 28 || d[0] != 0x50 || d[1] != 0x41 || d[2] != 0x55 || d[3] != 0x31) return null;
    final plen = d[20] | (d[21] << 8);
    if (d.length < 28 + plen || u32(d, 24 + plen) != crc32(d, 0, 24 + plen)) return null;
    return PauFrame(d[6], u32(d, 12), u32(d, 16), d[22] | (d[23] << 8), Uint8List.fromList(d.sublist(24, 24 + plen)));
  }

  Future<T> until<T>(T? Function() test, int ms, String what) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    for (;;) {
      final r = test();
      if (r != null) return r;
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) throw FlashTimeout(what);
      final c = Completer<void>();
      _wake = c;
      await c.future.timeout(left < const Duration(milliseconds: 500) ? left : const Duration(milliseconds: 500), onTimeout: () {});
    }
  }

  void clear() {
    lines.clear();
    frames.clear();
    _line.clear();
    _an = 0;
  }

  Future<void> write(Uint8List d) => _write(d);
  Future<void> writeLine(String s) => _write(ascii('$s\r\n'));
  Future<String> waitLine(int ms) => until(() => lines.isEmpty ? null : lines.removeAt(0), ms, 'line');

  Uint8List frame(int type, int sq, int off, Uint8List payload) {
    final d = Uint8List(28 + payload.length);
    d.setAll(0, [0x50, 0x41, 0x55, 0x31, 1, 1, type, 0]);
    w32(d, 8, session);
    w32(d, 12, sq);
    w32(d, 16, off);
    d[20] = payload.length & 255;
    d[21] = payload.length >> 8;
    d.setAll(24, payload);
    w32(d, 24 + payload.length, crc32(d, 0, 24 + payload.length));
    return cobsEncode(d);
  }

  /// One PAU1 request and the matching reply.
  Future<PauFrame> request(int type, int off, [Uint8List? payload, int ms = 6000]) async {
    final sq = ++seq;
    off &= 0xFFFFFFFF;
    await _write(frame(type, sq, off, payload ?? Uint8List(0)));
    return until(() {
      while (frames.isNotEmpty) {
        final f = frames.removeAt(0);
        if (f.type == type && f.seq == sq && f.off == off) return f;
      }
      return null;
    }, ms, '$type ${hex(off)}');
  }
}

// ------------------------------------------------------------------ app loading

Uint8List buildPdlo(Uint8List img) {
  final f = Uint8List(16 + _imageSize);
  f.setAll(0, ascii('PDLO'));
  w32(f, 4, _imageSize ~/ 4);
  f.setAll(8, _pdloToken);
  f.setAll(16, img.sublist(0, min(img.length, _imageSize)));
  for (var i = 0; i < f.length; i += 4) {
    w32(f, i, u32(f, i) ^ _pdloXor);
  }
  return f;
}

Uint8List? _keystream;
Uint8List _chunkFrame(int idx, Uint8List payload) {
  final nonce = Uint8List.fromList([1, 0, 0, 0]);
  _keystream ??= Uint8List.fromList(sha256.convert([...nonce, ...linkKey]).bytes);
  final body = Uint8List(12 + payload.length);
  body.setAll(4, ascii('TCP'));
  body[7] = 3;
  body[8] = idx & 255;
  body[9] = 255 - (idx & 255);
  final c = crc16(payload);
  body[10] = c & 255;
  body[11] = c >> 8;
  body.setAll(12, payload);
  final k = Uint8List.fromList(_keystream!);
  for (var i = 0; i < body.length; i++) {
    final j = i % 32;
    body[i] ^= k[j];
    k[j] = (k[j] * 2 + 1) & 255;
  }
  return Uint8List.fromList([...nonce, ...body]);
}

/// Is the device on the download screen? (three tries; some adapters garble the first bytes)
Future<bool> probe(FlashLink link) async {
  for (var t = 0; t < 3; t++) {
    await link.write(ascii('\r\n'));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    link.clear();
    await link.writeLine('ECHO REQ');
    final end = DateTime.now().add(const Duration(seconds: 2));
    for (;;) {
      final left = end.difference(DateTime.now()).inMilliseconds;
      if (left <= 0) break;
      String l;
      try {
        l = await link.waitLine(left);
      } on FlashTimeout {
        break;
      }
      if (l.contains('ECHO REP')) return true;
    }
  }
  return false;
}

/// Loads an image into the device's RAM (download screen) and starts it.
Future<void> loadApp(FlashLink link, Uint8List img, void Function(int done, int total)? progress) async {
  final file = buildPdlo(img);
  link.clear();
  await link.writeLine('PKT ${file.length}');
  String a;
  try {
    a = await link.waitLine(4000);
  } on FlashTimeout {
    a = '';
  }
  if (!a.startsWith('ACK')) throw FlashError('noAck', 'the device does not answer. Is it on the download screen?');
  var idx = 0, guard = 0;
  while (idx * _chunk < file.length) {
    if (++guard > 200) throw FlashError('repeats', 'too many repeats while loading');
    final off = idx * _chunk, n = min(_chunk, file.length - off);
    await link.write(_chunkFrame(idx, Uint8List.sublistView(file, off, off + n)));
    final r = await link.waitLine(6000);
    if (r.startsWith('ACK')) {
      idx++;
      progress?.call(min(idx * _chunk, file.length), file.length);
    } else if (r.startsWith('ENQ')) {
      final e = int.tryParse(r.substring(3).trim());
      if (e != null) idx = e;
    } else if (r.startsWith('NAK')) {
      // same chunk again
    } else if (r.startsWith('CAN')) {
      throw FlashError('devCancel', 'the device cancelled loading');
    } else {
      throw FlashError('unexpected', 'unexpected answer: $r');
    }
  }
}

// ------------------------------------------------------------------ rescue start
// A second load table at 0xFFE000 starts the flash app from 0xFF0000 when the device's own table
// or firmware is broken (a cut-off write): the device then comes up in the flash screen and can be
// written again without the download screen.

const int rescueOff = 0xFF0000, rescueTab = 0xFFE000, rescueCode = 0xE000, batPicOff = 0xFFF000;

Uint8List? rescueBlock(Uint8List app, Uint8List hdr, Uint8List? pic) {
  if (app.length > rescueCode || hdr.length < sector || asciiAt(hdr, 0, 8) != 'SONIXDEV') return null;
  final b = Uint8List(block64)..fillRange(0, block64, 0xFF);
  b.setAll(0, app);
  if (pic != null && pic.length == sector) b.setAll(batPicOff - rescueOff, pic);
  final t = Uint8List.fromList(hdr.sublist(0, sector));
  w32(t, 0x08, u32(t, 0x08) & ~1); // LOAD_CFG: not encrypted (CRC check stays on)
  w32(t, 0x10, 0x60000000 + rescueOff); // ADDR_USERCODE
  w32(t, 0x14, rescueCode); // SIZE_USERCODE
  w32(t, 0x24, crc32(b, 0, rescueCode)); // CRC_CHK_SUM
  t.fillRange(0x80, 0x84, 0); // encrypter mark off
  b.setAll(rescueTab - rescueOff, t);
  return b;
}

bool isRescue(Uint8List d, [int base = 0]) {
  final t = base + rescueTab - rescueOff;
  return asciiAt(d, t, 8) == 'SONIXDEV' && u32(d, t + 0x10) == 0x60000000 + rescueOff && u32(d, t + 0x14) == rescueCode;
}

/// The image with the rescue start, or null when 0xFF0000 holds something else.
Uint8List? withRescue(Uint8List img, Uint8List app) {
  final rb = rescueBlock(app, Uint8List.sublistView(img, 0, sector), Uint8List.fromList(img.sublist(batPicOff, batPicOff + sector)));
  if (rb == null) return null;
  var same = true;
  for (var i = 0; i < block64; i++) {
    if (img[rescueOff + i] != rb[i]) {
      same = false;
      break;
    }
  }
  if (same) return img;
  final picFree = allFF(img, rescueOff, batPicOff - rescueOff);
  if (!picFree && !isRescue(img, rescueOff)) return null;
  final out = Uint8List.fromList(img);
  out.setAll(rescueOff, rb);
  return out;
}

List<int> sectorOrder() => [
      for (var s = firstUser; s < flashSize; s += sector) s,
      for (var s = sector; s < firstUser; s += sector) s,
      0,
    ];

// ------------------------------------------------------------------ device

class DeviceInfo {
  DeviceInfo(this.edition, this.wave, this.maxBlock, this.jedec, this.capacity, this.flashError);
  int edition;
  final int wave, maxBlock, jedec, capacity, flashError;
  String name = '';
}

typedef Progress = void Function(String phase, int done, int total);

class WriteResult {
  WriteResult(this.written, this.kept, this.notes, this.image, this.rescue);
  final int written, kept;
  final List<String> notes;
  final Uint8List image;
  final bool rescue;
}

class Paradise {
  Paradise(this.link);
  final FlashLink link;
  DeviceInfo? info;
  bool cancelRequested = false;

  int get block {
    final b = info?.maxBlock ?? 1024;
    return b == 1024 || b == 2048 || b == 4096 ? b : 1024;
  }

  void _checkCancel([String code = 'cancelled']) {
    if (cancelRequested) throw FlashError(code, code == 'cancelled' ? 'cancelled' : 'cancelled. Keep the device switched on and write again');
  }

  Future<DeviceInfo> hello([int ms = 6000]) async {
    final r = await link.request(cmdHello, 0, null, ms);
    final p = r.payload;
    if (p.length != 44) throw FlashError('hello', 'unexpected HELLO answer');
    final i = DeviceInfo(p[8], p[9], p[10] | (p[11] << 8), u32(p, 24), u32(p, 32), u32(p, 36));
    info = i;
    // The flash app always reports 1 (Land); the real edition is the ID page in the flash.
    try {
      const c = [0, 0x70169E2C, 0x70169E2C, 0x70169E2C, 0x849633DB, 0x96CB83B8, 0x96CB83B8];
      Future<int> ok(int pg, List<int> ids) async {
        final v = u32(await read(pg, 4), 0);
        if (!ids.contains(v)) return 0;
        final f = await read(pg + 0xFF8, 8);
        final k = u32(f, 0);
        bool ft(int cc) => ((k + v) & 0xFFFFFFFF) == cc && u32(f, 4) == (~k & 0xFFFFFFFF);
        if (v == 4 && pg != 0xD49000 && ft(c[5])) return 7;
        return ft(c[v]) ? v : -v;
      }

      Future<bool> neonAt(int pg) async {
        if (u32(await read(pg, 4), 0) != 7) return false;
        final f = await read(pg + 0xFF8, 8);
        final k = u32(f, 0);
        return ((k + 7) & 0xFFFFFFFF) == 0x99431749 && u32(f, 4) == (~k & 0xFFFFFFFF);
      }

      if (await neonAt(0xD85000) || await neonAt(0xEFD000)) {
        i.edition = 8;
        i.name = editionNames[8]!;
        return i;
      }
      final g = await ok(0xD29000, [5, 6, 4]);
      final l = g > 0 ? 0 : await ok(0xD49000, [1, 2, 3, 4]);
      final cl = g > 0 || l > 0 ? 0 : await ok(0xEFD000, [1, 2, 3, 4, 5, 6]);
      final v = g > 0 ? g : l > 0 ? l : cl > 0 ? cl : l < 0 ? -l : g < 0 ? -g : 0;
      if (v != 0) i.edition = v;
    } on FlashTimeout {
      // keep the app's value
    }
    i.name = editionNames[i.edition] ?? 'Edition ${i.edition}';
    return i;
  }

  void ready() {
    final i = info;
    if (i == null || i.capacity != flashSize || i.flashError != 0) throw FlashError('notReady', 'flash not ready');
  }

  /// Bytes asked for per read. A Bluetooth bridge loses bytes of long answers (notifications
  /// sent faster than the phone takes them), so reads start smaller there and shrink by
  /// themselves when answers do not arrive whole, down to one that fits a single packet.
  int? readBlock;
  void Function(int size)? onReadBlock;

  Future<Uint8List> read(int off, int len) async {
    final out = Uint8List(len);
    var o = 0;
    var fails = 0;
    while (o < len) {
      final blk = min(readBlock ?? block, block);
      final want = min(blk, len - o);
      PauFrame? r;
      try {
        final x = await link.request(cmdRead, off + o, le32(blk), blk <= 256 ? 2500 : 4000);
        if (x.payload.length >= want && x.status == 0) r = x;
      } on FlashTimeout {
        // again, smaller
      }
      if (r == null) {
        fails++;
        link.frames.clear();
        if (blk > 128) {
          readBlock = blk ~/ 2;
          onReadBlock?.call(readBlock!);
          fails = 0;
        } else if (fails >= 6) {
          throw FlashError('readErr', 'read error at ${hex(off + o)}');
        }
        continue;
      }
      fails = 0;
      out.setAll(o, r.payload.sublist(0, want));
      o += want;
    }
    return out;
  }

  Future<int> crc(int off, int len) async {
    for (var t = 0; t < 4; t++) {
      try {
        final c = await link.request(cmdCrc, off, le32(len), 15000);
        if (c.payload.length == 4 && c.status == 0) return u32(c.payload, 0);
      } on FlashTimeout {
        // again
      }
    }
    throw FlashError('noCrc', 'no checksum at ${hex(off)}');
  }

  /// Seconds counter of the Paradise, or null with an older flash app.
  Future<int?> clockRead() async {
    try {
      final r = await link.request(cmdClockRead, 0, null, 2500);
      if (r.payload.length == 8) return u32(r.payload, 0);
    } on FlashTimeout {
      // older app
    }
    return null;
  }

  Future<bool> clockSet(int v) async {
    try {
      final r = await link.request(cmdClockSet, 0, le32(v), 2500);
      return r.payload.length == 4 && r.status == 0 && (u32(r.payload, 0) - v) < 5;
    } on FlashTimeout {
      return false;
    }
  }

  Future<PauFrame> writeState() async {
    for (var t = 0; t < 3; t++) {
      try {
        return await link.request(cmdWriteState, 0, null, 6000);
      } on FlashTimeout {
        // ping, then again
      }
      try {
        await link.request(cmdHello, 0, null, 3000);
      } on FlashTimeout {
        // ignore
      }
    }
    throw FlashError('lost', 'the device stopped answering before writing. Nothing was written. Switch the Paradise off and on, put it on the download screen, connect again and write again');
  }

  /// One 4 KB sector: data packets, then the commit with its CRC; the device erases, programs,
  /// reads back and compares. A lost answer is asked again; status 2 (buffer mismatch) sends again.
  Future<void> putSector(int s, Uint8List d) async {
    final blk = block, want = crc32(d, 0, sector);
    Future<PauFrame> ask(int type, int off, Uint8List pl, int ms) async {
      for (var t = 0;; t++) {
        try {
          return await link.request(type, off, pl, ms);
        } on FlashTimeout {
          if (t >= 2) rethrow;
        }
      }
    }

    for (var t = 0; t < 3; t++) {
      for (var o = 0; o < sector; o += blk) {
        await ask(cmdWriteData, s + o, Uint8List.sublistView(d, o, o + blk), 5000);
      }
      final c = await ask(cmdWriteCommit, s, le32(want), 15000);
      if (c.payload.length != 8) throw FlashError('notAccepted', 'sector ${hex(s)} not accepted. Keep the device switched on and write again');
      final st = u32(c.payload, 4);
      if (st == 2) continue;
      if (st != 0 || u32(c.payload, 0) != want) break;
      return;
    }
    throw FlashError('differs', 'sector ${hex(s)} differs after writing. Keep the device switched on and write again');
  }

  /// The whole flash (16 MB).
  Future<Uint8List> dump(Progress? progress) async {
    ready();
    final img = Uint8List(flashSize);
    for (var off = 0; off < flashSize; off += block64) {
      _checkCancel();
      img.setAll(off, await read(off, block64));
      progress?.call('read', off + block64, flashSize);
    }
    return img;
  }

  /// Sectors where the device differs from img.
  Future<Set<int>> changed(Uint8List img, Progress? progress, [int from = 0, int to = flashSize]) async {
    final out = <int>{};
    for (var off = from; off < to; off += block64) {
      _checkCancel();
      if (await crc(off, block64) != crc32(img, off, block64)) {
        for (var s = off; s < off + block64; s += sector) {
          if (await crc(s, sector) != crc32(img, s, sector)) out.add(s);
        }
      }
      progress?.call('compare', off + block64 - from, to - from);
    }
    return out;
  }

  /// Writes single sectors (address -> 4 KB), checked one by one.
  Future<int> writeSectors(Map<int, Uint8List> map, Progress? progress) async {
    ready();
    final st = await writeState();
    if (!(st.payload.length >= 16 && u32(st.payload, 12) != 0)) await link.request(cmdWriteTest, 0, null, 15000);
    await link.request(cmdWriteBegin, 0, Uint8List(36), 15000);
    final keys = map.keys.toList()..sort();
    var n = 0;
    for (final s in keys) {
      _checkCancel('cancelledWrite');
      await putSector(s, map[s]!);
      n++;
      progress?.call('write', n, keys.length);
    }
    await link.request(cmdWriteFinish, 0, null, 15000);
    return n;
  }

  /// Writes a whole 16 MB image.
  ///   onlyChanged: only sectors whose CRC differs
  ///   keepSaves: sectors with game progress stay as they are on the device (same edition family)
  ///   rescueApp: puts Paramix's rescue start at 0xFF0000 (when that area is free)
  Future<WriteResult> write(Uint8List img, {required bool onlyChanged, required bool keepSaves, Uint8List? rescueApp, Progress? progress}) async {
    if (img.length != flashSize) throw FlashError('size', 'the image must be exactly 16 MB');
    if (asciiAt(img, 0, 8) != 'SONIXDEV') throw FlashError('notParadise', 'not a Paradise image (SONIXDEV missing)');
    ready();
    var image = img;
    final notes = <String>[];
    var kept = 0;
    var rescue = false;
    if (rescueApp != null) {
      final r = withRescue(image, rescueApp);
      if (r != null) {
        image = r;
        rescue = true;
      } else {
        notes.add('no rescue start: 0xFF0000 is in use');
      }
    }
    Set<int>? ch;
    if (onlyChanged || keepSaves || rescue) ch = await changed(image, progress);
    if (keepSaves) {
      final k = await _keepSaves(image, ch!, notes);
      image = k.$1;
      kept = k.$2;
      for (final s in k.$3) {
        ch.remove(s);
      }
    }
    if (rescue) {
      // the save range reaches the end of the flash: the rescue start wins there
      final rb = rescueBlock(rescueApp!, Uint8List.sublistView(image, 0, sector), Uint8List.fromList(image.sublist(batPicOff, batPicOff + sector)))!;
      if (identical(image, img)) image = Uint8List.fromList(image);
      image.setAll(rescueOff, rb);
      for (var s = rescueOff; s < flashSize; s += sector) {
        if (await crc(s, sector) != crc32(image, s, sector)) {
          ch!.add(s);
        } else {
          ch!.remove(s);
        }
      }
    }
    final st = await writeState();
    if (!(st.payload.length >= 16 && u32(st.payload, 12) != 0)) {
      progress?.call('prepare', 0, 1);
      await link.request(cmdWriteTest, 0, null, 15000);
    }
    var order = sectorOrder();
    if (rescue) order = [...order.where((s) => s >= rescueOff), ...order.where((s) => s < rescueOff)];
    if (onlyChanged) {
      order = order.where((s) => ch!.contains(s)).toList();
      if (order.isEmpty) {
        await link.request(cmdWriteFinish, 0, null, 15000);
        return WriteResult(0, kept, notes, image, rescue);
      }
    } else if (ch != null) {
      order = order.where((s) => s >= 0x11000 || s == 0 || ch!.contains(s)).toList();
    }
    // The device's own table goes off while the rest is written (the ROM then starts the rescue), back at the end.
    final clear0 = rescue && order.any((s) => s != 0 && s < rescueOff);
    if (clear0 && order.last != 0) order.add(0);
    final nRes = order.where((s) => s >= rescueOff).length;
    final begin = Uint8List(36);
    begin.setAll(0, sha256.convert(image).bytes);
    w32(begin, 32, crc32(image));
    final pos = await link.request(cmdWriteBegin, 0, begin, 15000);
    var start = !onlyChanged && pos.payload.length >= 4 ? u32(pos.payload, 0) : 0;
    if (start >= order.length) start = 0;
    var written = 0;
    for (var i = start; i < order.length; i++) {
      _checkCancel('cancelledWrite');
      final s = order[i];
      if (clear0 && i == max(start, nRes)) {
        if (await crc(rescueOff, block64) != crc32(image, rescueOff, block64)) throw FlashError('rescueFail', 'the rescue start was not written correctly');
        await putSector(0, Uint8List(sector)..fillRange(0, sector, 0xFF));
      }
      await putSector(s, Uint8List.sublistView(image, s, s + sector));
      written++;
      progress?.call('write', i + 1 - start, order.length - start);
    }
    for (var off = 0; off < flashSize; off += block64) {
      if (await crc(off, block64) != crc32(image, off, block64)) throw FlashError('checkFail', 'check failed at ${hex(off)}. Keep the device switched on and write again');
      progress?.call('check', off + block64, flashSize);
    }
    await link.request(cmdWriteFinish, 0, null, 15000);
    return WriteResult(written, kept, notes, image, rescue);
  }

  /// "Keep saves": the Paradise save (from the page after the edition ID page to the end of the
  /// flash; Neon Planets to 0xF00000) stays as it is on the device, for the same edition family.
  Future<(Uint8List, int, List<int>)> _keepSaves(Uint8List img, Set<int> ch, List<String> notes) async {
    final ed = edition(img);
    if (ed == null) throw FlashError('unknownEd', 'unknown edition in the new ROM, untick "keep saves"');
    final dev = info!;
    final sameFam = dev.edition != ed.id && familyOf(dev.edition) != null && familyOf(dev.edition) == familyOf(ed.id);
    if (dev.edition != ed.id && !sameFam) {
      throw FlashError('otherEd', 'the device is ${dev.name}, the new ROM is ${ed.name}. Untick "keep saves" to switch the edition');
    }
    if (sameFam) notes.add('the device is ${dev.name}, the new ROM is ${ed.name}: same firmware, the device keeps its save and its field');
    final image = Uint8List.fromList(img);
    final from = ed.profile.idPage + (sameFam ? 0 : sector);
    final to = isSix(img) || ed.profile.ring ? 0xF00000 : flashSize;
    final prot = <int>[];
    var kept = 0;
    for (var s = from & ~0xFFF; s < to; s += sector) {
      if (!ch.contains(s)) continue;
      image.setAll(s, await read(s, sector));
      prot.add(s);
      kept++;
    }
    return (image, kept, prot);
  }
}

/// Opens the device: talks to the flash app, or loads it first from the download screen.
Future<(Paradise, bool)> connectParadise(FlashLink link, Uint8List flashApp, void Function(String phase, int done, int total)? status,
    {int? readBlock, void Function(int size)? onReadBlock}) async {
  final dev = Paradise(link)
    ..readBlock = readBlock
    ..onReadBlock = onReadBlock;
  try {
    await dev.hello(2500);
    return (dev, false);
  } on FlashTimeout {
    // not running yet
  }
  if (!await probe(link)) {
    if (link.rx == 0) {
      throw FlashError('noData', 'no answer, no data comes in from the adapter. Put the device on the download screen and try again. Still nothing: check the cable (TX/RX crossed, GND) and the adapter');
    }
    final h = link.rxHead.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    throw FlashError('garbled', 'data comes in, but it is not readable (${link.rx} bytes: $h). Check the cable (TX and RX) and the baud rate (460800)');
  }
  status?.call('load', 0, 1);
  await loadApp(link, flashApp, (d, t) => status?.call('load', d, t));
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  link.clear();
  for (var t = 0; t < 4; t++) {
    try {
      await dev.hello(4000);
      return (dev, true);
    } on FlashTimeout {
      // again
    }
  }
  throw FlashError('appSilent', 'the flash app was sent but does not answer. Try again');
}
