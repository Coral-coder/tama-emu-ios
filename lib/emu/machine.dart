import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/native.dart';
import 'cpu.dart';
import 'hw.dart';
import 'plink.dart';
import 'rom_info.dart';

enum ToyButton { a, b, c }

/// One running toy: the CPU paced to wall-clock time, its screen, sound, keys, saves and link.
class TamaMachine extends ChangeNotifier implements CpuHost {
  TamaMachine(this.profile, {required this.saveFile}) {
    lcd.wiring = profile.wiring;
    cpu = Cpu(profile.program, this);
    cpu.kmaskFix = true;
  }

  final ToyProfile profile;
  final File saveFile;
  late final Cpu cpu;
  final LcdState lcd = LcdState();

  // ---- settings ----
  bool sound = true;

  /// Keep living while the app is closed: on the next start the time away is played through.
  bool keepLiving = true;
  int _speed = 1;
  int get speed => _speed;

  // ---- pacing ----
  Timer? _timer;
  bool get running => _timer != null;
  int _baseTick = 0;
  int _baseWallUs = 0;
  bool catchingUp = false;
  double catchUpSeconds = 0;
  String? fault;

  // ---- sound ----
  int _bzFreq = buzzerFreqDhz[0];
  bool _bzOut = false, _bzShot = false;
  bool _toneOn = false;
  int _toneSinceTick = 0;

  // ---- keys the program presses itself (clock setting) ----
  final List<(int, int, bool)> _autoKeys = []; // (tick, pin, high)

  // ---- link (Paramix plink, 'D' edge frames) ----
  void Function(Uint8List bytes)? linkOut;
  late final PlinkCodec _codec = PlinkCodec(_onFrame);
  final LinkPlayback _play = LinkPlayback();
  int _lastHelloUs = 0;
  int linkEdgesOut = 0, linkEdgesIn = 0;

  DateTime? lastSaved;
  Timer? _saveTimer;

  static int _nowUs() => DateTime.now().microsecondsSinceEpoch;
  static int usOfTick(int tick) => (tick * 1000000 ~/ kTickFrequency) & 0xFFFFFFFF;

  // ================= lifecycle =================

  /// Loads the saved session (if any) and starts. Returns true when a session was resumed.
  Future<bool> boot() async {
    var resumed = false;
    if (await saveFile.exists()) {
      try {
        resumed = _restore(await saveFile.readAsBytes());
      } catch (e) {
        debugPrint('restore failed: $e');
      }
    }
    if (!resumed) {
      cpu.reset();
      lcd.clear();
      _baseTick = cpu.tickCounter;
      _baseWallUs = _nowUs();
      if (profile.knowsClock) scheduleClockSet(delaySeconds: 3);
    }
    start();
    _saveTimer = Timer.periodic(const Duration(seconds: 30), (_) => save());
    return resumed;
  }

