import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../services/app_state.dart';
import '../services/rom_library.dart';
import 'paradise_core.dart';

/// Unlocks a Paradise dump for its first start: finds the dump's device key on the phone
/// (Capybara's search over the 2^32 candidates, all cores), stores it with the ROM and starts the
/// game. Nothing to type; the next start is instant.
class ParadiseUnlock extends ChangeNotifier {
  ParadiseUnlock._();
  static final ParadiseUnlock instance = ParadiseUnlock._();

  RomEntry? rom;
  double progress = 0;
  String? error;
  bool get active => rom != null && error == null;
  Timer? _poll;
  final Stopwatch _sw = Stopwatch();

  Duration get elapsed => _sw.elapsed;

  /// Estimated time left, from the rate so far.
  Duration? get remaining {
    if (progress < 0.002 || _sw.elapsedMilliseconds < 3000) return null;
    final total = _sw.elapsedMilliseconds / progress;
    return Duration(milliseconds: (total - _sw.elapsedMilliseconds).round());
  }

  /// Starts a Paradise game; unlocks it first when needed.
  Future<void> play(RomEntry e) async {
    final app = AppState.instance;
    final r = await app.playParadise(e);
    if (r == null) return;
    if (r != 'key') {
      rom = e;
      error = r;
      notifyListeners();
      return;
    }
    await _unlock(e);
  }

  Future<void> _unlock(RomEntry e) async {
    if (rom != null && error == null) return; // one at a time
    final core = ParadiseCore.instance;
    rom = e;
    error = null;
    progress = 0;
    notifyListeners();
    if (core == null) {
      error = 'The Paradise core is not in this build (${ParadiseCore.loadError}).';
      notifyListeners();
      return;
    }
    final app = AppState.instance;
    final path = (await app.library.romFile(e)).path;
    _sw
      ..reset()
      ..start();
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      progress = core.keyProgress();
      notifyListeners();
    });
    final threads = Platform.numberOfProcessors;
    int? key;
    try {
      key = await Isolate.run(() => ParadiseCore.instance!.findKey(path, threads));
    } catch (err) {
      error = 'The search stopped: $err';
    }
    _poll?.cancel();
    _sw.stop();
    if (key == null) {
      error ??= 'This dump could not be unlocked: no key opens its firmware. Is it a complete 16 MB read of the flash?';
      notifyListeners();
      return;
    }
    await app.setParadiseKey(e, key);
    final r = await app.playParadise(e, key: key);
    if (r != null) {
      error = r == 'key' ? 'The key was found but the firmware did not start.' : r;
      notifyListeners();
      return;
    }
    rom = null;
    notifyListeners();
  }

  void cancel() {
    ParadiseCore.instance?.keyStop();
    _poll?.cancel();
    _sw.stop();
    rom = null;
    error = null;
    notifyListeners();
  }
}
