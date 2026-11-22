import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// A UART behind a TCP serial server on the network (ESP-Link, ESP32 serial bridge, ser2net).
class TcpTransport extends SerialTransport {
  TcpTransport._(this.host, this.port, this._s);

  final String host;
  final int port;
  final Socket _s;
  final _in = StreamController<Uint8List>.broadcast();

  @override
  String get label => '$host:$port';
  @override
  String get kind => 'TCP';
  @override
  Stream<Uint8List> get input => _in.stream;

  static Future<TcpTransport> connect(String host, int port) async {
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 8));
    s.setOption(SocketOption.tcpNoDelay, true);
    final t = TcpTransport._(host, port, s);
    s.listen((d) => t._in.add(d), onDone: () => t._in.close(), onError: (_) => t._in.close());
    return t;
  }

  @override
  Future<void> write(Uint8List data) async {
    _s.add(data);
    await _s.flush();
  }

  @override
  Future<void> close() async {
    try {
      await _s.close();
    } catch (_) {}
    _s.destroy();
    if (!_in.isClosed) await _in.close();
  }
}
