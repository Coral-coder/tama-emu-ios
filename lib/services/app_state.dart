import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../emu/machine.dart';
import '../emu/rom_info.dart';
import 'native.dart';
import 'rom_library.dart';
import 'serial/serial_hub.dart';
import 'tunnel.dart';

/// Where the link goes.
enum LinkMode {
  off('Off'),

  /// The emulated toy talks to a real one on the UART (a Paradise running V1Emu, Paramix plink).
  emuUart('Emulator ↔ UART'),

  /// The emulated toy talks to the other phone (its emulator or its UART).
  emuTunnel('Emulator ↔ Tunnel'),

  /// The UART is relayed to the other phone: two real toys through two phones.
  uartTunnel('UART ↔ Tunnel');

  const LinkMode(this.label);
  final String label;
}

class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  final RomLibrary library = RomLibrary.instance;
  final SerialHub serial = SerialHub.instance;
  final Tunnel tunnel = Tunnel.instance;

  TamaMachine? machine;
  RomEntry? machineRom;

  LinkMode linkMode = LinkMode.off;
  StreamSubscription<Uint8List>? _uartSub, _tunnelSub;

  bool keepLiving = true;
  bool sound = true;
  bool backgroundRun = true;
  bool ghostDots = true;

  late SharedPreferences prefs;

  /// The page the shell shows (0 play, 1 library, 2 studio, 3 hardware, 4 link).
  final ValueNotifier<int> page = ValueNotifier(0);

  /// A ROM waiting to be opened by the Studio page.
  final ValueNotifier<RomEntry?> studioOpen = ValueNotifier(null);

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    keepLiving = prefs.getBool('keepLiving') ?? true;
    sound = prefs.getBool('sound') ?? true;
    backgroundRun = prefs.getBool('backgroundRun') ?? true;
    ghostDots = prefs.getBool('ghostDots') ?? true;
    NativeBridge.volume = prefs.getDouble('volume') ?? 0.35;
    tunnel.myName = prefs.getString('myName') ?? 'Tama';
    await library.init();
    final last = prefs.getString('lastToy');
    if (last != null) {
      final e = library.entries.where((x) => x.id == last && x.kind == RomKind.e0c6s4x);
      if (e.isNotEmpty) await play(e.first);
    }
  }

  Future<void> setPref(String k, Object v) async {
    switch (v) {
      case bool b:
        await prefs.setBool(k, b);
      case double d:
        await prefs.setDouble(k, d);
      case String s:
        await prefs.setString(k, s);
    }
    notifyListeners();
  }

  Future<void> play(RomEntry e) async {
    await stopToy();
    final bytes = await library.bytes(e);
    final profile = ToyProfile(bytes);
    final m = TamaMachine(profile, saveFile: library.saveFileFor('${profile.id}-${e.id}'))
      ..keepLiving = keepLiving
      ..sound = sound;
    machine = m;
    machineRom = e;
    await prefs.setString('lastToy', e.id);
    await m.boot();
    if (backgroundRun) await NativeBridge.keepAlive(true, title: 'Tama', text: '${profile.displayName} is living');
    _wireLink();
    notifyListeners();
  }

  Future<void> stopToy() async {
    final m = machine;
    if (m == null) return;
    m.detachLink();
    await m.save();
    m.dispose();
    machine = null;
    machineRom = null;
    await NativeBridge.keepAlive(false);
    notifyListeners();
  }

  /// App lifecycle: going to the background / coming back.
  Future<void> onBackground() async {
    final m = machine;
    if (m == null) return;
    await m.save();
    if (!backgroundRun) m.pause();
  }

  void onForeground() {
    final m = machine;
    if (m == null) return;
    if (!m.running && !m.pausedByUser) m.start(); // catches up the time away when keepLiving
  }

  // ---------------- link routing ----------------

  void setLinkMode(LinkMode mode) {
    linkMode = mode;
    _wireLink();
    notifyListeners();
  }

  void _wireLink() {
    _uartSub?.cancel();
    _tunnelSub?.cancel();
    _uartSub = _tunnelSub = null;
    final m = machine;
    m?.detachLink();
    switch (linkMode) {
      case LinkMode.off:
        break;
      case LinkMode.emuUart:
        if (m == null) break;
        m.attachLink((b) => serial.write(b));
        _uartSub = serial.input.listen(m.linkIn);
        break;
      case LinkMode.emuTunnel:
        if (m == null) break;
        m.attachLink((b) => tunnel.sendData(b));
        _tunnelSub = tunnel.data.listen(m.linkIn);
        break;
      case LinkMode.uartTunnel:
        _uartSub = serial.input.listen((b) => tunnel.sendData(b));
        _tunnelSub = tunnel.data.listen((b) => serial.write(b));
        break;
    }
  }
}
