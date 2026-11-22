import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'transport.dart';

class UsbAdapter {
  UsbAdapter(this.id, this.name, this.vid, this.pid, this.driver);
  final int id;
  final String name;
  final int vid, pid;
  final String driver;
}

/// USB serial adapters over USB OTG (Android only; the app's UsbSerialBridge.kt on top of
/// usb-serial-for-android: CDC-ACM, CH34x, CP210x, FTDI, PL2303 ...). iOS gives apps no access to
/// USB serial adapters; use a BLE or Wi-Fi bridge there.
class UsbTransport extends SerialTransport {
  UsbTransport._(this.adapter);

  static const _ch = MethodChannel('tama/usb');
  static const _rx = EventChannel('tama/usb/rx');

  final UsbAdapter adapter;
  final _in = StreamController<Uint8List>.broadcast();
  StreamSubscription<dynamic>? _sub;

  static bool get supported => Platform.isAndroid;

  static Future<List<UsbAdapter>> list() async {
    if (!supported) return [];
    final l = await _ch.invokeListMethod<Map<dynamic, dynamic>>('list') ?? [];
    return [for (final m in l) UsbAdapter(m['id'] as int, (m['name'] ?? 'USB serial') as String, m['vid'] as int, m['pid'] as int, (m['driver'] ?? '') as String)];
  }

  @override
  String get label => adapter.name;
  @override
  String get kind => 'USB';
  @override
  Stream<Uint8List> get input => _in.stream;
  @override
  bool get canSetBaud => true;

  static Future<UsbTransport> open(UsbAdapter a, int baud) async {
    final t = UsbTransport._(a);
    t._sub = _rx.receiveBroadcastStream().listen(
      (d) => t._in.add(d as Uint8List),
      onError: (_) => t._in.close(),
    );
    try {
      await _ch.invokeMethod('open', {'id': a.id, 'baud': baud});
    } catch (e) {
      await t._sub?.cancel();
      rethrow;
    }
    return t;
  }

  @override
  Future<void> setBaud(int baud) => _ch.invokeMethod('baud', {'baud': baud});

  @override
  Future<void> setSignals({bool? dtr, bool? rts}) => _ch.invokeMethod('signals', {'dtr': dtr, 'rts': rts});

  @override
  Future<void> write(Uint8List data) => _ch.invokeMethod('write', {'data': data});

  @override
  Future<void> close() async {
    await _sub?.cancel();
    try {
      await _ch.invokeMethod('close');
    } catch (_) {}
    if (!_in.isClosed) await _in.close();
  }
}
