import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/app_state.dart';
import '../services/serial/ble_transport.dart';
import '../services/serial/serial_hub.dart';
import '../services/serial/tcp_transport.dart';
import '../services/serial/usb_transport.dart';
import 'theme.dart';

/// UART connections (BLE serial bridge, USB adapter, Wi-Fi bridge) and a terminal for the
/// Paradise dongle, a P-Com or any serial gadget.
class HardwareScreen extends StatefulWidget {
  const HardwareScreen({super.key});

  @override
  State<HardwareScreen> createState() => _HardwareScreenState();
}

class _HardwareScreenState extends State<HardwareScreen> {
  SerialHub get hub => AppState.instance.serial;
  final _send = TextEditingController();
  final _host = TextEditingController(text: '192.168.4.1');
  final _port = TextEditingController(text: '23');
  bool _hex = false;
  bool _hexIn = false;
  String _eol = '\r\n';
  bool _scanning = false;
  List<ScanResult> _ble = [];
  List<UsbAdapter> _usb = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  String? _err;

  static const bauds = [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600];

  @override
  void initState() {
    super.initState();
    _host.text = AppState.instance.prefs.getString('tcpHost') ?? _host.text;
    _port.text = AppState.instance.prefs.getString('tcpPort') ?? _port.text;
    if (UsbTransport.supported) _refreshUsb();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _refreshUsb() async {
    try {
      final l = await UsbTransport.list();
      if (mounted) setState(() => _usb = l);
    } catch (e) {
      if (mounted) setState(() => _err = 'USB: $e');
    }
  }

  Future<void> _scan() async {
    setState(() {
      _err = null;
      _ble = [];
    });
    if (Platform.isAndroid) {
      await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
    }
    if (await FlutterBluePlus.isSupported == false) {
      setState(() => _err = 'Bluetooth LE is not available on this device');
      return;
    }
    setState(() => _scanning = true);
    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((r) {
      if (mounted) setState(() => _ble = r.where((x) => x.device.platformName.isNotEmpty || x.advertisementData.serviceUuids.isNotEmpty).toList());
    });
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } catch (e) {
      _err = 'Scan: $e';
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _guard(Future<void> Function() f) async {
    setState(() => _err = null);
    try {
      await f();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  Future<void> _sendLine() async {
    final s = _send.text;
    if (s.isEmpty) return;
    if (_hexIn) {
      final clean = s.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
      final out = Uint8List(clean.length ~/ 2);
      for (var i = 0; i < out.length; i++) {
        out[i] = int.parse(clean.substring(2 * i, 2 * i + 2), radix: 16);
      }
      await hub.write(out);
    } else {
      await hub.writeText(s + _eol);
    }
    _send.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hardware · UART')),
      body: ListenableBuilder(
        listenable: hub,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _connection(context),
            if (_err != null) Padding(padding: const EdgeInsets.all(12), child: Text(_err!, style: const TextStyle(color: Colors.redAccent))),
            if (!hub.connected) ..._connectOptions(context),
            if (hub.connected) _terminal(context),
            const _HelpCard(),
          ],
        ),
      ),
    );
  }

  Widget _connection(BuildContext context) {
    final t = hub.transport;
    return Card(
      child: ListTile(
        leading: Icon(t != null ? Icons.cable : Icons.portable_wifi_off, color: t != null ? Colors.greenAccent : Colors.white38),
        title: Text(t == null ? 'Not connected' : '${t.kind}: ${t.label}'),
        subtitle: Text(t == null ? 'Pick a connection below' : 'rx ${hub.rxBytes} · tx ${hub.txBytes} bytes${t.canSetBaud ? ' · ${hub.baud} baud' : ''}'),
        trailing: t == null
            ? null
            : Row(mainAxisSize: MainAxisSize.min, children: [
                if (t.canSetBaud)
                  DropdownButton<int>(
                    value: hub.baud,
                    underline: const SizedBox(),
                    items: [for (final b in bauds) DropdownMenuItem(value: b, child: Text('$b'))],
                    onChanged: (b) => b == null ? null : hub.setBaud(b),
                  ),
                IconButton(icon: const Icon(Icons.close), onPressed: hub.disconnect),
              ]),
      ),
    );
  }

  List<Widget> _connectOptions(BuildContext context) {
    final title = Theme.of(context).textTheme.titleSmall!.copyWith(color: kAmber);
    return [
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Bluetooth LE serial bridge', style: title)),
      Card(
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.bluetooth_searching),
            title: Text(_scanning ? 'Scanning …' : 'Scan for bridges'),
            subtitle: const Text('Nordic UART (ESP32, nRF), HM-10 / HM-19 and similar'),
            onTap: _scanning ? null : _scan,
          ),
          for (final r in _ble)
            ListTile(
              dense: true,
              title: Text(r.device.platformName.isNotEmpty ? r.device.platformName : r.device.remoteId.str),
              subtitle: Text('${r.rssi} dBm · ${r.device.remoteId.str}'),
              trailing: const Icon(Icons.link),
              onTap: () => _guard(() async {
                await FlutterBluePlus.stopScan();
                await hub.attach(await BleTransport.connect(r.device));
              }),
            ),
        ]),
      ),
      if (UsbTransport.supported) ...[
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('USB serial adapter (OTG)', style: title)),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.usb),
              title: Text(_usb.isEmpty ? 'No adapter found' : '${_usb.length} adapter(s)'),
              subtitle: Text('CH340, CP210x, FTDI, PL2303, CDC-ACM · opens at ${hub.baud} baud'),
              trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: _refreshUsb),
            ),
            for (final d in _usb)
              ListTile(
                dense: true,
                title: Text(d.name),
                subtitle: Text('${d.driver} · VID ${d.vid.toRadixString(16)} PID ${d.pid.toRadixString(16)}'),
                trailing: const Icon(Icons.link),
                onTap: () => _guard(() async => hub.attach(await UsbTransport.open(d, hub.baud))),
              ),
          ]),
        ),
      ],
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Wi-Fi serial bridge (TCP)', style: title)),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(flex: 3, child: TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port'))),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _guard(() async {
                final p = int.tryParse(_port.text) ?? 23;
                AppState.instance.prefs.setString('tcpHost', _host.text);
                AppState.instance.prefs.setString('tcpPort', _port.text);
                await hub.attach(await TcpTransport.connect(_host.text.trim(), p));
              }),
              child: const Text('Connect'),
            ),
          ]),
        ),
      ),
    ];
  }

  Widget _terminal(BuildContext context) {
    final lines = hub.log.reversed.take(200).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Text('Terminal'),
            const Spacer(),
            FilterChip(label: const Text('HEX view'), selected: _hex, onSelected: (v) => setState(() => _hex = v)),
            const SizedBox(width: 6),
            IconButton(icon: const Icon(Icons.delete_sweep_outlined), onPressed: hub.clearLog),
          ]),
          Container(
            height: 260,
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.all(8),
            child: ListView.builder(
              reverse: true,
              itemCount: lines.length,
              itemBuilder: (_, i) {
                final l = lines[i];
                final text = _hex
                    ? l.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')
                    : utf8.decode(l.bytes, allowMalformed: true).replaceAll('\r', '');
                return Text('${l.out ? '>' : '<'} $text',
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: l.out ? kAmber : Colors.greenAccent));
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _send,
                onSubmitted: (_) => _sendLine(),
                decoration: InputDecoration(hintText: _hexIn ? 'hex bytes, e.g. A5 48 01 00 49' : 'text to send', isDense: true),
              ),
            ),
            IconButton(icon: const Icon(Icons.send), onPressed: _sendLine),
          ]),
          Wrap(spacing: 6, children: [
            FilterChip(label: const Text('Send hex'), selected: _hexIn, onSelected: (v) => setState(() => _hexIn = v)),
            ChoiceChip(label: const Text('CR LF'), selected: _eol == '\r\n', onSelected: (_) => setState(() => _eol = '\r\n')),
            ChoiceChip(label: const Text('LF'), selected: _eol == '\n', onSelected: (_) => setState(() => _eol = '\n')),
            ChoiceChip(label: const Text('none'), selected: _eol == '', onSelected: (_) => setState(() => _eol = '')),
            ActionChip(label: const Text('DTR/RTS pulse'), onPressed: () async {
              await hub.transport?.setSignals(dtr: false, rts: false);
              await Future<void>.delayed(const Duration(milliseconds: 120));
              await hub.transport?.setSignals(dtr: true, rts: true);
            }),
          ]),
        ]),
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(14),
        child: Text(
          'Paradise dongle: Paramix Studio talks to it at 460800 baud 8N1 (its Device tab and visits use '
          'this connection).\n\n'
          'P-Com and other toy comm boards: pick their baud rate (USB) or set it on the bridge, then use the '
          'terminal, or relay them to another phone on the Link page.\n\n'
          'iPhone: iOS gives apps no access to USB serial adapters, so use a BLE serial bridge (an ESP32 '
          'with a Nordic UART sketch, an HM-10 module) or a Wi-Fi serial bridge wired to the dongle\'s '
          'TX/RX/GND.',
        ),
      ),
    );
  }
}
