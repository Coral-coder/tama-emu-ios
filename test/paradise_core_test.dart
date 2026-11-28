// Needs the host build of native/tama_core (tool/build_native.sh host) on LD_LIBRARY_PATH and a
// Paradise dump in PARADISE_DUMP; skipped otherwise.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tama_tools/paradise/paradise_core.dart';

void main() {
  myLab();
  final dump = Platform.environment['PARADISE_DUMP'];
  test('the core loads and reports an encrypted dump without its key', () {
    final core = ParadiseCore.instance;
    if (core == null || dump == null) {
      markTestSkipped('no native core / dump: ${ParadiseCore.loadError}');
      return;
    }
    expect(core.cyclesPerSecond, 96000000);
    final h = ParadiseHandle(core);
    final r = h.load(dump, null);
    expect(r, anyOf(0, 1));
    final fb = Uint16List(128 * 128);
    h.screen(fb);
    if (r == 1) {
      h.run(core.cyclesPerSecond, 5000);
    }
    h.dispose();
    stdout.writeln('load without key -> $r');
  });
}

// The wide-screen board (My Lab) through the same binding: MYLAB_DUMP names its dump.
void myLab() {
  final dump = Platform.environment['MYLAB_DUMP'];
  test('a wide-screen dump boots, gives 160 x 128 and takes the keys', () {
    final core = ParadiseCore.instance;
    if (core == null || dump == null) {
      markTestSkipped('no native core / dump');
      return;
    }
    final h = ParadiseHandle(core);
    expect(h.load(dump, 0x5AAF34FB), 1);
    expect(h.screenSize(), (160, 128));
    final fb = Uint16List(160 * 128);
    for (var i = 0; i < 8; i++) {
      h.run(core.cyclesPerSecond, 20000);
    }
    h.screen(fb);
    final before = Uint16List.fromList(fb);
    expect(fb.toSet().length, greaterThan(4)); // a picture, not a blank screen
    h.press(ParadiseHandle.pinA);
    h.run(core.cyclesPerSecond ~/ 2, 20000);
    h.release(ParadiseHandle.pinA);
    h.run(core.cyclesPerSecond, 20000);
    h.screen(fb);
    expect(fb, isNot(before)); // the menu's cursor moved
    h.dispose();
  });
}
