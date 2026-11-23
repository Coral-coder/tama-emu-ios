import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../emu/machine.dart';
import '../emu/rom_info.dart';
import '../paradise/paradise_core.dart';
import '../paradise/paradise_machine.dart';
import '../ui/screen_filters.dart';
import 'native.dart';
import 'rom_library.dart';
import 'watch.dart';
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

/// The device key every one of these Paradise dumps opens with.
const int kParadiseKey = 0x5AAF34FB;

class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  final RomLibrary library = RomLibrary.instance;
  final SerialHub serial = SerialHub.instance;
  final Tunnel tunnel = Tunnel.instance;

  TamaMachine? machine;
  RomEntry? machineRom;

  /// The running Tamagotchi Paradise (Capybara core), when one is played.
  ParadiseMachine? paradise;
  RomEntry? paradiseRom;

  LinkMode linkMode = LinkMode.off;
  StreamSubscription<Uint8List>? _uartSub, _tunnelSub;

  bool keepLiving = true;
  bool sound = true;
  bool backgroundRun = true;
  bool ghostDots = true;
  Upscale upscale = Upscale.scale2x;
  ScreenFilter filter = ScreenFilter.none;

  Future<void> setLook({Upscale? upscale, ScreenFilter? filter}) async {
    if (upscale != null) this.upscale = upscale;
    if (filter != null) this.filter = filter;
    await prefs.setString('upscale', this.upscale.name);
    await prefs.setString('filter', this.filter.name);
    notifyListeners();
  }

  late SharedPreferences prefs;

  /// The page the shell shows (0 play, 1 device, 2 studio, 3 link, 4 more).
  final ValueNotifier<int> page = ValueNotifier(0);


  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    keepLiving = prefs.getBool('keepLiving') ?? true;
    sound = prefs.getBool('sound') ?? true;
    backgroundRun = prefs.getBool('backgroundRun') ?? true;
    ghostDots = prefs.getBool('ghostDots') ?? true;
    upscale = Upscale.values.asNameMap()[prefs.getString('upscale')] ?? Upscale.scale2x;
    filter = ScreenFilter.values.asNameMap()[prefs.getString('filter')] ?? ScreenFilter.none;
    NativeBridge.volume = prefs.getDouble('volume') ?? 0.35;
    tunnel.myName = prefs.getString('myName') ?? 'Tama';
    await library.init();
    unawaited(library.unpackAll());
    WatchLink.instance.start();
    final last = prefs.getString('lastToy');
    if (last != null) {
      final e = library.entries.where((x) => x.id == last);
      if (e.isNotEmpty) {
        if (e.first.kind == RomKind.e0c6s4x) {
          await play(e.first);
        } else if (e.first.kind == RomKind.paradise && paradiseKey(e.first) != null) {
          await playParadise(e.first);
        }
      }
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

  /// Device key of a Paradise dump (stored per ROM), or null.
  int? paradiseKey(RomEntry e) {
    final v = prefs.getString('pkey_${e.id}');
    return (v == null ? null : int.tryParse(v, radix: 16)) ?? e.deviceKey ?? kParadiseKey;
  }

  /// Care kept up by itself for a game (bits: 1 feed, 2 play, 4 cure).
  int autoCare(RomEntry e) => prefs.getInt('care_${e.id}') ?? 0;
  Future<void> setAutoCare(String id, int v) => prefs.setInt('care_$id', v);

  Future<void> setParadiseKey(RomEntry e, int key) => prefs.setString('pkey_${e.id}', key.toRadixString(16).padLeft(8, '0'));

  /// Starts a Paradise ROM. Returns null when it runs, or the reason it does not
  /// ('key' when the device key is missing or wrong).
  Future<String?> playParadise(RomEntry e, {int? key}) async {
    final core = ParadiseCore.instance;
    if (core == null) return 'The Paradise core is not in this build (${ParadiseCore.loadError}).';
    await stopToy();
    await stopParadise();
    final dump = await library.romFile(e);
    final m = ParadiseMachine(core: core, dumpPath: dump.path, savePath: library.paradiseSave(e).path, title: e.name)
      ..sound = sound
      ..autoCareBits = autoCare(e)
      ..onCall = (t) => NativeBridge.notify(t.replaceFirst('Tamagotchi Paradise · ', ''), 'Your Tamagotchi is calling you.');
    unawaited(NativeBridge.askToNotify());
    final r = m.boot(key ?? paradiseKey(e));
    if (r != 1) {
      m.dispose();
      return r == 0 ? 'key' : m.error;
    }
    if (key != null) await setParadiseKey(e, key);
    paradise = m;
    paradiseRom = e;
    await prefs.setString('lastToy', e.id);
    if (backgroundRun) await NativeBridge.keepAlive(true, title: 'Tama', text: '${e.name} is living');
    notifyListeners();
    return null;
  }

  Future<void> stopParadise() async {
    final m = paradise;
    if (m == null) return;
    paradise = null;
    paradiseRom = null;
    m.dispose();
    await NativeBridge.keepAlive(false);
    notifyListeners();
  }

  Future<void> play(RomEntry e) async {
    await stopParadise();
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
  DateTime? _bgAt;
  Future<void> onBackground() async {
    _bgAt = DateTime.now();
    paradise?.background = true;
    paradise?.releaseAll();
    paradise?.save();
    if (paradise != null && !backgroundRun) paradise!.pause();
    final m = machine;
    if (m == null) return;
    await m.save();
    if (!backgroundRun) m.pause();
  }

  void onForeground() {
    final away = _bgAt == null ? Duration.zero : DateTime.now().difference(_bgAt!);
    _bgAt = null;
    final p = paradise;
    if (p != null) {
      p.background = false;
      if (!p.running) p.resumeAfter(away);
    }
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
