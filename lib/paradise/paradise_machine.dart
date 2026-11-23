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
    // the date screens of a new start confirm themselves when the clock could be set (the form
    // is then filled in with the phone's date)
    if (h.syncClock() > 0) h.autoDate();
    h.autoCare(_autoCare);
    _h = h;
    error = null;
    start();
    // the save is written when it changed: every 2 s on screen, every 30 s in the background
    var n = 0;
    _saveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_bg || ++n % 15 == 0) save();
    });
    return 1;
  }

  void start() {
    if (_timer != null || _h == null) return;
    _clock
      ..reset()
      ..start();
    _lastUs = 0;
    _due = 0;
    _schedule(Duration.zero);
    notifyListeners();
  }

  /// The next slice. On screen: 60 a second (10 while the console sleeps, a key brings it back
  /// at once). In the background: once a second while it is awake, and while it sleeps not
  /// before its alarm (at most a minute): nothing can happen before then, and the phone stays
  /// asleep in between.
  void _schedule(Duration d) {
    _timer?.cancel();
    _timer = Timer(d, _tick);
  }

  int _nextMs = 16;
  void _tick() {
    _frame();
    final h = _h;
    if (_timer == null || h == null) return;
    if (!h.running) return;
    if (!_bg) {
      _nextMs = h.sleeping && link == null ? 100 : 16;
      _plan(this, 0);
    } else {
      final idle = link == null ? h.idleSeconds : 0;
      _nextMs = idle > 1 ? (idle.clamp(1, 60) * 1000) : 1000;
      _plan(this, idle > 1 ? idle : 0);
    }
    _schedule(Duration(milliseconds: _nextMs));
  }

  /// Every running console's wish: 0 needs the processor now, n sleeps n seconds by itself.
  static final Map<ParadiseMachine, int> _wishes = {};
  static void _plan(ParadiseMachine m, int? idle) {
    if (idle == null) {
      _wishes.remove(m);
    } else {
      _wishes[m] = idle;
    }
    if (_wishes.isEmpty) return;
    final awake = _wishes.values.any((v) => v == 0);
    // Android: while they all sleep the processor rests, woken by an alarm a moment before the
    // first console's own (a minute at most: the alarm is re-armed on every look)
    NativeBridge.power(hold: awake, wakeIn: awake ? 0 : _wishes.values.reduce((a, b) => a < b ? a : b).clamp(1, 3600));
  }

  /// A key or the dial: on screen the console answers at once, also from its slow sleeping pace.
  void _kick() {
    if (_timer != null && !_bg && _nextMs > 16) {
      _nextMs = 16;
      _schedule(Duration.zero);
    }
  }

  void pause() {
    releaseAll();
    _timer?.cancel();
    _timer = null;
    _plan(this, null);
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
    // (a background tick that waited for the alarm is run, not jumped: the core skips the parked
    // time itself and rings the alarm on the second)
    if (dt > (_bg && _nextMs > 1000 ? 65 : 2)) {
      h.advance(dt.floor());
      dt -= dt.floor();
    }
    final cps = core.cyclesPerSecond.toDouble();
    _due += cps * speed * dt;
    // at most a quarter of a second behind (two in the background, run once a second): past that
    // the emulation does not race to catch up
    // Never more than a short slice of work at a time (the screen must stay smooth, also with
    // other games living in the background). What cannot be run in time is not lost: the
    // console's clock skips it, as the toy's clock chip keeps counting while it sleeps.
    // (in the background a sleeping console runs whole minutes in one go: it is parked, the core
    // skips straight to its alarm, so that costs next to nothing)
    final cap = (_bg ? (_nextMs > 1000 ? 61.0 : 1.5) : 0.25) * cps * speed;
    if (_due > cap) {
      _skipped += (_due - cap) / cps;
      _due = cap;
      final whole = _skipped.floor();
      if (whole > 0) {
        h.advance(whole);
        _skipped -= whole;
      }
    }
    final want = _due.floor();
    final done = (want > 0 ? h.run(want, _bg ? 30 : 12) : 0).clamp(0, want > 0 ? want : 0);
    _due -= done;
    if (dt > 0) load = load * 0.9 + 0.1 * (done / (cps * speed * dt)).clamp(0, 1);
    // in the background the screen is still read, once a second: the game cards show it live
    if ((!_bg || now - _shotUs > 1000000) && h.screen(screen)) {
      _shotUs = now;
      frame++;
      notifyListeners();
    }
    link?.pump();
    final note = h.note();
    // the buzzer plays while the game is on screen; in the background a notification calls
    _tone(sound && !_bg ? note : 0);
    _watchCalls(note);
    // the console sleeps when left alone, like the toy (a key or the dial wakes it); only with
    // "keep the screen on" is it woken right away
    if (!background && keepScreenOn && h.sleeping) h.wake();
    if (!h.running) {
      error = 'The console stopped.';
      pause();
    }
  }

  /// While the app is in the background, every sound (after 3 s of quiet: one melody is one
  /// sound) makes [onCall] post a notification.
  /// In the background nothing is drawn and the console is run once a second: while it sleeps
  /// (most of the time) the core skips ahead to its next alarm, so little battery goes by.
  bool _bg = false;
  int _shotUs = 0;
  double _skipped = 0; // seconds the clock still owes (time that could not be run)
  bool get background => _bg;
  set background(bool v) {
    if (v == _bg) return;
    _bg = v;
    if (_timer != null) {
      _nextMs = _bg ? 1000 : 16;
      _schedule(Duration.zero);
    }
  }
  bool keepScreenOn = false;
  void Function(String title)? onCall;
  int _quietSince = 0;
  void _watchCalls(double note) {
    final ms = DateTime.now().millisecondsSinceEpoch;
    if (note <= 0) {
      if (_quietSince == 0) _quietSince = ms;
      return;
    }
    final quiet = _quietSince == 0 ? 0 : ms - _quietSince;
    _quietSince = 0;
    if (background && quiet > 3000) onCall?.call(title);
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

  /// What the console sent on its link port, and bytes for it (see [ParadiseLink]).
  Uint8List linkTake() => _h?.linkTake() ?? Uint8List(0);
  void linkGive(Uint8List d) => _h?.linkGive(d);
  void linkClear() => _h?.linkClear();

  /// The link this console is on (another game, or a real unit), pumped every frame.
  ParadiseLink? link;

  void press(int pin) {
    _h?.press(pin);
    _kick();
  }
  /// Nothing stays held (the app went to the background, a sheet opened over the keys).
  void releaseAll() => _h?.releaseAll();
  void release(int pin) => _h?.release(pin);

  /// One step of the wheel: played by the core in console time, so no edge is lost between
  /// two frames (a quick spin of the dial queues its steps).
  Future<void> turn(bool right) async {
    _h?.turn(right);
    _kick();
  }

  /// The reset button: the console restarts on its save, the clock set again from the phone.
  void reset() {
    final h = _h;
    if (h == null) return;
    save();
    h.reset();
    if (h.syncClock() > 0) h.autoDate();
    if (!running) start();
  }

  PetState? pet() => _h?.pet();
  bool care(int what) => _h?.care(what) ?? false;
  Uint8List? block() => _h?.block();
  bool blockWrite(int offset, List<int> bytes) => _h?.blockWrite(offset, bytes) ?? false;
  int get consoleSeconds => _h?.seconds ?? 0;
  (int, int) petPlaces() => _h?.petPlaces() ?? (0x104, 0x7C);
  int _autoCare = 0;
  int get autoCareBits => _autoCare;
  set autoCareBits(int v) {
    _autoCare = v;
    _h?.autoCare(v);
  }

  /// Types [text] into the game's naming screen (the cursor on the box to fill): for each
  /// character the picker opens (OK), the group is chosen (letters or digits: → steps through the
  /// groups), OK enters it, the dial turns to the character, OK writes it and the cursor moves on.
  /// Letters A to Z, digits and spaces; returns the characters it could not type.
  bool typing = false;
  double typingProgress = 0;
  Future<String> typeText(String text, {void Function()? onStep}) async {
    if (typing || _h == null) return text;
    typing = true;
    final skipped = StringBuffer();
    Future<void> key(int pin) async {
      press(pin);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      release(pin);
      await Future<void>.delayed(const Duration(milliseconds: 650));
    }

    try {
      final chars = text.toUpperCase().split('');
      for (var n = 0; n < chars.length; n++) {
        final c = chars[n];
        final p = _pickerPlace(c);
        if (p == null) {
          skipped.write(c);
          continue;
        }
        await key(ParadiseHandle.pinB); // open the picker (letters)
        for (var g = 0; g < p.$1; g++) {
          await key(ParadiseHandle.pinA); // next group
        }
        await key(ParadiseHandle.pinB); // into the group
        for (var i = 0; i < p.$2; i++) {
          await turn(true);
          await Future<void>.delayed(const Duration(milliseconds: 280));
        }
        await key(ParadiseHandle.pinB); // write it; the cursor moves on
        typingProgress = (n + 1) / chars.length;
        notifyListeners();
      }
    } finally {
      typing = false;
      typingProgress = 0;
      notifyListeners();
    }
    return skipped.toString();
  }

  /// (group, steps) of a character in the picker: the groups go letters, digits, symbols, ...;
  /// in a group the characters come six at a time with a space between ("ABCDEF GHIJKL ...").
  static (int, int)? _pickerPlace(String c) {
    const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    const digits = '1234567890';
    if (c == ' ') return (0, 6);
    final l = letters.indexOf(c);
    if (l >= 0) return (0, l + l ~/ 6);
    final d = digits.indexOf(c);
    if (d >= 0) return (1, d + d ~/ 6);
    return null;
  }

  void save() {
    try {
      _h?.writeSave();
    } catch (e) {
      debugPrint('paradise save: $e');
    }
  }

  bool snapshot(String path) => _h?.snapshot(path) ?? false;

  /// The live memory (see [ParadiseHandle.memRead]); null when not running.
  ParadiseHandle? get handle => _h;

  /// The ROM with this game's save in it, ready to flash to the real toy.
  bool exportFlash(String path) {
    save();
    return _h?.exportFlash(path) ?? false;
  }
  bool restore(String path) => _h?.restore(path) ?? false;

  @override
  void dispose() {
    _timer?.cancel();
    _plan(this, null);
    _saveTimer?.cancel();
    save();
    _tone(0);
    _h?.dispose();
    _h = null;
    super.dispose();
  }

  static Future<bool> exists(String p) => File(p).exists();
}

/// A wire on the console's link port.
abstract class ParadiseLink {
  void pump();
  String get status;
  Future<void> close();
}

/// Two games of the app, link port to link port (as two units held together).
class TwinLink implements ParadiseLink {
  TwinLink(this.a, this.b) {
    a.linkClear();
    b.linkClear();
    a.link = this;
    b.link = this;
  }
  final ParadiseMachine a, b;
  int ab = 0, ba = 0;

  @override
  void pump() {
    final x = a.linkTake();
    if (x.isNotEmpty) {
      b.linkGive(x);
      ab += x.length;
    }
    final y = b.linkTake();
    if (y.isNotEmpty) {
      a.linkGive(y);
      ba += y.length;
    }
  }

  @override
  String get status => 'Linked · ${a.title.replaceFirst('Tamagotchi Paradise · ', '')} → $ab bytes, ← $ba bytes';

  @override
  Future<void> close() async {
    if (a.link == this) a.link = null;
    if (b.link == this) b.link = null;
  }
}
