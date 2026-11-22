// Dart FFI binding of native/tama_core: the Capybara Tamagotchi Paradise emulator (infinition,
// GPL-3.0) compiled into the app (iOS: static library in the app binary; Android: libtama_core.so).

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _Tama extends Opaque {}

typedef _NewN = Pointer<_Tama> Function();
typedef _FreeN = Void Function(Pointer<_Tama>);
typedef _FreeD = void Function(Pointer<_Tama>);
typedef _LoadN = Int32 Function(Pointer<_Tama>, Pointer<Utf8>, Uint32, Int32);
typedef _LoadD = int Function(Pointer<_Tama>, Pointer<Utf8>, int, int);
typedef _PathN = Int32 Function(Pointer<_Tama>, Pointer<Utf8>);
typedef _PathD = int Function(Pointer<_Tama>, Pointer<Utf8>);
typedef _IntN = Int32 Function(Pointer<_Tama>);
typedef _IntD = int Function(Pointer<_Tama>);
typedef _RunN = Uint64 Function(Pointer<_Tama>, Uint64, Uint32);
typedef _RunD = int Function(Pointer<_Tama>, int, int);
typedef _ScreenN = Int32 Function(Pointer<_Tama>, Pointer<Uint16>);
typedef _ScreenD = int Function(Pointer<_Tama>, Pointer<Uint16>);
typedef _PinN = Void Function(Pointer<_Tama>, Uint32);
typedef _PinD = void Function(Pointer<_Tama>, int);
typedef _NoteN = Float Function(Pointer<_Tama>);
typedef _NoteD = double Function(Pointer<_Tama>);
typedef _U64N = Uint64 Function();
typedef _U64D = int Function();
typedef _VoidN = Void Function();
typedef _VoidD = void Function();
typedef _KeyN = Int32 Function(Pointer<Utf8>, Uint32, Pointer<Uint32>);
typedef _KeyD = int Function(Pointer<Utf8>, int, Pointer<Uint32>);

DynamicLibrary _open() {
  if (Platform.isAndroid || Platform.isLinux) return DynamicLibrary.open('libtama_core.so');
  if (Platform.isMacOS) return DynamicLibrary.open('libtama_core.dylib');
  return DynamicLibrary.process(); // iOS: linked into the app
}

class ParadiseCore {
  ParadiseCore._(DynamicLibrary l)
      : _new = l.lookupFunction<_NewN, _NewN>('tama_new'),
        _free = l.lookupFunction<_FreeN, _FreeD>('tama_free'),
        _load = l.lookupFunction<_LoadN, _LoadD>('tama_load'),
        _openSave = l.lookupFunction<_PathN, _PathD>('tama_open_save'),
        _writeSave = l.lookupFunction<_IntN, _IntD>('tama_write_save'),
        _run = l.lookupFunction<_RunN, _RunD>('tama_run'),
        _running = l.lookupFunction<_IntN, _IntD>('tama_running'),
        _screen = l.lookupFunction<_ScreenN, _ScreenD>('tama_screen'),
        _press = l.lookupFunction<_PinN, _PinD>('tama_press'),
        _release = l.lookupFunction<_PinN, _PinD>('tama_release'),
        _note = l.lookupFunction<_NoteN, _NoteD>('tama_note'),
        _sleeping = l.lookupFunction<_IntN, _IntD>('tama_sleeping'),
        _snapshot = l.lookupFunction<_PathN, _PathD>('tama_snapshot'),
        _restore = l.lookupFunction<_PathN, _PathD>('tama_restore'),
        cyclesPerSecond = l.lookupFunction<_U64N, _U64D>('tama_cycles_per_second')(),
        _findKey = l.lookupFunction<_KeyN, _KeyD>('tama_find_key'),
        _keyProgress = l.lookupFunction<_U64N, _U64D>('tama_find_key_progress'),
        _keyStop = l.lookupFunction<_VoidN, _VoidD>('tama_find_key_stop');

  static ParadiseCore? _instance;
  static String? loadError;

  /// The native core, or null when it is not in this build (loadError says why).
  static ParadiseCore? get instance {
    if (_instance != null) return _instance;
    try {
      _instance = ParadiseCore._(_open());
    } catch (e) {
      loadError = '$e';
    }
    return _instance;
  }

  final Pointer<_Tama> Function() _new;
  final _FreeD _free;
  final _LoadD _load;
  final _PathD _openSave;
  final _IntD _writeSave;
  final _RunD _run;
  final _IntD _running;
  final _ScreenD _screen;
  final _PinD _press, _release;
  final _NoteD _note;
  final _IntD _sleeping;
  final _PathD _snapshot, _restore;
  final int cyclesPerSecond;
  final _KeyD _findKey;
  final _U64D _keyProgress;
  final _VoidD _keyStop;

  /// Searches a dump's device key (blocking: run it in an isolate). Null when not found.
  int? findKey(String dumpPath, int threads) {
    final p = dumpPath.toNativeUtf8();
    final out = calloc<Uint32>();
    try {
      return _findKey(p, threads, out) == 1 ? out.value : null;
    } finally {
      calloc.free(p);
      calloc.free(out);
    }
  }

  /// Fraction of the key search done (0..1).
  double keyProgress() => _keyProgress() / 4294967296.0;
  void keyStop() => _keyStop();
}

/// One running Paradise.
class ParadiseHandle {
  ParadiseHandle(this.core) : _t = core._new();

  final ParadiseCore core;
  Pointer<_Tama> _t;
  final Pointer<Uint16> _fb = calloc<Uint16>(128 * 128);

  static const int pinA = 0x09, pinB = 0x0B, pinC = 0x0A, pinWheel = 0x08, enc1 = 0x20, enc2 = 0x21;

  int _withPath(String p, int Function(Pointer<Utf8>) f) {
    final c = p.toNativeUtf8();
    try {
      return f(c);
    } finally {
      calloc.free(c);
    }
  }

  /// 1 bootable, 0 encrypted (key missing or wrong), -1 error.
  int load(String dump, int? key) => _withPath(dump, (c) => core._load(_t, c, key ?? 0, key == null ? 0 : 1));
  int openSave(String path) => _withPath(path, (c) => core._openSave(_t, c));
  int writeSave() => core._writeSave(_t);
  int run(int cycles, int budgetMs) => core._run(_t, cycles, budgetMs);
  bool get running => core._running(_t) != 0;
  bool get sleeping => core._sleeping(_t) != 0;
  void press(int pin) => core._press(_t, pin);
  void release(int pin) => core._release(_t, pin);
  double note() => core._note(_t);
  bool snapshot(String path) => _withPath(path, (c) => core._snapshot(_t, c)) == 0;
  bool restore(String path) => _withPath(path, (c) => core._restore(_t, c)) == 0;

  /// The 128 x 128 screen (RGB565); returns true when it changed since the last call.
  bool screen(Uint16List out) {
    final changed = core._screen(_t, _fb) != 0;
    out.setAll(0, _fb.asTypedList(128 * 128));
    return changed;
  }

  void dispose() {
    if (_t == nullptr) return;
    core._free(_t);
    _t = nullptr;
    calloc.free(_fb);
  }
}
