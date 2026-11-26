// Simulated playdate partner for the Tamagotchi Paradise: a native Dart port of Paramix Studio's
// src/visit.js (1.6.9, GPL-3.0-or-later).
//
// The Paradise talks on its contacts (UART, 460800 8-N-1) with the "TCP" protocol described by GMMan
// (tama-para-research, protocols/tcp.md and playdate.md). We play the other device: the player
// starts a playdate on the Paradise and presses B there, so the Paradise is the initiator and we answer.
//
// Flow as recipient (measured with two emulated consoles):
//   < PKT 2        session ID (type bit 4), 2 random bytes
//   < PKT 131092   ghost package + planet screenshot + playdate data (0x20014 bytes)
//   > PKT 131092   our answer: their own package with the chosen edition (rom_type) and our own IDs
//   < PKT 2        friendship level
//     ECHO REQ / ECHO REP while the animation runs
//   < PKT 4        play result (u16 result, bit 0 of the next u16: breeding possible)
//     with breeding: we answer "BREED 0" and "SYNC 1" (we never breed)
//
// No game data is in here: the visitor is a copy of the player's own Tama, only the edition and the IDs
// are ours. The chunks use the same link key as the flash app loader (flash.dart: linkKey). Transport free:
// send(bytes) out, feed(bytes) in (or [Visitor.listen] on a stream of bytes), so the same code runs in the check.
//
// Differences to the JS: a length in "PKT n" that is not a whole number is ignored; nonce and timeScale are there
// for the check (fixed nonces, shorter waits). Where the JS runs into a TypeError (a packet that ends while a chunk
// of it is still being encrypted) the same error is logged, with the text Chrome gives it.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// ignore_for_file: constant_identifier_names

const Map<String, int> ED = {'land': 1, 'water': 2, 'sky': 3, 'jade': 4, 'tropics': 5, 'glacier': 6};
const int _PD = 0x20000; // playdate data in the phase 1 packet

Uint8List _enc(String s) => Uint8List.fromList(utf8.encode(s));

int crc16(Uint8List d) {
  var c = 0;
  for (var i = 0; i < d.length; i++) {
    c ^= d[i];
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1;
    }
  }
  return c;
}

Uint8List _keystream(Uint8List nonce, Uint8List key) {
  final m = Uint8List(4 + key.length);
  m.setRange(0, 4, nonce);
  m.setRange(4, 4 + key.length, key);
  return Uint8List.fromList(sha256.convert(m).bytes);
}

/// encrypt and decrypt are the same: XOR with the keystream, each key byte becomes 2k+1 after use
Uint8List cryptSync(Uint8List nonce, Uint8List key, Uint8List data) {
  final k = _keystream(nonce, key), out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    final j = i & 31;
    out[i] = data[i] ^ k[j];
    k[j] = (k[j] * 2 + 1) & 255;
  }
  return out;
}

/// As in the JS, where the hash comes from the browser later: the answer arrives after the lines that are already
/// read have been worked through (a turn of the event loop). The visitor depends on that order.
Future<Uint8List> crypt(Uint8List nonce, Uint8List key, Uint8List data) async {
  await Future<void>.delayed(Duration.zero);
  return cryptSync(nonce, key, data);
}

final Random _rng = Random.secure();
Uint8List _rnd4() {
  final n = Uint8List(4);
  for (var i = 0; i < 4; i++) {
    n[i] = _rng.nextInt(256);
  }
  return n;
}

int _u32(Uint8List b, int o) => (b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24) & 0xFFFFFFFF;
void _w16(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = v >> 8 & 255;
}

void _w32(Uint8List b, int o, int v) {
  b[o] = v & 255;
  b[o + 1] = v >> 8 & 255;
  b[o + 2] = v >> 16 & 255;
  b[o + 3] = v >> 24 & 255;
}

bool _jsSpace(int c) =>
    (c >= 9 && c <= 13) || c == 0x20 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000 || c == 0xFEFF;

/// JS String.trim (Dart also trims U+0085).
String _trim(String s) {
  var a = 0, b = s.length;
  while (a < b && _jsSpace(s.codeUnitAt(a))) {
    a++;
  }
  while (b > a && _jsSpace(s.codeUnitAt(b - 1))) {
    b--;
  }
  return s.substring(a, b);
}

/// the link key: 32 characters, as text or as the bytes of the key file (String or Uint8List). null: not a key.
Uint8List? parseKey(Object x) {
  // (bytes: only printable ASCII passes the test below, so Latin-1 and windows-1252 give the same answer)
  var s = x is String ? x : String.fromCharCodes(x as Uint8List);
  s = _trim(s);
  if (!RegExp(r'^[\x21-\x7e]{16,64}$').hasMatch(s)) return null;
  return _enc(s);
}

