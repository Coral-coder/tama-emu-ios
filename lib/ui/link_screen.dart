import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../services/app_state.dart';
import '../services/tunnel.dart';
import 'theme.dart';

class LinkScreen extends StatefulWidget {
  const LinkScreen({super.key});

  @override
  State<LinkScreen> createState() => _LinkScreenState();
}

class _LinkScreenState extends State<LinkScreen> {
  final _code = TextEditingController();
  final _chat = TextEditingController();
  final _name = TextEditingController();
  String? _err;
  bool _joining = false;

  AppState get app => AppState.instance;
  Tunnel get tunnel => app.tunnel;

  @override
  void initState() {
    super.initState();
    _name.text = tunnel.myName;
    _code.text = app.prefs.getString('lastCode') ?? '';
  }

  Future<void> _join() async {
    setState(() {
      _err = null;
      _joining = true;
    });
    try {
      tunnel.myName = _name.text.trim().isEmpty ? 'Tama' : _name.text.trim();
      await app.setPref('myName', tunnel.myName);
      await app.setPref('lastCode', _code.text);
      await tunnel.join(_code.text);
    } catch (e) {
      _err = '$e';
    }
    if (mounted) setState(() => _joining = false);
  }

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleSmall!.copyWith(color: kAmber);
    return Scaffold(
      appBar: AppBar(title: const Text('Link')),
      body: ListenableBuilder(
        listenable: Listenable.merge([app, tunnel, app.serial]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('What is linked', style: title)),
            Card(
              child: RadioGroup<LinkMode>(
                groupValue: app.linkMode,
                onChanged: (v) => app.setLinkMode(v!),
                child: Column(children: [
                  for (final mode in LinkMode.values)
                    RadioListTile<LinkMode>(value: mode, title: Text(mode.label), subtitle: Text(_modeHelp(mode)), dense: true),
                  _readiness(),
                ]),
              ),
            ),
            Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text('Tunnel to another phone', style: title)),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(tunnel.status),
                  if (tunnel.connected) Text('rx ${tunnel.rxBytes} · tx ${tunnel.txBytes} bytes${tunnel.peerOnline ? ' · ${tunnel.peerName} online' : ''}', style: const TextStyle(color: Colors.white60)),
                  const SizedBox(height: 8),
                  if (!tunnel.connected) ...[
                    TextField(controller: _name, decoration: const InputDecoration(labelText: 'Your name (shown to the other phone)')),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _code,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(labelText: 'Link code (both phones enter the same)'),
                        ),
                      ),
                      IconButton(
                        tooltip: 'New code',
                        icon: const Icon(Icons.casino_outlined),
                        onPressed: () => setState(() => _code.text = Tunnel.newCode()),
                      ),
                      IconButton(
                        tooltip: 'Copy',
                        icon: const Icon(Icons.copy),
                        onPressed: () => Clipboard.setData(ClipboardData(text: _code.text)),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      initialValue: tunnel.brokerIndex,
                      decoration: const InputDecoration(labelText: 'Relay server (both phones the same)'),
                      items: [for (var i = 0; i < Tunnel.brokers.length; i++) DropdownMenuItem(value: i, child: Text(Tunnel.brokers[i].$1))],
                      onChanged: (v) => tunnel.brokerIndex = v ?? 0,
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _joining ? null : _join,
                      icon: const Icon(Icons.hub_outlined),
                      label: Text(_joining ? 'Connecting …' : 'Join'),
                    ),
                  ] else ...[
                    Text('Code ${Tunnel.display(tunnel.code ?? '')}', style: const TextStyle(fontSize: 22, letterSpacing: 2, color: kAmber)),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 120,
                      child: ListView(reverse: true, children: [for (final l in tunnel.chat.reversed) Text(l)]),
                    ),
                    Row(children: [
                      Expanded(child: TextField(controller: _chat, decoration: const InputDecoration(hintText: 'message', isDense: true))),
                      IconButton(
                        icon: const Icon(Icons.send),
                        onPressed: () {
                          if (_chat.text.isNotEmpty) tunnel.sendChat(_chat.text);
                          _chat.clear();
                        },
                      ),
                    ]),
                    OutlinedButton(onPressed: tunnel.leave, child: const Text('Leave')),
                  ],
                  if (_err != null) Text(_err!, style: const TextStyle(color: Colors.redAccent)),
                ]),
              ),
            ),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'How the link works: the emulated toy\'s contact (P20, as Paramix V1Emu wires it for the '
                  'Digital Monster battles) goes out as Paramix plink "D" frames: each edge with its time. '
                  'The other side plays the edges back with a fixed delay, so the pulse lengths stay exact '
                  'over a UART or the internet.\n\n'
                  '• Emulator ↔ UART: plug the dongle into a Paradise running V1Emu (Studio → Emulator) to '
                  'battle the emulated Digimon against the real one.\n'
                  '• Emulator ↔ Tunnel: two phones, each with an emulator or with a UART.\n'
                  '• UART ↔ Tunnel: the bytes of two physical toys / dongles / P-Coms are relayed as they are.\n\n'
                  'The tunnel is end-to-end encrypted with a key made from the code; the relay server only '
                  'passes the bytes on.',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readiness() {
    final m = app.machine;
    final items = <String>[];
    final mode = app.linkMode;
    if (mode == LinkMode.emuUart || mode == LinkMode.emuTunnel) items.add(m == null ? '✗ no toy running' : '✓ ${m.profile.displayName}${m.profile.isDigimon ? '' : ' (only the Digimon use the contact)'}');
    if (mode == LinkMode.emuUart || mode == LinkMode.uartTunnel) items.add(app.serial.connected ? '✓ UART ${app.serial.transport!.label}' : '✗ no UART (Hardware page)');
    if (mode == LinkMode.emuTunnel || mode == LinkMode.uartTunnel) items.add(tunnel.peerOnline ? '✓ tunnel to ${tunnel.peerName}' : tunnel.connected ? '… waiting for the other phone' : '✗ tunnel not joined');
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Align(alignment: Alignment.centerLeft, child: Text(items.join('\n'), style: const TextStyle(color: Colors.white70))),
    );
  }

  static String _modeHelp(LinkMode m) => switch (m) {
        LinkMode.off => 'The toy plays on its own',
        LinkMode.emuUart => 'Emulated toy ↔ real toy on the UART (Paramix plink, 460800)',
        LinkMode.emuTunnel => 'Emulated toy ↔ the other phone',
        LinkMode.uartTunnel => 'Real toy on the UART ↔ the other phone (raw bytes)',
      };
}
