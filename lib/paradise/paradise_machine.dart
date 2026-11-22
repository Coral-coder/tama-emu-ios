import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../services/native.dart';
import 'paradise_core.dart';

/// A running Tamagotchi Paradise: the native core paced to real time (96 million cycles per
/// second), its screen, sound, keys, wheel and save.
class ParadiseMachine extends ChangeNotifier {
  ParadiseMachine({required this.core, required this.dumpPath, required this.savePath, required this.title});

  final ParadiseCore core;
  final String dumpPath;
  final String savePath;
  final String title;
  ParadiseHandle? _h;

  final Uint16List screen = Uint16List(128 * 128);
  int frame = 0; // bumps when the screen changed

  bool sound = true;
  double speed = 1;
  Timer? _timer;
  Timer? _saveTimer;
  final Stopwatch _clock = Stopwatch();
  int _lastUs = 0;
  double _due = 0;
  String? error;
  double load = 0; // share of real time the emulation keeps up with (1 = full speed)
  bool _toneOn = false;

  bool get running => _timer != null;

  /// Boots the dump with its key and the save. Returns 1 ok, 0 key needed / wrong, -1 error.
  int boot(int? key) {
    _h?.dispose();
    final h = ParadiseHandle(core);
    final r = h.load(dumpPath, key);
    if (r != 1) {
      h.dispose();
      error = r == 0 ? 'The firmware stays encrypted: the device key is missing or wrong.' : 'The dump could not be loaded.';
      return r;
    }
    h.openSave(savePath);
    // the game's clock follows the phone (no date and time to set by hand)
    h.syncClock();
    h.autoDate();
    _h = h;
    error = null;
    start();
    _saveTimer = Timer.periodic(const Duration(seconds: 2), (_) => save());
    return 1;
  }

  void start() {
    if (_timer != null || _h == null) return;
    _clock
      ..reset()
      ..start();
    _lastUs = 0;
    _due = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) => _frame());
    notifyListeners();
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    _tone(0);
    save();
    notifyListeners();
  }

  void _frame() {
    final h = _h;
    if (h == null) return;
    final now = _clock.elapsedMicroseconds;
    var dt = (now - _lastUs) / 1e6;
    _lastUs = now;
    // The phone held the app (suspended, or a long stall): the console's clock chip kept counting.
    if (dt > 2) {
      h.advance(dt.floor());
      dt -= dt.floor();
    }
    final cps = core.cyclesPerSecond.toDouble();
    _due += cps * speed * dt;
    // at most a quarter of a second behind: past that the emulation does not race to catch up
    if (_due > cps * 0.25 * speed) _due = cps * 0.25 * speed;
    final want = _due.floor();
    final done = want > 0 ? h.run(want, 12) : 0;
    _due -= done;
    if (dt > 0) load = load * 0.9 + 0.1 * (done / (cps * speed * dt)).clamp(0, 1);
    if (h.screen(screen)) {
      frame++;
      notifyListeners();
    }
    final note = h.note();
    _tone(sound ? note : 0);
    _watchCalls(note);
    if (!h.running) {
      error = 'The console stopped.';
      pause();
    }
  }

  /// While the app is in the background, a sound after a quiet spell is the pet calling:
  /// [onCall] posts a notification (at most one every 10 minutes).
  bool background = false;
  void Function(String title)? onCall;
  int _quietSince = 0;
  int _lastCall = 0;
  void _watchCalls(double note) {
    final ms = DateTime.now().millisecondsSinceEpoch;
    if (note <= 0) {
      if (_quietSince == 0) _quietSince = ms;
      return;
    }
    final quiet = _quietSince == 0 ? 0 : ms - _quietSince;
    _quietSince = 0;
    if (background && quiet > 20000 && ms - _lastCall > 600000) {
      _lastCall = ms;
      onCall?.call(title);
    }
  }

  /// Resumes after the app comes back: the console's clock catches up with the time it was held.
  void resumeAfter(Duration away) {
    if (_h == null) return;
    if (away.inSeconds > 2 && _timer == null) _h!.advance(away.inSeconds);
    start();
  }

  void _tone(double hz) {
    final on = hz > 20;
    if (!on && !_toneOn) return;
    _toneOn = on;
    NativeBridge.tone(on ? (hz * 10).round() : 0, on);
  }

  void press(int pin) => _h?.press(pin);
  void release(int pin) => _h?.release(pin);

  /// One step of the wheel (the two encoder lines in quadrature). Steps queue up, so a quick
  /// spin of the dial plays out step by step.
  Future<void> _turns = Future.value();
  Future<void> turn(bool right) => _turns = _turns.then((_) => _step(right));

  Future<void> _step(bool right) async {
    final h = _h;
    if (h == null) return;
    final a = right ? ParadiseHandle.enc1 : ParadiseHandle.enc2;
    final b = right ? ParadiseHandle.enc2 : ParadiseHandle.enc1;
    const step = Duration(milliseconds: 18);
    h.press(a);
    await Future<void>.delayed(step);
    h.press(b);
    await Future<void>.delayed(step);
    h.release(a);
    await Future<void>.delayed(step);
    h.release(b);
  }

  void save() {
    try {
      _h?.writeSave();
    } catch (e) {
      debugPrint('paradise save: $e');
    }
  }

  bool snapshot(String path) => _h?.snapshot(path) ?? false;
  bool restore(String path) => _h?.restore(path) ?? false;

  @override
  void dispose() {
    _timer?.cancel();
    _saveTimer?.cancel();
    save();
    _tone(0);
    _h?.dispose();
    _h = null;
    super.dispose();
  }

  static Future<bool> exists(String p) => File(p).exists();
}