/// JS unary plus for the numbers that come in a command line. null: NaN or not a whole number.
int? _num(String? s) {
  if (s == null) return null;
  final t = _trim(s);
  if (t.isEmpty) return 0;
  if (RegExp(r'^0[xX][0-9a-fA-F]+$').hasMatch(t)) return int.tryParse(t.substring(2), radix: 16);
  if (RegExp(r'^0[oO][0-7]+$').hasMatch(t)) return int.tryParse(t.substring(2), radix: 8);
  if (RegExp(r'^0[bB][01]+$').hasMatch(t)) return int.tryParse(t.substring(2), radix: 2);
  if (!RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$').hasMatch(t)) return null;
  final d = double.tryParse(t);
  if (d == null || d.isNaN || d.isInfinite || d != d.truncateToDouble() || d.abs() > 9007199254740992.0) return null;
  return d.toInt();
}

class VisitState {
  String phase = 'wait'; // wait, send, play, done, error
  int sid = 0, got = 0;
  bool stopped = false, started = false, badKey = false;
  int? result;
}

/// log events: 'start', 'packet' {kind}, 'sent', 'result' {result, breed}, 'done', 'error' {text}
typedef VisitLog = void Function(String event, Map<String, Object?> info);

class _Tx {
  _Tx(this.data, this.type) : n = (data.length / 0x1000).ceil();
  final Uint8List data;
  final int type, n;
  int idx = 0, tries = 0;
  bool started = false;
  final Completer<void> done = Completer<void>();
  Timer? timer;
}

class _Rx {
  _Rx(this.n) : data = Uint8List(n);
  final int n;
  int off = 0, idx = 0;
  final Uint8List data;
}

class _VisitError implements Exception {
  _VisitError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The simulated second Paradise. edition: 'water' ... or 1..6; key: the link key ([parseKey]); send: bytes to the
/// Paradise; log: what happens. Bytes from the Paradise go to [feed] (or [listen] to a stream).
class Visitor {
  Visitor({required Object edition, required this.key, required this.send, VisitLog? log, Uint8List Function()? nonce, this.timeScale = 1})
    : _log = log ?? ((_, _) {}),
      _nonce = nonce ?? _rnd4,
      _ed = edition is int ? edition : (ED[edition.toString().toLowerCase()] ?? 0) {
    if (_ed == 0) throw StateError('unknown edition');
  }

  final Uint8List key;

  /// Bytes to the Paradise.
  final Future<void> Function(Uint8List) send;
  final VisitLog _log;
  final Uint8List Function() _nonce;
  final int _ed;

  /// 1: the real waits (150 ms, 2 s, 3 s, 5 s); smaller for the check.
  final double timeScale;
  final VisitState state = VisitState();

  Uint8List _buf = Uint8List(0);
  int _need = 0; // > 0: a chunk of this size is expected
  _Rx? _rx; // packet coming in
  _Tx? _tx; // packet going out
  Timer? _echo;
  Future<void> _queue = Future<void>.value();
  StreamSubscription<Uint8List>? _sub;

  Duration _ms(int ms) => Duration(microseconds: (ms * 1000 * timeScale).round());
  Future<void> _out(Uint8List b) => send(b);
  Future<void> _line(String s) => _out(_enc('$s\r\n'));
  void _quiet(Future<void> f) => f.catchError((Object _) {});

  /// Feed the visitor from a serial port's stream of bytes.
  void listen(Stream<Uint8List> input) {
    _sub?.cancel();
    _sub = input.listen(feed);
  }

  void _idle(bool on) {
    _echo?.cancel();
    _echo = null;
    // the other device pings every 3 to 4 s while nothing is sent; we do the same so it sees us
    if (on && !state.stopped) {
      _echo = Timer.periodic(_ms(3000), (_) {
        if (_tx == null && _rx == null && _need == 0) _quiet(_line('ECHO REQ'));
      });
    }
  }

  Future<void> _sendPacket(Uint8List data, int type) async {
    final tx = _tx = _Tx(data, type);
    tx.done.future.ignore();
    await _line('PKT ${data.length}');
    if (_tx == null) throw _VisitError("Cannot set properties of null (setting 'timer')"); // (the JS TypeError)
    _tx!.timer = Timer(_ms(2000), _retryPkt);
    return tx.done.future;
  }

  void _retryPkt() {
    final tx = _tx;
    if (tx == null || state.stopped) return;
    if (++tx.tries >= 3) {
      _tx = null;
      _quiet(_line('CAN'));
      tx.done.completeError(_VisitError('no ACK'));
      return;
    }
    _quiet(_line('PKT ${tx.data.length}'));
    tx.timer = Timer(_ms(2000), _retryPkt);
  }

  Future<void> _sendChunk() async {
    var tx = _tx;
    if (tx == null) throw _VisitError("Cannot read properties of null (reading 'idx')");
    final i = tx.idx, a = i * 0x1000, e = min(tx.data.length, (i + 1) * 0x1000);
    final d = a >= 0 && a <= e ? Uint8List.sublistView(tx.data, a, e) : Uint8List(0);
    final p = Uint8List(12 + d.length);
    _w32(p, 0, state.sid);
    p[4] = 0x54;
    p[5] = 0x43;
    p[6] = 0x50;
    p[7] = tx.type;
    p[8] = i;
    p[9] = 255 - i;
    _w16(p, 10, crc16(d));
    p.setRange(12, 12 + d.length, d);
    final n = _nonce(), c = await crypt(n, key, p), all = Uint8List(4 + c.length);
    all.setRange(0, 4, n);
    all.setRange(4, 4 + c.length, c);
    // (the packet may have ended or been cancelled meanwhile: the JS TypeError, with Chrome's text)
    tx = _tx;
    if (tx == null) throw _VisitError("Cannot read properties of null (reading 'timer')");
    tx.timer?.cancel();
    tx.timer = Timer(_ms(5000), () {
      final t = _tx;
      if (t != null && ++t.tries < 3) {
        _quiet(_sendChunk());
      } else if (t != null) {
        _tx = null;
        t.done.completeError(_VisitError('no ACK for a chunk'));
      }
    });
    await _out(all);
  }

  void _onAck() {
    final tx = _tx;
    if (tx == null) return;
    tx.tries = 0;
    if (tx.started) tx.idx++;
    tx.started = true;
    if (tx.idx >= tx.n) {
      tx.timer?.cancel();
      _tx = null;
      tx.done.complete();
      return;
    }
    _sendChunk().catchError(_fail);
  }

  Uint8List? _answer(Uint8List their) {
    if (their.length < _PD + 0x14) return null;
    final a = Uint8List.fromList(their);
    _w16(a, _PD, 0); // force_send_away: never
    _w16(a, _PD + 2, _ed); // rom_type: the chosen edition
    _w32(a, _PD + 4, 0x504D5800 | _ed); // device UID of the simulated device ("PMX" + edition)
    _w32(a, _PD + 8, _u32(their, _PD + 8) ^ 0x5A5A0000 ^ _ed); // character UID: theirs, changed
    return a;
  }

  Future<void> _packet(Uint8List d, int type) async {
    state.got++;
    if ((type & 0x10) != 0) {
      _log('packet', {'kind': 'session'});
      return;
    }
    if (d.length == 0x20014) {
      _log('packet', {'kind': 'data', 'ed': _u32(d, _PD) >> 16});
      state.phase = 'send';
      final a = _answer(d)!;
      await Future<void>.delayed(_ms(150)); // the other device also waits a moment before it answers
      await _sendPacket(a, type & 15);
      state.phase = 'play';
      _log('sent', {});
      _idle(true);
      return;
    }
    if (d.length == 2) {
      _log('packet', {'kind': 'friendship', 'level': d[0] | d[1] << 8});
      return;
    }
    if (d.length == 4) {
      final result = d[0] | d[1] << 8, breed = (d[2] & 1) != 0;
      state.result = result;
      _log('result', {'result': result, 'breed': breed});
      if (breed) {
        await _line('BREED 0');
        await _line('SYNC 1');
        return;
      }
      _finish();
      return;
    }
    _log('packet', {'kind': 'other', 'n': d.length});
  }

  void _finish() {
    if (state.phase == 'done') return;
    state.phase = 'done';
    _idle(false);
    _log('done', {'result': state.result});
  }

  void _fail(Object e) {
    if (state.stopped) return;
    _idle(false);
    state.phase = 'error';
    _log('error', {'text': e is _VisitError ? e.message : e.toString()});
  }

  Future<void> _chunk(Uint8List c) async {
    final n = Uint8List.sublistView(c, 0, 4), p = await crypt(n, key, Uint8List.sublistView(c, 4));
    final sid = _u32(p, 0), type = p[7], idx = p[8], crc = p[10] | p[11] << 8, d = Uint8List.sublistView(p, 12);
    final ok = p[4] == 0x54 && p[5] == 0x43 && p[6] == 0x50 && p[9] == 255 - idx && crc16(d) == crc && (state.sid == 0 || (type & 0x10) != 0 || sid == state.sid);
    if (!ok) {
      _need = c.length;
      await _line('NAK');
      if (!state.badKey && p[4] != 0x54) {
        state.badKey = true;
        _log('error', {'text': 'key'});
      }
      return;
    }
    final rx = _rx;
    if (rx == null) throw _VisitError("Cannot read properties of null (reading 'idx')");
    if (idx != rx.idx) {
      _need = c.length;
      await _line('ENQ ${rx.idx}');
      return;
    }
    if ((type & 0x10) != 0) state.sid = sid;
    rx.data.setRange(rx.off, rx.off + d.length, d);
    rx.off += d.length;
    rx.idx++;
    final left = rx.n - rx.off;
    _need = left > 0 ? 16 + min(0x1000, left) : 0;
    await _line('ACK');
    if (left == 0) {
      _rx = null;
      _packet(rx.data, type).catchError(_fail);
    }
  }

  Future<void> _command(String s) async {
    final w = _trim(s).split(RegExp(r'\s+'));
    if (w[0].isEmpty) return;
    if (w[0] == 'PKT') {
      final n = _num(w.length > 1 ? w[1] : null);
      if (n == null || !(n > 0 && n <= 0x100000)) return;
      if (state.phase == 'wait' && !state.started) {
        state.started = true;
        _log('start', {});
      }
      _rx = _Rx(n);
      _need = 16 + min(0x1000, n);
      await _line('ACK');
      return;
    }
    if (w[0] == 'ACK') {
      _onAck();
      return;
    }
    if (w[0] == 'NAK') {
      if (_tx != null && _tx!.started) _sendChunk().catchError(_fail);
      return;
    }
    if (w[0] == 'ENQ') {
      final tx = _tx;
      if (tx != null) {
        tx.idx = _num(w.length > 1 ? w[1] : null) ?? 0;
        tx.started = true;
        _sendChunk().catchError(_fail);
      }
      return;
    }
    if (w[0] == 'CAN') {
      final tx = _tx;
      if (tx != null) {
        _tx = null;
        tx.done.completeError(_VisitError('cancelled by the Paradise'));
      } else if (state.phase != 'done') {
        _fail(_VisitError('cancelled by the Paradise'));
      }
      return;
    }
    if (w[0] == 'ECHO') {
      if (w.length > 1 && w[1] == 'REQ') await _line('ECHO REP');
      return;
    }
    if (w[0] == 'SYNC') return; // we sent ours with BREED 0
  }

  Future<void> _pump() async {
    for (;;) {
      if (_need != 0) {
        if (_buf.length < _need) return;
        final c = Uint8List.fromList(Uint8List.sublistView(_buf, 0, _need));
        _buf = Uint8List.fromList(Uint8List.sublistView(_buf, _need));
        _need = 0;
        await _chunk(c);
        continue;
      }
      var j = -1;
      for (var i = 0; i + 1 < _buf.length; i++) {
        if (_buf[i] == 13 && _buf[i + 1] == 10) {
          j = i;
          break;
        }
      }
      if (j < 0) {
        if (_buf.length > 256) _buf = Uint8List.fromList(Uint8List.sublistView(_buf, _buf.length - 64));
        return;
      }
      // (Latin-1; the JS decodes windows-1252, which gives the same words and the same white space)
      final s = String.fromCharCodes(Uint8List.sublistView(_buf, 0, j));
      _buf = Uint8List.fromList(Uint8List.sublistView(_buf, j + 2));
      await _command(s);
    }
  }

  /// Bytes from the Paradise. The future ends when they are worked through.
  Future<void> feed(Uint8List bytes) {
    if (state.stopped) return _queue;
    final b = Uint8List(_buf.length + bytes.length);
    b.setRange(0, _buf.length, _buf);
    b.setRange(_buf.length, b.length, bytes);
    _buf = b;
    _queue = _queue.then((_) => _pump()).catchError(_fail);
    return _queue;
  }

  void stop() {
    state.stopped = true;
    _idle(false);
    _tx?.timer?.cancel();
    _tx = null;
    _rx = null;
    _sub?.cancel();
    _sub = null;
  }
}

/// As the JS: createVisitor({ edition, key, send, log }).
Visitor createVisitor({required Object edition, required Uint8List key, required Future<void> Function(Uint8List) send, VisitLog? log, Uint8List Function()? nonce, double timeScale = 1}) =>
    Visitor(edition: edition, key: key, send: send, log: log, nonce: nonce, timeScale: timeScale);
