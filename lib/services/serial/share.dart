import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'serial_hub.dart';

/// Shares this phone's serial connection (a USB adapter on Android, say) on the Wi-Fi: another
/// phone running Tama connects to it as to a Wi-Fi serial bridge (Hardware → Wi-Fi, this phone's
/// address, port 2323) and talks to the toy through it.
class SerialShare extends ChangeNotifier {
  SerialShare._();
  static final SerialShare instance = SerialShare._();
  static const port = 2323;

  ServerSocket? _server;
  Socket? _client;
  StreamSubscription<Uint8List>? _hubSub;
  List<String> addresses = [];
  String? peer;
  int toPeer = 0, fromPeer = 0;

  bool get on => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, port, shared: true);
    addresses = [
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
        for (final a in i.addresses)
          if (!a.isLoopback) a.address,
    ];
    _server!.listen((s) {
      _client?.destroy();
      _client = s;
      s.setOption(SocketOption.tcpNoDelay, true);
      peer = s.remoteAddress.address;
      notifyListeners();
      s.listen((d) {
        fromPeer += d.length;
        SerialHub.instance.write(d);
      }, onDone: () {
        if (_client == s) {
          _client = null;
          peer = null;
          notifyListeners();
        }
      }, onError: (_) {});
    });
    _hubSub = SerialHub.instance.input.listen((d) {
      final c = _client;
      if (c == null) return;
      toPeer += d.length;
      c.add(d);
    });
    notifyListeners();
  }

  Future<void> stop() async {
    await _hubSub?.cancel();
    _hubSub = null;
    _client?.destroy();
    _client = null;
    peer = null;
    await _server?.close();
    _server = null;
    notifyListeners();
  }
}
