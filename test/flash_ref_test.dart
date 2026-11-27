// The native Paramix device protocol against reference bytes from Paramix's own flash.js
// (tool/flashcheck/ref.js): link key, PDLO file, a PAU1 frame, the rescue block, the write order.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tama_tools/paramix/bytes.dart';
import 'package:tama_tools/paramix/flash.dart';

String hexs(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // the Studio's own flash app: the reference values were made with it (the app ships its build
  // with the restart command, tool/flashapp)
  final app = File('third_party/paramix-studio/flash/flashapp.bin');

  test('link key', () {
    expect(hexs(linkKey), '5350715245517174756876674a75526578714d664738467a737441676d6e6637');
  });

  test('PDLO file of the flash app', () {
    if (!app.existsSync()) return markTestSkipped('run tool/sync_paramix.sh');
    expect(sha256.convert(buildPdlo(app.readAsBytesSync())).toString(), 'cb28cba62aefbc53d8845c94532bb7f4decd9fb1f45606883b73f2046a097246');
  });

  test('PAU1 frame', () {
    final link = FlashLink(const Stream<Uint8List>.empty(), (_) async {});
    final f = link.frame(5, 7, 0xD49000, Uint8List.fromList([0, 4, 0, 0]));
    // the reference used session 0x12345678
    final d = Uint8List(28 + 4)..setAll(0, [0x50, 0x41, 0x55, 0x31, 1, 1, 5, 0]);
    w32(d, 8, 0x12345678);
    w32(d, 12, 7);
    w32(d, 16, 0xD49000);
    d[20] = 4;
    d.setAll(24, [0, 4, 0, 0]);
    w32(d, 28, crc32(d, 0, 28));
    expect(hexs(cobsEncode(d)), '0008504155310101050678563412070101010390d4020401010102040105ab37eb5e00');
    expect(f.length, cobsEncode(d).length);
    // and COBS round trip
    final enc = cobsEncode(d);
    expect(cobsDecode(Uint8List.sublistView(enc, 1, enc.length - 1), enc.length - 2), d);
  });

  test('rescue block', () {
    if (!app.existsSync()) return markTestSkipped('run tool/sync_paramix.sh');
    final hdr = Uint8List(0x1000)..setAll(0, 'SONIXDEV'.codeUnits);
    for (var i = 8; i < 0x1000; i++) {
      hdr[i] = (i * 7) & 255;
    }
    final a = app.readAsBytesSync();
    final b = rescueBlock(Uint8List.sublistView(a, 0, a.length < 0xE000 ? a.length : 0xE000), hdr, null)!;
    expect(sha256.convert(b).toString(), '96ebfffad828dbe6449b13d5ed1778ae58fc388cc7ba0993111add0e0be8c723');
  });

  test('write order', () {
    final o = sectorOrder();
    final b = Uint8List(o.length * 4);
    for (var i = 0; i < o.length; i++) {
      w32(b, i * 4, o[i]);
    }
    expect(sha256.convert(b).toString(), '24023dd7ba9b9c8208aaa8a6c8f4fcbe816f88aeec06934d97fdd145706b872d');
  });
}
