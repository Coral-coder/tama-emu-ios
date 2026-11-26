// Builds ROMs with the native compose (menu, six fields) from the dumps in DUMPS into OUT, to try
// ignore_for_file: avoid_print
// them in the emulator (native/tama_core examples). Prints sizes and hashes only.
import 'dart:io';
import 'dart:typed_data';

import 'package:tama_tools/paramix/compose.dart';
import 'package:tama_tools/paramix/feld.dart';
import 'package:tama_tools/paramix/six.dart';

Uint8List f(String p) => File(p).readAsBytesSync();
void main() {
  final d = Platform.environment['DUMPS']!, out = Platform.environment['OUT']!;
  const p = 'third_party/paramix-studio';
  final a = ComposeAssets(feld: f('$p/feld/feld.bin'), feldS: f('$p/feld/feld_s.bin'), stubFeld: f('$p/feld/stub_feld_tpl.bin'), stubEmu: f('$p/emu/stub_tpl.bin'), six: f('$p/six/six.bin'));
  void make(String name, String base, ComposeOptions o) {
    try {
      final r = composeRom(f('$d/$base.bin'), o, a);
      File('$out/$name.bin').writeAsBytesSync(r);
      final fi = feldFind(r, a.stubFeld);
      print('$name: ok, fields ${fieldNames(r)}, menu ${fi != null ? 'v${fi.version} flags ${fi.flags}' : 'none'}, six ${sixInfo(r)?.version}');
    } catch (e) {
      print('$name: $e');
    }
  }

  make('tropical-six-menu', 'tropical', ComposeOptions(fields: true, bag: true, tama: true, sixWant: true, sixSource: f('$d/land.bin')));
  make('glacier-six', 'glacier', ComposeOptions(sixWant: true, sixSource: f('$d/water.bin')));
  make('jade-sky-menu', 'jade', const ComposeOptions(fields: true, bag: true, tama: true, sixWant: true));
  make('water-menu', 'water', const ComposeOptions(fields: true, bag: true, tama: true));
  make('neon-menu', 'neon', const ComposeOptions(bag: true, tama: true));
  final six = File('$out/tropical-six-menu.bin');
  if (six.existsSync()) {
    try {
      final b = six.readAsBytesSync();
      final r = composeRom(b, ComposeOptions.of(b, a, texts: {14: 'MY ISLAND', 64: 'HOME'}), a);
      File('$out/tropical-six-names.bin').writeAsBytesSync(r);
      print('tropical-six-names: ok, fields ${fieldNames(r)}, texts ${fieldTexts(r)}, menu ${feldFind(r, a.stubFeld) != null}, six ${sixInfo(r)?.version}');
    } catch (e) {
      print('tropical-six-names: $e');
    }
  }
  make('tropical-six-nosource', 'tropical', const ComposeOptions(sixWant: true));
}
