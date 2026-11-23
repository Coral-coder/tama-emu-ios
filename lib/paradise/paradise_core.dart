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
typedef _ClockN = Int32 Function(Pointer<_Tama>, Uint64);
typedef _ClockD = int Function(Pointer<_Tama>, int);
typedef _AdvN = Void Function(Pointer<_Tama>, Uint32);
typedef _AdvD = void Function(Pointer<_Tama>, int);
typedef _SoundsN = Uint32 Function(Pointer<_Tama>);
typedef _PetN = Void Function(Pointer<_Tama>, Pointer<Int32>);
typedef _PetD = void Function(Pointer<_Tama>, Pointer<Int32>);
typedef _BlockN = Int32 Function(Pointer<_Tama>, Pointer<Uint8>);
typedef _MemSizeN = Uint32 Function(Pointer<_Tama>, Uint32);
typedef _MemSizeD = int Function(Pointer<_Tama>, int);
typedef _MemN = Uint32 Function(Pointer<_Tama>, Uint32, Uint32, Pointer<Uint8>, Uint32);
typedef _MemD = int Function(Pointer<_Tama>, int, int, Pointer<Uint8>, int);
typedef _FreezeN = Void Function(Pointer<_Tama>, Uint32, Uint32, Pointer<Uint8>, Uint32);
typedef _FreezeD = void Function(Pointer<_Tama>, int, int, Pointer<Uint8>, int);
typedef _BlockD = int Function(Pointer<_Tama>, Pointer<Uint8>);
typedef _ClockCareN = Int32 Function(Pointer<_Tama>, Uint32);
typedef _ClockCareD = int Function(Pointer<_Tama>, int);
typedef _TakeN = Uint32 Function(Pointer<_Tama>, Pointer<Uint8>, Uint32);
typedef _TakeD = int Function(Pointer<_Tama>, Pointer<Uint8>, int);
typedef _GiveN = Void Function(Pointer<_Tama>, Pointer<Uint8>, Uint32);
typedef _GiveD = void Function(Pointer<_Tama>, Pointer<Uint8>, int);
typedef _BlockWriteN = Int32 Function(Pointer<_Tama>, Uint32, Pointer<Uint8>, Uint32);
typedef _BlockWriteD = int Function(Pointer<_Tama>, int, Pointer<Uint8>, int);
typedef _PlacesN = Void Function(Pointer<_Tama>, Pointer<Uint32>);
typedef _PlacesD = void Function(Pointer<_Tama>, Pointer<Uint32>);
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
        _exportFlash = l.lookupFunction<_PathN, _PathD>('tama_export_flash'),
        _memSize = l.lookupFunction<_MemSizeN, _MemSizeD>('tama_mem_size'),
        _memRead = l.lookupFunction<_MemN, _MemD>('tama_mem_read'),
        _memWrite = l.lookupFunction<_MemN, _MemD>('tama_mem_write'),
        _memFreeze = l.lookupFunction<_FreezeN, _FreezeD>('tama_mem_freeze'),
        _memUnfreezeAll = l.lookupFunction<_FreeN, _FreeD>('tama_mem_unfreeze_all'),
        _restore = l.lookupFunction<_PathN, _PathD>('tama_restore'),
        cyclesPerSecond = l.lookupFunction<_U64N, _U64D>('tama_cycles_per_second')(),
        _syncClock = l.lookupFunction<_ClockN, _ClockD>('tama_sync_clock'),
        _advance = l.lookupFunction<_AdvN, _AdvD>('tama_advance'),
        _idle = l.lookupFunction<Uint32 Function(Pointer<_Tama>), _IntD>('tama_idle_seconds'),
        _autoDate = l.lookupFunction<_AdvN, _AdvD>('tama_auto_date'),
        _wake = l.lookupFunction<_IntN, _IntD>('tama_wake'),
        _turn = l.lookupFunction<_PinN, _PinD>('tama_turn'),
        _reset = l.lookupFunction<_FreeN, _FreeD>('tama_reset'),
        _releaseAll = l.lookupFunction<_FreeN, _FreeD>('tama_release_all'),
        _linkTake = l.lookupFunction<_TakeN, _TakeD>('tama_link_take'),
        _linkGive = l.lookupFunction<_GiveN, _GiveD>('tama_link_give'),
        _linkClear = l.lookupFunction<_FreeN, _FreeD>('tama_link_clear'),
        _blockWrite = l.lookupFunction<_BlockWriteN, _BlockWriteD>('tama_block_write'),
        _petPlaces = l.lookupFunction<_PlacesN, _PlacesD>('tama_pet_places'),
        _seconds = l.lookupFunction<_SoundsN, _IntD>('tama_seconds'),
        _pet = l.lookupFunction<_PetN, _PetD>('tama_pet'),
        _care = l.lookupFunction<_ClockCareN, _ClockCareD>('tama_care'),
        _autoCare = l.lookupFunction<_PinN, _PinD>('tama_auto_care'),
        _block = l.lookupFunction<_BlockN, _BlockD>('tama_block'),
        _sounds = l.lookupFunction<_SoundsN, _IntD>('tama_sounds'),
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
  final _PathD _exportFlash;
  final _MemSizeD _memSize;
  final _MemD _memRead, _memWrite;
  final _FreezeD _memFreeze;
  final _FreeD _memUnfreezeAll;
  final _PathD _snapshot, _restore;
  final int cyclesPerSecond;
  final _ClockD _syncClock;
  final _AdvD _advance;
  final _IntD _idle;
  final _AdvD _autoDate;
  final _IntD _wake;
  final _PinD _turn;
  final _FreeD _reset;
  final _FreeD _releaseAll;
  final _TakeD _linkTake;
  final _GiveD _linkGive;
  final _FreeD _linkClear;
  final _BlockWriteD _blockWrite;
  final _PlacesD _petPlaces;
  final _IntD _seconds;
  final _PetD _pet;
  final _ClockCareD _care;
  final _PinD _autoCare;
  final _BlockD _block;
  final _IntD _sounds;
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
  /// Seconds the console stays parked by itself (until its alarm), 0 while awake.
  int get idleSeconds => core._idle(_t);
  void press(int pin) => core._press(_t, pin);
  void release(int pin) => core._release(_t, pin);
  double note() => core._note(_t);
  /// Sounds the console started so far.
  int get sounds => core._sounds(_t);
  final Pointer<Uint8> _linkBuf = calloc<Uint8>(8192);

  /// The link port (the console's UART at 460800 baud): what it sent since the last call.
  Uint8List linkTake() {
    final n = core._linkTake(_t, _linkBuf, 8192);
    return n == 0 ? Uint8List(0) : Uint8List.fromList(_linkBuf.asTypedList(n));
  }

  /// Bytes arriving on the link port.
  void linkGive(Uint8List d) {
    for (var o = 0; o < d.length; o += 8192) {
      final n = (d.length - o).clamp(0, 8192);
      _linkBuf.asTypedList(n).setAll(0, d.sublist(o, o + n));
      core._linkGive(_t, _linkBuf, n);
    }
  }

  void linkClear() => core._linkClear(_t);

  /// Writes bytes into the game's settings block (memory and save, checksum fixed).
  bool blockWrite(int offset, List<int> bytes) {
    final b = calloc<Uint8>(bytes.length);
    try {
      b.asTypedList(bytes.length).setAll(0, bytes);
      return core._blockWrite(_t, offset, b, bytes.length) == 1;
    } finally {
      calloc.free(b);
    }
  }

  /// The console's seconds counter.
  int get seconds => core._seconds(_t);

  // ---- memory tool: 0 work RAM, 1 flash (ROM and saves), 2 program RAM ----
  int memSize(int region) => core._memSize(_t, region);

  Uint8List memRead(int region, int addr, int n) {
    final b = calloc<Uint8>(n);
    try {
      final k = core._memRead(_t, region, addr, b, n);
      return Uint8List.fromList(b.asTypedList(k));
    } finally {
      calloc.free(b);
    }
  }

  int memWrite(int region, int addr, List<int> bytes) {
    final b = calloc<Uint8>(bytes.length);
    try {
      b.asTypedList(bytes.length).setAll(0, bytes);
      return core._memWrite(_t, region, addr, b, bytes.length);
    } finally {
      calloc.free(b);
    }
  }

  /// Holds bytes at an address (the game cannot change them); empty lets go.
  void memFreeze(int region, int addr, List<int> bytes) {
    final b = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      b.asTypedList(bytes.length).setAll(0, bytes);
      core._memFreeze(_t, region, addr, b, bytes.length);
    } finally {
      calloc.free(b);
    }
  }

  void memUnfreezeAll() => core._memUnfreezeAll(_t);

  /// Offsets of the pet's record and of the planet level in the settings block.
  (int, int) petPlaces() {
    final o = calloc<Uint32>(2);
    try {
      core._petPlaces(_t, o);
      return (o[0], o[1]);
    } finally {
      calloc.free(o);
    }
  }

  /// Lets go of every key and the dial.
  void releaseAll() => core._releaseAll(_t);

  /// The reset button on the back: the console restarts (its save stays).
  void reset() => core._reset(_t);

  /// One step of the dial, played on the encoder lines in console time (queued).
  void turn(bool right) => core._turn(_t, right ? 1 : 0);

  /// The pet, live from the game's memory; null when the game has no pet (yet).
  PetState? pet() {
    final o = calloc<Int32>(8);
    try {
      core._pet(_t, o);
      if (o[0] != 1) return null;
      return PetState(character: o[1], stage: o[2], hunger: o[3], happy: o[4], sick: o[5], level: o[6], block: o[7]);
    } finally {
      calloc.free(o);
    }
  }

  static const careFeed = 1, carePlay = 2, careCure = 4;

  /// Feeds / plays / cures now (bits [careFeed], [carePlay], [careCure]). False: no pet.
  bool care(int what) => core._care(_t, what) == 1;

  /// Care kept up by itself every 10 s of game time (0: off).
  void autoCare(int what) => core._autoCare(_t, what);

  /// The game's settings block as it is in memory (4 KB), for looking inside; null if not found.
  Uint8List? block() {
    final b = calloc<Uint8>(4096);
    try {
      return core._block(_t, b) == 1 ? Uint8List.fromList(b.asTypedList(4096)) : null;
    } finally {
      calloc.free(b);
    }
  }

  /// Wakes the console from its power-save sleep (its screen comes back on).
  bool wake() => core._wake(_t) == 1;

  /// For the next [seconds], the date screens of a new start confirm themselves (the firmware
  /// fills the form in from its clock, which follows the phone).
  void autoDate([int seconds = 180]) => core._autoDate(_t, seconds);

  /// The console's clock jumps ahead (time the phone held the app suspended).
  void advance(int seconds) {
    if (seconds > 0) core._advance(_t, seconds);
  }
  /// Sets the game's clock to the phone's local time. Returns the settings pages set (0: none yet,
  /// e.g. before the first setup).
  int syncClock([DateTime? at]) {
    final t = at ?? DateTime.now();
    // the firmware counts its days from 2025-01-01
    final local = t.millisecondsSinceEpoch ~/ 1000 + t.timeZoneOffset.inSeconds - 1735689600;
    return core._syncClock(_t, local);
  }

  bool snapshot(String path) => _withPath(path, (c) => core._snapshot(_t, c)) == 0;
  /// The 16 MB flash as the toy would hold it now (the dump with this save), ready to flash.
  bool exportFlash(String path) => _withPath(path, (c) => core._exportFlash(_t, c)) == 0;
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
    calloc.free(_linkBuf);
  }
}

/// The pet as the game keeps it: hunger 0..6, happiness 0..20.
class PetState {
  PetState({required this.character, required this.stage, required this.hunger, required this.happy, required this.sick, required this.level, required this.block});
  final int character, stage, hunger, happy, sick, level, block;
  bool get exists => character != 0;
  static const stages = ['egg', 'baby', 'child', 'teen', 'adult', 'senior', '6', '7'];
  String get stageName => stages[stage & 7];
}
