// Check of lib/paramix/visit.dart against third_party/paramix-studio/src/visit.js (the original).
// dart run tool/paramix_check/visit_check.dart        (no dumps needed; VERBOSE=1 prints every transcript)
// Prints one line per case: "<case name> <value or sha256>", the same lines as tool/paramix_check/visit.js.
// The Paradise side is scripted with fixed bytes (test key, fixed nonces); everything the module sends and logs is
// recorded in order. The waits of the module (150 ms, 2 s, 3 s, 5 s) are shortened for the cases about them.

// ignore_for_file: avoid_print, non_constant_identifier_names, library_prefixes, constant_identifier_names

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tama_tools/paramix/visit.dart' as V;

final lines = <String>[];
String sha(List<int> b) => sha256.convert(b).toString();
String shaS(String s) => sha256.convert(utf8.encode(s)).toString();
void out(String n, Object? v) => lines.add('$n $v');
Uint8List enc(String s) => Uint8List.fromList(utf8.encode(s));
Future<void> sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));
final Uint8List key = V.parseKey('TestKeyOnly-NotTheReal-0123456789')!;
const SID = 0xEB24098E;
final verbose = Platform.environment['VERBOSE'] != null;

Future<Uint8List> chunk(int sid, int type, int idx, Uint8List data, {bool badCrc = false, Uint8List? k, int n = 0}) async {
  final p = Uint8List(12 + data.length);
  p[0] = sid & 255;
  p[1] = sid >> 8 & 255;
  p[2] = sid >> 16 & 255;
  p[3] = sid >> 24 & 255;
  p[4] = 0x54;
  p[5] = 0x43;
  p[6] = 0x50;
  p[7] = type;
  p[8] = idx;
  p[9] = 255 - idx;
  final c = V.crc16(data) ^ (badCrc ? 0x0101 : 0);
  p[10] = c & 255;
  p[11] = c >> 8;
  p.setRange(12, 12 + data.length, data);
  final nn = Uint8List.fromList([idx, 7, 9, 11 + n]), e = await V.crypt(nn, k ?? key, p), all = Uint8List(4 + e.length);
  all.setRange(0, 4, nn);
  all.setRange(4, all.length, e);
  return all;
}

Uint8List mine(int seed) {
  final m = Uint8List(0x20014);
  for (var i = 0; i < m.length; i++) {
    m[i] = (i * 31 + 7 + seed) & 255;
  }
  m[0x20002] = 1;
  m[0x20004] = 0x8E;
  return m;
}

Uint8List part(Uint8List b, int a, [int? e]) => Uint8List.sublistView(b, a < b.length ? a : b.length, e == null || e > b.length ? b.length : e);

/// one scripted visit: tr is the transcript (sends and log events in order)
class Session {
  Session(Object edition, double scale) {
    var nonceN = 0;
    v = V.createVisitor(
      edition: edition,
      key: key,
      timeScale: scale,
      nonce: () {
        nonceN++;
        final n = Uint8List(4);
        for (var i = 0; i < 4; i++) {
          n[i] = (nonceN * 37 + i * 11 + (nonceN >> 8)) & 255;
        }
        return n;
      },
      send: (b) async => rec(b),
      log: (e, i) => tr.add('L $e ${i.keys.map((k) => '$k=${i[k]}').join(',')}'),
    );
  }
  late final V.Visitor v;
  final tr = <String>[];

  void rec(Uint8List b) {
    var txt = b.length <= 40 && b.length >= 2 && b[b.length - 2] == 13 && b[b.length - 1] == 10;
    for (var i = 0; txt && i < b.length - 2; i++) {
      if (b[i] < 32 || b[i] > 126) txt = false;
    }
    tr.add(txt ? 'S "${latin1.decode(b.sublist(0, b.length - 2))}"' : 'S ${b.length}:${sha(b)}');
  }

  /// feed, then wait until n more entries are in the transcript (or 6 s)
  Future<void> step(Object bytes, int n) async {
    final want = tr.length + n;
    await v.feed(bytes is String ? enc(bytes) : bytes as Uint8List);
    for (var i = 0; i < 3000 && tr.length < want; i++) {
      await sleep(2);
    }
    if (tr.length < want) tr.add('TIMEOUT');
  }

  Future<void> until(int n, int ms) async {
    final want = tr.length + n;
    for (var i = 0; i < ms / 2 && tr.length < want; i++) {
      await sleep(2);
    }
    if (tr.length < want) tr.add('TIMEOUT');
  }

