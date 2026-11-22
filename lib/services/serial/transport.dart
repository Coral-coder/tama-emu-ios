import 'dart:async';
import 'dart:typed_data';

/// A byte pipe to a UART: a BLE serial bridge, a USB serial adapter (Android) or a TCP serial
/// server (ESP-Link, ser2net ...).
abstract class SerialTransport {
  String get label;

  /// "BLE", "USB" or "TCP".
  String get kind;

  Stream<Uint8List> get input;
  Future<void> write(Uint8List data);

  /// Baud rate of the UART. Only a USB adapter can change it; a BLE or TCP bridge has its own.
  Future<void> setBaud(int baud) async {}
  bool get canSetBaud => false;
  Future<void> setSignals({bool? dtr, bool? rts}) async {}
  Future<void> close();

  /// Best chunk size for writes.
  int get chunk => 4096;
}
