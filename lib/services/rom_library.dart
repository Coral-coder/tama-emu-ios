import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package:image/image.dart' as img;

import '../emu/rom_info.dart';
import '../paramix/sprites.dart';

/// A game's name as shown: just the ROM's own name ("Neon Planets", not "Tamagotchi Paradise · …").
String shortName(String n) => n.replaceFirst(RegExp(r'^Tamagotchi Paradise\s*[·:\-–]\s*', caseSensitive: false), '').trim();

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
    this.deviceKey,
  });

  final String id;
  String name;
  final RomKind kind;
  final int size;
  final String? asset; // gzip asset in the app bundle
  final File? file; // imported copy in the app's documents
  final String? note;

  /// Device key of a built-in Paradise dump (its firmware is locked to the device it came from).
  final int? deviceKey;

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
          name: shortName(m['name'] as String),
          kind: RomKind.values.byName(m['kind'] as String),
          size: m['size'] as int,
          asset: 'assets/roms/${m['file']}',
          note: m['note'] as String?,
          deviceKey: m['key'] is String ? int.tryParse(m['key'] as String, radix: 16) : null,
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
          name: shortName(m['name'] as String),
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

  static int _writeUnpacked(TransferableTypedData raw, bool gz, String path) {
    final b = raw.materialize().asUint8List();
    final out = gz ? gzip.decode(b) : b;
    File(path).writeAsBytesSync(out, flush: true);
    return out.length;
  }

  /// Adds a ROM; returns the entry (an existing one when the same bytes are there already).
  Future<RomEntry> import(Uint8List b, String fileName, {String? note}) async {
    final kind = detectKind(b);
    final id = fnv1a(b).toRadixString(16).padLeft(8, '0') + b.length.toRadixString(16);
    final have = entries.where((e) => e.id == id);
    if (have.isNotEmpty) return have.first;
    var name = shortName(fileName.replaceAll(RegExp(r'\.(bin|BIN|rom|ROM)$'), '').replaceAll('_', ' ').replaceFirst(RegExp(r'^Tamagotchi[ _]Paradise[ _]', caseSensitive: false), ''));
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

  /// The ROM as a file on disk (the Paradise core reads its dump from a path). Built-in ROMs are
  /// unpacked once into the app's documents.
  /// The ROM as a file the emulator opens. Built-in ROMs are unpacked once, off the UI thread
  /// (gunzip and write on a worker isolate), and kept.
  final Map<String, Future<File>> _unpacking = {};
  Future<File> romFile(RomEntry e) {
    if (e.file != null) return Future.value(e.file!);
    return _unpacking.putIfAbsent(e.id, () async {
      try {
        return await _unpack(e);
      } catch (_) {
        _unpacking.remove(e.id); // try again next time
        rethrow;
      }
    });
  }

  Future<File> _unpack(RomEntry e) async {
    final f = File('${docs.path}/unpacked/${e.id}.bin');
    if (await f.exists() && await f.length() == e.size) return f;
    await f.parent.create(recursive: true);
    final data = await rootBundle.load(e.asset!);
    final raw = TransferableTypedData.fromList([data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)]);
    final gz = e.asset!.endsWith('.gz');
    final tmp = '${f.path}.part';
    final n = await Isolate.run(() => _writeUnpacked(raw, gz, tmp));
    if (n != e.size) throw 'the built-in ROM unpacked to $n bytes, not ${e.size}';
    await File(tmp).rename(f.path);
    return f;
  }

  /// Unpacks every built-in ROM in the background (after launch), so a game starts at once.
  Future<void> unpackAll() async {
    for (final e in entries.where((e) => e.asset != null)) {
      try {
        await romFile(e);
      } catch (err) {
        debugPrint('unpack ${e.name}: $err');
      }
    }
  }

  /// Cover picture of a ROM (PNG), taken from the ROM's own graphics: a Paradise shows its
  /// edition's field. Null for ROMs without pictures (the first toys draw their own).
  /// A ROM changed on disk (its pictures): its cover and unpacked copy are made again.
  Future<void> forget(RomEntry e) async {
    _covers.remove(e.id);
    _unpacking.remove(e.id);
    for (final f in [File('${docs.path}/covers/${e.id}.png'), File('${docs.path}/unpacked/${e.id}.bin')]) {
      if (await f.exists()) await f.delete();
    }
  }

  final Map<String, Future<File?>> _covers = {};
  Future<File?> cover(RomEntry e) => _covers.putIfAbsent(e.id, () => _makeCover(e));

  Future<File?> _makeCover(RomEntry e) async {
    if (e.kind != RomKind.paradise) return null;
    final f = File('${docs.path}/covers/${e.id}.png');
    if (await f.exists()) return f;
    try {
      final png = await compute(_coverPng, await bytes(e));
      if (png == null) return null;
      await f.parent.create(recursive: true);
      await f.writeAsBytes(png, flush: true);
      return f;
    } catch (err) {
      debugPrint('cover ${e.name}: $err');
      return null;
    }
  }

  static Uint8List? _coverPng(Uint8List rom) {
    final c = paradiseCover(rom);
    if (c == null) return null;
    final im = img.Image.fromBytes(width: c.w, height: c.h, bytes: c.data.buffer, numChannels: 4);
    return img.encodePng(img.copyResize(im, width: 256, height: 256, interpolation: img.Interpolation.average));
  }

  File paradiseSave(RomEntry e) => File('${saveDir.path}/paradise-${e.id}.save');
  File slotFileFor(String toyId, int slot) => File('${saveDir.path}/$toyId.slot$slot');
}