  Future<void> packet(int type, Uint8List data, int extra) async {
    await step('PKT ${data.length}\r\n', tr.isEmpty ? 2 : 1);
    final n = (data.length / 0x1000).ceil();
    for (var i = 0; i < n; i++) {
      await step(await chunk(SID, type, i, part(data, i * 0x1000, (i + 1) * 0x1000)), 1 + (i == n - 1 ? extra : 0));
    }
  }

  // ... 'PKT 131092' is out
  Future<void> open(int seed) async {
    await packet(0x11, Uint8List.fromList([0xAB, 0xAB]), 1);
    await packet(0x01, mine(seed), 2);
  }

  // 33 chunks, then 'sent'
  Future<void> answer() async {
    await step('ACK\r\n', 1);
    for (var i = 0; i < 33; i++) {
      await step('ACK\r\n', 1);
    }
  }

  Future<void> end(String name) async {
    await sleep(40);
    v.stop();
    await sleep(20);
    out('visit.$name', '${tr.length} ${shaS(tr.join('\n'))} ${v.state.phase},${v.state.got},${v.state.sid.toRadixString(16)},${v.state.result}');
    if (verbose) {
      for (var i = 0; i < tr.length; i++) {
        out('  $name[$i]', tr[i]);
      }
    }
  }
}

