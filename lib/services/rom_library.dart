import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../emu/rom_info.dart';

/// One ROM in the library: built into the app (assets/roms) or imported by the user.
class RomEntry {
  RomEntry({
    required this.id,
    required this.name,
    required this.kind,
    required this.size,
    this.asset,
    this.file,
    this.note,
  });

  final String id;
  String name;
  final RomKind kind;
  final int size;
  final String? asset; // gzip asset in the app bundle
  final File? file; // imported copy in the app's documents
  final String? note;

  bool get bundled => asset != null;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'kind': kind.name, 'size': size, 'note': note};
}

class RomLibrary extends ChangeNotifier {
  RomLibrary._();
  static final RomLibrary instance = RomLibrary._();

  final List<RomEntry> entries = [];
  late Directory docs;
  late Directory romDir;
  late Directory saveDir;
  late Directory studioOut;
  bool ready = false;

  Future<void> init() async {
    docs = await getApplicationDocumentsDirectory();
    romDir = Directory('${docs.path}/roms');
    saveDir = Directory('${docs.path}/saves');
    studioOut = Directory('${docs.path}/studio');
    for (final d in [romDir, saveDir, studioOut]) {
      await d.create(recursive: true);
    }
    await reload();
    ready = true;
    notifyListeners();
  }

  Future<void> reload() async {
    entries.clear();
    // Built-in ROMs: assets/roms/index.json lists them (written by tool/roms.sh at build time).
    try {
      final idx = jsonDecode(await rootBundle.loadString('assets/roms/index.json')) as List;
      for (final e in idx) {
        final m = e as Map<String, dynamic>;
        entries.add(RomEntry(
          id: m['id'] as String,
          name: m['name'] as String,
          kind: RomKind.values.byName(m['kind'] as String),
          size: m['size'] as int,
          asset: 'assets/roms/${m['file']}',
          note: m['note'] as String?,
        ));
      }
    } catch (_) {
      // No ROMs built into this build (public builds leave them out).
    }
    // Imported ROMs: <id>.bin with <id>.json next to it.
    await for (final f in romDir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final bin = File(f.path.replaceAll(RegExp(r'\.json$'), '.bin'));
        if (!await bin.exists()) continue;
        if (entries.any((e) => e.id == m['id'])) continue;
        entries.add(RomEntry(
          id: m['id'] as String,
          name: m['name'] as String,
          kind: RomKind.values.byName(m['kind'] as String),
          size: m['size'] as int,
          file: bin,
          note: m['note'] as String?,
        ));
      } catch (_) {}
    }
    entries.sort((a, b) {
      final k = a.kind.index.compareTo(b.kind.index);
      return k != 0 ? k : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    notifyListeners();
  }

  Future<Uint8List> bytes(RomEntry e) async {
    if (e.file != null) return e.file!.readAsBytes();
    final data = await rootBundle.load(e.asset!);
    final raw = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    return e.asset!.endsWith('.gz') ? await compute(_gunzip, raw) : Uint8List.fromList(raw);
  }

  static Uint8List _gunzip(Uint8List b) => Uint8List.fromList(gzip.decode(b));

  /// Adds a ROM; returns the entry (an existing one when the same bytes are there already).
  Future<RomEntry> import(Uint8List b, String fileName, {String? note}) async {
    final kind = detectKind(b);
    final id = fnv1a(b).toRadixString(16).padLeft(8, '0') + b.length.toRadixString(16);
    final have = entries.where((e) => e.id == id);
    if (have.isNotEmpty) return have.first;
    var name = fileName.replaceAll(RegExp(r'\.(bin|BIN|rom|ROM)$'), '').replaceAll('_', ' ');
    if (kind == RomKind.e0c6s4x) {
      final p = ToyProfile(b);
      if (!p.name.startsWith('TAMA 4')) name = p.displayName;
    }
    final e = RomEntry(id: id, name: name, kind: kind, size: b.length, file: File('${romDir.path}/$id.bin'), note: note);
    await e.file!.writeAsBytes(b, flush: true);
    await File('${romDir.path}/$id.json').writeAsString(jsonEncode(e.toJson()));
    await reload();
    return entries.firstWhere((x) => x.id == id);
  }

  Future<void> rename(RomEntry e, String name) async {
    e.name = name;
    if (e.file != null) {
      await File('${romDir.path}/${e.id}.json').writeAsString(jsonEncode(e.toJson()));
    }
    notifyListeners();
  }

  Future<void> remove(RomEntry e) async {
    if (e.file == null) return;
    await e.file!.delete();
    final j = File('${romDir.path}/${e.id}.json');
    if (await j.exists()) await j.delete();
    await reload();
  }

  /// Writes the ROM to a temporary file (for sharing / exporting).
  Future<File> exportFile(RomEntry e) async {
    final dir = await getTemporaryDirectory();
    final safe = e.name.replaceAll(RegExp(r'[^A-Za-z0-9 _.-]'), '_');
    final f = File('${dir.path}/$safe.bin');
    await f.writeAsBytes(await bytes(e), flush: true);
    return f;
  }

  File saveFileFor(String toyId) => File('${saveDir.path}/$toyId.state');
  File slotFileFor(String toyId, int slot) => File('${saveDir.path}/$toyId.slot$slot');
}
