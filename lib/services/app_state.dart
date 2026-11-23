import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import '../emu/machine.dart';
import '../emu/rom_info.dart';
import '../paradise/paradise_core.dart';
import '../paradise/paradise_machine.dart';
import '../ui/screen_filters.dart';
import 'native.dart';
import '../paradise/unit_link.dart';
import '../ui/shell_theme.dart';
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
  /// Every Paradise game that is running (several at once: each lives on, its own save, in the
  /// background), and the one on screen.
  final Map<String, ParadiseMachine> games = {};
  final Map<String, RomEntry> gameRoms = {};
  String? focused;
  ParadiseMachine? get paradise => focused == null ? null : games[focused];
  RomEntry? get paradiseRom => focused == null ? null : gameRoms[focused];
  /// A second game running beside the first, linked to it (two units held together).
  ParadiseMachine? partner;
  RomEntry? partnerRom;
  ParadiseLink? get link => paradise?.link;

  LinkMode linkMode = LinkMode.off;
  StreamSubscription<Uint8List>? _uartSub, _tunnelSub;

  bool keepLiving = true;
  bool sound = true;
  bool backgroundRun = true;
  /// Keeps the console (and the phone's screen) awake while a game is shown. Off: it sleeps like
  /// the toy, and spends far less battery.
  bool keepScreenOn = false;
  /// When the pet calls, the watch pops up and sounds too (not only the phone).
  bool watchCalls = true;

  /// The app coloured like a toy (shell, buttons, dial): this is the default; each Paradise game
  /// has its own, first taken from its artwork, then as you change it.
  ShellTheme shellTheme = ShellTheme.presets.first;
  final Map<String, ShellTheme> _gameThemes = {};
  ShellTheme themeOf(String? id) => (id == null ? null : _gameThemes[id]) ?? shellTheme;
  ShellTheme get currentTheme => themeOf(focused);

  Future<void> setGameTheme(String id, ShellTheme t) async {
    _gameThemes[id] = t;
    await prefs.setString('theme_$id', t.encode());
    notifyListeners();
  }

  /// The game's theme: the one saved for it, or one made from its artwork.
  Future<void> ensureGameTheme(RomEntry e, {bool fresh = false}) async {
    if (e.kind != RomKind.paradise) return;
    final saved = fresh ? null : ShellTheme.decode(prefs.getString('theme_${e.id}'));
    if (saved != null) {
      _gameThemes[e.id] = saved;
      return;
    }
    final ed = editionTheme(e.name);
    if (ed != null) {
      await setGameTheme(e.id, ed);
      return;
    }
    try {
      final cover = await library.cover(e);
      if (cover == null) return;
      final im = img.decodePng(await cover.readAsBytes());
      if (im == null) return;
      final t = themeFromPixels(e.name, im.convert(numChannels: 4).toUint8List());
      await setGameTheme(e.id, t);
    } catch (err) {
      debugPrint('theme ${e.name}: $err');
    }
  }
  Future<void> setShellTheme(ShellTheme t) async {
    shellTheme = t;
    await prefs.setString('shellTheme', t.encode());
    notifyListeners();
  }
  bool ghostDots = true;
  Upscale upscale = Upscale.scale2x;
  /// The screen filters, in the order they are applied (they stack).
  List<ScreenFilter> filters = [];

  Future<void> setLook({Upscale? upscale, List<ScreenFilter>? filters}) async {
    if (upscale != null) this.upscale = upscale;
    if (filters != null) this.filters = filters.where((f) => f != ScreenFilter.none).toList();
    await prefs.setString('upscale', this.upscale.name);
    await prefs.setStringList('filters', [for (final f in this.filters) f.name]);
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
    keepScreenOn = prefs.getBool('keepScreenOn') ?? false;
    watchCalls = prefs.getBool('watchCalls') ?? true;
    shellTheme = ShellTheme.decode(prefs.getString('shellTheme')) ?? ShellTheme.presets.first;
    ghostDots = prefs.getBool('ghostDots') ?? true;
    upscale = Upscale.values.asNameMap()[prefs.getString('upscale')] ?? Upscale.scale2x;
    final names = prefs.getStringList('filters') ?? [if (prefs.getString('filter') != null) prefs.getString('filter')!];
    filters = [for (final n in names) if (ScreenFilter.values.asNameMap()[n] case final f? when f != ScreenFilter.none) f];
    NativeBridge.volume = prefs.getDouble('volume') ?? 0.35;
    tunnel.myName = prefs.getString('myName') ?? 'Tama';
    await library.init();
    unawaited(library.unpackAll());
    WatchLink.instance.start();
    for (final id in prefs.getStringList('runningGames') ?? const <String>[]) {
      final e = library.entries.where((x) => x.id == id && x.kind == RomKind.paradise);
      if (e.isNotEmpty) await playParadise(e.first, focus: false);
    }
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
  Future<String?> playParadise(RomEntry e, {int? key, bool focus = true}) async {
    final core = ParadiseCore.instance;
    if (core == null) return 'The Paradise core is not in this build (${ParadiseCore.loadError}).';
    if (focus) await stopToy();
    await ensureGameTheme(e);
    final running = games[e.id];
    if (running != null) {
      if (focus) _focus(e.id);
      return null;
    }
    final dump = await library.romFile(e);
    final m = ParadiseMachine(core: core, dumpPath: dump.path, savePath: library.paradiseSave(e).path, title: e.name)
      ..sound = sound
      ..keepScreenOn = keepScreenOn
      ..autoCareBits = autoCare(e)
      ..onCall = (t) {
        final name = t.replaceFirst('Tamagotchi Paradise · ', '');
        NativeBridge.notify(name, 'Your Tamagotchi is calling you.');
        if (watchCalls) WatchLink.instance.call(name);
      };
    unawaited(NativeBridge.askToNotify());
    final r = m.boot(key ?? paradiseKey(e));
    if (r != 1) {
      m.dispose();
      return r == 0 ? 'key' : m.error;
    }
    if (key != null) await setParadiseKey(e, key);
    games[e.id] = m;
    gameRoms[e.id] = e;
    m.background = true;
    await _rememberRunning();
    if (focus) {
      _focus(e.id);
      await prefs.setString('lastToy', e.id);
    }
    if (backgroundRun) await NativeBridge.keepAlive(true, title: 'Tama', text: '${games.length == 1 ? e.name : '${games.length} Tamagotchis'} living');
    notifyListeners();
    return null;
  }

  /// Puts a running game on screen; the others go on in the background (no drawing, once a
  /// second, the console mostly asleep).
  void _focus(String? id) {
    focused = id;
    for (final g in games.entries) {
      g.value.background = g.key != id || _bgAt != null;
      if (g.key != id) g.value.releaseAll();
    }
    notifyListeners();
  }

  /// Back to the games: the one on screen goes on living in the background.
  Future<void> showGames() async {
    await unlink();
    final m = paradise;
    if (m != null) unawaited(saveShot(focused!, m));
    _focus(null);
  }

  Future<void> _rememberRunning() => prefs.setStringList('runningGames', games.keys.toList());

  /// The last picture of a game's screen (shown on its card while it is not running).
  File shotFile(String id) => File('${library.docs.path}/shots/$id.png');
  Future<void> saveShot(String id, ParadiseMachine m) async {
    try {
      final rgba = Uint8List(128 * 128 * 4);
      final s = m.screen;
      for (var i = 0; i < s.length; i++) {
        final v = s[i];
        rgba[i * 4] = ((v >> 11) & 31) * 255 ~/ 31;
        rgba[i * 4 + 1] = ((v >> 5) & 63) * 255 ~/ 63;
        rgba[i * 4 + 2] = (v & 31) * 255 ~/ 31;
        rgba[i * 4 + 3] = 255;
      }
      if (rgba.every((b) => b == 0 || b == 255) && s.every((v) => v == 0)) return; // asleep, black: keep the last
      final png = await compute(_png, rgba);
      final f = shotFile(id);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(png, flush: true);
      shotRevision++;
      notifyListeners();
    } catch (err) {
      debugPrint('shot: $err');
    }
  }

  int shotRevision = 0;
  void shotsChanged() {
    shotRevision++;
    notifyListeners();
  }
  static Uint8List _png(Uint8List rgba) => img.encodePng(img.Image.fromBytes(width: 128, height: 128, bytes: rgba.buffer, numChannels: 4));

  /// Stops a game for good (saved; it no longer lives in the background).
  Future<void> stopGame(String id) async {
    if (id == focused) await unlink();
    final m = games.remove(id);
    gameRoms.remove(id);
    if (m == null) return;
    await saveShot(id, m);
    m.dispose();
    if (focused == id) focused = null;
    await _rememberRunning();
    if (games.isEmpty && machine == null) await NativeBridge.keepAlive(false);
    notifyListeners();
  }

  /// Starts [e] as a second console and links it to the game being played. Same ROM: the
  /// partner gets a save of its own.
  Future<String?> linkPartner(RomEntry e) async {
    final core = ParadiseCore.instance;
    final a = paradise;
    if (core == null || a == null) return 'Start a game first.';
    await unlink();
    final dump = await library.romFile(e);
    final same = paradiseRom?.id == e.id;
    final save = same ? library.paradiseSave(e).path.replaceFirst('.save', '-partner.save') : library.paradiseSave(e).path;
    final b = ParadiseMachine(core: core, dumpPath: dump.path, savePath: save, title: e.name)
      ..sound = false
      ..autoCareBits = autoCare(e);
    final r = b.boot(paradiseKey(e));
    if (r != 1) {
      b.dispose();
      return b.error ?? 'The game did not start.';
    }
    partner = b;
    partnerRom = e;
    TwinLink(a, b);
    notifyListeners();
    return null;
  }

  /// Links the game being played to a real unit on the serial connection.
  Future<String?> linkUnit() async {
    final a = paradise;
    if (a == null) return 'Start a game first.';
    if (!serial.connected) return 'Connect the serial adapter or bridge first (Link → Hardware).';
    await unlink();
    UnitLink(a, serial);
    notifyListeners();
    return null;
  }

  Future<void> unlink() async {
    await paradise?.link?.close();
    final b = partner;
    partner = null;
    partnerRom = null;
    b?.dispose();
    notifyListeners();
  }

  /// Stops the game on screen.
  Future<void> stopParadise() async {
    final id = focused;
    if (id != null) await stopGame(id);
  }

  Future<void> play(RomEntry e) async {
    await showGames();
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
    for (final g in games.entries) {
      g.value.background = true;
      g.value.releaseAll();
      g.value.save();
      unawaited(saveShot(g.key, g.value));
      if (!backgroundRun) g.value.pause();
    }
    partner?.background = true;
    // the watch gets the latest saves, so it continues where the phone was
    unawaited(WatchLink.instance.syncAll());
    final m = machine;
    if (m == null) return;
    await m.save();
    if (!backgroundRun) m.pause();
  }

  void onForeground() {
    final away = _bgAt == null ? Duration.zero : DateTime.now().difference(_bgAt!);
    _bgAt = null;
    for (final g in games.entries) {
      g.value.background = g.key != focused;
      if (!g.value.running) g.value.resumeAfter(away);
    }
    partner?.background = false;
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
