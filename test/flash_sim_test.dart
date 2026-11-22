// The native Paramix device protocol against a simulated flash app (PAU1 over a fake serial
// line, 16 MB flash in memory): connect, read, only changes, keep saves, other edition refused.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tama_tools/paramix/bytes.dart';
import 'package:tama_tools/paramix/flash.dart';

/// The device side of PAU1, as Paramix's flash app (flash/src/fw.c) answers.
class FakeFlashApp {
  FakeFlashApp(this.flash);
  final Uint8List flash;
  final _toHost = StreamController<Uint8List>.broadcast();
  final List<int> _rx = [];
  final Uint8List _buf = Uint8List(sector);
  int writes = 0;

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

  void _reply(Uint8List req, Uint8List payload, [int status = 0]) {
    final plen = payload.length;
    final d = Uint8List(28 + plen);
    d.setAll(0, req.sublist(0, 20));
    d[20] = plen & 255;
    d[21] = plen >> 8;
    d[22] = status;
    d.setAll(24, payload);
    w32(d, 24 + plen, crc32(d, 0, 24 + plen));
    scheduleMicrotask(() => _toHost.add(cobsEncode(d)));
  }

  void _frame(Uint8List d) {
    if (d.length < 28 || u32(d, 0) != 0x31554150) return;
    final type = d[6], off = u32(d, 16), plen = d[20] | (d[21] << 8);
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
        final n = u32(p, 0);
        _reply(d, Uint8List.fromList(flash.sublist(off, off + n)));
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
        writes++;
        final r = Uint8List(8);
        w32(r, 0, crc32(flash, off, sector));
        _reply(d, r);
      case cmdWriteTest:
      case cmdWriteFinish:
        _reply(d, Uint8List(0));
    }
  }
}

Uint8List landImage() {
  final img = Uint8List(flashSize)..fillRange(0, flashSize, 0xFF);
  img.setAll(0, 'SONIXDEV'.codeUnits);
  final r = Random(1);
  for (var i = 0x11000; i < 0x300000; i++) {
    img[i] = r.nextInt(256);
  }
  // edition ID page: Land (1) with its footer
  const c = 0x70169E2C, k = c - 1;
  w32(img, 0xD49000, 1);
  w32(img, 0xD49000 + 0xFF8, k);
  w32(img, 0xD49000 + 0xFFC, ~k & 0xFFFFFFFF);
  // a save page
  for (var i = 0xEFE000; i < 0xEFF000; i++) {
    img[i] = i & 255;
  }
  return img;
}

void main() {
  test('connect, read, write only changes and keep the save', () async {
    final device = landImage();
    final app = FakeFlashApp(device);
    final link = FlashLink(app.toHost, app.fromHost);
    final (dev, loaded) = await connectParadise(link, Uint8List(16), null);
    expect(loaded, isFalse); // the flash app already answered
    expect(dev.info!.name, 'Land');

    final r = await dev.read(0x20000, 0x3000);
    expect(r, device.sublist(0x20000, 0x23000));

    // new image: one byte in the characters, one in the save
    final img = Uint8List.fromList(device);
    img[0x200010] ^= 0x5A;
    img[0xEFE100] ^= 0x33;
    final saveBefore = Uint8List.fromList(device.sublist(0xEFE000, 0xEFF000));
    final res = await dev.write(img, onlyChanged: true, keepSaves: true);
    expect(res.written, 1);
    expect(res.kept, 1);
    expect(device.sublist(0xEFE000, 0xEFF000), saveBefore);
    expect(device[0x200010], img[0x200010]);

    // without keep: the save sector is written too
    final res2 = await dev.write(img, onlyChanged: true, keepSaves: false);
    expect(res2.written, 1);
    expect(device, img);

    // another firmware family (Jade Forest) is refused with keep saves; Land -> Water (same
    // firmware) would be allowed and keep the device's field, as in Paramix
    final other = Uint8List.fromList(img);
    w32(other, 0xD49000, 4);
    w32(other, 0xD49000 + 0xFF8, 0x849633DB - 4);
    w32(other, 0xD49000 + 0xFFC, ~(0x849633DB - 4) & 0xFFFFFFFF);
    await expectLater(dev.write(other, onlyChanged: true, keepSaves: true), throwsA(isA<FlashError>()));
    link.dispose();
  });
}
