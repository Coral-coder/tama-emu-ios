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

/// Paramix Studio (mameise, GPL-3.0) in a web view. Its Web Serial calls go to the app's UART
/// connection, its downloads come back to the app.
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

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
        onProgress: (p) => setState(() => _progress = p),
        onPageFinished: (_) => setState(() => _progress = 100),
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
    app.studioOpen.addListener(_openPending);
  }

  @override
  void dispose() {
    app.studioOpen.removeListener(_openPending);
    _rx?.cancel();
    _rxFlush?.cancel();
    super.dispose();
  }

  Future<List<String>> _androidPick(FileSelectorParams p) async {
    if (p.mode == FileSelectorMode.openMultiple) {
      final res = await FilePicker.pickFiles();
      return [for (final f in res) f.uri.toString()];
    }
    final f = await FilePicker.pickFile();
    return f == null ? [] : [f.uri.toString()];
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
        setState(() => _ready = true);
        _openPending();
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
        title: const Text('No UART connected'),
        content: const Text('Connect the dongle first (BLE serial bridge, USB adapter on Android, or a Wi-Fi serial bridge) on the Hardware page, then press the Studio\'s device button again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
          FilledButton(
            onPressed: () {
              Navigator.pop(c);
              app.page.value = 3;
            },
            child: const Text('Hardware'),
          ),
        ],
      ),
    );
  }

  Future<void> _gotFile(String name, Uint8List b) async {
    final out = File('${app.library.studioOut.path}/$name');
    await out.writeAsBytes(b, flush: true);
    if (!mounted) return;
    final kind = detectKind(b);
    await showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(name), subtitle: Text('${b.length} bytes · saved in Files → Tama → studio')),
          ListTile(
            leading: const Icon(Icons.library_add_outlined),
            title: const Text('Add to the library'),
            onTap: () async {
              Navigator.pop(c);
              await app.library.import(b, name, note: 'from the Studio');
            },
          ),
          if (kind == RomKind.e0c6s4x)
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('Add and play'),
              onTap: () async {
                Navigator.pop(c);
                final e = await app.library.import(b, name, note: 'from the Studio');
                await app.play(e);
                app.page.value = 0;
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

  Future<void> _openPending() async {
    final e = app.studioOpen.value;
    if (e == null || !_ready) return;
    app.studioOpen.value = null;
    await _sendToStudio(e);
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
      // A Paradise image opens as the ROM; anything else goes to the emulator tab (TamaEmu / V1Emu).
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
          const ListTile(title: Text('Open in the Studio')),
          for (final r in app.library.entries)
            ListTile(
              title: Text(r.name),
              subtitle: Text(r.kind == RomKind.paradise ? 'Paradise ROM' : r.kind == RomKind.e0c6s4x ? 'toy ROM (to build into a Paradise)' : 'file'),
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
        title: const Text('Paramix Studio'),
        actions: [
          ListenableBuilder(
            listenable: app.serial,
            builder: (_, _) => Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(app.serial.connected ? Icons.usb : Icons.usb_off, color: app.serial.connected ? Colors.greenAccent : Colors.white38),
            ),
          ),
          IconButton(tooltip: 'Open from the library', icon: const Icon(Icons.folder_open), onPressed: _pickFromLibrary),
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
