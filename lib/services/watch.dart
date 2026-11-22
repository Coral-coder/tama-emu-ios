import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'rom_library.dart';

/// The Apple Watch link: a game (dump, key, save) goes to the watch, and the watch's saves come
/// back, so the pet lives on whichever one plays it.
class WatchLink {
  WatchLink._();
  static final WatchLink instance = WatchLink._();
  static const _ch = MethodChannel('tama/watch');

  bool get available => Platform.isIOS;
  final Set<String> _sentDumps = {};

  void start() {
    if (!available) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'save') await _received(Map<String, dynamic>.from(call.arguments as Map));
      return null;
    });
    _pending();
  }

  Future<void> _pending() async {
    try {
      final list = await _ch.invokeMethod<List<dynamic>>('pending') ?? [];
      for (final m in list) {
        await _received(Map<String, dynamic>.from(m as Map));
      }
    } catch (e) {
      debugPrint('watch pending: $e');
    }
  }

  /// A save from the watch: it replaces the phone's (the game restarts on it when it is open here).
  Future<void> _received(Map<String, dynamic> m) async {
    final app = AppState.instance;
    final id = m['id'] as String?;
    final path = m['path'] as String?;
    if (id == null || path == null) return;
    final e = app.library.entries.where((x) => x.id == id);
    if (e.isEmpty) return;
    final f = File(path);
    if (!await f.exists()) return;
    final playing = app.paradiseRom?.id == id;
    if (playing) await app.stopParadise();
    final dest = app.library.paradiseSave(e.first);
    await dest.parent.create(recursive: true);
    await f.copy(dest.path);
    await f.delete();
    if (playing) await app.playParadise(e.first);
  }

  /// Sends a game to the watch; the phone stops playing it (the watch has it now).
  Future<String?> send(RomEntry e) async {
    final app = AppState.instance;
    try {
      final st = Map<String, dynamic>.from(await _ch.invokeMethod('status') as Map);
      if (st['supported'] != true || st['paired'] != true) return 'No Apple Watch is paired with this iPhone.';
      if (st['installed'] != true) return 'Install Tama on your Apple Watch first (Watch app on the iPhone → Available apps).';
      if (app.paradiseRom?.id == e.id) await app.stopParadise();
      // a new game is set up on the phone; the watch only carries on a game already started
      final save = app.library.paradiseSave(e);
      if (!await save.exists() || await save.length() == 0) {
        return 'Start this game on the iPhone first (hatch and name your Tamagotchi), then send it to the watch.';
      }
      final dump = await app.library.romFile(e);
      await _ch.invokeMethod('send', {
        'id': e.id,
        'name': e.name,
        'key': app.paradiseKey(e) ?? 0x5AAF34FB,
        'care': app.autoCare(e),
        'dump': dump.path,
        'sendDump': !_sentDumps.contains(e.id),
        'save': app.library.paradiseSave(e).path,
      });
      _sentDumps.add(e.id);
      return null;
    } on PlatformException catch (err) {
      return err.message ?? '$err';
    } catch (err) {
      return '$err';
    }
  }
}