  void start() {
    if (_timer != null) return;
    _rebaseIfNeeded();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) => _frame());
    notifyListeners();
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    _setTone(false);
    notifyListeners();
  }

  bool _pausedByUser = false;
  void togglePause() {
    if (running) {
      _pausedByUser = true;
      pause();
    } else {
      _pausedByUser = false;
      _baseTick = cpu.tickCounter;
      _baseWallUs = _nowUs();
      start();
    }
  }

  bool get pausedByUser => _pausedByUser;

  void _rebaseIfNeeded() {
    if (_baseWallUs == 0 || !keepLiving) {
      _baseTick = cpu.tickCounter;
      _baseWallUs = _nowUs();
    }
  }

  set speed(int s) {
    _baseTick = cpu.tickCounter;
    _baseWallUs = _nowUs();
    _speed = s.clamp(1, 64);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _saveTimer?.cancel();
    _setTone(false);
    super.dispose();
  }

  // ================= the run loop =================

  void _frame() {
    if (fault != null) return;
    final now = _nowUs();
    final target = _baseTick + ((now - _baseWallUs) * kTickFrequency * _speed) ~/ 1000000;
    final behind = target - cpu.tickCounter;
    final wasCatching = catchingUp;
    catchingUp = behind > kTickFrequency * 2 * _speed;
    catchUpSeconds = behind / kTickFrequency;
    final sw = Stopwatch()..start();
    // Up to ~11 ms of work per frame; a long catch-up continues over the next frames.
    while (cpu.tickCounter < target && sw.elapsedMicroseconds < 11000) {
      var stop = cpu.tickCounter + 4096;
      if (stop > target) stop = target;
      if (_autoKeys.isNotEmpty && _autoKeys.first.$1 < stop) stop = _autoKeys.first.$1 < cpu.tickCounter ? cpu.tickCounter + 1 : _autoKeys.first.$1;
      cpu.runUntil(stop);
      if (cpu.fault != null) {
        fault = cpu.fault;
        pause();
        break;
      }
      while (_autoKeys.isNotEmpty && _autoKeys.first.$1 <= cpu.tickCounter) {
        final k = _autoKeys.removeAt(0);
        cpu.setInputPin(k.$2, k.$3);
        if (_autoKeys.isEmpty) _afterClockKeys();
      }
    }
    // A tone longer than 3 s stops (as V1Emu does)
    if (_toneOn && cpu.tickCounter - _toneSinceTick > kTickFrequency * 3) _setTone(false, cut: true);
    if (linkOut != null && now - _lastHelloUs > 1000000) {
      _lastHelloUs = now;
      linkOut!(PlinkCodec.encode(0x48, [0]));
    }
    if (lcd.dirty || wasCatching != catchingUp) {
      lcd.dirty = false;
      notifyListeners();
    }
  }

  // ================= keys =================

  static int _pinOf(ToyButton b) => switch (b) { ToyButton.a => 2, ToyButton.b => 1, ToyButton.c => 0 };

  void press(ToyButton b, bool down) => cpu.setInputPin(_pinOf(b), !down);

  /// The tap / shake sensor (K03) for 120 ms.
  void shake() {
    cpu.setInputPin(3, false);
    Timer(const Duration(milliseconds: 120), () => cpu.setInputPin(3, true));
  }

  // ================= clock =================

  /// Presses the toy's own keys to start its clock (fresh start), then writes the phone's time.
  void scheduleClockSet({double delaySeconds = 0.5}) {
    _autoKeys.clear();
    var t = cpu.tickCounter + (delaySeconds * kTickFrequency).round();
    for (final k in profile.clockSetKeys) {
      final pin = [2, 1, 0][k];
      _autoKeys.add((t, pin, false));
      _autoKeys.add((t + kTickFrequency * 15 ~/ 100, pin, true));
      t += kTickFrequency * 6 ~/ 10;
    }
  }

  void _afterClockKeys() {
    Timer(const Duration(milliseconds: 300), writeClock);
  }

  /// Writes the phone's time of day into the toy's clock nibbles (for the toys whose clock is known).
  void writeClock([DateTime? at]) {
    if (!profile.knowsClock) return;
    final t = at ?? DateTime.now();
    final h = t.hour, m = t.minute, s = t.second;
    final cb = profile.clockBase;
    cpu.setMemory(cb, s % 10);
    cpu.setMemory(cb + 1, s ~/ 10);
    cpu.setMemory(cb + 2, m % 10);
    cpu.setMemory(cb + 3, m ~/ 10);
    if (profile.clock12) {
      cpu.setMemory(cb + 4, h % 12 != 0 ? h % 12 : 12);
      cpu.setMemory(cb + 5, h >= 12 ? 1 : 0);
    } else {
      cpu.setMemory(cb + 4, h & 15);
      cpu.setMemory(cb + 5, h >> 4);
    }
  }

  /// The toy's time of day, or null when its clock was never set.
  Duration? toyClock() {
    if (!profile.knowsClock) return null;
    final cb = profile.clockBase;
    final s = cpu.memory[cb] + 10 * cpu.memory[cb + 1];
    final m = cpu.memory[cb + 2] + 10 * cpu.memory[cb + 3];
    int h;
    if (profile.clock12) {
      h = cpu.memory[cb + 4];
      if (h < 1 || h > 12) return null;
      h = h % 12 + (cpu.memory[cb + 5] != 0 ? 12 : 0);
    } else {
      h = cpu.memory[cb + 4] | (cpu.memory[cb + 5] << 4);
    }
    if (s > 59 || m > 59 || h > 23) return null;
    return Duration(hours: h, minutes: m, seconds: s);
  }

  // ================= CpuHost =================

  @override
  void setLcdPin(int seg, int com, bool on) => lcd.setPin(seg, com, on);

  @override
  void setBuzzerFreq(int code) {
    _bzFreq = buzzerFreqDhz[code & 7];
    if (_toneOn) NativeBridge.tone(_bzFreq, true);
  }

  @override
  void enableBuzzer(bool on) {
    _bzOut = on;
    _applyTone();
  }

  @override
  void buzzerShot(bool on) {
    _bzShot = on;
    _applyTone();
  }

  void _applyTone() => _setTone(_bzOut || _bzShot);

  void _setTone(bool on, {bool cut = false}) {
    final want = on && sound && !catchingUp && running;
    if (want && !_toneOn) _toneSinceTick = cpu.tickCounter;
    _toneOn = want && !cut;
    NativeBridge.tone(_bzFreq, _toneOn);
  }

  @override
  bool linkLineLowFromPeer() => linkOut != null && _play.lineLow(usOfTick(cpu.tickCounter));

  @override
  void linkDriveChanged(bool low, int tick) {
    final out = linkOut;
    if (out == null) return;
    final t = usOfTick(tick);
    linkEdgesOut++;
    out(PlinkCodec.encode(0x44, [low ? 1 : 0, t & 0xFF, (t >> 8) & 0xFF, (t >> 16) & 0xFF, (t >> 24) & 0xFF]));
  }

  /// Bytes from the other side of the link (UART or tunnel).
  void linkIn(List<int> bytes) => _codec.feed(bytes);

  void _onFrame(int type, Uint8List d) {
    if (type != 0x44 || d.length != 5) return;
    linkEdgesIn++;
    _play.push(d[0] != 0, d[1] | (d[2] << 8) | (d[3] << 16) | (d[4] << 24));
  }

  void attachLink(void Function(Uint8List) out) {
    _play.reset();
    linkOut = out;
    notifyListeners();
  }

  void detachLink() {
    linkOut = null;
    _play.reset();
    notifyListeners();
  }

  bool get linked => linkOut != null;
  DateTime? get linkLastRx => _codec.lastRx;

  // ================= saves =================

  static const int _magic = 0x544D5331; // "TMS1"

  Uint8List snapshot() {
    final st = cpu.saveState();
    final h = ByteData(32);
    h.setUint32(0, _magic);
    h.setInt64(4, _nowUs());
    h.setInt64(12, cpu.tickCounter);
    h.setUint32(20, profile.hash);
    h.setUint32(24, st.length);
    h.setUint32(28, keepLiving ? 1 : 0);
    return Uint8List.fromList([...h.buffer.asUint8List(), ...st]);
  }

  bool _restore(Uint8List b) {
    if (b.length < 32) return false;
    final h = ByteData.sublistView(b);
    if (h.getUint32(0) != _magic || h.getUint32(20) != profile.hash) return false;
    final wall = h.getInt64(4);
    final len = h.getUint32(24);
    if (!cpu.loadState(Uint8List.sublistView(b, 32, 32 + len))) return false;
    lcd.dirty = true;
    _baseTick = cpu.tickCounter;
    // Keep living: the toy's time goes on from when it was saved.
    _baseWallUs = keepLiving ? wall : _nowUs();
    return true;
  }

  /// Loads a snapshot made by [snapshot] (a save slot): it runs on from now.
  bool loadSnapshot(Uint8List b) {
    final ok = _restore(b);
    if (ok) {
      _baseTick = cpu.tickCounter;
      _baseWallUs = _nowUs();
      notifyListeners();
    }
    return ok;
  }

  Future<void> save() async {
    if (catchingUp) return; // a half-played absence is not a save point
    try {
      await saveFile.parent.create(recursive: true);
      final tmp = File('${saveFile.path}.tmp');
      await tmp.writeAsBytes(snapshot(), flush: true);
      await tmp.rename(saveFile.path);
      lastSaved = DateTime.now();
    } catch (e) {
      debugPrint('save failed: $e');
    }
  }

  Future<void> resetToy() async {
    pause();
    cpu.reset();
    lcd.clear();
    fault = null;
    _baseTick = cpu.tickCounter;
    _baseWallUs = _nowUs();
    if (profile.knowsClock) scheduleClockSet(delaySeconds: 3);
    start();
    await save();
  }
}
