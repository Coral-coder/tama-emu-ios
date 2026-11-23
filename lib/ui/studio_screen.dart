import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../emu/rom_info.dart';
import '../services/app_state.dart';
import '../services/rom_library.dart';
import 'hardware_screen.dart';

/// Paramix Studio (mameise, GPL-3.0, third_party/paramix-studio) in full, offline, in a web
/// view: every tool it has. Its Web Serial calls go to the app's UART connection (dongle, USB,
/// Wi-Fi), its downloads come back to the app, and ROMs from the library can be opened in it.
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key, this.title = 'Paramix Studio', this.tab, this.button, this.open});

  final String title;

  /// The Studio tab to show first (figs, all, names, dim, emu, doom, gb, sms, pm, ab, wolf, feld, save).
  final String? tab;

  /// Or a button to press once loaded (btnDevice: the device page).
  final String? button;

  /// A ROM from the library to open right away.
  final RomEntry? open;

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  late final WebViewController _web;
  bool _ready = false;
  int _progress = 0;
  StreamSubscription<Uint8List>? _rx;
  final BytesBuilder _rxBuf = BytesBuilder(copy: false);
  Timer? _rxFlush;
  String? _dlName;
  BytesBuilder? _dl;
  String? _busy;

  AppState get app => AppState.instance;

  @override
  void initState() {
    super.initState();
    PlatformWebViewControllerCreationParams params = const PlatformWebViewControllerCreationParams();
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(allowsInlineMediaPlayback: true, mediaTypesRequiringUserAction: const {});
    }
    _web = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF111111))
      ..addJavaScriptChannel('TamaBridge', onMessageReceived: (m) => _onMessage(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _progress = 100);
        },
      ));
    final pc = _web.platform;
    if (pc is AndroidWebViewController) {
      pc.setAllowFileAccess(true);
      pc.setOnShowFileSelector(_androidPick);
      AndroidWebViewController.enableDebugging(kDebugMode);
    } else if (pc is WebKitWebViewController) {
      pc.setInspectable(true);
    }
    _web.loadFlutterAsset('assets/studio/index.html');
  }

  @override
  void dispose() {
    _rx?.cancel();
    _rxFlush?.cancel();
    super.dispose();
  }

  Future<List<String>> _androidPick(FileSelectorParams p) async {
    final res = await FilePicker.pickFiles(type: FileType.any);
    return [
      for (final f in res)
        if (f.path != null) Uri.file(f.path!).toString(),
    ];
  }

  Future<void> _js(String code) async {
    try {
      await _web.runJavaScript(code);
    } catch (e) {
      debugPrint('studio js: $e');
    }
  }

  void _reply(int id, bool ok, [String? val]) => _js('window.__tamaReply($id, $ok, ${jsonEncode(val)})');

  Future<void> _onMessage(String raw) async {
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = (m['id'] as int?) ?? 0;
    final serial = app.serial;
    switch (m['t']) {
      case 'ready':
        if (mounted) setState(() => _ready = true);
        await _start();
      case 'log':
        debugPrint('studio: ${m['msg']}');
      case 'requestPort':
        if (serial.connected) {
          _reply(id, true);
        } else {
          _reply(id, false, 'No UART connected');
          if (mounted) _noPort();
        }
      case 'open':
        final baud = (m['baud'] as num?)?.toInt() ?? 460800;
        if (!serial.connected) {
          _reply(id, false, 'No UART connected');
          return;
        }
        if (serial.transport!.canSetBaud) await serial.setBaud(baud);
        await _rx?.cancel();
        _rx = serial.input.listen(_onRx);
        _reply(id, true);
      case 'write':
        try {
          await serial.write(base64Decode(m['b64'] as String));
          _reply(id, true);
        } catch (e) {
          _reply(id, false, '$e');
        }
      case 'close':
        await _rx?.cancel();
        _rx = null;
        _reply(id, true);
      case 'signals':
        try {
          await serial.transport?.setSignals(dtr: m['dataTerminalReady'] as bool?, rts: m['requestToSend'] as bool?);
        } catch (_) {}
        _reply(id, true);
      case 'fileStart':
        _dlName = m['name'] as String?;
        _dl = BytesBuilder(copy: false);
      case 'fileChunk':
        _dl?.add(base64Decode(m['b64'] as String));
      case 'fileEnd':
        final b = _dl?.takeBytes();
        final name = _dlName ?? 'download.bin';
        _dl = null;
        if (b != null) await _gotFile(name, b);
    }
  }

  /// Once the page is up: the tool asked for, and the ROM to open.
  Future<void> _start() async {
    // the page sets itself up right after its scripts ran
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (widget.open != null) await _sendToStudio(widget.open!);
    if (widget.tab != null) await _js('window.__tamaTab(${jsonEncode(widget.tab)})');
    if (widget.button != null) await _js('window.__tamaClick(${jsonEncode(widget.button)})');
  }

  void _onRx(Uint8List d) {
    _rxBuf.add(d);
    _rxFlush ??= Timer(const Duration(milliseconds: 8), () {
      _rxFlush = null;
      final b = _rxBuf.takeBytes();
      if (b.isNotEmpty) _js('window.__tamaSerialRx("${base64Encode(b)}")');
    });
  }

  void _noPort() {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('No dongle connected'),
        content: const Text('Connect your Tama Bridge or USB serial adapter on the Hardware page first, then press the Studio\'s button again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
          FilledButton(
            onPressed: () {
              Navigator.pop(c);
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HardwareScreen()));
            },
            child: const Text('Hardware'),
          ),
        ],
      ),
    );
  }

  Future<void> _gotFile(String name, Uint8List b) async {
    await app.library.studioOut.create(recursive: true);
    final out = File('${app.library.studioOut.path}/$name');
    await out.writeAsBytes(b, flush: true);
    if (!mounted) return;
    final kind = detectKind(b);
    await showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(name), subtitle: Text('${b.length} bytes · kept in Files → Tama → studio')),
          if (kind == RomKind.paradise)
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('Add to my games and play'),
              onTap: () async {
                Navigator.pop(c);
                final e = await app.library.import(b, name, note: 'from Paramix');
                await app.playParadise(e);
                if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          ListTile(
            leading: const Icon(Icons.library_add_outlined),
            title: const Text('Add to the ROMs'),
            onTap: () async {
              Navigator.pop(c);
              await app.library.import(b, name, note: 'from Paramix');
            },
          ),
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: const Text('Share / save elsewhere'),
            onTap: () async {
              Navigator.pop(c);
              await SharePlus.instance.share(ShareParams(files: [XFile(out.path)], subject: name));
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _sendToStudio(RomEntry e) async {
    setState(() => _busy = 'Opening ${e.name} …');
    try {
      final b = await app.library.bytes(e);
      final name = '${e.name.replaceAll(RegExp(r'[^A-Za-z0-9 _.-]'), '_')}.bin';
      await _js('window.__tamaFileBegin(${jsonEncode(name)})');
      const ch = 768 * 1024;
      for (var i = 0; i < b.length; i += ch) {
        final end = i + ch > b.length ? b.length : i + ch;
        await _js('window.__tamaFileChunk("${base64Encode(Uint8List.sublistView(b, i, end))}")');
      }
      // a Paradise image opens as the ROM; anything else goes to the emulator tab (firmware)
      await _js('window.__tamaFileEnd(${jsonEncode(e.kind == RomKind.paradise ? 'fileRom' : 'fileEmu')})');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _pickFromLibrary() async {
    final e = await showModalBottomSheet<RomEntry>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Open in Paramix')),
          for (final r in app.library.entries)
            ListTile(
              title: Text(r.name),
              subtitle: Text(r.kind == RomKind.paradise ? 'Paradise ROM' : 'firmware / other file'),
              onTap: () => Navigator.pop(c, r),
            ),
        ]),
      ),
    );
    if (e != null) await _sendToStudio(e);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          ListenableBuilder(
            listenable: app.serial,
            builder: (_, _) => Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(app.serial.connected ? Icons.usb : Icons.usb_off, color: app.serial.connected ? Colors.greenAccent : Colors.white38),
            ),
          ),
          IconButton(tooltip: 'Open a ROM from my library', icon: const Icon(Icons.folder_open), onPressed: _ready ? _pickFromLibrary : null),
          IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh), onPressed: () => _web.reload()),
        ],
        bottom: _progress < 100 || _busy != null
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(value: _busy != null ? null : _progress / 100),
              )
            : null,
      ),
      body: WebViewWidget(controller: _web),
    );
  }
}
