// Needs the host build of native/tama_core (tool/build_native.sh host) on LD_LIBRARY_PATH and a
// Paradise dump in PARADISE_DUMP; skipped otherwise.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tama_tools/paradise/paradise_core.dart';

void main() {
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
