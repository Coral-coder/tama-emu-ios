import 'dart:async';
import 'native.dart';
import 'dart:convert';

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

  BluetoothDevice? device;
  BluetoothCharacteristic? _cfg;
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
        if (m.containsKey('found')) {
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
