// The key search must start on a worker isolate (Neon showed "object is unsendable"). With a file
// that has no encrypted firmware the native search returns at once, so this runs no real search.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tama_tools/paradise/paradise_core.dart';
import 'package:tama_tools/paradise/unlock.dart';

void main() {
  test('the search closure can be sent to an isolate', () async {
    if (ParadiseCore.instance == null) return markTestSkipped('no native core: ${ParadiseCore.loadError}');
    final f = File('${Directory.systemTemp.createTempSync('k').path}/x.bin')..writeAsBytesSync(List.filled(4096, 0xFF));
    final k = await searchDeviceKey(f.path, 1);
    expect(k, isNull);
  });
}
