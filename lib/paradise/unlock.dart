import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../services/app_state.dart';
import '../services/rom_library.dart';
import 'paradise_core.dart';

/// The search itself, on a worker isolate. Top-level on purpose: the closure sent to the isolate
/// may only hold the path and the thread count (an instance method's closure drags `this` along,
/// timers and all, and the isolate refuses it).
Future<int?> searchDeviceKey(String dumpPath, int threads) {
  return Isolate.run(() => ParadiseCore.instance!.findKey(dumpPath, threads));
}

/// Unlocks a Paradise dump for its first start: finds the dump's device key on the phone
/// (Capybara's search over the 2^32 candidates), stores it with the ROM and starts the game.
/// Nothing to type; the next start is instant.
class ParadiseUnlock extends ChangeNotifier {
  ParadiseUnlock._();
  static final ParadiseUnlock instance = ParadiseUnlock._();

  RomEntry? rom;
  String phase = '';
  double progress = 0;
  String? error;
  bool _running = false;
  Timer? _poll;
  final Stopwatch _sw = Stopwatch();

  Duration get elapsed => _sw.elapsed;

  /// Estimated time left, from the rate so far.
  Duration? get remaining {
    if (progress < 0.002 || _sw.elapsedMilliseconds < 3000) return null;
    final total = _sw.elapsedMilliseconds / progress;
    return Duration(milliseconds: (total - _sw.elapsedMilliseconds).round());
  }

  void _set(String p) {
    phase = p;
    notifyListeners();
  }

  void _fail(String e) {
    _poll?.cancel();
    _sw.stop();
    _running = false;
    error = e;
    notifyListeners();
  }

  /// Starts a Paradise game; unlocks it first when needed.
  Future<void> play(RomEntry e) async {
    if (_running) return;
    _running = true;
    rom = e;
    error = null;
    progress = 0;
    _sw
      ..reset()
      ..start();
    // the screen ticks from the first moment, whatever step it is in
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final core = ParadiseCore.instance;
      if (core != null && phase.startsWith('Searching')) progress = core.keyProgress();
      notifyListeners();
    });
    final app = AppState.instance;
    try {
      _set('Unpacking the ROM …');
      final path = (await app.library.romFile(e)).path;
      _set('Starting …');
      final r = await app.playParadise(e);
      if (r == null) return _done();
      if (r != 'key') return _fail(r);
      if (ParadiseCore.instance == null) return _fail('The Paradise core is not in this build (${ParadiseCore.loadError}).');
      _set('Searching for the lock of this dump …');
      final threads = Platform.numberOfProcessors > 2 ? Platform.numberOfProcessors - 1 : 1;
      final key = await searchDeviceKey(path, threads);
      if (!_running) return; // cancelled
      if (key == null) {
        return _fail('This dump could not be unlocked: no key opens its firmware. Is it a complete 16 MB read of the flash?');
      }
      await app.setParadiseKey(e, key);
      _set('Starting …');
      final r2 = await app.playParadise(e, key: key);
      if (r2 != null) return _fail(r2 == 'key' ? 'The key was found but the firmware did not start.' : r2);
      _done();
    } catch (err) {
      _fail('$phase failed: $err');
    }
  }

  void _done() {
    _poll?.cancel();
    _sw.stop();
    _running = false;
    rom = null;
    error = null;
    notifyListeners();
  }

  void cancel() {
    if (phase.startsWith('Searching')) ParadiseCore.instance?.keyStop();
    _done();
  }
}
