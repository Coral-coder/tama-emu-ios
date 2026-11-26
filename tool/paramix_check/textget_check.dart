// textGet of every edition, hashed (compare with the same loop over core.js in Node).
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:tama_tools/paramix/core_more.dart';

void main() {
  for (final n in ['water', 'land', 'sky', 'jade', 'tropical', 'glacier', 'neon']) {
    final r = File('${Platform.environment['DUMPS']}/$n.bin').readAsBytesSync();
    final s = StringBuffer();
    for (var i = 0; i < 120; i++) {
      s.write('${textGet(r, i)}|');
    }
    print('$n ${sha256.convert(utf8.encode(s.toString()))}');
  }
}
