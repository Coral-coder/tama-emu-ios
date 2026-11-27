import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:material_ui/material_ui.dart';

import '../services/dongle.dart';
import '../services/serial/serial_hub.dart';

/// The Tama Bridge's settings, over Bluetooth: its name, the line speed, Wi-Fi (its own network
/// or yours), and the link to another bridge (two real toys, no phone).
class DongleScreen extends StatefulWidget {
  const DongleScreen({super.key});

  @override
  State<DongleScreen> createState() => _DongleScreenState();
}

class _DongleScreenState extends State<DongleScreen> {
  final d = Dongle.instance;
  List<ScanResult> _results = [];
  StreamSubscription<List<ScanResult>>? _scan;
  bool _scanning = false;
  final _name = TextEditingController(), _ssid = TextEditingController(), _pass = TextEditingController(), _appass = TextEditingController();
  bool _filled = false;

  @override
  void initState() {
    super.initState();
    d.addListener(_changed);
    if (!d.connected) _startScan();
  }

  @override
  void dispose() {
    d.removeListener(_changed);
    _scan?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (d.connected && !_filled && d.state.isNotEmpty) {
      _filled = true;
      _name.text = d.state['name'] as String? ?? '';
      final w = d.state['wifi'] as Map? ?? {};
      _ssid.text = w['ssid'] as String? ?? '';
    }
    setState(() {});
  }

