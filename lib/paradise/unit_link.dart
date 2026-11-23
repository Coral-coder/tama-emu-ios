import 'dart:async';
import 'dart:typed_data';

import '../services/serial/serial_hub.dart';
import 'paradise_machine.dart';

/// A game of the app on the serial connection (the USB adapter, or a Bluetooth / Wi-Fi serial
/// bridge) wired to the link port of a real Tamagotchi Paradise: TX to RX, RX to TX, GND, at
/// 460800 baud 8N1. The real unit sees another console.
class UnitLink implements ParadiseLink {
  UnitLink(this.m, this.hub) {
    m.linkClear();
    m.link = this;
    if (hub.baud != 460800) unawaited(hub.setBaud(460800));
    _sub = hub.input.listen((d) {
      rx += d.length;
      m.linkGive(d);
    });
  }

  final ParadiseMachine m;
  final SerialHub hub;
  StreamSubscription<Uint8List>? _sub;
  int tx = 0, rx = 0;

  @override
  void pump() {
    if (!hub.connected) return;
    final x = m.linkTake();
    if (x.isEmpty) return;
    tx += x.length;
    unawaited(hub.write(x));
  }

  @override
  String get status => hub.connected
      ? 'Linked to the real unit (${hub.transport?.label}) · → $tx bytes, ← $rx bytes'
      : 'The serial connection is closed';

  @override
  Future<void> close() async {
    await _sub?.cancel();
    if (m.link == this) m.link = null;
  }
}
