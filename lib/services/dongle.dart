import 'dart:async';
import 'native.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'serial/ble_transport.dart';
import 'serial/serial_hub.dart';

/// The Tama Bridge's settings, over Bluetooth (its settings service: JSON lines both ways). No
/// wiring or game link needed: the bridge only has to be powered and near.
class Dongle extends ChangeNotifier {
  Dongle._();
  static final Dongle instance = Dongle._();

  static final Guid cfgService = Guid('7A3E0001-6B5C-4C1D-9C2A-5D1E8F7A0001');
  static final Guid cfgChar = Guid('7A3E0002-6B5C-4C1D-9C2A-5D1E8F7A0001');

  static final Guid otaChar = Guid('7A3E0003-6B5C-4C1D-9C2A-5D1E8F7A0001');

  BluetoothDevice? device;
  BluetoothCharacteristic? _cfg, _ota;
  Completer<Map<String, dynamic>>? _otaReply;

  /// Update over Bluetooth: null when idle, else 0..1.
  double? updateProgress;
  String? updateNote;
  StreamSubscription<List<int>>? _sub;
  StreamSubscription<BluetoothConnectionState>? _state;
  String _buf = '';
  Map<String, dynamic> state = {};
  List<Map<String, dynamic>> found = [];
  bool scanningPeers = false;
  String? error;

  bool get connected => _cfg != null;
  String get name => state['name'] as String? ?? device?.platformName ?? 'Tama Bridge';

  /// Bridges in reach (they advertise the Nordic UART service).
  Stream<List<ScanResult>> scan() {
    error = null;
    FlutterBluePlus.startScan(withServices: [BleTransport.nusService], timeout: const Duration(seconds: 6)).catchError((Object e) {
      error = NativeBridge.bluetoothRefused(e)
          ? 'Tama is not allowed to use Bluetooth. Turn it on in Settings → Tama → Bluetooth, then look again.'
          : 'Scan: $e';
      notifyListeners();
    });
    return FlutterBluePlus.scanResults;
  }