  void _startScan() {
    setState(() {
      _scanning = true;
      _results = [];
    });
    _scan?.cancel();
    _scan = d.scan().listen((r) => setState(() => _results = r));
    Future<void>.delayed(const Duration(seconds: 6), () {
      if (mounted) setState(() => _scanning = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(d.connected ? d.name : 'Dongle'), actions: [
        if (d.connected) IconButton(tooltip: 'Read again', icon: const Icon(Icons.refresh), onPressed: d.refresh),
        if (d.connected)
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.bluetooth_disabled),
            onPressed: () {
              _filled = false;
              d.disconnect();
              _startScan();
            },
          ),
      ]),
      body: d.connected ? _settings(context) : _finder(context),
    );
  }

  Widget _finder(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Your Tama Bridge, powered and near: it shows here (Bluetooth; no wiring needed to change its settings).', style: TextStyle(color: Colors.white60)),
        const SizedBox(height: 12),
        if (d.error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(d.error!, style: const TextStyle(color: Colors.redAccent))),
        for (final r in _results)
          Card(
            child: ListTile(
              leading: const Icon(Icons.bluetooth_connected),
              title: Text(r.device.platformName.isNotEmpty ? r.device.platformName : r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.remoteId.str),
              subtitle: Text('${r.device.remoteId.str} · ${r.rssi} dBm'),
              onTap: () async {
                await FlutterBluePlus.stopScan();
                await d.connect(r.device);
              },
            ),
          ),
        const SizedBox(height: 8),
        _scanning ? const Center(child: CircularProgressIndicator()) : FilledButton.icon(onPressed: _startScan, icon: const Icon(Icons.search), label: const Text('Look again')),
        const SizedBox(height: 16),
        const Text('No bridge yet? An ESP32 board and the Windows flasher from the repository\'s Releases page (esp32-bridge-…) make one.',
            style: TextStyle(fontSize: 12, color: Colors.white54)),
      ]);

  Future<void> _update(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final fw = await d.latestFirmware();
    if (!context.mounted) return;
    if (fw == null) {
      messenger.showSnackBar(const SnackBar(content: Text('No firmware found for this board (or no network).')));
      return;
    }
    final same = fw.version == d.firmware;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(same ? 'Firmware ${fw.version} is on the bridge' : 'Firmware ${fw.version} is ready'),
        content: Text('${same ? 'The newest build is ${fw.version} (build ${fw.build}); you can send it again. ' : 'The bridge has ${d.firmware}. '}'
            '${(fw.size / 1024).round()} KB over Bluetooth, a few minutes. Keep the bridge powered and the phone near; '
            'if it stops, the bridge keeps its old firmware.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Later')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(same ? 'Send again' : 'Update')),
        ],
      ),
    );
    if (yes != true) return;
    final err = await d.update(fw);
    messenger.showSnackBar(SnackBar(content: Text(err ?? 'Done. The bridge restarts with firmware ${fw.version}: connect to it again.')));
  }

  Widget _settings(BuildContext context) {
    final s = d.state;
    final w = Map<String, dynamic>.from(s['wifi'] as Map? ?? {});
    final p = Map<String, dynamic>.from(s['peer'] as Map? ?? {});
    final pins = Map<String, dynamic>.from(s['pins'] as Map? ?? {});
    final mode = (w['mode'] as num?)?.toInt() ?? 1;
    final baud = (s['baud'] as num?)?.toInt() ?? 460800;
    final title = Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800);
    final playing = SerialHub.instance.connected && SerialHub.instance.transport?.label == d.device?.platformName;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          leading: const Icon(Icons.memory),
          title: Text('${s['chip'] ?? 'ESP32'} · firmware ${s['v'] ?? '?'}'),
          subtitle: Text('${s['mac'] ?? ''}\nToy line: RX GPIO ${pins['rx'] ?? '?'}, TX GPIO ${pins['tx'] ?? '?'}'),
          isThreeLine: true,
        ),
      ),
      Card(
        child: d.updateNote != null
            ? ListTile(
                leading: const Icon(Icons.system_update_alt),
                title: Text(d.updateNote!),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(value: d.updateProgress == 0 ? null : d.updateProgress),
                ),
                trailing: d.updateProgress == null ? null : Text('${(d.updateProgress! * 100).round()} %'),
              )
            : ListTile(
                leading: const Icon(Icons.system_update_alt),
                title: const Text('Update the firmware'),
                subtitle: Text(d.canUpdate
                    ? 'Over Bluetooth, from here. Takes a few minutes.'
                    : 'This firmware cannot take updates over Bluetooth yet: flash 2.2 or later once over USB (the web flasher), from then on it updates here.'),
                enabled: d.canUpdate,
                onTap: () => _update(context),
              ),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: playing ? null : () async {
          await d.useForPlay();
          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The bridge is the serial connection now: link a game with ⋯ → Link with my real unit.')));
          setState(() {});
        },
        icon: const Icon(Icons.cable),
        label: Text(playing ? 'In use for play' : 'Use it for play'),
      ),
      const SizedBox(height: 18),
      Text('Name', style: title),
      Row(children: [
        Expanded(child: TextField(controller: _name, decoration: const InputDecoration(hintText: 'Tama Bridge'))),
        TextButton(onPressed: () => d.set({'name': _name.text.trim()}), child: const Text('Save')),
      ]),
      const Text('The bridge restarts to take a new name.', style: TextStyle(fontSize: 12, color: Colors.white54)),
      const SizedBox(height: 18),
      Text('Line speed', style: title),
      DropdownButton<int>(
        isExpanded: true,
        value: const [460800, 230400, 115200, 57600, 38400, 19200, 9600].contains(baud) ? baud : null,
        hint: Text('$baud baud'),
        items: [
          for (final b in const [460800, 230400, 115200, 57600, 38400, 19200, 9600])
            DropdownMenuItem(value: b, child: Text(b == 460800 ? '460800 baud (Tamagotchi Paradise)' : '$b baud')),
        ],
        onChanged: (v) {
          if (v != null) d.set({'baud': v});
        },
      ),
      const SizedBox(height: 18),
      Text('Wi-Fi', style: title),
      const SizedBox(height: 6),
      SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 0, label: Text('Off')),
          ButtonSegment(value: 1, label: Text('Own network')),
          ButtonSegment(value: 2, label: Text('Join mine')),
        ],
        selected: {mode},
        onSelectionChanged: (v) => d.set({'wifi': v.first}),
      ),
      const SizedBox(height: 8),
      if (mode == 1) ...[
        Text('Network "Tama-Bridge" at ${w['ip'] ?? '192.168.4.1'}, port 23.', style: const TextStyle(color: Colors.white70)),
        Row(children: [
          Expanded(child: TextField(controller: _appass, decoration: const InputDecoration(labelText: 'Its password (8 or more)'))),
          TextButton(onPressed: _appass.text.length >= 8 ? () => d.set({'appass': _appass.text}) : null, child: const Text('Save')),
        ]),
      ],
      if (mode == 2) ...[
        TextField(controller: _ssid, decoration: const InputDecoration(labelText: 'Network name')),
        TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
        const SizedBox(height: 6),
        Row(children: [
          FilledButton(onPressed: () => d.set({'ssid': _ssid.text.trim(), 'pass': _pass.text, 'wifi': 2}), child: const Text('Join')),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              w['connected'] == true ? 'Joined: ${w['ip']} (also tama-bridge.local), port 23' : 'Not joined yet',
              style: TextStyle(color: w['connected'] == true ? Colors.greenAccent : Colors.white54),
            ),
          ),
        ]),
      ],
      const SizedBox(height: 18),
      Text('Link to another bridge', style: title),
      const Text('Two real toys, each on a bridge: the bridges talk Bluetooth to each other (playdates, gifts), no phone needed. Turn it on in one of the two only.',
          style: TextStyle(fontSize: 12, color: Colors.white54)),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(p['addr'] == null || (p['addr'] as String).isEmpty ? 'No bridge picked' : 'With ${p['addr']}'),
        subtitle: Text(p['on'] == true ? (p['connected'] == true ? 'Linked' : 'Looking for it …') : 'Off'),
        value: p['on'] == true,
        onChanged: (p['addr'] as String? ?? '').isEmpty ? null : (v) => d.set({'peeron': v}),
      ),
      OutlinedButton.icon(
        onPressed: d.scanningPeers ? null : d.findPeers,
        icon: const Icon(Icons.radar),
        label: Text(d.scanningPeers ? 'Looking …' : 'Find other bridges'),
      ),
      for (final f in d.found)
        ListTile(
          leading: const Icon(Icons.bluetooth),
          title: Text((f['name'] as String?)?.isNotEmpty == true ? f['name'] as String : 'Bridge'),
          subtitle: Text('${f['addr']} · ${f['rssi']} dBm'),
          trailing: TextButton(onPressed: () => d.set({'peer': f['addr'], 'peeron': true}), child: const Text('Link')),
        ),
      const SizedBox(height: 24),
      OutlinedButton.icon(onPressed: d.restart, icon: const Icon(Icons.restart_alt), label: const Text('Restart the bridge')),
      const SizedBox(height: 30),
    ]);
  }
}
