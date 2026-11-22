import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'transport.dart';

class TermLine {
  TermLine(this.out, this.bytes) : at = DateTime.now();
  final bool out; // true: sent by the phone
  final Uint8List bytes;
  final DateTime at;
}

/// The one UART connection of the app, shared by the terminal, the emulator link, the tunnel relay
/// and Paramix Studio's device tab.
class SerialHub extends ChangeNotifier {
  SerialHub._();
  static final SerialHub instance = SerialHub._();

  SerialTransport? transport;
  int baud = 460800;
  int rxBytes = 0, txBytes = 0;
  final List<TermLine> log = [];
  bool logEnabled = true;
  final _in = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _sub;

  /// Bytes from the UART, for whoever uses the connection.
  Stream<Uint8List> get input => _in.stream;
  bool get connected => transport != null;

  Future<void> attach(SerialTransport t) async {
    await disconnect();
    transport = t;
    rxBytes = txBytes = 0;
    _sub = t.input.listen((d) {
      rxBytes += d.length;
      _addLog(false, d);
      _in.add(d);
    }, onDone: () {
      transport = null;
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> disconnect() async {
    final t = transport;
    transport = null;
    await _sub?.cancel();
    _sub = null;
    if (t != null) {
      try {
        await t.close();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> write(Uint8List d) async {
    final t = transport;
    if (t == null) return;
    txBytes += d.length;
    _addLog(true, d);
    await t.write(d);
  }

  Future<void> writeText(String s) => write(Uint8List.fromList(utf8.encode(s)));

  Future<void> setBaud(int b) async {
    baud = b;
    await transport?.setBaud(b);
    notifyListeners();
  }

  void _addLog(bool out, Uint8List d) {
    if (!logEnabled) return;
    // merge small pieces of the same direction that arrive close together
    if (log.isNotEmpty && log.last.out == out && DateTime.now().difference(log.last.at).inMilliseconds < 40 && log.last.bytes.length < 512) {
      final m = Uint8List.fromList([...log.last.bytes, ...d]);
      log[log.length - 1] = TermLine(out, m);
    } else {
      log.add(TermLine(out, d));
      if (log.length > 600) log.removeRange(0, 100);
    }
    notifyListeners();
  }

  void clearLog() {
    log.clear();
    notifyListeners();
  }
}
