import 'dart:io';
import '../services/native.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../emu/rom_info.dart';
import '../paramix/edition.dart';
import '../paramix/flash.dart';
import '../paramix/save_flow.dart' as sf;
import '../services/app_state.dart';
import '../services/rom_library.dart';
import '../services/serial/serial_hub.dart';
import '../services/serial/usb_transport.dart';
import 'hardware_screen.dart';
import 'theme.dart';

/// The Paradise on the UART adapter (USB OTG): read it and write a ROM to it: the
/// device tab of Paramix Studio, native.
class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key, this.image, this.imageName});

  /// A ROM to write (the game with your save in it); without it the write asks which ROM.
  final Uint8List? image;
  final String? imageName;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  SerialHub get hub => AppState.instance.serial;
  List<UsbAdapter> _usb = [];
  FlashLink? _link;
  Paradise? _dev;
  bool _restartAfter = true;
  bool _busy = false;
  String _phase = '';
  double? _progress;
  final List<String> _log = [];
  bool _onlyChanged = true, _keepSaves = true, _rescue = true;
  // with the game's own save to write, the device's save is replaced by it
  late final bool _withSave = widget.image != null;
  Uint8List? _flashApp;
  Timer? _usbPoll;

  @override
  void initState() {
    super.initState();
    if (_withSave) _keepSaves = false;
    _refreshUsb();
    _usbPoll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!hub.connected) _refreshUsb();
    });
    hub.addListener(_hubChanged);
  }

  @override
  void dispose() {
    _usbPoll?.cancel();
    hub.removeListener(_hubChanged);
    _link?.dispose();
    super.dispose();
  }

  void _hubChanged() {
    if (!hub.connected && _dev != null) {
      _link?.dispose();
      _link = null;
      _dev = null;
      _say('Adapter disconnected');
    }
    if (mounted) setState(() {});
  }

  bool _toldWhy = false;

  Future<void> _refreshUsb() async {
    if (!UsbTransport.supported) return;
    try {
      final l = await UsbTransport.list();
      if (mounted) setState(() => _usb = l);
      if (l.isEmpty && Platform.isIOS && !_toldWhy) {
        _toldWhy = true;
        final why = await IosUsbTransport.whyNone();
        if (why != null && mounted) _say('USB: $why');
      }
      // one adapter plugged in and nothing connected: connect it right away
      if (l.length == 1 && !hub.connected && !_busy) await _openUsb(l.first);
    } catch (_) {}
  }

  Future<void> _openUsb(UsbAdapter a) => _task('Opening ${a.name}', () async {
        await hub.attach(await UsbTransport.open(a, paradiseBaud));
        hub.baud = paradiseBaud;
        _say('${a.name} open at $paradiseBaud baud');
      });

  void _say(String s) {
    setState(() => _log.insert(0, s));
  }

  void _prog(String phase, int done, int total) {
    if (!mounted) return;
    setState(() {
      _phase = switch (phase) {
        'load' => 'Loading the flash app',
        'read' => 'Reading',
        'compare' => 'Comparing',
        'write' => 'Writing',
        'check' => 'Checking',
        'prepare' => 'Preparing',
        _ => phase,
      };
      _progress = total > 0 ? done / total : null;
    });
  }

  Future<void> _task(String what, Future<void> Function() f) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _phase = what;
      _progress = null;
    });
    // a transfer takes minutes: the app stays alive in the background and the screen stays on
    final app = AppState.instance;
    await NativeBridge.keepAlive(true, title: 'Tama', text: what);
    await NativeBridge.keepScreenOn(true);
    try {
      await f();
    } on FlashError catch (e) {
      _say('✗ ${e.message}');
    } catch (e) {
      _say('✗ $e');
    } finally {
      await NativeBridge.keepScreenOn(false);
      if (!(app.backgroundRun && (app.games.isNotEmpty || app.machine != null))) await NativeBridge.keepAlive(false);
      if (mounted) {
        setState(() {
          _busy = false;
          _phase = '';
          _progress = null;
        });
      }
    }
  }

  Future<void> _connectParadise() => _task('Connecting to the Paradise', () async {
        _flashApp ??= (await rootBundle.load('assets/paramix/flashapp.bin')).buffer.asUint8List();
        _link?.dispose();
        final link = FlashLink(hub.input, hub.write);
        _link = link;
        if (hub.transport?.canSetBaud ?? false) await hub.setBaud(paradiseBaud);
        // a Bluetooth bridge: short reads (long answers lose bytes on the way to the phone)
        final ble = hub.transport?.kind == 'BLE';
        final (dev, loaded) = await connectParadise(link, _flashApp!, _prog,
            readBlock: ble ? 1024 : null, onReadBlock: (n) => _say('Slow link: reading $n bytes at a time'));
        _dev = dev;
        final i = dev.info!;
        _say('✓ Paradise ${i.name}${loaded ? ' (flash app loaded)' : ''} · flash ${(i.capacity >> 20)} MB, JEDEC ${i.jedec.toRadixString(16)}');
      });

  Future<void> _read() => _task('Reading the device', () async {
        final dev = _dev!;
        dev.cancelRequested = false;
        final img = await dev.dump(_prog);
        final now = DateTime.now();
        String two(int v) => v.toString().padLeft(2, '0');
        final name = 'Device backup · ${dev.info!.name} ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}${two(now.minute)}';
        final e = await AppState.instance.library.import(img, '$name.bin', note: 'read from the device');
        _say('✓ Read 16 MB → library: ${e.name}');
      });

  Future<void> _write() async {
    final lib = AppState.instance.library;
    final roms = lib.entries.where((e) => e.kind == RomKind.paradise).toList();
    final given = widget.image;
    final pick = given != null
        ? null
        : await showModalBottomSheet<RomEntry>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Write which ROM to the device?')),
          for (final r in roms) ListTile(leading: const Icon(Icons.memory), title: Text(r.name), onTap: () => Navigator.pop(c, r)),
        ]),
      ),
    );
    if ((given == null && pick == null) || !mounted) return;
    final img = given ?? await lib.bytes(pick!);
    final name = given != null ? (widget.imageName ?? 'your game with its save') : pick!.name;
    final ed = edition(img);
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Write to the device?'),
        content: Text(
          '$name${ed != null ? ' (${ed.name})' : ''} → Paradise ${_dev!.info!.name}\n\n'
          '${_onlyChanged ? 'Only the sectors that differ are written.' : 'The whole flash is written.'} '
          '${_keepSaves ? 'The device keeps its save.' : 'The save on the device is replaced.'}\n\n'
          'Keep the device switched on and the cable in until it is done. Read a backup first if you have none.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Write')),
        ],
      ),
    );
    if (yes != true) return;
    await _task('Writing $name', () async {
      final dev = _dev!;
      dev.cancelRequested = false;
      final r = await dev.write(img, onlyChanged: _onlyChanged, keepSaves: _keepSaves, rescueApp: _rescue ? _flashApp : null, progress: _prog);
      _say(r.written == 0
          ? '✓ The device already holds this ROM'
          : '✓ Written: ${r.written} sectors${r.kept > 0 ? ', ${r.kept} save sectors kept' : ''}${r.rescue ? ', rescue start in place' : ''}');
      for (final n in r.notes) {
        _say('  $n');
      }
      if (_restartAfter) await _leave(dev);
    });
  }

  /// The toy leaves the flash screen and starts its game (no reset button).
  Future<void> _leave(Paradise dev) async {
    final ok = await dev.restart();
    _say(ok ? '✓ The toy restarts into its game' : 'The toy did not restart by itself: press its reset button');
    if (ok && mounted) setState(() => _dev = null);
  }

  Future<void> _clockNow({bool leave = false}) => _task('Setting the toy\'s clock', () async {
        final dev = _dev!;
        final err = await sf.devClockNow(dev);
        _say(err ?? '✓ The toy\'s clock is set to the phone\'s time');
        if (leave) await _leave(dev);
      });

  @override
  Widget build(BuildContext context) {
    final t = hub.transport;
    final title = Theme.of(context).textTheme.titleSmall!.copyWith(color: kAmber);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paramix Studio · Device'),
        actions: [
          IconButton(
            tooltip: 'Connections & terminal',
            icon: const Icon(Icons.terminal),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HardwareScreen())),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('1 · UART adapter', style: title)),
        Card(
          child: Column(children: [
            ListTile(
              leading: Icon(t != null ? Icons.usb : Icons.usb_off, color: t != null ? Colors.greenAccent : Colors.white38),
              title: Text(t == null ? 'No adapter connected' : '${t.kind}: ${t.label}'),
              subtitle: Text(t == null
                  ? (UsbTransport.supported ? 'Plug the adapter in through USB OTG; it connects by itself' : 'This phone has no USB serial access; use the connections page')
                  : 'rx ${hub.rxBytes} · tx ${hub.txBytes} bytes'),
              trailing: t != null ? IconButton(icon: const Icon(Icons.close), onPressed: hub.disconnect) : null,
            ),
            if (t == null)
              for (final a in _usb)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.cable),
                  title: Text(a.name),
                  subtitle: Text('${a.driver} · VID ${a.vid.toRadixString(16)} PID ${a.pid.toRadixString(16)}'),
                  trailing: const Icon(Icons.link),
                  onTap: () => _openUsb(a),
                ),
          ]),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text('2 · Paradise', style: title)),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(_dev == null
                  ? 'Wire the adapter to the Paradise (TX↔RX crossed, GND), put the Paradise on its download screen, then connect.'
                  : 'Connected: Paradise ${_dev!.info!.name}'),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: t == null || _busy ? null : _connectParadise,
                icon: const Icon(Icons.power),
                label: Text(_dev == null ? 'Connect to the Paradise' : 'Connect again'),
              ),
              if (_dev != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(onPressed: _busy ? null : _read, icon: const Icon(Icons.download), label: const Text('Read the device (backup to the library)')),
                const SizedBox(height: 8),
                OutlinedButton.icon(onPressed: _busy ? null : _write, icon: const Icon(Icons.upload), label: Text(_withSave ? 'Write my game with its save to the toy' : 'Write a ROM to the device …')),
                const SizedBox(height: 8),
                OutlinedButton.icon(onPressed: _busy ? null : () => _clockNow(leave: true), icon: const Icon(Icons.schedule), label: const Text('Set the clock and start the game')),
                const SizedBox(height: 8),
                OutlinedButton.icon(onPressed: _busy ? null : () => _task('Restarting the toy', () => _leave(_dev!)), icon: const Icon(Icons.restart_alt), label: const Text('Leave the flash screen (start the game)')),
                SwitchListTile(dense: true, title: const Text('Start the game when a write is done'), value: _restartAfter, onChanged: (v) => setState(() => _restartAfter = v)),
                SwitchListTile(dense: true, title: const Text('Only changes'), value: _onlyChanged, onChanged: (v) => setState(() => _onlyChanged = v)),
                SwitchListTile(dense: true, title: const Text('Keep the saves on the device'), value: _keepSaves, onChanged: (v) => setState(() => _keepSaves = v)),
                SwitchListTile(
                  dense: true,
                  title: const Text('Rescue start'),
                  subtitle: const Text('A cut-off write leaves the device in the flash screen, ready to write again'),
                  value: _rescue,
                  onChanged: (v) => setState(() => _rescue = v),
                ),
              ],
            ]),
          ),
        ),
        if (_busy)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(_phase),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: _progress),
                if (_progress != null) Text('${(_progress! * 100).toStringAsFixed(1)} %', style: const TextStyle(fontSize: 12)),
                if (_dev != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(onPressed: () => _dev!.cancelRequested = true, child: const Text('Cancel')),
                  ),
              ]),
            ),
          ),
        if (_log.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final l in _log.take(30)) Text(l, style: const TextStyle(fontSize: 13))]),
            ),
          ),
      ]),
    );
  }
}
