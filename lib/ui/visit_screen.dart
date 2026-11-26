import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../paramix/flash.dart' show linkKey;
import '../paramix/visit.dart';
import '../services/app_state.dart';
import '../services/native.dart';
import '../services/serial/serial_hub.dart';
import 'hardware_screen.dart';

/// Native simulated playdate: the app plays a second Paradise that visits your real toy over
/// the dongle (Paramix Studio's visit.js ported to Dart, no web page).
class VisitScreen extends StatefulWidget {
  const VisitScreen({super.key});

  @override
  State<VisitScreen> createState() => _VisitScreenState();
}

class _VisitScreenState extends State<VisitScreen> {
  static const _editions = [('land', 'Land'), ('water', 'Water'), ('sky', 'Sky'), ('jade', 'Jade Forest'), ('tropics', 'Tropics'), ('glacier', 'Glacier')];
  SerialHub get hub => AppState.instance.serial;
  String _ed = 'water';
  Visitor? _v;
  StreamSubscription<Uint8List>? _sub;
  String _status = '';
  int _visits = 0;

  String get _edName => _editions.firstWhere((e) => e.$1 == _ed).$2;
  bool get _on => _sub != null;

  @override
  void initState() {
    super.initState();
    _ed = AppState.instance.prefs.getString('visitEd') ?? 'water';
    hub.addListener(_hub);
  }

  @override
  void dispose() {
    hub.removeListener(_hub);
    _stop(quiet: true);
    super.dispose();
  }

  void _hub() {
    if (!hub.connected && _on) _stop();
    if (mounted) setState(() {});
  }

  void _say(String s) {
    if (mounted) setState(() => _status = s);
  }

  /// A fresh visitor waiting for the toy (after every visit, and when the edition changes).
  void _arm() {
    _v?.stop();
    final ed = _edName;
    _v = createVisitor(
      edition: _ed,
      key: parseKey(linkKey)!,
      send: hub.write,
      log: (e, i) {
        if (e == 'start') {
          _say('Connected, exchanging data …');
        } else if (e == 'sent') {
          _say('The two are playing …');
        } else if (e == 'done') {
          _visits++;
          _say('Visit done ($ed). For the next one press B on the Paradise again.');
          Timer(const Duration(milliseconds: 500), () {
            if (_on) {
              _arm();
              _say('Visit done ($ed). For the next one press B on the Paradise again.');
            }
          });
        } else if (e == 'error') {
          final text = '${i['text']}';
          if (text == 'key') {
            _say('The Paradise does not understand the data.');
          } else {
            _say('Stopped: $text. Press B on the Paradise again.');
            Timer(const Duration(seconds: 1), () {
              if (_on) _arm();
            });
          }
        }
      },
    );
    _say('Waiting for the Paradise ($ed visits). On the toy: planet menu, CONNECTION, PLAYDATE, then B.');
  }

  Future<void> _start() async {
    if (!hub.connected) return;
    if (hub.transport?.canSetBaud ?? false) await hub.setBaud(460800);
    _sub = hub.input.listen((d) => _v?.feed(d));
    // a visit takes a while: keep going with the phone locked
    await NativeBridge.keepAlive(true, title: 'Tama', text: 'Playdate with $_edName');
    _arm();
  }

  Future<void> _stop({bool quiet = false}) async {
    _v?.stop();
    _v = null;
    await _sub?.cancel();
    _sub = null;
    final app = AppState.instance;
    if (!(app.backgroundRun && (app.games.isNotEmpty || app.machine != null))) await NativeBridge.keepAlive(false);
    if (!quiet) _say('');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playdate with a visitor')),
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Text('The app plays a second Paradise that comes to visit your real toy. The dongle goes on the toy\'s contacts; the toy runs normally '
                '(not on its download screen).\n\n1. Choose who visits, then Start.\n2. On the toy: planet menu, CONNECTION, PLAYDATE, then B.'),
          ),
        ),
        Card(
          child: ListTile(
            leading: Icon(hub.connected ? Icons.usb : Icons.usb_off, color: hub.connected ? Colors.greenAccent : Colors.white38),
            title: Text(hub.connected ? hub.transport!.label : 'No dongle connected'),
            subtitle: hub.connected ? null : const Text('Connect your Tama Bridge or adapter first.'),
            trailing: hub.connected ? null : const Icon(Icons.chevron_right),
            onTap: hub.connected ? null : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HardwareScreen())),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(children: [
              const Expanded(child: Text('Who visits')),
              DropdownButton<String>(
                value: _ed,
                items: [for (final e in _editions) DropdownMenuItem(value: e.$1, child: Text(e.$2))],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _ed = v);
                  AppState.instance.prefs.setString('visitEd', v);
                  final p = _v?.state.phase;
                  if (_on && (p == null || p == 'wait' || p == 'done' || p == 'error')) _arm();
                },
              ),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: !hub.connected
              ? null
              : () async {
                  if (_on) {
                    await _stop();
                  } else {
                    await _start();
                  }
                  if (mounted) setState(() {});
                },
          icon: Icon(_on ? Icons.stop : Icons.play_arrow_rounded),
          label: Text(_on ? 'Stop' : 'Start'),
        ),
        if (_status.isNotEmpty) Padding(padding: const EdgeInsets.all(14), child: Text(_status, style: Theme.of(context).textTheme.titleMedium)),
        if (_visits > 0) Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Text('$_visits visit${_visits == 1 ? '' : 's'} so far', style: const TextStyle(color: Colors.white54))),
      ]),
    );
  }
}
