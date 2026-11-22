import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:typed_data/typed_buffers.dart';

/// Links two phones through the internet with a shared code. Both join the same code; bytes go
/// through a public MQTT broker, end-to-end encrypted with AES-GCM (key from the code), so the
/// broker only sees noise on a topic derived from the code.
class Tunnel extends ChangeNotifier {
  Tunnel._();
  static final Tunnel instance = Tunnel._();

  static const brokers = [
    ('broker.emqx.io', 8883),
    ('broker.hivemq.com', 8883),
    ('test.mosquitto.org', 8886),
  ];
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  // message kinds
  static const kindData = 1;
  static const kindHello = 2;
  static const kindChat = 3;
  static const kindBye = 4;

  MqttServerClient? _client;
  String? code;
  String status = 'Not connected';
  bool connected = false;
  String peerName = '';
  DateTime? peerSeen;
  int rxBytes = 0, txBytes = 0;
  int brokerIndex = 0;
  String myName = 'Tama';
  final List<String> chat = [];

  late String _myId;
  late String _topic;
  SecretKey? _key;
  final _algo = AesGcm.with256bits();
  final _data = StreamController<Uint8List>.broadcast();
  Timer? _hello;

  /// Link bytes from the other phone.
  Stream<Uint8List> get data => _data.stream;
  bool get peerOnline => peerSeen != null && DateTime.now().difference(peerSeen!).inSeconds < 12;

  static String newCode() {
    final r = Random.secure();
    final s = List.generate(8, (_) => _alphabet[r.nextInt(_alphabet.length)]).join();
    return '${s.substring(0, 4)}-${s.substring(4)}';
  }

  static String normalize(String c) => c.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  Future<void> join(String rawCode) async {
    await leave();
    final c = normalize(rawCode);
    if (c.length < 6) throw Exception('The code needs at least 6 letters or digits');
    code = c;
    final topicHash = await Sha256().hash(utf8.encode('tama-tools/topic/$c'));
    _topic = 'tamatools/v1/${_hex(topicHash.bytes).substring(0, 32)}';
    final keyHash = await Sha256().hash(utf8.encode('tama-tools/key/$c'));
    _key = SecretKey(keyHash.bytes);
    _myId = _hex(List.generate(6, (_) => Random.secure().nextInt(256)));
    final (host, port) = brokers[brokerIndex % brokers.length];
    status = 'Connecting to $host …';
    notifyListeners();
    final cl = MqttServerClient.withPort(host, 'tama-$_myId', port);
    cl.secure = true;
    cl.keepAlivePeriod = 20;
    cl.autoReconnect = true;
    cl.logging(on: false);
    cl.setProtocolV311();
    cl.connectionMessage = MqttConnectMessage().withClientIdentifier('tama-$_myId').startClean();
    cl.onDisconnected = () {
      connected = false;
      status = 'Disconnected';
      notifyListeners();
    };
    cl.onAutoReconnected = () {
      connected = true;
      status = 'Connected (reconnected)';
      cl.subscribe('$_topic/+', MqttQos.atMostOnce);
      notifyListeners();
    };
    _client = cl;
    try {
      await cl.connect();
    } catch (e) {
      status = 'Could not reach $host: $e';
      _client = null;
      notifyListeners();
      rethrow;
    }
    cl.subscribe('$_topic/+', MqttQos.atMostOnce);
    cl.updates?.listen(_onMessages);
    connected = true;
    status = 'Waiting for the other phone (code ${display(c)})';
    _hello = Timer.periodic(const Duration(seconds: 4), (_) => _send(kindHello, utf8.encode(myName)));
    await _send(kindHello, utf8.encode(myName));
    notifyListeners();
  }

  static String display(String c) => c.length == 8 ? '${c.substring(0, 4)}-${c.substring(4)}' : c;

  Future<void> leave() async {
    _hello?.cancel();
    _hello = null;
    if (_client != null && connected) {
      try {
        await _send(kindBye, const []);
      } catch (_) {}
    }
    _client?.autoReconnect = false;
    _client?.disconnect();
    _client = null;
    connected = false;
    peerSeen = null;
    peerName = '';
    code = null;
    status = 'Not connected';
    notifyListeners();
  }

  Future<void> sendData(Uint8List d) => _send(kindData, d);

  Future<void> sendChat(String s) async {
    chat.add('me: $s');
    await _send(kindChat, utf8.encode(s));
    notifyListeners();
  }

  Future<void> _send(int kind, List<int> body) async {
    final cl = _client;
    final key = _key;
    if (cl == null || key == null || cl.connectionStatus?.state != MqttConnectionState.connected) return;
    final nonce = _algo.newNonce();
    final box = await _algo.encrypt([kind, ...body], secretKey: key, nonce: nonce);
    final payload = Uint8Buffer()..addAll([...nonce, ...box.cipherText, ...box.mac.bytes]);
    if (kind == kindData) txBytes += body.length;
    cl.publishMessage('$_topic/$_myId', MqttQos.atMostOnce, payload);
  }

  Future<void> _onMessages(List<MqttReceivedMessage<MqttMessage>> msgs) async {
    for (final m in msgs) {
      if (m.topic.endsWith('/$_myId')) continue;
      final p = m.payload;
      if (p is! MqttPublishMessage) continue;
      final raw = Uint8List.fromList(p.payload.message);
      if (raw.length < 12 + 16 + 1) continue;
      try {
        final box = SecretBox(raw.sublist(12, raw.length - 16), nonce: raw.sublist(0, 12), mac: Mac(raw.sublist(raw.length - 16)));
        final clear = await _algo.decrypt(box, secretKey: _key!);
        final kind = clear[0];
        final body = Uint8List.fromList(clear.sublist(1));
        final wasOnline = peerOnline;
        peerSeen = DateTime.now();
        switch (kind) {
          case kindData:
            rxBytes += body.length;
            _data.add(body);
            break;
          case kindHello:
            peerName = utf8.decode(body, allowMalformed: true);
            if (!wasOnline) {
              status = 'Linked with $peerName';
              notifyListeners();
              await _send(kindHello, utf8.encode(myName));
            }
            break;
          case kindChat:
            chat.add('$peerName: ${utf8.decode(body, allowMalformed: true)}');
            break;
          case kindBye:
            peerSeen = null;
            status = '$peerName left';
            break;
        }
        if (kind != kindData || !wasOnline) notifyListeners();
      } catch (e) {
        debugPrint('tunnel: dropped a message ($e)');
      }
    }
  }

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