  Future<void> connect(BluetoothDevice d) async {
    error = null;
    await disconnect();
    try {
      await d.connect(timeout: const Duration(seconds: 12), autoConnect: false);
      try {
        await d.requestMtu(247);
      } catch (_) {}
      final services = await d.discoverServices();
      BluetoothCharacteristic? c;
      for (final s in services) {
        if (s.uuid == cfgService) {
          for (final x in s.characteristics) {
            if (x.uuid == cfgChar) c = x;
            if (x.uuid == otaChar) _ota = x;
          }
        }
      }
      if (c == null) {
        error = 'This bridge has no settings (old firmware): flash version 2.0 or later.';
        notifyListeners();
        return;
      }
      device = d;
      _cfg = c;
      await c.setNotifyValue(true);
      _sub = c.onValueReceived.listen(_onData);
      _state = d.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _cfg = null;
          notifyListeners();
        }
      });
      await refresh();
    } catch (e) {
      error = 'Could not connect: $e';
    }
    notifyListeners();
  }

  void _onData(List<int> v) {
    _buf += utf8.decode(v, allowMalformed: true);
    while (true) {
      final i = _buf.indexOf('\n');
      if (i < 0) break;
      final line = _buf.substring(0, i);
      _buf = _buf.substring(i + 1);
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        if (m.containsKey('ota') && m['ota'] is String) {
          final r = _otaReply;
          _otaReply = null;
          if (r != null && !r.isCompleted) r.complete(m);
        } else if (m.containsKey('found')) {
          found = [for (final f in m['found'] as List) Map<String, dynamic>.from(f as Map)];
          scanningPeers = false;
        } else {
          state = m;
        }
        notifyListeners();
      } catch (_) {}
    }
  }

  Future<void> _send(Map<String, dynamic> m) async {
    final c = _cfg;
    if (c == null) return;
    final b = utf8.encode('${jsonEncode(m)}\n');
    final chunk = ((device?.mtuNow ?? 23) - 3).clamp(20, 240);
    for (var i = 0; i < b.length; i += chunk) {
      await c.write(b.sublist(i, (i + chunk).clamp(0, b.length)), withoutResponse: false);
    }
  }

  // ---- firmware update over Bluetooth ----
  static const _repo = 'Coral-coder/tama-emu-ios';
  static const _slugs = {
    'ESP32': 'esp32',
    'ESP32-C3': 'esp32c3',
    'ESP32-S3': 'esp32s3',
    'ESP32-C6': 'esp32c6',
    'Heltec V3': 'heltec-v3',
    'Heltec V4': 'heltec-v4',
    'T-LoRa V1.6.1': 'tlora-v161',
  };

  String get firmware => '${state['v'] ?? '?'}';

  /// The bridge can take an update from the app (firmware 2.2 or later).
  bool get canUpdate => _cfg != null && _ota != null && state['ota'] == true;

  /// The newest firmware for this board on GitHub: (version, build, url, size), or null.
  Future<({String version, int build, String url, int size})?> latestFirmware() async {
    final slug = _slugs['${state['chip']}'];
    if (slug == null) return null;
    final client = HttpClient()..userAgent = 'Tama-app-updater';
    try {
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$_repo/releases?per_page=40'));
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      for (final r in jsonDecode(await res.transform(utf8.decoder).join()) as List) {
        final m = RegExp(r'^esp32-bridge-([0-9.]+)-(\d+)$').firstMatch('${r['tag_name']}');
        if (m == null) continue;
        final a = (r['assets'] as List).cast<Map>().where((a) => a['name'] == 'tama-bridge-$slug-ota.bin').firstOrNull;
        if (a == null) continue;
        return (version: m.group(1)!, build: int.parse(m.group(2)!), url: a['browser_download_url'] as String, size: (a['size'] as num).toInt());
      }
      return null;
    } catch (e) {
      debugPrint('firmware check: $e');
      return null;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _otaAsk(Map<String, dynamic> m, Duration wait) async {
    final c = Completer<Map<String, dynamic>>();
    _otaReply = c;
    await _send(m);
    return c.future.timeout(wait, onTimeout: () => {'ota': 'error', 'msg': 'the bridge did not answer'});
  }

  /// Downloads the firmware and sends it to the bridge, which checks it (size and MD5) and
  /// restarts on it. Null when done, else what went wrong. The bridge keeps its old firmware
  /// unless the whole image arrived intact.
  Future<String?> update(({String version, int build, String url, int size}) fw) async {
    final ota = _ota;
    if (!canUpdate || ota == null) return 'This bridge cannot be updated from the app yet: flash firmware 2.2 or later once over USB.';
    final client = HttpClient()..userAgent = 'Tama-app-updater';
    try {
      updateNote = 'Downloading the firmware …';
      updateProgress = 0;
      notifyListeners();
      final res = await (await client.getUrl(Uri.parse(fw.url))).close();
      if (res.statusCode != 200) return 'The download failed (${res.statusCode}).';
      final b = BytesBuilder(copy: false);
      await for (final chunk in res) {
        b.add(chunk);
      }
      final img = b.takeBytes();
      // an ESP32 program image starts with 0xE9
      if (img.length < 0x10000 || img[0] != 0xE9) return 'That file is not a firmware image.';
      await NativeBridge.keepAlive(true, title: 'Tama', text: 'Updating the bridge');
      await NativeBridge.keepScreenOn(true);
      updateNote = 'Sending to the bridge … keep it powered and near';
      notifyListeners();
      final ready = await _otaAsk({
        'ota': {'size': img.length, 'md5': crypto.md5.convert(img).toString()},
      }, const Duration(seconds: 20));
      if (ready['ota'] != 'ready') return 'The bridge refused the update: ${ready['msg'] ?? ready['ota']}';
      final chunk = ((device?.mtuNow ?? 23) - 3).clamp(20, 240);
      for (var i = 0; i < img.length; i += chunk) {
        if (_cfg == null) return 'The bridge disconnected. It keeps its old firmware: connect and try again.';
        await ota.write(img.sublist(i, (i + chunk).clamp(0, img.length)), withoutResponse: false);
        if (i % (chunk * 16) == 0) {
          updateProgress = i / img.length;
          notifyListeners();
        }
      }
      updateProgress = 1;
      updateNote = 'Checking …';
      notifyListeners();
      final done = await _otaAsk({'otaEnd': true}, const Duration(seconds: 30));
      if (done['ota'] != 'done') return 'The bridge did not accept the firmware (${done['msg'] ?? 'check failed'}). It keeps its old one.';
      return null;
    } catch (e) {
      try {
        await _send({'otaAbort': true});
      } catch (_) {}
      return 'The update stopped: $e. The bridge keeps its old firmware.';
    } finally {
      client.close();
      updateProgress = null;
      updateNote = null;
      await NativeBridge.keepScreenOn(false);
      await NativeBridge.keepAlive(false);
      notifyListeners();
    }
  }

  Future<void> refresh() => _send({'get': 1});
  Future<void> set(Map<String, dynamic> m) => _send({'set': m});
  Future<void> restart() => _send({'restart': true});

  Future<void> findPeers() async {
    scanningPeers = true;
    found = [];
    notifyListeners();
    await _send({'scan': true});
  }

  /// Uses the bridge for play too (the serial connection of the app).
  Future<void> useForPlay() async {
    final d = device;
    if (d == null) return;
    await SerialHub.instance.attach(await BleTransport.connect(d));
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    await _state?.cancel();
    _sub = null;
    _state = null;
    _cfg = null;
    _ota = null;
    final d = device;
    device = null;
    state = {};
    found = [];
    // the play connection, if it is this bridge, stays
    if (d != null && SerialHub.instance.transport?.label != d.platformName) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    notifyListeners();
  }
}
