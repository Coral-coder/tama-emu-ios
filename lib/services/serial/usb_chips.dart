// USB serial chip setup over raw control transfers (iOS: through the app's DriverKit driver).
// The requests follow usb-serial-for-android (mik3y, MIT), which the Android side uses as is.

import 'dart:typed_data';

typedef ControlFn = Future<Uint8List?> Function(int type, int request, int value, int index, {Uint8List? data, int length});

abstract class UsbChip {
  UsbChip(this.ctl, this.iface);
  final ControlFn ctl;
  final int iface;

  String get name;
  Future<void> open(int baud);
  Future<void> setBaud(int baud);
  Future<void> setSignals({required bool dtr, required bool rts});

  /// Received bulk data as the chip sends it; FTDI puts two status bytes in front of every packet.
  Uint8List filterRx(Uint8List d) => d;

  Future<void> out(int type, int req, int value, int index, [Uint8List? data]) async {
    await ctl(type, req, value, index, data: data, length: data?.length ?? 0);
  }

  static UsbChip forDevice(int vid, int pid, int dataIface, ControlFn ctl) {
    switch (vid) {
      case 0x1A86:
      case 0x4348:
        if (pid == 0x55D3 || pid == 0x55D4 || pid == 0x55D2) return CdcChip(ctl, dataIface); // CH343/CH9102: CDC
        return Ch34xChip(ctl, dataIface);
      case 0x10C4:
        return Cp210xChip(ctl, dataIface);
      case 0x0403:
        return FtdiChip(ctl, dataIface);
      case 0x067B:
        return Pl2303Chip(ctl, dataIface);
      default:
        return CdcChip(ctl, dataIface);
    }
  }
}

Uint8List _lineCoding(int baud) {
  final b = Uint8List(7);
  ByteData.sublistView(b).setUint32(0, baud, Endian.little);
  b[4] = 0; // 1 stop bit
  b[5] = 0; // no parity
  b[6] = 8; // 8 data bits
  return b;
}

/// CDC-ACM (CH343, CH9102, ESP32-S2/S3, RP2040, Arduino, STM32 VCP, many others).
class CdcChip extends UsbChip {
  CdcChip(super.ctl, super.iface);
  // the control (communication) interface is the one before the data interface
  int get _comm => iface > 0 ? iface - 1 : 0;
  @override
  String get name => 'CDC-ACM';
  @override
  Future<void> open(int baud) async {
    await setBaud(baud);
    await setSignals(dtr: true, rts: true);
  }

  @override
  Future<void> setBaud(int baud) => out(0x21, 0x20, 0, _comm, _lineCoding(baud));
  @override
  Future<void> setSignals({required bool dtr, required bool rts}) => out(0x21, 0x22, (dtr ? 1 : 0) | (rts ? 2 : 0), _comm);
}

/// WCH CH340 / CH341.
class Ch34xChip extends UsbChip {
  Ch34xChip(super.ctl, super.iface);
  bool _dtr = true, _rts = true;
  @override
  String get name => 'CH34x';

  Future<void> _o(int req, int value, int index) => out(0x40, req, value, index);
  Future<void> _i(int req, int value, int index, int len) async => ctl(0xC0, req, value, index, length: len);

  @override
  Future<void> open(int baud) async {
    await _i(0x5f, 0, 0, 2); // version
    await _o(0xa1, 0, 0);
    await setBaud(baud);
    await _i(0x95, 0x2518, 0, 2);
    await _o(0x9a, 0x2518, 0xC3); // rx, tx, 8 bits
    await _i(0x95, 0x0706, 0, 2);
    await _o(0xa1, 0x501f, 0xd90a);
    await setBaud(baud);
    await _lines();
    await _i(0x95, 0x0706, 0, 2);
  }

  @override
  Future<void> setBaud(int baud) async {
    int factor, divisor;
    if (baud == 921600) {
      divisor = 7;
      factor = 0xf300;
    } else {
      factor = 1532620800 ~/ baud;
      divisor = 3;
      while (factor > 0xfff0 && divisor > 0) {
        factor >>= 3;
        divisor--;
      }
      if (factor > 0xfff0) throw ArgumentError('baud rate $baud not possible on a CH34x');
      factor = 0x10000 - factor;
    }
    divisor |= 0x0080;
    await _o(0x9a, 0x1312, (factor & 0xff00) | divisor);
    await _o(0x9a, 0x0f2c, factor & 0xff);
  }

  Future<void> _lines() => _o(0xa4, ~((_dtr ? 1 << 5 : 0) | (_rts ? 1 << 6 : 0)) & 0xFFFF, 0);

