// dart run tool/cover_check.dart <rom> <out.png>: decodes the ROM's cover (and prints a CRC of its RGBA)
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:tama_tools/paramix/bytes.dart';
import 'package:tama_tools/paramix/edition.dart';
import 'package:tama_tools/paramix/sprites.dart';

void main(List<String> a) {
  final rom = File(a[0]).readAsBytesSync();
  final sw = Stopwatch()..start();
  final c = paradiseCover(rom)!;
  stdout.writeln('${edition(rom)?.name} ${c.w}x${c.h} crc ${crc32(c.data).toRadixString(16)} in ${sw.elapsedMilliseconds} ms');
  final im = img.Image.fromBytes(width: c.w, height: c.h, bytes: c.data.buffer, numChannels: 4);
  File(a[1]).writeAsBytesSync(img.encodePng(img.copyResize(im, width: 256)));
}
