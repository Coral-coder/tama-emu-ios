import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'transport.dart';

/// BLE serial bridges: Nordic UART Service (ESP32 / nRF bridges), HM-10 / HM-19 / CC254x (FFE0 /
/// FFE1), or any device with one notify and one write characteristic.
class BleTransport extends SerialTransport {
  BleTransport._(this.device, this._tx, this.rxChar, this._mtu);

  final BluetoothDevice device;
  final BluetoothCharacteristic _tx; // phone -> device
  final BluetoothCharacteristic rxChar; // device -> phone (notify)
  final int _mtu;
  final _in = StreamController<Uint8List>.broadcast();
  StreamSubscription<List<int>>? _sub;
  StreamSubscription<BluetoothConnectionState>? _state;

  static final Guid nusService = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid nusRx = Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E'); // write
  static final Guid nusTx = Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E'); // notify
  static final Guid hmService = Guid('FFE0');
  static final Guid hmChar = Guid('FFE1');

  @override
  String get label => device.platformName.isNotEmpty ? device.platformName : device.remoteId.str;
  @override
  String get kind => 'BLE';
  @override
  Stream<Uint8List> get input => _in.stream;
  @override
  int get chunk => (_mtu - 3).clamp(20, 512);

  static Future<BleTransport> connect(BluetoothDevice d) async {
    await d.connect(timeout: const Duration(seconds: 12), autoConnect: false);
    var mtu = 23;
    try {
      mtu = await d.requestMtu(247);
    } catch (_) {
      mtu = d.mtuNow;
    }
    final services = await d.discoverServices();
    BluetoothCharacteristic? tx, rx;
    for (final s in services) {
      if (s.uuid == nusService) {
        for (final c in s.characteristics) {
          if (c.uuid == nusRx) tx = c;
          if (c.uuid == nusTx) rx = c;
        }
      } else if (s.uuid == hmService) {
        for (final c in s.characteristics) {
          if (c.uuid == hmChar) tx = rx = c;
        }
      }
    }
    if (tx == null || rx == null) {
      // generic: the first notify and the first write characteristic of one service
      for (final s in services) {
        BluetoothCharacteristic? n, w;
        for (final c in s.characteristics) {
          if (n == null && (c.properties.notify || c.properties.indicate)) n = c;
          if (w == null && (c.properties.write || c.properties.writeWithoutResponse)) w = c;
        }
        if (n != null && w != null) {
          rx = n;
          tx = w;
          break;
        }
      }
    }
    if (tx == null || rx == null) {
      await d.disconnect();
      throw Exception('No serial service on this device (looked for Nordic UART, FFE0/FFE1 and any notify + write pair)');
    }
    final t = BleTransport._(d, tx, rx, mtu);
    await rx.setNotifyValue(true);
    t._sub = rx.onValueReceived.listen((v) => t._in.add(Uint8List.fromList(v)));
    t._state = d.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) t._in.close();
    });
    return t;
  }

  @override
  Future<void> write(Uint8List data) async {
    final noResp = _tx.properties.writeWithoutResponse;
    for (var i = 0; i < data.length; i += chunk) {
      final end = (i + chunk) > data.length ? data.length : i + chunk;
      await _tx.write(data.sublist(i, end), withoutResponse: noResp);
    }
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await _state?.cancel();
    try {
      await device.disconnect();
    } catch (_) {}
    if (!_in.isClosed) await _in.close();
  }
}