Future<void> main() async {
  // ---- pure functions
  out('ED', V.ED.keys.map((k) => '$k=${V.ED[k]}').join(','));
  final keys = <(String, Object)>[
    ('text', 'TestKeyOnly-NotTheReal-0123456789'), ('short', 'short'), ('spaces', '  0123456789abcdef \r\n'), ('inner', '0123456789 abcdefghij'), ('long', 'x' * 64), ('toolong', 'x' * 65), //
    ('bytes', enc('KeyFromAFile-0123456789ABCDEF\n')),
    ('bytes8', Uint8List.fromList([0x85, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51])),
    ('nbsp', Uint8List.fromList([0xA0, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0xA0])),
    ('empty', ''), ('ctl', '0123456789abcdef\x01'),
  ];
  for (final (n, x) in keys) {
    final k = V.parseKey(x);
    out('parseKey.$n', k != null ? '${k.length}:${sha(k)}' : 'null');
  }
  for (final n in [0, 1, 2, 255, 4096, 70000]) {
    final d = Uint8List(n);
    for (var i = 0; i < n; i++) {
      d[i] = (i * 73 + n) & 255;
    }
    out('crc16.$n', V.crc16(d));
  }
  for (final n in [0, 1, 31, 32, 33, 100, 4108]) {
    final d = Uint8List(n);
    for (var i = 0; i < n; i++) {
      d[i] = (i * 5 + 3) & 255;
    }
    final nn = Uint8List.fromList([1, 2, 3, n & 255]);
    final c = await V.crypt(nn, key, d), b = await V.crypt(nn, key, c);
    out('crypt.$n', '$n:${sha(c)} back=${sha(b) == sha(d) ? 1 : 0}');
  }
  for (final Object ed in ['nowhere', 0, '', 'WATER', 6, 300]) {
    try {
      final v = V.createVisitor(edition: ed, key: key, send: (_) async {});
      out('edition.$ed', 'ok ${v.state.phase}');
      v.stop();
    } on StateError catch (e) {
      out('edition.$ed', 'ERR ${e.message}');
    }
  }

  // ---- a whole visit, for every edition (names and numbers), without and with breeding
  for (final (Object ed, bool breed) in [('sky', false), ('land', false), ('water', true), ('Jade', false), ('tropics', true), ('glacier', false), (5, true), (2, false), (300, false)]) {
    final s = Session(ed, 1);
    await s.open(ed is int ? ed : (ed as String).length);
    await s.answer();
    await s.step('ECHO REQ\r\n', 1);
    await s.packet(0x01, Uint8List.fromList([4, 0]), 1);
    await s.packet(0x01, Uint8List.fromList([7, 1, breed ? 1 : 0, 0]), 2 + (breed ? 1 : 0));
    if (breed) {
      await s.step('SYNC 1\r\n', 0);
      await s.step('CAN\r\n', 1);
    }
    await s.end('visit.$ed${breed ? '.breed' : ''}');
  }

  // ---- broken input: wrong CRC, wrong index, wrong key, other session, split and odd lines
  {
    final s = Session('water', 1);
    for (final l in ['\r\n', 'FOO 1 2\r\n', 'PKT\r\n', 'PKT 0\r\n', 'PKT abc\r\n', 'PKT 9999999\r\n', 'ECHO\r\n', 'ECHO REP\r\n', '  ACK  \r\n', 'NAK\r\n', 'ENQ 3\r\n', 'SYNC 1\r\n']) {
      await s.step(l, 0);
    }
    await s.step(Uint8List(300)..fillRange(0, 300, 0x41), 0);
    await s.step('zz\r\n', 0); // more than 256 bytes without a line end
    await s.step('  ECHO \t REQ  \r\n', 1);
    for (final c in 'PKT 0x2\r'.split('')) {
      await s.step(c, 0); // byte by byte, the length as a hex number
    }
    await s.step('\n', 2);
    final ab = Uint8List.fromList([0xAB, 0xAB]), other = enc('AnotherKey-0123456789-abcdefgh');
    final good = await chunk(SID, 0x11, 0, ab);
    await s.step(await chunk(SID, 0x11, 0, ab, badCrc: true), 1); // NAK
    await s.step(await chunk(SID, 0x11, 1, ab), 1); // ENQ 0
    await s.step(await chunk(SID, 0x11, 0, ab, k: other), 2); // NAK, error key
    await s.step(await chunk(SID, 0x11, 0, ab, k: other, n: 1), 1); // NAK only
    await s.step(part(good, 0, 5), 0);
    await s.step(part(good, 5, 17), 0);
    await s.step(part(good, 17), 2); // in three pieces
    await s.step('PKT 6000\r\n', 1);
    final d = Uint8List(6000);
    for (var i = 0; i < d.length; i++) {
      d[i] = (i * 7) & 255;
    }
    await s.step(await chunk(0x12345678, 0x01, 0, part(d, 0, 0x1000)), 1); // another session: NAK
    await s.step(await chunk(SID, 0x01, 0, part(d, 0, 0x1000)), 1);
    final c1 = await chunk(SID, 0x01, 1, part(d, 0x1000)), two = Uint8List(c1.length + 10);
    two.setRange(0, c1.length, c1);
    two.setRange(c1.length, two.length, enc('ECHO REQ\r\n'));
    await s.step(two, 3);
    await s.step('\n', 0); // ACK, packet other, ECHO REP in one read ... the line end later
    await s.step('PKT 3\r\n', 1);
    await s.step('ECHO REQ\r\nECHO REQ\r\n', 1); // taken as the chunk (19 bytes): NAK, one byte left
    await s.step('ECHO REQ\r\nECHO REQ', 1); // 18 more: NAK again
    await s.end('broken');
  }

  // ---- our packet: NAK and ENQ from the Paradise, then CAN while playing
  {
    final s = Session('glacier', 1);
    await s.open(3);
    await s.step('NAK\r\n', 0); // nothing sent yet
    for (final l in ['ACK\r\n', 'NAK\r\n', 'ACK\r\n', 'ENQ 5\r\n', 'ACK\r\n', 'ENQ 32\r\n', 'ENQ 40\r\n', 'ENQ x\r\n']) {
      await s.step(l, 1);
    }
    await s.step('ENQ 31\r\nACK\r\nACK\r\n', 3);
    await s.step('ACK\r\n', 0);
    await s.step('CAN\r\n', 1);
    await s.step('CAN\r\n', 1);
    await s.end('resend');
  }
  // ---- our packet cancelled by the Paradise
  {
    final s = Session('land', 1);
    await s.open(4);
    await s.step('ACK\r\n', 1);
    await s.step('CAN\r\n', 1);
    await s.step('ACK\r\n', 0);
    await s.end('cancel');
  }
  // ---- nobody answers our PKT: twice again, then CAN
  {
    final s = Session('sky', 0.05);
    await s.open(5);
    await s.until(4, 3000);
    await s.end('noAck');
  }
  // ---- a chunk is not acknowledged: twice again, then the error
  {
    final s = Session('jade', 0.05);
    await s.open(6);
    await s.step('ACK\r\n', 1);
    await s.until(3, 4000);
    await s.end('noChunkAck');
  }
  // ---- while playing we ping
  {
    final s = Session('tropics', 0.05);
    await s.open(7);
    await s.answer();
    await s.until(2, 3000);
    s.v.stop();
    await sleep(400);
    await s.end('echo');
  }
  // ---- stopped while the answer is being prepared
  {
    final s = Session('water', 1);
    await s.packet(0x11, Uint8List.fromList([0xAB, 0xAB]), 1);
    await s.step('PKT 131092\r\n', 1);
    final m = mine(8);
    for (var i = 0; i < 33; i++) {
      await s.step(await chunk(SID, 0x01, i, part(m, i * 0x1000, (i + 1) * 0x1000)), i == 32 ? 2 : 1);
    }
    s.v.stop();
    await s.v.feed(enc('ECHO REQ\r\n'));
    await sleep(400);
    await s.end('stop');
  }
  print(lines.join('\n'));
  exit(0);
}