  @override
  Future<void> setSignals({required bool dtr, required bool rts}) {
    _dtr = dtr;
    _rts = rts;
    return _lines();
  }
}

/// Silicon Labs CP210x.
class Cp210xChip extends UsbChip {
  Cp210xChip(super.ctl, super.iface);
  @override
  String get name => 'CP210x';

  Future<void> _set(int req, int value, [Uint8List? data]) => out(0x41, req, value, iface, data);

  @override
  Future<void> open(int baud) async {
    await _set(0x00, 0x0001); // UART enable
    await _set(0x07, 0x0303 | 0x0300); // DTR, RTS
    await _set(0x03, 0x0800); // 8N1
    await setBaud(baud);
  }

  @override
  Future<void> setBaud(int baud) {
    final d = Uint8List(4);
    ByteData.sublistView(d).setUint32(0, baud, Endian.little);
    return _set(0x1E, 0, d);
  }

  @override
  Future<void> setSignals({required bool dtr, required bool rts}) => _set(0x07, (dtr ? 1 : 0) | (rts ? 2 : 0) | 0x0300);
}

/// FTDI FT232R / FT231X / FT2232 (first port).
class FtdiChip extends UsbChip {
  FtdiChip(super.ctl, super.iface);
  int _maxPacket = 64;
  @override
  String get name => 'FTDI';
  int get _port => iface + 1;

  @override
  Future<void> open(int baud) async {
    await out(0x40, 0, 0, _port); // reset
    await out(0x40, 9, 1, _port); // latency timer 1 ms
    await out(0x40, 4, 8, _port); // 8N1
    await setSignals(dtr: true, rts: true);
    await setBaud(baud);
  }

  @override
  Future<void> setBaud(int baud) async {
    int divisor, sub;
    if (baud >= 2500000) {
      divisor = 0;
      sub = 0;
    } else if (baud >= 1750000) {
      divisor = 1;
      sub = 0;
    } else {
      divisor = ((24000000 << 1) ~/ baud + 1) >> 1;
      sub = divisor & 7;
      divisor >>= 3;
      if (divisor > 0x3fff) throw ArgumentError('baud rate $baud not possible on an FTDI');
    }
    var value = divisor, index = 0;
    switch (sub) {
      case 4:
        value |= 0x4000;
      case 2:
        value |= 0x8000;
      case 1:
        value |= 0xc000;
      case 3:
        index |= 1;
      case 5:
        value |= 0x4000;
        index |= 1;
      case 6:
        value |= 0x8000;
        index |= 1;
      case 7:
        value |= 0xc000;
        index |= 1;
    }
    await out(0x40, 3, value, iface > 0 ? (index << 8) | _port : index);
  }

  @override
  Future<void> setSignals({required bool dtr, required bool rts}) async {
    await out(0x40, 1, (dtr ? 1 : 0) | 0x0100, _port);
    await out(0x40, 1, (rts ? 2 : 0) | 0x0200, _port);
  }

  set maxPacket(int v) => _maxPacket = v;

  @override
  Uint8List filterRx(Uint8List d) {
    final out = BytesBuilder(copy: false);
    for (var o = 0; o < d.length; o += _maxPacket) {
      final end = (o + _maxPacket) < d.length ? o + _maxPacket : d.length;
      if (end - o > 2) out.add(Uint8List.sublistView(d, o + 2, end));
    }
    return out.toBytes();
  }
}

/// Prolific PL2303.
class Pl2303Chip extends UsbChip {
  Pl2303Chip(super.ctl, super.iface);
  bool _dtr = true, _rts = true;
  @override
  String get name => 'PL2303';

  Future<void> _vin(int value, int index) async => ctl(0xC0, 0x01, value, index, length: 1);
  Future<void> _vout(int value, int index) => out(0x40, 0x01, value, index);

  @override
  Future<void> open(int baud) async {
    await _vin(0x8484, 0);
    await _vout(0x0404, 0);
    await _vin(0x8484, 0);
    await _vin(0x8383, 0);
    await _vin(0x8484, 0);
    await _vout(0x0404, 1);
    await _vin(0x8484, 0);
    await _vin(0x8383, 0);
    await _vout(0, 1);
    await _vout(1, 0);
    await _vout(2, 0x44);
    await setBaud(baud);
    await setSignals(dtr: true, rts: true);
  }

  @override
  Future<void> setBaud(int baud) => out(0x21, 0x20, 0, 0, _lineCoding(baud));

  @override
  Future<void> setSignals({required bool dtr, required bool rts}) {
    _dtr = dtr;
    _rts = rts;
    return out(0x21, 0x22, (_dtr ? 1 : 0) | (_rts ? 2 : 0), 0);
  }
}
