import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'transport.dart';
import 'usb_chips.dart';

class UsbAdapter {
  UsbAdapter(this.id, this.name, this.vid, this.pid, this.driver);
  final int id;
  final String name;
  final int vid, pid;
  final String driver;
}

/// USB serial adapters, directly:
///  - Android (USB OTG): the app's UsbSerialBridge.kt on usb-serial-for-android (CDC-ACM, CH34x,
///    CP210x, FTDI, PL2303 and unknown devices tried as CDC-ACM)
///  - iOS / iPadOS: the app's DriverKit driver (ios/TamaSerialDriver) for the raw USB pipe and
///    lib/services/serial/usb_chips.dart for the chip setup
abstract class UsbTransport extends SerialTransport {
  static bool get supported => Platform.isAndroid || Platform.isIOS;

  static Future<List<UsbAdapter>> list() async {
    if (Platform.isAndroid) return AndroidUsbTransport.list();
    if (Platform.isIOS) return IosUsbTransport.list();
    return [];
  }

  static Future<UsbTransport> open(UsbAdapter a, int baud) {
    if (Platform.isIOS) return IosUsbTransport.open(a, baud);
    return AndroidUsbTransport.open(a, baud);
  }

  @override
  String get kind => 'USB';
  @override
  bool get canSetBaud => true;
}

String _chipName(int vid) => switch (vid) {
      0x1A86 || 0x4348 => 'CH34x',
      0x10C4 => 'CP210x',
      0x0403 => 'FTDI',
      0x067B => 'PL2303',
      _ => 'CDC-ACM',
    };

class AndroidUsbTransport extends UsbTransport {
  AndroidUsbTransport._(this.adapter);

  static const _ch = MethodChannel('tama/usb');
  static const _rx = EventChannel('tama/usb/rx');

  final UsbAdapter adapter;
  final _in = StreamController<Uint8List>.broadcast();
  StreamSubscription<dynamic>? _sub;

  /// Why there is no adapter on this iPad/iPhone, or null when USB should work.
  static Future<String?> whyNone() async {
    try {
      final st = Map<String, dynamic>.from(await _ch.invokeMethod('status') as Map);
      if (st['driver'] != true) {
        return 'This build has no USB driver. Apple has granted Tama\'s DriverKit capabilities for development '
            'only, and TestFlight / App Store builds may carry the driver only once Apple approves it for '
            'distribution (developer.apple.com/contact/request/system-extension). Until then, use a Bluetooth '
            'or Wi-Fi serial bridge.';
      }
      if (st['iokit'] != true) return 'This device cannot talk to USB drivers (an iPad with an M-series chip is needed).';
      return 'Plug the adapter in, then allow Tama\'s driver: Settings → General → Login Items & Extensions → '
          'Driver Extensions (an iPad with an M-series chip is needed).';
    } catch (e) {
      return '$e';
    }
  }

  static Future<List<UsbAdapter>> list() async {
    final l = await _ch.invokeListMethod<Map<dynamic, dynamic>>('list') ?? [];
    return [for (final m in l) UsbAdapter(m['id'] as int, (m['name'] ?? 'USB serial') as String, m['vid'] as int, m['pid'] as int, (m['driver'] ?? '') as String)];
  }

  @override
  String get label => adapter.name;
  @override
  Stream<Uint8List> get input => _in.stream;

  static Future<AndroidUsbTransport> open(UsbAdapter a, int baud) async {
    final t = AndroidUsbTransport._(a);
    t._sub = _rx.receiveBroadcastStream().listen((d) => t._in.add(d as Uint8List), onError: (_) => t._in.close());
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

class IosUsbTransport extends UsbTransport {
  IosUsbTransport._(this.adapter, this.chip);

  static const _ch = MethodChannel('tama/usbdk');
  static const _rx = EventChannel('tama/usbdk/rx');

  final UsbAdapter adapter;
  final UsbChip chip;
  final _in = StreamController<Uint8List>.broadcast();
  StreamSubscription<dynamic>? _sub;
  bool _dtr = true, _rts = true;

  /// Why there is no adapter on this iPad/iPhone, or null when USB should work.
  static Future<String?> whyNone() async {
    try {
      final st = Map<String, dynamic>.from(await _ch.invokeMethod('status') as Map);
      if (st['driver'] != true) {
        return 'This build has no USB driver. Apple has granted Tama\'s DriverKit capabilities for development '
            'only, and TestFlight / App Store builds may carry the driver only once Apple approves it for '
            'distribution (developer.apple.com/contact/request/system-extension). Until then, use a Bluetooth '
            'or Wi-Fi serial bridge.';
      }
      if (st['iokit'] != true) return 'This device cannot talk to USB drivers (an iPad with an M-series chip is needed).';
      return 'Plug the adapter in, then allow Tama\'s driver: Settings → General → Login Items & Extensions → '
          'Driver Extensions (an iPad with an M-series chip is needed).';
    } catch (e) {
      return '$e';
    }
  }

  static Future<List<UsbAdapter>> list() async {
    final l = await _ch.invokeListMethod<Map<dynamic, dynamic>>('list') ?? [];
    return [
      for (final m in l)
        UsbAdapter((m['id'] as num).toInt(), (m['name'] ?? 'USB serial') as String, (m['vid'] as num).toInt(), (m['pid'] as num).toInt(), _chipName((m['vid'] as num).toInt())),
    ];
  }

  static Future<Uint8List?> _control(int type, int request, int value, int index, {Uint8List? data, int length = 0}) {
    return _ch.invokeMethod<Uint8List>('control', {
      'type': type,
      'request': request,
      'value': value & 0xFFFF,
      'index': index & 0xFFFF,
      'length': data?.length ?? length,
      'data': ?data,
    });
  }

  @override
  String get label => '${adapter.name} (${chip.name})';
  @override
  Stream<Uint8List> get input => _in.stream;

  static Future<IosUsbTransport> open(UsbAdapter a, int baud) async {
    final r = await _ch.invokeMapMethod<String, dynamic>('open', {'id': a.id});
    final vp = (r?['vidPid'] as num?)?.toInt() ?? ((a.vid << 16) | a.pid);
    final iface = (r?['interface'] as num?)?.toInt() ?? 0;
    final chip = UsbChip.forDevice(vp >> 16, vp & 0xFFFF, iface, _control);
    final t = IosUsbTransport._(a, chip);
    t._sub = _rx.receiveBroadcastStream().listen((d) {
      final f = chip.filterRx(d as Uint8List);
      if (f.isNotEmpty) t._in.add(f);
    }, onError: (_) => t._in.close());
    try {
      await chip.open(baud);
    } catch (e) {
      await t.close();
      rethrow;
    }
    return t;
  }

  @override
  Future<void> setBaud(int baud) => chip.setBaud(baud);

  @override
  Future<void> setSignals({bool? dtr, bool? rts}) {
    _dtr = dtr ?? _dtr;
    _rts = rts ?? _rts;
    return chip.setSignals(dtr: _dtr, rts: _rts);
  }

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
