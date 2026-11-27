// A toy that is not there: a game of the app behind the flash app's protocol. Everything that
// talks to a real Paradise on its download screen (back up the save, write it, set the clock,
// leave the flash screen) then works on the game, through the very same code.

import 'dart:async';
import 'dart:typed_data';

import 'bytes.dart';
import 'flash.dart';
import 'saves.dart';

/// The device side of PAU1, as the flash app (flash/src/fw.c) answers, over a flash image.
class VirtualToy {
  VirtualToy(this.flash, {this.counter = 0, this.onRestart});

  /// The 16 MB the toy would hold: the ROM with the game's pages on it.
  final Uint8List flash;

  /// The always powered clock: its seconds counter, and the control register (bit 7: running).
  int counter;
  int ctrl = 0xE0;

  /// Called when the host asks the toy to leave the flash screen.
  void Function()? onRestart;

  /// True once a sector was written or the clock was set.
  bool changed = false;

  final _toHost = StreamController<Uint8List>.broadcast();
  final List<int> _rx = [];
  final Uint8List _buf = Uint8List(sector);

  Stream<Uint8List> get toHost => _toHost.stream;

  Future<void> fromHost(Uint8List d) async {
    for (final b in d) {
      if (b == 0) {
        if (_rx.isNotEmpty) _frame(cobsDecode(Uint8List.fromList(_rx), _rx.length));
        _rx.clear();
      } else {
        _rx.add(b);
      }
    }
  }

  void dispose() => _toHost.close();

  void _reply(Uint8List req, Uint8List payload, [int status = 0]) {
    final plen = payload.length;
    final d = Uint8List(28 + plen);
    d.setAll(0, req.sublist(0, 20));
    d[20] = plen & 255;
    d[21] = plen >> 8;
    d[22] = status;
    d.setAll(24, payload);
    w32(d, 24 + plen, crc32(d, 0, 24 + plen));
    scheduleMicrotask(() {
      if (!_toHost.isClosed) _toHost.add(cobsEncode(d));
    });
  }

  void _frame(Uint8List d) {
    if (d.length < 28 || u32(d, 0) != 0x31554150) return;
    final type = d[6], off = u32(d, 16), plen = d[20] | (d[21] << 8);
    if (24 + plen > d.length) return;
    final p = Uint8List.sublistView(d, 24, 24 + plen);
    switch (type) {
      case cmdHello:
        final h = Uint8List(44);
        h[8] = 1;
        w16(h, 10, 4096);
        w32(h, 24, 0xC22018);
        w32(h, 32, flashSize);
        _reply(d, h);
      case cmdRead:
        final n = u32(p, 0), end = off + n > flash.length ? flash.length : off + n;
        _reply(d, Uint8List.fromList(Uint8List.sublistView(flash, off > end ? end : off, end)));
      case cmdCrc:
        _reply(d, le32(crc32(flash, off, u32(p, 0))));
      case cmdWriteState:
        _reply(d, Uint8List(16)..[12] = 1);
      case cmdWriteBegin:
        _reply(d, le32(0));
      case cmdWriteData:
        _buf.setAll(off & (sector - 1), p);
        _reply(d, Uint8List(0));
      case cmdWriteCommit:
        flash.setAll(off, _buf);
        changed = true;
        final r = Uint8List(8);
        w32(r, 0, crc32(flash, off, sector));
        _reply(d, r);
      case cmdWriteTest:
      case cmdWriteFinish:
        _reply(d, Uint8List(0));
      case cmdClockRead:
        final r = Uint8List(8);
        w32(r, 0, counter);
        w32(r, 4, ctrl);
        _reply(d, r);
      case cmdClockSet:
        counter = u32(p, 0);
        changed = true;
        _reply(d, le32(counter));
      case cmdRestart:
        _reply(d, Uint8List(0));
        scheduleMicrotask(() => onRestart?.call());
    }
  }
}

/// The flash a toy would hold for a game of the app: [rom] with the pages of the game's save
/// file [gameFile] (null: a game not played yet) on it. Also gives the decoded file.
(Uint8List image, ParaSave? file) gameImage(Uint8List rom, Uint8List? gameFile) {
  final img = Uint8List(flashSize)..fillRange(0, flashSize, 0xFF);
  img.setRange(0, rom.length < flashSize ? rom.length : flashSize, rom);
  if (gameFile == null) return (img, null);
  final g = paraDecode(gameFile);
  g.pages.forEach((a, d) {
    if (a < img.length) img.setRange(a, a + d.length < img.length ? a + d.length : img.length, d);
  });
  return (img, g);
}

/// The game's save file for [image]: every 4 KB page that differs from [rom], with the clock
/// [counter]; alarm, status and registers stay as in [old].
Uint8List gameFileOf(Uint8List rom, Uint8List image, ParaSave? old, int counter, int edition, {DateTime? now}) {
  final pages = <int, Uint8List>{};
  for (var a = 0; a + sector <= image.length; a += sector) {
    var same = a + sector <= rom.length;
    if (same) {
      for (var i = a; i < a + sector; i++) {
        if (image[i] != rom[i]) {
          same = false;
          break;
        }
      }
    }
    if (!same) pages[a] = Uint8List.fromList(Uint8List.sublistView(image, a, a + sector));
  }
  final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  return paraWrite(ParaSave(stamp: stamp, counter: counter, alarm: old?.alarm ?? 0, status: old?.status ?? 0, regs: old?.regs ?? const [], pages: pages, edition: edition), edition);
}
