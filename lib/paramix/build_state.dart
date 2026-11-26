// The state of Paramix Studio's page and everything in its glue code (third_party/paramix-studio/
// src/app.js, mameise, GPL-3.0-or-later) that is logic and not DOM: loading a ROM and reading back
// what an already modified one holds (loadRom, app.js:412), the rules for the programs (addExtra,
// makeMain, the star, removing), the trial builds (roomTry, roomFit) and the "Your new ROM" overview
// (renderPlan). The build itself is in compose_full.dart. docs/paramix-ui-spec.md describes every
// field (section 1) and every rule (sections 2 to 4, 7); the names here are the ones of app.js.
//
// A screen makes a state with [BuildState.load], changes it through the methods (they do what the
// page's handlers do, with the same messages) or the plain fields, and calls composeFull.
//
// What the page reads from its controls while building is a field here: [doomEp], [doomMusic].
// Messages the page shows as a toast are collected in [messages].

// ignore_for_file: library_prefixes, non_constant_identifier_names, constant_identifier_names

import 'dart:convert';
import 'dart:typed_data';

import 'compose.dart' show ComposeError;
import 'compose_full.dart';
import 'core_more.dart' as C;
import 'doom_port.dart' as D;
import 'emu_build.dart' as E;
import 'feld.dart' as F;
import 'saves.dart' as SV;
import 'six.dart' as S6;

export 'compose.dart' show ComposeError;
export 'doom_port.dart' show DoomEmbedded, DoomPort;
export 'emu_build.dart' show EmuBinaries, EmuOpt, Extra, T7Fig;
export 'feld.dart' show FeldEmbedded;

// ------------------------------------------------------------------ assets
/// The programs the Studio embeds (assets/paramix/, the files of third_party/paramix-studio/`dir`/).
class BuildAssets {
  BuildAssets({required this.emu, this.feld, this.six, this.flash, this.doom, this.doomPort});

  /// emu.bin, stub_tpl.bin, t7.bin, t7x.bin, t18.bin, t18x.bin, v1.bin, v3.bin, gb.bin, gbc.bin, sms.bin, pm.bin,
  /// ab.bin, wolf.bin, wolfsod.bin (JS: E.embedded(), E.t7Embedded() ...).
  final E.EmuBinaries emu;

  /// feld.bin, feld_s.bin, feldc.bin, feldc_s.bin, stub_feld_tpl.bin (JS: F.embedded()).
  final F.FeldEmbedded? feld;

  /// six.bin (JS: S6.embedded()).
  final Uint8List? six;

  /// flashapp.bin (JS: FL.embedded()).
  final Uint8List? flash;

  /// doom_app.bin, doom_xip.bin, doomf_app.bin, doomf_xip.bin (JS: D.embedded()).
  final D.DoomEmbedded? doom;

  /// The WAD converter, when there is one (see doom_port.dart).
  final D.DoomPort? doomPort;
}

// ------------------------------------------------------------------ pieces of the state
/// A message of the page (toast): text and whether it is an error.
class BuildMessage {
  const BuildMessage(this.text, [this.error = false]);
  final String text;
  final bool error;
  @override
  String toString() => text;
}

/// state.emu (spec 1.4): the newly chosen main program at 0x0A0000.
class MainEmu {
  /// TamaEmu (colour Tama): { guest, dev, size, big, kept? }.
  MainEmu.tama(Uint8List this.guest, this.dev, {required this.size, required this.big, this.kept = false})
      : t7 = false,
        t18 = false,
        v1 = false,
        rom = null,
        figs = [];

  /// T7Emu: { t7: true, dev: 't7', rom, figs, size }.
  MainEmu.t7(Uint8List this.rom, this.figs, {this.size = 0})
      : t7 = true,
        t18 = false,
        v1 = false,
        dev = 't7',
        guest = null,
        big = false,
        kept = false;

  /// T18Emu: { t18: true, dev: 't18', rom, size, items? }.
  MainEmu.t18(Uint8List this.rom, {required this.size})
      : t7 = false,
        t18 = true,
        v1 = false,
        dev = 't18',
        guest = null,
        big = false,
        kept = false,
        figs = [];

  /// V1Emu / V3Emu: { v1: true, dev: 'v1', rom, size }.
  MainEmu.v1(Uint8List this.rom)
      : t7 = false,
        t18 = false,
        v1 = true,
        dev = 'v1',
        guest = null,
        big = false,
        kept = false,
        size = rom.length + 0x2000,
        figs = [];

  final bool t7, t18, v1;
  String dev;
  Uint8List? guest, rom;
  List<E.T7Fig> figs;
  int size;
  bool big, kept;
  bool items = false;
}

/// One conversion of a WAD (state.doom.fit[key]): does it fit with music / without, the sizes, the data.
class DoomFit {
  DoomFit({required this.music, required this.plain, required this.sizeM, required this.sizeP, this.mcuM, this.mcuP, this.linkSaved});
  bool music, plain;
  int sizeM, sizeP;
  Uint8List? mcuM, mcuP;
  int? linkSaved;
}

/// An extra WAD of state.doom.pwads: file name, data and what doom.js pwadInfo says (episodes, title).
class DoomPwad {
  DoomPwad(this.name, this.data, {this.eps = const [], this.maps = const [], this.title = 'EXTRA'});
  final String name;
  final Uint8List data;
  final List<String> eps, maps;
  final String title;
}

/// state.doom (spec 1.5): the result of app.js doomCompute, i.e. a WAD with all its conversions. The
/// conversion itself is not ported (doom.js wadSub, gbaExtras, convert): this is the input.
/// Keys of [fit]: an episode digit, 'all' (whole WAD), 'P<i>' (own episode of an extra WAD), 'Q<i>'
/// (DOOM II map pack alone).
class DoomData {
  DoomData({required this.wad, this.wadM, List<DoomPwad>? pwads, required this.eps, required this.fit, required this.ok, Set<String>? sel, Map<String, String>? titles, this.whole = false, this.d2 = false})
      : pwads = pwads ?? [],
        sel = sel ?? {...ok.take(1)},
        titles = titles ?? {};
  final Uint8List wad;
  final Uint8List? wadM;
  final List<DoomPwad> pwads;
  final List<String> eps;
  final Map<String, DoomFit> fit;
  final List<String> ok;
  final Set<String> sel;
  final Map<String, String> titles;
  bool whole;
  final bool d2;
}

/// state.saveIn: an imported V1Emu / TamaEmu save. key: 'm' (main program) or the index in extras.
class SaveIn {
  SaveIn(this.key, this.kind, [this.data]);
  final Object key;
  final String kind; // 'v1', 'tama'
  final Uint8List? data;
}

/// What the page adds to an entry of state.extras (spec 1.5, "Extra fields added by the UI").
class _XUi {
  bool fresh = false, carry = false, fromParaMain = false, fromPara = false, saveImp = false;
  DoomData? wadSrc;
  String? keys0;
}

final Expando<_XUi> _xui = Expando('paramix extra');

extension ExtraUi on E.Extra {
  _XUi get _ui => _xui[this] ??= _XUi();

  /// Added in this session (not yet in the ROM).
  bool get fresh => _xui[this]?.fresh ?? false;
  set fresh(bool v) => _ui.fresh = v;

  /// A save taken along from the device (TamaEmu): its ranges come from the image.
  bool get carry => _xui[this]?.carry ?? false;
  set carry(bool v) => _ui.carry = v;

  /// The Paradise's main emulator, moved into the list (clean ROM, start device without room at 0x0A0000).
  bool get fromParaMain => _xui[this]?.fromParaMain ?? false;
  set fromParaMain(bool v) => _ui.fromParaMain = v;

  /// The Paradise's DOOM, moved into the list.
  bool get fromPara => _xui[this]?.fromPara ?? false;
  set fromPara(bool v) => _ui.fromPara = v;

  /// T18Emu: its save was imported.
  bool get saveImp => _xui[this]?.saveImp ?? false;
  set saveImp(bool v) => _ui.saveImp = v;

  /// DOOM: the state.doom object the entry was made from.
  DoomData? get wadSrc => _xui[this]?.wadSrc;
  set wadSrc(DoomData? v) => _ui.wadSrc = v;

  /// DOOM: JSON of the keys as read from the ROM.
  String? get keys0 => _xui[this]?.keys0;
  set keys0(String? v) => _ui.keys0 = v;
}

/// A row of the Names tab: the name in the ROM, the text numbers that hold it, the longest name allowed.
class NameRow {
  const NameRow(this.name, this.idx, this.max);
  final String name;
  final List<int> idx;
  final int max;
}

/// One chip of the overview: label, text (parts, the bold one is the main emulator), colour class.
class PlanChip {
  PlanChip(this.label, this.parts, this.cls);
  PlanChip.text(this.label, String text, this.cls) : parts = [(text, false)];
  final String label;
  final List<(String, bool)> parts;
  final String cls; // 'new', 'keep', 'del', 'off'
  String get text => parts.map((p) => p.$1).join();
}

/// One segment of the flash bar: key ('fw', 'doom', 'emu', 'gb', 'sms', 'pm', 'ab', 'wolf', 'slots', 'save',
/// 'resv', 'free'), label and bytes.
class PlanSeg {
  PlanSeg(this.key, this.label, this.size);
  final String key, label;
  int size;
}

/// The "Your new ROM" box (renderPlan, spec 3.4).
class Plan {
  Plan(this.chips, this.segs, this.total, this.warnings, this.rule, this.needRoomTrial);
  final List<PlanChip> chips;
  final List<PlanSeg> segs;
  final int total;
  final List<String> warnings;
  final String rule;

  /// The page would now run a quiet trial build for the free room of a start device (roomSoon): call
  /// [BuildState.roomTry] and ask for the plan again.
  final bool needRoomTrial;

  /// The legend: "label N MB" for every segment with a size.
  List<String> get legend => [
        for (final s in segs)
          if (s.size > 0) '${s.label} ${planMB(s.size)}'
      ];

  /// The text of the box as the page shows it (title, chips, legend, warnings, rule), without separators.
  String get text => ['Your new ROM', for (final c in chips) '${c.label} ${c.text}', ...legend, ...warnings, rule].join();
}

/// app.js MB(n): 2 decimals below 1 MB, else 1, trailing zeros cut.
String planMB(int n) => '${(n / 1048576).toStringAsFixed(n < 1048576 ? 2 : 1).replaceFirst(RegExp(r'\.?0+$'), '')} MB';

// ------------------------------------------------------------------ pure helpers of app.js
int rd32(Uint8List b, int o) {
  int at(int i) => i >= 0 && i < b.length ? b[i] : 0;
  return (at(o) | (at(o + 1) << 8) | (at(o + 2) << 16) | (at(o + 3) << 24)) & 0xFFFFFFFF;
}

String msgOf(Object e) => e is ComposeError
    ? e.message
    : e is FormatException
        ? e.message
        : e is StateError
            ? e.message
            : e is ArgumentError
                ? '${e.message}'
                : e.toString();

final RegExp _onlyPacked = RegExp(r'^(.+) only fits packed$');

/// app.js em(x) in English: the module's message, with the one rewrite of MSG_EN.
String em(Object e) {
  final s = e is String ? e : msgOf(e);
  final m = _onlyPacked.firstMatch(s);
  return m != null ? '${m[1]} only fits packed (big save): in the Emulator tab switch on "Pack the firmware" in its row, or remove another program' : s;
}

List<E.AppEntry> _entries(List<F.FeldApp> apps) => [for (final a in apps) E.AppEntry(a.src, a.name)];

/// test24 EXIT_KEY: how to go back from a program, for all of them (tab Menu): "EX" << 16 | mode in the last word of
/// each program's vector table (IRQ 63, never used); 0 = as before (the word stays the program's own).
const int EXIT_AT = 0x13C, EXIT_MAGIC = 0x5845;

/// app.js romExtras(rom): the programs of the menu of a ROM.
List<E.Extra> romExtras(Uint8List rom, F.FeldEmbedded? fe) => fe != null ? E.appsRead(rom, _entries(F.feldApps(rom, fe.stub).apps)) : [];

List<int> exitOffs(Uint8List rom, F.FeldEmbedded? fe) {
  final offs = F.isClean(rom) ? <int>[] : [0xA0000];
  try {
    for (final x in romExtras(rom, fe)) {
      offs.add(x.off);
    }
  } catch (_) {}
  return offs.where((o) {
    final w = rd32(rom, o + EXIT_AT);
    return (w >> 16) == EXIT_MAGIC || (w == rd32(rom, o + EXIT_AT - 4) && (w & 1) != 0 && w < 0x10000);
  }).toList();
}

/// "Back from programs" of a ROM: 0..3.
int exitGet(Uint8List rom, F.FeldEmbedded? fe) {
  for (final o in exitOffs(rom, fe)) {
    final w = rd32(rom, o + EXIT_AT);
    if ((w >> 16) == EXIT_MAGIC) return w & 3;
  }
  return 0;
}

Uint8List exitSet(Uint8List rom, int mode, F.FeldEmbedded? fe) {
  var out = rom;
  for (final o in exitOffs(rom, fe)) {
    final w = mode != 0 ? ((EXIT_MAGIC << 16) | mode) & 0xFFFFFFFF : rd32(rom, o + EXIT_AT - 4);
    if (rd32(out, o + EXIT_AT) == w) continue;
    if (identical(out, rom)) out = Uint8List.fromList(rom);
    out[o + EXIT_AT] = w & 255;
    out[o + EXIT_AT + 1] = (w >> 8) & 255;
    out[o + EXIT_AT + 2] = (w >> 16) & 255;
    out[o + EXIT_AT + 3] = (w >> 24) & 255;
  }
  return out;
}

/// app.js romEmuCfg(rom): the settings of the main TamaEmu, or null.
SV.EmuCfg? romEmuCfg(Uint8List rom) => F.appKind(rom) == 2 && F.emuType(rom) == 'tama' ? SV.emuCfg(Uint8List.sublistView(rom, 0xA0000, 0xA1000)) : null;

/// app.js mainName(r): the name of the main emulator of a ROM ('' without).
String mainName(Uint8List r) {
  final ty = F.emuType(r);
  if (ty == 't7') return E.t7XName(E.t7FromRom(r)!.rom);
  if (ty == 't18') return E.extraName(E.Extra(kind: 't18'));
  if (ty == 'v1') {
    final v = E.v1FromRom(r);
    return v != null ? E.v1Name(v) : 'V1';
  }
  final c = romEmuCfg(r);
  if (c != null) return E.extraName(E.Extra(kind: 'tama', dev: c.dev));
  return '';
}

/// app.js stubList(rom): where the stub can sit: the emulator's own at 0x0B0000, or the menu's (also elsewhere).
List<(int, Uint8List)> stubList(Uint8List rom, F.FeldEmbedded? fe) {
  final ee = E.embedded(), l = <(int, Uint8List)>[];
  if (ee != null) l.add((E.stubOff, ee.stub));
  if (fe != null) {
    l.add((E.stubOff, fe.stub));
    final f = F.feldFind(rom, fe.stub);
    if (f != null && f.stubOff != E.stubOff) l.add((f.stubOff, fe.stub));
  }
  return l;
}

/// 1.6.8: an extra that is the same firmware as the main emulator only once (app.js sameFw).
bool sameFw(E.Extra a, E.Extra b) {
  // 1.6.8: colour Tamas by their code blocks (the rest of the flash holds the pet's own writes)
  final ka = E.extraKind(a), kb = E.extraKind(b);
  if (ka == 'tama' && kb == 'tama') {
    if (a.dev != b.dev) return false;
    final ga = a.guest!, gb = b.guest!;
    for (final k in const [0, 1, 0x40, 0x41]) {
      final o = k << 16;
      if (o + 0x10000 > ga.length || o + 0x10000 > gb.length) continue;
      for (var i = o; i < o + 0x10000; i++) {
        if (ga[i] != gb[i]) return false;
      }
    }
    return true;
  }
  if (ka != kb) return false;
  final x0 = ka == 'tama' ? a.guest : (ka == 't18' ? a.fw : a.rom), x1 = ka == 'tama' ? b.guest : (ka == 't18' ? b.fw : b.rom);
  if (x0 == null || x1 == null || x0.isEmpty || x1.isEmpty) return false;
  final p0 = x0.length <= x1.length ? x0 : x1, p1 = x0.length <= x1.length ? x1 : x0;
  for (var i = 0; i < p0.length; i += 4093) {
    if (p0[i] != p1[i]) return false;
  }
  for (var i = 0; i < p0.length; i++) {
    if (p0[i] != p1[i]) return false;
  }
  for (var i = p0.length; i < p1.length; i++) {
    if (p1[i] != 0xFF) return false;
  }
  return true;
}

/// app.js fieldTexts(rom, six): which text numbers hold the field names. [six] as the page passes
/// sixActive() for the Names list (null: as the ROM is, for the menu).
List<({List<int> idx, String name})> fieldTextsOf(Uint8List rom, [bool? six]) {
  var fn = F.fieldNames(rom).map((s) => s.toUpperCase()).toList();
  const lws = ['LAND', 'WATER', 'SKY'];
  final out = <({List<int> idx, String name})>[];
  if (six != null) {
    final id = F.feldId(rom);
    if (!six) {
      fn = fn.take(3).toList();
    } else if (fn.length <= 3) {
      fn = [...fn, if (id == 4) 'SKY' else if (id >= 5) ...lws];
    }
  }
  for (var i = 0; i < fn.length; i++) {
    final k = lws.indexOf(fn[i]), own = i < 3 ? 14 + i : (k >= 0 ? 64 + k : -1);
    if (own < 0) continue;
    final idx = [own];
    if (i < 3 && k >= 0 && C.textGet(rom, 64 + k) == C.textGet(rom, own)) idx.add(64 + k);
    out.add((idx: idx, name: C.textGet(rom, own)));
  }
  return out;
}

/// The version of a menu program (the word after the "FELD" magic), 0 when not found.
int _feldVersion(Uint8List? f) {
  if (f == null) return 0;
  for (var i = 0; i + 8 <= f.length; i += 4) {
    if (rd32(f, i) == 0x444C4546) return f[i + 4] | (f[i + 5] << 8);
  }
  return 0;
}

const Set<String> OWN_CHIP = {'wolf', 'gb', 'sms', 'pm', 'ab'};
String groupKind(String? kind) => OWN_CHIP.contains(kind) ? kind! : 'emu';
const Set<String> SESS_KINDS = {'tama', 't18', 't7', 'v1', 'gb', 'sms', 'pm', 'ab'};
const List<String> DLC_DEV = ['idl', 'ps', '4u', '4u-plain'];
const int DOOM_WHOLE_REGION = 0xA0000; // level data room of the whole WAD
const int T18_FEW_N = 6;
const int DL_AT = 0x10000000 + 0xFF0000 - 0x11000;

Map<String, Object?>? _optJson(E.EmuOpt? o) => o == null ? null : {'vol': o.vol, 'dim': o.dim, 'off': o.off};
bool _isPQ(String e) => e.isNotEmpty && (e[0] == 'P' || e[0] == 'Q');

class _Mute {
  String? err;
}

// ------------------------------------------------------------------ the state
class BuildState {
  BuildState._(this.assets, this.rom, this.name);

  final BuildAssets assets;

  /// state.ctx.rom: the loaded ROM (the pet editor and "Clear slot" replace it).
  Uint8List rom;

  /// state.ctx of a ROM with the Paradise (C.openRom); null for a clean ROM ([ctxClean]).
  C.RomCtx? ctx;

  /// state.ctx.clean: the loaded ROM is a start device without the Paradise.
  bool ctxClean = false;

  /// state.ctx.edition: the edition's name.
  String edition = '?';

  /// state.name: file name of the loaded ROM; base of the output name.
  String name;

  /// The language the patchers get (the texts the programs show on the device): 'en' or 'de'.
  String lang = 'en';

  /// sprite index -> new encoded sprite entry. Pre-filled by C.spriteAlign at load.
  Map<int, Uint8List> changed = {};

  /// C.fieldSets(ctx) and group -> character name from the text table.
  List<C.FieldSet> fields = [];
  Map<int, String> charNames = {};

  // --- set by loadRom (spec 1.3)
  bool clean = false, cleanInit = false;
  Uint8List? pmBios;
  bool _pmBiosRead = false; // JS: state.pmBios === undefined until pmBiosNow
  List<int>? gbKeys, smsKeys, pmKeys, abKeys;
  bool? gbInv, smsInv, pmInv, abInv;
  Map<String, Object>? wolfKeys;

  /// The newly chosen main program.
  MainEmu? emu;

  /// Imported/edited T7Emu save of the main program, and { i, save } for extra i.
  Uint8List? t7save;
  ({int i, Uint8List save})? t7saveX;
  SaveIn? saveIn;

  /// "Take the program at 0x0A0000 out" (an emulator, or DOOM when DOOM is built in).
  bool emuRemove = false;
  DoomData? doom;

  /// { fire, fwd, back, use, mod, run, invert }.
  Map<String, Object>? doomKeys;

  /// Bytes of the second (Land/Water/Sky) ROM for six fields, its file name; "All 6 fields" ticked;
  /// built-in extra fields are to be taken out.
  Uint8List? six;
  String sixName = '';
  bool sixWant = false, sixOff = false;
  bool petDirty = false;

  /// text index -> new name.
  Map<int, String> texts = {};

  /// group -> (dx, dy), each -16..16; poseAdj: group -> "ox:oy" -> (ox, oy, dx, dy) for "This pose only".
  Map<int, (int, int)> eyeShift = {}, mouthShift = {};
  Map<int, Map<String, (int, int, int, int)>> poseAdj = {};

  /// The installed main TamaEmu's firmware with its save read back from the ROM (mainGuestLoad).
  ({Uint8List g, String dev})? mainGuest;

  /// "Pack the firmware" for the main TamaEmu.
  bool emuPack = false;
  bool sixPlanet = true, sixMenu = true;

  /// Settings of the main program: start when switched on, clock, remember where you left off, NFC, options.
  bool emuAuto = false, emuClock = true, emuSess = true, emuNfc = true;
  E.EmuOpt emuOpt = const E.EmuOpt();

  /// The menu: several saves with field choice, items and Tamapoints, change Tama, play time earns points.
  bool feld = false, bag = false, tama = false, gplay = false, saves = true;
  bool feldInit = false, bagInit = false, tamaInit = false, gplayInit = false, savesInit = true;

  /// Start device.
  bool launch = false, launchInit = false;
  Map<int, Uint8List>? launchMap;
  bool t18Few = false;

  /// "Back from programs": 0..3.
  int exitKey = 0, exitKeyInit = 0;

  /// The programs of the menu.
  List<E.Extra> extras = [];
  bool extrasDirty = false;

  /// Chip groups whose program in the ROM is older than the embedded one (null: none; JS false).
  Set<String>? extrasUp;
  bool wolfInit = false, wolfKeysDirty = false;
  List<String> oldT7 = [];
  bool t18Broken = false;
  Map<String, String> sig0 = {};
  bool cleanClock = true;

  /// The main program of a start device with DOOM / a clean ROM: an entry of [extras], [pickEmu] or null.
  Object? mainPick;
  static const String pickEmu = 'emu';
  bool feldStale = false;

  // --- fields that only appear later in the page (spec 1.3, "Other fields")
  Uint8List? t18Main;
  bool t18Dirty = false;

  /// Map adult id -> picture (E.t18PicMake). As in the page it is not read from the ROM at load
  /// (spec 1.3, "Trap"): a screen that shows them sets it from E.t18PicsRead(rom).
  Map<int, Uint8List>? t18Pics;
  bool t18PicsDirty = false;
  bool mainDirty = false;
  ({String sig, int kb})? roomFree;
  bool paraMainTaken = false;

  // --- what the page keeps in controls (spec 1.6)
  /// doomEp (select, default first option) and doomMusic (checkbox, default checked).
  String doomEp = '1';
  bool doomMusic = true;

  /// The page's confirm(): asked before the stored saves are deleted (six fields out). Default: yes.
  bool Function(String question)? confirm;

  // --- module variables of app.js
  int lastRoom = 0, lastFree = -1;
  _Mute? _mute;

  /// Everything the page would have shown as a toast, in order.
  final List<BuildMessage> messages = [];

  /// The text of the last error toast (also while muted), for composeFull.
  String? lastError;

  F.FeldEmbedded? get fe => assets.feld;

  void toast(String msg, [bool err = false]) {
    if (err) lastError = msg;
    if (_mute != null) {
      if (err) _mute!.err = msg;
      return;
    }
    messages.add(BuildMessage(msg, err));
  }

  // ---------------------------------------------------------------- loading (app.js:412)
  /// What loadRom does: detection and reading back the settings of an already modified ROM (spec section 4).
  /// Throws [ComposeError] "This is not a Paradise dump: ..." for anything else.
  static BuildState load(Uint8List buf, BuildAssets assets, {String name = 'rom.bin', String lang = 'en'}) {
    E.emuBinaries = assets.emu;
    final s = BuildState._(assets, buf, name)..lang = lang;
    // CLEAN_ROM: a ROM without the Paradise (start device of this Studio): only the programs, no pictures or texts
    final clean = F.isClean(buf);
    if (clean) {
      final ed = F.edition(buf);
      s.ctxClean = true;
      s.edition = ed != null ? (C.EDITIONS[ed.id] ?? '${ed.id}') : '?';
    } else {
      try {
        s.ctx = C.openRom(buf);
      } catch (e) {
        throw ComposeError('This is not a Paradise dump: ${em(e)}');
      }
      s.edition = s.ctx!.edition;
    }
    s.clean = clean;
    s.cleanInit = clean;
    // 1.7.3 test21 SPR_ALIGN: own Tama pictures of older versions with an odd length are padded
    if (!clean) {
      final ctx = s.ctx!;
      for (final g in ctx.groups) {
        for (var k = 0; k < 6; k++) {
          final f = C.spriteAlign(g + k < ctx.entries.length ? ctx.entries[g + k] : null);
          if (f != null) s.changed[g + k] = f;
        }
      }
    }
    {
      final c = romEmuCfg(buf);
      s.emuPack = c != null && c.version >= 5 && c.lzOff != 0 && (!E.packAsk || E.lzCount(buf, c.lzOff) > E.packFew);
    }
    {
      final si = S6.sixInfo(buf);
      s.sixPlanet = si != null && si.version >= 5 ? si.planet : true;
      s.sixMenu = si != null && si.version >= 6 ? si.fieldMenu : true;
    }
    final fe = assets.feld;
    {
      final l = stubList(buf, fe), g = E.autoGet(buf, l);
      s.emuAuto = g ?? E.autoGetOld(buf, l);
    }
    s.emuClock = E.emuClockGet(buf) ?? true;
    s.emuSess = E.emuSessGet(buf) ?? true; // 1.7.3 test7
    s.emuNfc = E.emuNfcGet(buf) ?? true;
    s.emuOpt = E.emuOptGet(buf) ?? const E.EmuOpt();
    final f = fe != null ? F.feldFind(buf, fe.stub) : null;
    s.feld = f != null && (f.flags & F.fFields) != 0;
    s.bag = f != null && (f.flags & F.fBag) != 0;
    s.tama = f != null && (f.flags & F.fTama) != 0;
    s.gplay = f != null && (f.flags & F.fGplay) != 0;
    s.saves = true;
    s.feldInit = s.feld;
    s.bagInit = s.bag;
    s.tamaInit = s.tama;
    s.gplayInit = s.gplay;
    s.savesInit = true;
    s.launch = f != null && f.version >= 2 && (f.flags & F.fLaunch) != 0;
    s.launchInit = s.launch;
    s.exitKey = exitGet(buf, fe);
    s.exitKeyInit = s.exitKey;
    final read = f != null ? E.appsRead(buf, _entries(F.feldApps(buf, fe!.stub).apps)) : <E.Extra>[];
    s.extras = [for (final x in read) _fromRom(x)];
    s.extrasUp = f != null ? s.extrasOld(buf, _entries(F.feldApps(buf, fe!.stub).apps)) : null;
    s.wolfInit = s.extras.any((x) => x.kind == 'wolf');
    // 1.6.11 test2: a T7Emu that can lose the pet's save (old build): named in red until it is written anew
    if (F.emuType(buf) == 't7' && E.t7Outdated(buf)) {
      final n = mainName(buf);
      s.oldT7.add(n.isNotEmpty ? n : 'TAMA-GO');
    }
    for (final x in read) {
      if (E.extraKind(x) == 't7' && E.t7Outdated(buf, x.off)) s.oldT7.add(x.name ?? '');
    }
    // test5: a T18Emu in the menu whose blocks were emptied (fault up to test4: main program removed in a start device)
    s.t18Broken = s.extras.any((x) {
      if (x.kind != 't18' || x.keepOff == null) return false;
      final c = E.t18Cfg(buf, x.keepOff!);
      if (c == null) return false;
      var n = 0;
      for (final b in c.map) {
        if (b == 0xFFFF) continue;
        var all = true;
        for (var i = b << 16; i < (b + 1) << 16 && i < buf.length; i++) {
          if (buf[i] != 0xFF) {
            all = false;
            break;
          }
        }
        if (all) n++;
      }
      return n >= 8;
    });
    s.sig0 = {for (final g in const ['emu', 'gb', 'sms', 'pm', 'ab']) g: s.groupSig(g)};
    if (f != null && clean) {
      try {
        s.cleanClock = !(F.feldApps(buf, fe!.stub).noClock ?? false); // 1.7.3 test7
      } catch (_) {}
    }
    // 1.6.9 test13: start device with DOOM, the main program out of the menu's list and its autostart
    if (f != null && s.launch) {
      final fa = F.feldApps(buf, fe!.stub);
      if (fa.v9) {
        s.emuAuto = fa.auto ?? false;
        final ms = fa.mainSrc ?? 0;
        final k = ms != 0 ? read.indexWhere((x) => x.off == ms - 0x10000000 + 0x11000) : -1;
        s.mainPick = k >= 0 && k < s.extras.length ? s.extras[k] : null;
      }
    }
    // A menu from an older Studio version is rebuilt on save (e.g. 0.9.5 had no item pictures)
    if (f != null) {
      if (clean) {
        try {
          final fa = F.feldApps(buf, fe!.stub);
          final re = fe.feldc != null
              ? F.cleanApply(buf, F.FeldOpts(apps: fa.apps, dl: fa.dl ?? 0, mainSrc: fa.mainSrc ?? 0, auto: fa.auto ?? false, noClock: fa.noClock ?? false, spot: F.cleanInfo(buf)), fe.forClean())
              : buf;
          s.feldStale = _differs(re, buf);
        } catch (_) {
          s.feldStale = false;
        }
      } else {
        try {
          final embOld = F.FeldEmbedded(stub: fe!.stub, oldStub: E.embedded()?.stub);
          final fa = F.feldApps(buf, fe.stub);
          var low = 0;
          if (fa.apps.isNotEmpty) {
            low = fa.apps.map((a) => a.src - 0x10000000 + 0x11000).reduce((a, b) => a < b ? a : b);
          }
          final dl = f.version >= 7 ? rd32(buf, f.off + 0x334) : 0, dlo = dl != 0 ? dl - 0x10000000 + 0x11000 : 0;
          final re = F.feldApply(
              F.feldStrip(buf, embOld, const F.FeldEmuPort()),
              F.FeldOpts(
                  fields: s.feld,
                  bag: s.bag,
                  tama: s.tama,
                  gplay: s.gplay,
                  saves: s.saves,
                  launch: s.launch,
                  apps: fa.apps,
                  name0: fa.name0,
                  appsLow: low,
                  dl: dl,
                  mainSrc: fa.mainSrc ?? 0,
                  auto: fa.auto ?? false,
                  fieldNames: [for (final x in fieldTextsOf(buf)) x.name]),
              F.feldSlots(buf, fe.stub),
              F.FeldEmbedded(stub: fe.stub, feld: fe.feld, feldS: fe.feldS),
              const F.FeldEmuPort());
          if (dlo != 0) re.setRange(dlo, dlo + 0x10000, buf, dlo); // the flash app stays where it is
          s.feldStale = re.length != buf.length || _differs(re, buf);
        } catch (_) {
          s.feldStale = false;
        }
      }
    }
    // fields and character names (from the ROM's character table and text table)
    if (!clean) {
      try {
        s.fields = C.fieldSets(s.ctx!);
        final tt = F.textTabelle(buf), chars = C.charGroups(s.ctx!); // 1.7.6 GFX_MAP: Neon Planets too
        if (tt >= 0) {
          for (final c in chars) {
            final n = F.zeichenkette(buf, tt, c.name);
            if (n.isNotEmpty && c.group != null && !s.charNames.containsKey(c.group)) s.charNames[c.group!] = n;
          }
        }
      } catch (_) {
        s.fields = [];
      }
    }
    s._renderEmu();
    s._renderDoom();
    return s;
  }

  static bool _differs(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length; i++) {
      if (i >= b.length || a[i] != b[i]) return true;
    }
    return false;
  }

  /// An entry of the menu as loadRom keeps it (app.js:438, spec 1.5).
  static E.Extra _fromRom(E.Extra x) {
    final E.Extra y;
    switch (x.kind) {
      case 'tama':
        y = E.Extra(kind: 'tama', guest: x.guest, dev: x.dev, clock: x.clock, nfc: x.nfc, opt: x.opt, packed: x.packed);
      case 't18':
        y = E.Extra(kind: 't18', fw: x.fw, clock: x.clock, opt: x.opt, keepOff: x.off);
      case 'v1':
        y = E.Extra(kind: 'v1', rom: x.rom, clock: x.clock);
      case 'gb':
        y = E.Extra(kind: 'gb', rom: x.rom, keys: x.keys, inv: x.inv, save: x.save);
      case 'sms':
        y = E.Extra(kind: 'sms', rom: x.rom, title: x.title, gg: x.gg, keys: x.keys, inv: x.inv, save: x.save);
      case 'ab':
        y = E.Extra(kind: 'ab', rom: x.rom, title: x.title, keys: x.keys, inv: x.inv, save: x.save);
      case 'pm':
        y = E.Extra(kind: 'pm', rom: x.rom, title: x.title, keys: x.keys, inv: x.inv, save: x.save, bios: x.bios);
      case 'wolf':
        y = E.Extra(kind: 'wolf', pack: x.pack, keyMap: x.keyMap, save: x.save);
      case 'doom':
        y = E.Extra(kind: 'doom', mcu: x.mcu, keyMap: x.keyMap, save: x.save, name: x.name, region: x.region)..keys0 = jsonEncode(x.keyMap);
      default:
        y = E.Extra(rom: x.rom, figs: x.figs ?? [], clock: x.clock);
    }
    if (x.sess == false) y.sess = false; // sessKeep
    return y;
  }

  /// app.js extrasOld: does a program in the menu come from an older Studio? (vectors and code differ from the
  /// program in this one). Returns the groups (chips) whose program is older, or null.
  Set<String>? extrasOld(Uint8List rom, List<E.AppEntry> apps) {
    final up = <String>{};
    try {
      final progs = <String, Uint8List?>{
        't7': E.t7Embedded()?.app,
        'tama': E.embedded()?.app,
        'v1': E.v1Embedded()?.app,
        'gb': E.gbEmbedded(),
        'sms': E.smsEmbedded(),
        'pm': E.pmEmbedded(),
        'ab': E.abEmbedded()
      };
      for (final x in E.appsRead(rom, apps)) {
        final k = E.extraKind(x);
        // 1.7.2: Game Boy Color games against GBCEmu; T18Emu: its image is patched all over; test4: V3Emu against its own program
        final img = k == 't18'
            ? null
            : k == 'v1' && E.v3Detect(x.rom)
                ? E.v3Embedded()
                : k == 'gb' && E.gbIsColor(x.rom!)
                    ? E.gbcEmbedded()
                    : progs[k];
        if (img == null || img.isEmpty) continue;
        final at = x.off;
        bool same(int a, int z) {
          for (var i = a; i < z; i++) {
            if (rom[at + i] != img[i]) return false;
          }
          return true;
        }

        if (!same(0, EXIT_AT) || !same(0x800, img.length < 0x10000 ? img.length : 0x10000)) up.add(groupKind(k));
      }
    } catch (_) {
      return null;
    }
    return up.isNotEmpty ? up : null;
  }

  // ---------------------------------------------------------------- predicates (spec 1.7)
  Uint8List entry(int i) {
    final lm = launch ? launchMap : null;
    return changed[i] ?? (lm != null ? lm[i] : null) ?? ctx!.entries[i];
  }
  bool menuWanted() => feld || bag || tama || gplay || launch;

  /// launcher ROM (1.6.8): the small images, computed once per ROM
  Map<int, Uint8List> launchMapGet() => launchMap ??= C.launcherChanges(ctx!);
  bool sixActive() => !launch && ((S6.sixInfo(rom) != null && !sixOff) || six != null || sixWant);

  int estimateEnd() {
    if (ctxClean) return C.ASSET_BASE; // CLEAN_ROM: no pictures
    final c = ctx!;
    var pack = 4 * c.entries.length;
    for (var i = 0; i < c.entries.length; i++) {
      pack += (4 - pack % 4) % 4;
      pack += entry(i).length;
    }
    int al(int n) => n + ((4 - n % 4) % 4);
    return C.ASSET_BASE + 16 + 48 + al(c.files[0].length) + al(pack) + al(c.files[2].length);
  }

  /// 0 none, 1 DOOM, 2 emulator at 0x0A0000 (0 for a clean ROM).
  int appInstalled() {
    try {
      if (ctxClean) return 0; // CLEAN_ROM: no main program at 0x0A0000, every program is in the menu (DOOM too, test3)
      if (fe != null && F.isLaunch(rom, fe!.stub)) return F.appKind(rom); // 1.6.8: start device, the home screen hooks point to the trampolines
      return E.installedOrigs(rom, E.sceneTable(rom)) != null ? F.appKind(rom) : 0;
    } catch (_) {
      return 0;
    }
  }

  bool emuInstalled() => appInstalled() == 2;
  bool doomInstalled() => appInstalled() == 1;

  bool emuClockDirty() {
    final sv = E.emuSessGet(rom);
    if (sv != null && sv != emuSess) return true;
    final c = E.emuClockGet(rom), n = E.emuNfcGet(rom), o = E.emuOptGet(rom), w = emuOpt;
    return (c != null && c != emuClock) || (n != null && n != emuNfc) || (o != null && (o.vol != w.vol || o.dim != w.dim || o.off != w.off));
  }

  bool emuAutoDirty() =>
      (emuInstalled() || (doomInstalled() && !launch)) && emu == null && !emuRemove && doom == null && ((E.autoGet(rom, stubList(rom, fe)) ?? false) != emuAuto || (emuInstalled() && emuClockDirty()));

  bool emuUpPending() {
    final emb = E.embedded();
    if (emu != null || emuRemove || doom != null || emb == null || !emuInstalled()) return false;
    try {
      final ty = F.emuType(rom);
      if (ty == 't7') return E.t7Embedded() != null && E.t7Upgrade(rom, E.t7Embedded()!) != null;
      if (ty == 'v1') return E.v1Embedded() != null && E.v1Upgrade(rom, E.v1Embedded()) != null;
      if (ty == 't18') return E.t18Embedded() != null && E.t18Upgrade(rom, E.t18Embedded()!, E.embedded()?.stub) != null;
      return E.emuUpgrade(rom, emb.app) != null;
    } catch (_) {
      return false;
    }
  }

  /// Room for a main program at 0x0A0000 (false in Tropical, Glacier, Neon Planets, Jade Forest wave 2).
  bool a0Free() {
    if (F.appKind(rom) != 0) return true;
    for (var i = 0xA0000; i < 0xA1000 && i < rom.length; i++) {
      if (rom[i] != 0xFF) return false;
    }
    return true;
  }

  bool appRoom() => !a0Free() || estimateEnd() <= 0x830000; // without a main program the trial build decides (roomMissing)

  /// 1.6.9 test13: the Studio's menu program knows the main program out of its list (version 9)
  bool mainV9() => fe != null && _feldVersion(fe!.feld) >= 9;

  /// CLEAN_ROM: the feld build of this Studio knows the clock sector (menu version 10)
  bool cleanCan() => fe != null && fe!.feldc != null && _feldVersion(fe!.feldc) >= 10;
  bool doomFree() => clean || (launch && !a0Free());
  bool doomMain() {
    if (doomFree()) return false;
    return doom != null || (doomInstalled() && !emuRemove && (launch || emu == null));
  }

  List<E.Extra> doomXs() => extras.where((x) => x.kind == 'doom').toList();
  bool clockOff() => clean && cleanClock == false;

  /// "the star can be given to any program of the list" (renderApps: lp).
  bool starFree() => launch && (doomMain() || clean) && mainV9();

  /// Size of one episode as it will be written: with music if ticked and it fits
  int doomEpSize(DoomFit? f) => f == null ? 0 : (doomMusic && f.music ? f.sizeM : f.sizeP);

  Uint8List? doomMcuOf(E.Extra x) {
    final d = x.wadSrc;
    if (d == null) return x.mcu;
    final ep = x.ep is String && (x.ep as String).isNotEmpty ? x.ep as String : doomEp;
    final f = d.fit[ep] ?? (x.ep != 'all' && d.ok.isNotEmpty ? d.fit[d.ok[0]] : null); // 1.7.3 test12: x.ep (several episodes)
    if (f == null || !f.plain) return null;
    return doomMusic && f.music ? f.mcuM : f.mcuP;
  }

  E.Extra? doomParaX(Uint8List src) {
    final len = rd32(src, D.WAD_OFF);
    if (len == 0 || len > D.REGION_OFF - D.WAD_OFF - 4) return null;
    final keys = D.doomKeysGet(src) ?? D.KEYS_DEFAULT;
    return E.Extra(kind: 'doom', mcu: Uint8List.fromList(src.sublist(D.WAD_OFF + 4, D.WAD_OFF + 4 + len)), keyMap: keys, save: Uint8List.fromList(src.sublist(D.SAVE_OFF, D.SAVE_END)))
      ..keys0 = jsonEncode(keys)
      ..fromPara = true;
  }

  // ---------------------------------------------------------------- the main program as an extra
  /// app.js emuX(em): the main program (state.emu) in the form of a further program.
  static E.Extra? emuX(MainEmu? em) => em == null
      ? null
      : em.v1
          ? E.Extra(kind: 'v1', rom: em.rom)
          : em.t18
              ? E.Extra(kind: 't18', fw: em.rom)
              : em.t7
                  ? E.Extra(rom: em.rom, figs: em.figs)
                  : E.Extra(kind: 'tama', guest: em.guest, dev: em.dev);

  /// app.js emuNm(em): its name.
  static String emuNm(MainEmu em) => em.v1
      ? E.v1Name(em.rom!)
      : em.t7
          ? E.t7XName(em.rom)
          : em.t18
              ? E.extraName(E.Extra(kind: 't18'))
              : E.tamaName(em.guest, em.dev);

  /// app.js installedX(r0): the installed main program read from the ROM.
  Future<E.Extra?> installedX(Uint8List r0) async {
    final ty = F.emuType(r0);
    if (ty == 't7') {
      final c7 = E.t7FromRom(r0);
      return c7 != null ? E.Extra(rom: c7.rom, figs: c7.figs) : null;
    }
    if (ty == 't18') {
      final fw = E.t18FromRom(r0);
      return fw != null ? E.Extra(kind: 't18', fw: fw) : null;
    }
    if (ty == 'v1') {
      final r = E.v1FromRom(r0);
      return r != null ? E.Extra(kind: 'v1', rom: r) : null;
    }
    final cfg = romEmuCfg(r0);
    return cfg != null ? E.Extra(kind: 'tama', guest: await SV.emuGuestAsync((a, n) => Uint8List.sublistView(r0, a, a + n), cfg), dev: cfg.dev) : null;
  }

  /// Reads the installed main TamaEmu firmware with its save into [mainGuest].
  Future<bool> mainGuestLoad() async {
    if (mainGuest != null) return true;
    final cfg = romEmuCfg(rom);
    if (cfg == null) return false;
    final g = await SV.emuGuestAsync((a, n) => Uint8List.sublistView(rom, a, a + n), cfg);
    mainGuest = (g: g, dev: cfg.dev);
    return true;
  }

  E.Extra? curMainX() => emuX(emu);

  /// The current main T7Emu (chosen, or the installed one read from the ROM), for the figures.
  MainEmu? t7State() {
    if (emu != null && emu!.t7) return emu;
    final cur = E.t7FromRom(rom);
    if (cur == null) return null;
    return MainEmu.t7(cur.rom, cur.figs, size: 0);
  }

  static int t7Size(MainEmu st) => st.rom!.length + st.figs.fold(0, (n, f) => n + f.data.length);
  static int _t18Size(Uint8List fw) {
    var n = 0;
    for (var k = 0; k < 128; k++) {
      final a = k << 16, z = (k + 1) << 16;
      for (var i = a; i < z && i < fw.length; i++) {
        if (fw[i] != 0xFF) {
          n++;
          break;
        }
      }
    }
    return n << 16;
  }

  /// 1.6.8: choosing or dropping an emulator does not bring back a DOOM the user took out (emuRemove means "take the
  /// program at 0x0A0000 out", which is DOOM when DOOM is built in)
  void emuRemoveClear() {
    if (!doomInstalled()) emuRemove = false;
  }

  void extrasDedupe(E.Extra? mainX) {
    final mainE = mainX ?? emuX(emu);
    if (mainE != null && extras.any((x) => sameFw(x, mainE))) {
      extras = extras.where((x) => !sameFw(x, mainE)).toList();
      extrasDirty = true;
    }
    // the same firmware twice in the menu: once is enough (it would share nothing, only take room)
    final xs = extras, keep = <E.Extra>[];
    for (var i = 0; i < xs.length; i++) {
      if (!xs.sublist(0, i).any((y) => sameFw(xs[i], y))) keep.add(xs[i]);
    }
    if (keep.length != xs.length) {
      extras = keep;
      extrasDirty = true;
    }
  }

  // ---------------------------------------------------------------- what the page does while rendering
  /// One key layout per kind: taken from the first game in the list, else the default (gbKeysNow ...).
  List<int> gbKeysNow() => gbKeys ??= _keys9('gb', E.gbKeysDefault, (v) => gbInv = v);
  List<int> smsKeysNow() => smsKeys ??= _keys9('sms', E.smsKeysDefault, (v) => smsInv = v);
  List<int> pmKeysNow() => pmKeys ??= _keys9('pm', E.pmKeysDefault, (v) => pmInv = v);
  List<int> abKeysNow() => abKeys ??= _keys9('ab', E.abKeysDefault, (v) => abInv = v);
  List<int> _keys9(String kind, List<int> def, void Function(bool) inv) {
    E.Extra? x;
    for (final y in extras) {
      if (y.kind == kind && y.keys != null && y.keys!.length == 9) {
        x = y;
        break;
      }
    }
    inv(x != null ? x.inv : true); // 1.6.10 test1: wheel reversed by default
    return x != null ? [...x.keys!] : [...def];
  }

  Uint8List? pmBiosNow() {
    if (!_pmBiosRead) {
      _pmBiosRead = true;
      pmBios = null;
      for (final y in extras) {
        if (y.kind == 'pm' && y.bios != null && y.bios!.isNotEmpty) {
          pmBios = y.bios;
          break;
        }
      }
    }
    return pmBios;
  }

  Map<String, Object> wolfKeysNow() {
    if (wolfKeys == null) {
      E.Extra? x;
      for (final y in extras) {
        if (y.kind == 'wolf') {
          x = y;
          break;
        }
      }
      wolfKeys = {...E.wolfKeysDefault, ...?x?.keyMap};
    }
    return wolfKeys!;
  }

  void _gamesApply(String kind, List<int> keys, bool inv) {
    for (final x in extras) {
      if (x.kind == kind) {
        x.keys = [...keys];
        x.inv = inv;
      }
    }
    extrasDirty = true;
  }

  /// The key layout of the games of one kind ('gb', 'sms', 'pm', 'ab') changed: [keys] 9 button codes, wheel reversed.
  void setGameKeys(String kind, List<int> keys, bool inv) {
    switch (kind) {
      case 'gb':
        gbKeys = [...keys];
        gbInv = inv;
      case 'sms':
        smsKeys = [...keys];
        smsInv = inv;
      case 'pm':
        pmKeys = [...keys];
        pmInv = inv;
      case 'ab':
        abKeys = [...keys];
        abInv = inv;
      default:
        throw ArgumentError(kind);
    }
    _gamesApply(kind, keys, inv);
  }

  /// The Pokémon mini BIOS for all its games (null: the free one).
  void setPmBios(Uint8List? bios) {
    _pmBiosRead = true;
    pmBios = bios;
    for (final x in extras) {
      if (x.kind == 'pm') x.bios = pmBios;
    }
    extrasDirty = true;
  }

  /// The keys of Wolfenstein 3D ({ fire, fwd, back, use, mod, run, invert, turn }).
  void setWolfKeys(Map<String, Object> keys) {
    wolfKeys = {...keys};
    final xs = extras.where((y) => y.kind == 'wolf').toList();
    for (final x in xs) {
      x.keyMap = {...wolfKeys!};
    }
    if (xs.isNotEmpty) {
      extrasDirty = true;
      wolfKeysDirty = true;
    }
  }

  /// The state changes of renderEmu (key layouts read once, a star that points nowhere is taken back).
  void _renderEmu() {
    gbKeysNow();
    smsKeysNow();
    pmBiosNow();
    pmKeysNow();
    abKeysNow();
    wolfKeysNow();
    final lp = starFree();
    if (lp && mainPick != null && mainPick != pickEmu && !extras.contains(mainPick)) mainPick = null;
    if (lp && mainPick == pickEmu && emu == null) mainPick = null;
  }

  /// The state changes of renderDoom: the episode select keeps a valid value, music is unticked where it does not
  /// fit, the keys are read once.
  void _renderDoom() {
    final d = doom, has = doomFree() ? doomXs().any((x) => x.wadSrc == null) : doomInstalled();
    final multi = doomFree() && d != null && (d.ok.length > 1 || d.ok.any(_isPQ) || (d.fit['all']?.plain ?? false));
    final opts = d != null && d.ok.any((e) => !_isPQ(e)) ? d.ok.where((e) => !_isPQ(e)).toList() : ['1'];
    if (!opts.contains(doomEp)) doomEp = opts.first;
    final f = d?.fit[doomEp];
    DoomFit? fm;
    if (multi) {
      if (d.whole) {
        fm = d.fit['all'];
      } else {
        for (final e in d.ok) {
          final g = d.sel.contains(e) ? d.fit[e] : null;
          if (g != null && g.music) {
            fm = g;
            break;
          }
        }
      }
    } else {
      fm = f;
    }
    if (fm != null && !fm.music) doomMusic = false;
    final showKeys = d != null || (has && (doomFree() || !emuRemove));
    if (showKeys && doomKeys == null) {
      Map<String, Object>? k;
      if (doomFree()) {
        final xs = doomXs();
        k = xs.isNotEmpty ? xs.first.keyMap : null;
      } else if (has) {
        k = D.doomKeysGet(rom);
      }
      doomKeys = {...(k ?? D.KEYS_DEFAULT)};
    }
  }

  /// Call after changing plain fields that the page would follow with a re-render (the lazy reads above).
  void sync() {
    _renderEmu();
    _renderDoom();
  }

  // ---------------------------------------------------------------- DOOM as a program of the list
  /// 1.7.2 test4: the main program of a start device with the Paradise (at 0x0A0000) becomes an entry of the list
  /// too, so there is only one star: it keeps it until another program gets it
  Future<void> paraMainSync() async {
    if (!doomFree()) {
      if (paraMainTaken) {
        final mp = mainPick;
        if (mp is E.Extra && mp.fromParaMain) mainPick = null;
        extras = extras.where((x) => !x.fromParaMain).toList();
        emuRemove = false;
        paraMainTaken = false;
      }
      return;
    }
    if (ctxClean || paraMainTaken || emu != null || emuRemove || !emuInstalled()) return;
    final x = await installedX(rom);
    if (x == null) return;
    x
      ..fromParaMain = true
      ..clock = emuClock
      ..nfc = emuNfc
      ..opt = emuOpt
      ..sess = emuSess;
    extras.insert(0, x);
    mainPick ??= x;
    emuRemove = true;
    paraMainTaken = true;
    extrasDirty = true;
  }

  void doomFreeSync() {
    if (!doomFree()) {
      // back to the Paradise: DOOM of the DOOM tab or of the start device as before
      bool out(E.Extra x) => x.fromPara || x.wadSrc != null;
      final mp = mainPick;
      if (mp is E.Extra && mp.kind == 'doom' && out(mp)) mainPick = null;
      extras = extras.where((x) => !out(x)).toList();
      return;
    }
    final old = doomXs(), wasMain = old.contains(mainPick);
    final d = doom;
    if (d != null) {
      // 1.7.3 test12: each chosen episode its own entry in the menu
      final want = [
        if (d.whole) 'all' else ...d.ok.where((e) => d.sel.contains(e) && !_isPQ(e)),
        ...d.ok.where((e) => _isPQ(e) && d.sel.contains(e)),
      ];
      final gone = old.where((x) => !identical(x.wadSrc, d)).toList();
      // a new WAD replaces the DOOM of the ROM (as before); a save of the same episode (menu name "DOOM E2") goes along
      for (final x in old) {
        if (!identical(x.wadSrc, d) || !want.contains(x.ep)) {
          if (identical(mainPick, x)) mainPick = null;
          extras.remove(x);
          extrasDirty = true;
        }
      }
      for (final e in want) {
        if (doomXs().any((x) => identical(x.wadSrc, d) && x.ep == e)) continue;
        final sz = doomEpSize(d.fit[e]);
        final x = E.Extra(kind: 'doom', ep: e, size: sz != 0 ? sz : 0x300000, keyMap: {...(doomKeys ?? D.KEYS_DEFAULT)})..wadSrc = d;
        if (e == 'all') {
          x.region = DOOM_WHOLE_REGION;
          if (d.d2) x.d2 = true;
        }
        if (_isPQ(e)) x.title = d.titles[e] ?? 'DOOM';
        final nm = e == 'all' ? (d.d2 ? 'DOOM II' : 'DOOM') : (_isPQ(e) ? x.title : 'DOOM E$e');
        for (final g in gone) {
          if (g.name == nm) {
            if (g.save != null && g.save!.isNotEmpty) x.save = g.save;
            break;
          }
        }
        final i = extras.indexWhere((y) => y.kind == 'doom' && identical(y.wadSrc, d) && y.ep is String && (y.ep as String).compareTo(e) > 0 && !_isPQ(e));
        extras.insert(i >= 0 ? i : extras.length, x);
        extrasDirty = true;
        if (wasMain && !doomXs().contains(mainPick)) mainPick = x;
      }
      if (wasMain && mainPick == null && doomXs().isNotEmpty) mainPick = doomXs()[0]; // the star stays with DOOM
    } else if (!ctxClean && doomInstalled() && !emuRemove && old.isEmpty) {
      final x = doomParaX(rom);
      if (x != null) {
        extras.add(x);
        mainPick ??= x;
        extrasDirty = true; // it was the main program (shown first while it has the star)
      }
    }
  }

  // ---------------------------------------------------------------- the menu tab's switches
  /// launchOn: start device on or off.
  Future<void> setLaunch(bool on) async {
    launch = on;
    if (!launch) {
      clean = false;
      await paraMainSync();
      doomFreeSync();
    }
    if (launch) {
      launchMapGet();
      feld = bag = tama = gplay = false;
      sixWant = false;
      six = null;
    }
    _renderEmu();
  }

  /// cleanOn: without the Paradise (only in a start device).
  Future<void> setClean(bool on) async {
    clean = on;
    if (clean) {
      six = null;
      sixWant = false;
    }
    await paraMainSync();
    doomFreeSync();
    roomFree = null;
    _renderEmu();
    _renderDoom();
  }

  /// cleanClock: the clean ROM asks for the clock at the start.
  void setCleanClock(bool on) {
    cleanClock = on;
    mainDirty = true;
    _renderEmu();
  }

  /// sixOn: more fields (Tropical / Glacier: all 6; Jade Forest: Sky) on, or out again. Returns true when the page
  /// would now ask for the Land, Water or Sky ROM ([setSixSource]).
  bool setSixOn(bool on) {
    sixOff = !on && S6.sixInfo(rom) != null; // 1.6.8: take the extra fields out again
    sixWant = on;
    if (!on) {
      six = null;
      return false;
    }
    feld = true;
    return six == null && S6.sixNeedsSource(rom);
  }

  /// fileSix: the Land, Water or Sky ROM the field pictures come from. False (with the message) when it is not one.
  bool setSixSource(Uint8List buf, String fname) {
    if (!S6.sixSource(buf)) {
      toast('$fname is not a Land, Water or Sky ROM.', true);
      return false;
    }
    six = buf;
    sixName = fname;
    sixWant = true;
    feld = true;
    toast('Field pictures taken from $fname.');
    return true;
  }

  /// A name edited in the Names tab (nameRow): [idx] the text numbers of the row, [cur] the name in the ROM.
  void setName(List<int> idx, String cur, String input) {
    final v = C.textClean(input);
    for (final i in idx) {
      if (v == null || v.isEmpty || v == cur) {
        texts.remove(i);
      } else {
        texts[i] = v;
      }
    }
  }

  // ---------------------------------------------------------------- the emulator tab
  /// btnEmu / fileEmu (app.js:1990): one button for everything: the first program is the main one (A and C), every
  /// further one goes to the menu.
  Future<void> chooseFirmware(Uint8List g, String fname) async {
    if (E.gbDetect(g)) {
      await addExtra(g, fname);
      return;
    }
    if (E.smsDetect(g, fname)) {
      await addExtra(g, fname);
      return;
    }
    // test25: no room at 0x0A0000: the menu; the first program stays the main one
    if (emu != null || (emuInstalled() && !emuRemove) || extras.isNotEmpty || (E.v1Detect(g) && doomMain()) || !a0Free()) {
      await addExtra(g, fname);
      return;
    }
    void after() {
      extrasDedupe(null);
      emuRemoveClear();
      if (!launch) doom = null;
      _renderDoom();
    }

    if (E.v1Detect(g)) {
      emu = MainEmu.v1(g);
      after();
    } else if (E.t18Detect(g)) {
      emu = MainEmu.t18(g, size: _t18Size(g));
      after();
    } else if (E.t7Detect(g)) {
      final old = emu != null && emu!.t7 ? emu : t7State(); // the figures stay
      final st = MainEmu.t7(g, old != null && E.t7Kind(g) == 'go' ? old.figs : []);
      st.size = t7Size(st);
      emu = st;
      after();
    } else {
      try {
        final dev = E.emuDetect(g);
        final pk = E.packMain(g, dev, null, emuPack);
        emu = MainEmu.tama(g, dev, size: pk.blob.length, big: pk.big);
        after();
      } catch (err) {
        toast('Firmware not recognised: ${em(err)}', true);
      }
    }
    _renderEmu();
  }

  bool canMain(E.Extra x) {
    if (OWN_CHIP.contains(x.kind)) return false; // 1.6.9 test36: GBEmu only in the menu (and Wolf3D)
    // outside a start device only T7Emu goes to the menu, so the old main program must be a T7Emu (or none)
    if (launch) return true;
    if (!a0Free()) return false; // test25: no main program at 0x0A0000 in this edition
    final em = emu;
    final ty = em != null ? (em.v1 ? 'v1' : (em.t7 ? 't7' : (em.t18 ? 't18' : 'tama'))) : (emuInstalled() && !emuRemove ? F.emuType(rom) : null);
    return ty == null || ty.isEmpty || ty == 't7' || ty == 'v1';
  }

  /// The star outside a start device: entry [i] of the list becomes the main program (A and C).
  Future<void> makeMain(int i) async {
    if (i < 0 || i >= extras.length) return;
    final x = extras[i];
    var old = curMainX();
    if (old == null && emuInstalled() && !emuRemove) old = await installedX(rom);
    MainEmu em;
    if (x.kind == 't18') {
      em = MainEmu.t18(x.fw!, size: _t18Size(x.fw!));
    } else if (x.kind == 'tama') {
      final pk = E.packMain(x.guest!, x.dev!, null, emuPack);
      em = MainEmu.tama(x.guest!, x.dev!, size: pk.blob.length, big: pk.big);
    } else if (x.kind == 'v1') {
      em = MainEmu.v1(x.rom!);
    } else {
      em = MainEmu.t7(x.rom!, x.figs ?? []);
      em.size = t7Size(em);
    }
    extras.removeAt(i);
    if (old != null) old.opt = emuOpt;
    emuOpt = x.opt ?? const E.EmuOpt();
    // outside a start device only T7Emu and V1Emu go to the menu; another main program is replaced
    if (old != null && !launch && (old.kind == 'tama' || old.kind == 't18')) {
      toast('${E.extraName(x)} is now the main program instead of ${E.extraName(old)}.');
      old = null;
    }
    if (old != null) extras.insert(0, old);
    emu = em;
    emuRemoveClear();
    extrasDirty = true;
    t7saveX = null;
    mainGuest = null;
    if (!launch) doom = null;
    if (!x.fresh) toast('${E.extraName(x)} is now the main program. The saves of the swapped programs start anew.');
    _renderDoom();
    _renderEmu();
  }

  _Snap _snap() => _Snap(emu, [...extras], emuRemove, mainPick, emuOpt, mainGuest);
  void _back(_Snap s) {
    emu = s.emu;
    extras = [...s.extras];
    emuRemove = s.emuRemove;
    mainPick = s.mainPick;
    emuOpt = s.emuOpt;
    mainGuest = s.mainGuest;
    extrasDirty = true;
  }

  /// test17: the star in a start device: only if it still fits, otherwise the old order stays
  Future<void> mainChecked(int i) async {
    if (!launch) return makeMain(i);
    final snap = _snap();
    await makeMain(i);
    final m = await roomTry();
    if (m.k != 0 || m.err.isNotEmpty) {
      _back(snap);
      _renderDoom();
      _renderEmu();
      toast(m.k != 0 ? 'As the first entry about ${m.k} KB of room are missing. It stays as it was.' : 'More emulators: ${m.err}', true);
    }
  }

  /// The star where it can be given freely ([starFree]): an entry of [extras], [pickEmu] or null (DOOM).
  void pick(Object? v) {
    mainPick = v;
    mainDirty = true;
    _renderEmu();
  }

  /// × on a program of the list.
  void removeExtra(int i) {
    final x = extras[i];
    if (identical(mainPick, x)) {
      mainPick = null;
      mainDirty = true;
    }
    if (x.fromPara) emuRemove = true;
    if (x.wadSrc != null) doom = null;
    extras.removeAt(i);
    extrasDirty = true;
    t7saveX = null;
    _renderEmu();
  }

  /// × on the installed main program ("Remove emulator").
  void removeMain() {
    emu = null;
    emuRemove = true;
    _renderEmu();
  }

  /// × on a newly chosen main program, or ↺ on a removed one ("Undo").
  void undoMain() {
    emu = null;
    emuRemoveClear();
    t7save = null;
    _renderEmu();
    _renderDoom();
  }

  /// × on the DOOM row ("Remove DOOM").
  void doomOut() {
    if (doom != null) {
      doom = null;
    } else {
      emuRemove = true;
      if (!launch) emu = null;
    }
    _renderEmu();
    _renderDoom();
  }

  /// ↺ on a DOOM that is going away.
  void doomBack() {
    emuRemove = false;
    if (!launch) emu = null;
    _renderEmu();
    _renderDoom();
  }

  /// "Remove DOOM" of the DOOM tab (btnDoomOff).
  void doomOff() {
    if (doomFree()) {
      for (final x in doomXs()) {
        if (identical(mainPick, x)) {
          mainPick = null;
          mainDirty = true;
        }
        if (x.fromPara) emuRemove = true;
      }
      extras = extras.where((x) => x.kind != 'doom').toList();
      extrasDirty = true;
      doom = null;
      _renderEmu();
      _renderDoom();
      return;
    }
    doom = null;
    if (!launch) emu = null;
    emuRemove = true;
    _renderEmu();
    _renderDoom();
  }

  /// fileWad after the conversion: [d] is what app.js doomCompute returns. False (with the message) where DOOM
  /// cannot go.
  bool setDoom(DoomData d) {
    // DOOM_LAUNCH: without room at 0x0A0000 DOOM goes only into the menu of a start device
    if (!ctxClean && !launch && !a0Free()) {
      toast('In this edition DOOM works in a start device only (Menu tab).', true);
      return false;
    }
    doom = d;
    if (!launch) emu = null;
    if (!doomFree()) emuRemove = false;
    doomFreeSync();
    _renderEmu();
    _renderDoom();
    return true;
  }

  /// A change of the episode boxes of [doom] (sel, whole): the entries of the list follow.
  void doomSelChanged() {
    doomFreeSync();
    _renderEmu();
    _renderDoom();
  }

  /// doomMusic: with or without music changes the size of each entry and the room.
  void setDoomMusic(bool on) {
    doomMusic = on;
    for (final x in doomXs()) {
      final d = x.wadSrc;
      if (d == null) continue;
      final ep = x.ep is String && (x.ep as String).isNotEmpty ? x.ep as String : (d.ok.isNotEmpty ? d.ok[0] : '');
      final sz = doomEpSize(d.fit[ep]);
      x.size = sz != 0 ? sz : x.size;
      x.mcu = null;
    }
    extrasDirty = true;
    _renderEmu();
    _renderDoom();
  }

  /// doomEp: the episode of DOOM next to the Paradise.
  void setDoomEp(String ep) {
    doomEp = ep;
    _renderDoom();
  }

  /// The DOOM keys from the controls (keysChanged).
  void setDoomKeys(Map<String, Object> k) {
    if (doomKeys == null) return;
    doomKeys!.addAll(k);
    _renderDoom();
  }

  /// app.js addExtra(g, fname, preset): a further program for the menu, with every rule and message (spec 2.5).
  Future<void> addExtra(Uint8List g, String fname, [E.Extra? preset]) async {
    E.Extra? x = preset;
    if (x != null) {
      /* 1.7.3: made by its tab (Arduboy) */
    } else if (E.gbDetect(g)) {
      if (E.gbColorOnly(g) && !E.gbIsColor(g)) {
        toast('$fname: Game Boy Color only, that does not work', true);
        return;
      }
      x = E.Extra(kind: 'gb', rom: g, keys: [...gbKeysNow()], inv: gbInv != false); // 1.6.9 test36: GBEmu
    } else if (E.pmDetect(g)) {
      x = E.Extra(kind: 'pm', rom: g, title: E.pmTitle(fname), keys: [...pmKeysNow()], inv: pmInv != false, bios: pmBios); // 1.7.3 PokeMiniEmu
    } else if (E.smsDetect(g, fname)) {
      x = E.Extra(kind: 'sms', rom: g, title: E.smsTitle(fname), gg: E.smsGameGear(g, fname), keys: [...smsKeysNow()], inv: smsInv != false); // 1.6.10 test2: SMSEmu
    } else if (E.v1Detect(g)) {
      x = E.Extra(kind: 'v1', rom: g); // 1.6.8: V1Emu (first Tamagotchis, Digital Monster)
    } else if (E.t7Detect(g)) {
      x = E.Extra(rom: g);
    } else if (E.t18Detect(g)) {
      x = E.Extra(kind: 't18', fw: g);
    } else {
      try {
        final dev = E.emuDetect(g);
        try {
          E.packGuest(g, dev);
        } catch (_) {
          E.packGuest(g, dev, lz: true);
        }
        x = E.Extra(kind: 'tama', guest: g, dev: dev);
      } catch (_) {
        x = null;
      }
    }
    if (x == null) {
      var main = false;
      try {
        main = E.t18Detect(g) || E.emuDetect(g).isNotEmpty;
      } catch (_) {
        main = false;
      }
      toast(
          main && !launch
              ? '$fname: colour Tama and TG18 firmware go as a further program only in a start device. Otherwise remove the emulator above with × first.'
              : launch
                  ? '$fname: neither a Tama-Go or Friends ROM nor a colour Tama or TG18 firmware.'
                  : '$fname: not a Tama-Go or Friends ROM.',
          true);
      return;
    }
    if (extras.length >= E.appxMax) {
      toast('At most 12 more emulators.', true);
      return;
    }
    {
      // 1.6.8: each program once
      var m = curMainX();
      if (m == null && emuInstalled() && !emuRemove) {
        final r0 = rom, ty = F.emuType(r0);
        if (ty == 't7') {
          final c7 = E.t7FromRom(r0);
          if (c7 != null) m = E.Extra(rom: c7.rom);
        } else if (ty == 't18') {
          final fw = E.t18FromRom(r0);
          if (fw != null) m = E.Extra(kind: 't18', fw: fw);
        } else if (ty == 'v1') {
          final r = E.v1FromRom(r0);
          if (r != null) m = E.Extra(kind: 'v1', rom: r);
        } else if (x.kind == 'tama') {
          await mainGuestLoad();
          if (mainGuest != null) m = E.Extra(kind: 'tama', guest: mainGuest!.g, dev: mainGuest!.dev);
        }
      }
      final x0 = x;
      if ((m != null && sameFw(x0, m)) || extras.any((y) => sameFw(x0, y))) {
        toast('${E.extraName(x)} is already in.', true);
        return;
      }
    }
    if (x.kind == 't18' && (extras.any((y) => y.kind == 't18') || (emu != null && emu!.t18) || (emu == null && F.emuType(rom) == 't18' && !emuRemove))) {
      toast('T18Emu goes only once per ROM.', true);
      return;
    }
    final nx = x;
    nx.fresh = true;
    extras.add(nx);
    extrasDirty = true;
    t7saveX = null;
    // test25: no room at 0x0A0000 and no start device: a colour Tama or TG18 cannot go anywhere
    if (!launch && !a0Free() && (nx.kind == 'tama' || nx.kind == 't18')) {
      extras = extras.where((y) => !identical(y, nx)).toList();
      toast('$fname: colour Tamas and TG18 work in this edition in a start device only (Menu tab).', true);
      _renderEmu();
      return;
    }
    // outside a start device a colour Tama or TG18 only runs as the main program (A and C): it becomes the main one
    if (!launch && (nx.kind == 'tama' || nx.kind == 't18')) {
      await makeMain(extras.length - 1);
      return;
    }
    // 1.6.8: does it still fit? A trial build right away, not only when writing
    final f = await roomFit(), k = f.k;
    if (k != 0 || f.err.isNotEmpty) {
      extras = extras.where((y) => !identical(y, nx)).toList();
      extrasDirty = true;
      _renderEmu();
      toast(k != 0 ? _noRoomAdd(nx, k) : 'More emulators: ${f.err}', true);
      return;
    }
    _renderEmu();
  }

  String _noRoomAdd(E.Extra x, int k) =>
      'No room left for ${E.extraName(x)}: about $k KB missing. (The top 64 KB stay free for the write protection.)${E.packOpt && extras.any((y) => y.kind == 'tama' && !y.packed) ? ' Tip: "Pack the firmware" for TamaEmu saves room.' : ''}';

  /// fileAb: an Arduboy game (.hex, read with E.abHex).
  Future<void> addArduboy(Uint8List bin, String fname) async {
    abKeysNow();
    await addExtra(bin, fname, E.Extra(kind: 'ab', rom: bin, title: E.abTitle(fname), keys: [...abKeys!], inv: abInv != false));
  }

  /// fileWolf after the pack is built (wolf.js build is not ported: the pack is the input): one Wolfenstein 3D and
  /// one Spear of Destiny, a new one replaces the old one; room check.
  Future<void> addWolf(Uint8List pack) async {
    final sod = E.wolfSod(pack);
    final old = extras.indexWhere((y) => y.kind == 'wolf' && E.wolfSod(y.pack) == sod); // 1.6.11 test2: Wolf3D and SOD side by side
    final x = E.Extra(kind: 'wolf', pack: pack, keyMap: {...wolfKeysNow()})..fresh = true;
    if (old < 0 && extras.length >= E.appxMax) {
      toast('At most 12 more emulators.', true);
      return;
    }
    final prev = old >= 0 ? extras[old] : null;
    if (old >= 0) {
      extras[old] = x;
      toast('There is only one Wolfenstein 3D and one Spear of Destiny in the menu, the new one replaces the old one.');
    } else {
      extras.add(x);
    }
    extrasDirty = true;
    final f = await roomFit(), k = f.k;
    if (k != 0 || f.err.isNotEmpty) {
      if (prev != null) {
        extras[extras.indexOf(x)] = prev;
      } else {
        extras = extras.where((y) => !identical(y, x)).toList();
      }
      extrasDirty = true;
      _renderEmu();
      toast(k != 0 ? _noRoomAdd(x, k) : 'More emulators: ${f.err}', true);
      return;
    }
    _renderEmu();
  }

  /// fileT7Fig: figures for a Tama-Go, the main one ([target] null) or entry [target] of the list. [files]: name and
  /// raw file.
  void addFigures(List<(String, Uint8List)> files, [int? target]) {
    final xi = target != null;
    E.Extra? x;
    MainEmu? st;
    List<E.T7Fig> figs;
    if (xi) {
      x = target < extras.length ? extras[target] : null;
      if (x == null || x.kind != null || E.t7Kind(x.rom) != 'go') return;
      figs = x.figs ?? (x.figs = []);
    } else {
      st = t7State();
      if (st == null) return;
      figs = st.figs;
    }
    for (final (fname, raw) in files) {
      if (!E.t7FigDetect(raw)) {
        toast('$fname: not a figure.', true);
        continue;
      }
      final d = E.t7FigData(raw);
      if (figs.length >= 16) {
        toast('No room for more figures.', true);
        break;
      }
      if (figs.any((f) => E.t7FigName(f.name) == E.t7FigName(fname))) {
        toast('${E.t7FigName(fname)} is already in.', true);
        continue;
      }
      if (!xi && E.t7Room([...figs, E.T7Fig(fname, d)], st!.rom!.length) < 0) {
        toast('No room left for ${E.t7FigName(fname)}.', true);
        continue;
      }
      figs.add(E.T7Fig(fname, d));
    }
    if (xi) {
      extrasDirty = true;
      t7saveX = null;
      _renderEmu();
      return;
    }
    st!.size = t7Size(st);
    emu = st;
    emuRemoveClear();
    if (!launch) doom = null;
    _renderDoom();
    _renderEmu();
  }

  /// "Pack the firmware" of the main TamaEmu; an installed one is read back and built anew.
  Future<void> setEmuPack(bool v) async {
    emuPack = v;
    final e = emu;
    if (e != null && e.guest != null) {
      final pk = E.packMain(e.guest!, e.dev, null, v);
      e.size = pk.blob.length;
      e.big = pk.big;
      _renderEmu();
      return;
    }
    if (await mainGuestLoad()) {
      final mg = mainGuest!, pk = E.packMain(mg.g, mg.dev, null, v);
      emu = MainEmu.tama(mg.g, mg.dev, size: pk.blob.length, big: pk.big, kept: true);
      mainGuest = null;
    }
    _renderEmu();
  }

  // ---------------------------------------------------------------- the Names tab (renderNames, spec 2.3)
  /// The rows of the three lists: the name in the ROM, the text numbers it stands in, the longest name allowed.
  ({List<NameRow> fields, List<NameRow> chars, List<NameRow> items}) nameRows() {
    final fields = [for (final f in fieldTextsOf(rom, sixActive())) NameRow(f.name, f.idx, 11)], chars = <NameRow>[], items = <NameRow>[];
    final seen = <int>{};
    try {
      for (final c in C.charTable(ctx!.files[0])) {
        if (!(c.id > 1000 && c.id < 9000) || seen.contains(c.name)) continue;
        final nm = C.textGet(rom, c.name);
        if (nm.isEmpty) continue;
        seen.add(c.name);
        chars.add(NameRow(nm, [c.name], 12));
      }
    } catch (_) {
      /* no character table */
    }
    for (final it in F.itemCatalog(rom).items) {
      if (seen.contains(it.text)) continue;
      final nm = C.textGet(rom, it.text);
      if (nm.isEmpty) continue;
      seen.add(it.text);
      items.add(NameRow(nm, [it.text], 22));
    }
    return (fields: fields, chars: chars, items: items);
  }

  // ---------------------------------------------------------------- settings in the rows of the program list
  /// "Start when switched on" of the main program (mainSet / autoL of renderApps).
  void setMainAuto(bool v) {
    emuAuto = v;
    if (launch) mainDirty = true;
    _renderEmu();
  }

  /// Clock, "remember where you left off", NFC and the options of the main program.
  void setMainClock(bool v) {
    emuClock = v;
    _renderEmu();
  }

  void setMainSess(bool v) {
    emuSess = v;
    _renderEmu();
  }

  void setMainNfc(bool v) {
    emuNfc = v;
    _renderEmu();
  }

  void setMainOpt({int? vol, int? dim, int? off}) {
    emuOpt = E.EmuOpt(vol: vol ?? emuOpt.vol, dim: dim ?? emuOpt.dim, off: off ?? emuOpt.off);
    _renderEmu();
  }

  /// The same for entry [i] of the list (clock, sess, nfc, "Pack the firmware", options).
  void setExtra(int i, {bool? clock, bool? sess, bool? nfc, bool? pack, int? vol, int? dim, int? off}) {
    final x = extras[i];
    if (clock != null) x.clock = clock;
    if (sess != null) x.sess = sess;
    if (nfc != null) x.nfc = nfc;
    if (pack != null) x.packed = pack;
    if (vol != null || dim != null || off != null) {
      final o = x.opt ?? const E.EmuOpt();
      x.opt = E.EmuOpt(vol: vol ?? o.vol, dim: dim ?? o.dim, off: off ?? o.off);
    }
    extrasDirty = true;
    _renderEmu();
  }

  /// "Back from programs" (exitKey select).
  void setExitKey(int v) => exitKey = v;

  // ---------------------------------------------------------------- DOOM: the conversions of a WAD
  /// app.js doomCompute (1.7.3 test17): the conversions of a WAD (and its extra WADs) in one place: the base with
  /// map packs merged, each episode, the whole WAD, and each own episode of an extra WAD (Sigil) as its own entry.
  /// The conversion is [port]'s (doom.js is not ported).
  Future<DoomData> doomCompute(D.DoomPort port, Uint8List w, [List<DoomPwad> pwads = const [], Set<String>? keepSel]) async {
    if (assets.doom == null) throw StateError('This build does not contain the DOOM program.');
    final mapPw = pwads.where((p) => p.eps.isEmpty).toList(), epPw = pwads.where((p) => p.eps.isNotEmpty).toList();
    final wm = mapPw.isNotEmpty ? port.wadMerge(w, [for (final p in mapPw) (data: p.data, slot: false)]) : w;
    final eps = port.wadEpisodes(wm).where((x) => x == 'M' || x.compareTo('4') <= 0).toList();
    if (eps.isEmpty) throw StateError('E1 bis E4 fehlen'); // 1.7.3 test14: E4 (Ultimate DOOM) too
    // Does the episode fit in the ROM? With music, otherwise without.
    // test15 DOOM_PKREG: without the Paradise an episode may be as big as the biggest free piece (0x111000..0xEFD000)
    const big = 0xEFD000 - 0x111000 - 4;
    final free = doomFree(), room = free ? big : D.REGION_OFF - D.WAD_OFF - 4;
    final fit = <String, DoomFit>{}, ok = <String>[];
    final d2 = eps[0] == 'M'; // 1.7.3 test15: DOOM II, only as a whole WAD without the Paradise
    if (d2 && !free) throw StateError('DOOM II only goes into a ROM without the Paradise.');
    Future<DoomFit> one(Uint8List src, String ep, [Set<String>? only]) async {
      Future<Uint8List> conv(bool m) async {
        final sub = port.wadSub(src, ep, m, only);
        return port.convert(sub, port.gbaExtras(sub));
      }

      final cm = await conv(true), sm = cm.length, music = sm <= room;
      final cp = music && !free ? cm : await conv(false), sp = cp.length; // 1.7.3 test13: without the Paradise the version without music too
      return DoomFit(music: music, plain: sp <= room, sizeM: sm, sizeP: sp, mcuM: cm, mcuP: cp); // test3: kept for DOOM in the menu
    }

    for (final ep in d2 ? const <String>[] : eps) {
      fit[ep] = await one(wm, ep);
      if (fit[ep]!.plain) ok.add(ep);
    }
    // 1.7.3 test15: the whole WAD in one piece (without the Paradise; about the size of the WAD instead of the sum of the episodes)
    if (free && (eps.length > 1 || d2)) {
      Future<Uint8List> conv(bool m) async {
        final sub = port.wadSub(wm, eps.join(), m);
        return port.convert(sub, port.gbaExtras(sub));
      }

      final cm = await conv(true), cp = await conv(false);
      fit['all'] = DoomFit(music: cm.length <= big, plain: cp.length <= big, sizeM: cm.length, sizeP: cp.length, mcuM: cm, mcuP: cp);
    }
    // 1.7.3 test17: an own episode of an extra WAD (Sigil E5, Sigil II E6) in the place of E4, its own entry (only without the Paradise)
    final titles = <String, String>{};
    if (free && !d2) {
      for (var i = 0; i < epPw.length; i++) {
        final k = 'P$i', src = port.wadMerge(wm, [(data: epPw[i].data, slot: true)]);
        final f = fit[k] = await one(src, '4');
        titles[k] = epPw[i].title;
        if (f.plain) ok.add(k);
        // 1.7.3 test21 DOOM_LINK: shared with DOOM in the same ROM (pictures, sounds), the room needed is that much less
        if (E.doomLink && f.mcuP != null) {
          Uint8List? ref = fit['all']?.mcuP;
          if (ref == null) {
            for (final e in eps) {
              final m = fit[e]?.mcuP;
              if (m != null && (ref == null || m.length > ref.length)) ref = m;
            }
          }
          if (ref != null) {
            var sv = 0;
            for (final l in E.doomLinks([E.Extra(kind: 'doom', mcu: ref), E.Extra(kind: 'doom', mcu: f.mcuP)]).values) {
              sv += l.saved;
            }
            f.linkSaved = sv;
          }
        }
      }
    }
    // 1.7.3 test17: a DOOM II map pack (one-humanity) also alone, only its maps, as its own entry
    if (free && d2) {
      for (var i = 0; i < mapPw.length; i++) {
        final k = 'Q$i', only = mapPw[i].maps.where((m) => RegExp(r'^MAP\d\d$').hasMatch(m)).toSet();
        if (only.isEmpty || !only.contains('MAP01')) continue; // a new game starts at MAP01
        fit[k] = await one(wm, 'M', only);
        titles[k] = mapPw[i].title;
        if (fit[k]!.plain) ok.add(k);
      }
    }
    final sel = keepSel != null ? keepSel.where(ok.contains).toSet() : ok.take(1).toSet();
    return DoomData(wad: w, wadM: wm, pwads: [...pwads], eps: eps, fit: fit, ok: ok, sel: sel, titles: titles, whole: fit['all']?.plain ?? false, d2: d2);
  }

  // ---------------------------------------------------------------- trial builds (spec 3.3)
  /// test17 ROOM_AUTO: a trial build that also reports other failures, and the room really left afterwards.
  /// k: KB missing for the programs (0: they fit), err: another reason the build failed.
  Future<({int k, String err})> roomTry() async {
    lastRoom = 0;
    lastFree = -1;
    final mute = _mute = _Mute();
    var ok = false;
    try {
      ok = (await composeRaw(this)) != null;
    } catch (e) {
      mute.err = em(e);
    } finally {
      _mute = null;
    }
    if (ok && lastFree >= 0) roomFree = (sig: roomSig(), kb: lastFree);
    return (k: lastRoom, err: !ok && lastRoom == 0 ? (mute.err ?? '?') : '');
  }

  static final Expando<int> _roomIds = Expando('room');
  static int _roomIdN = 0;
  static int _roomId(Object? a) => a == null ? 0 : (_roomIds[a] ??= ++_roomIdN);
  static String _roomContX(E.Extra? x) =>
      x == null ? '' : ['${(x.figs ?? const <E.T7Fig>[]).fold<int>(0, (n, f) => n + f.data.length)}/${(x.figs ?? const <E.T7Fig>[]).length}', _roomId(x.guest), _roomId(x.rom), _roomId(x.fw)].join(':');
  static String _roomContE(MainEmu? x) => x == null ? '' : ['${x.figs.fold<int>(0, (n, f) => n + f.data.length)}/${x.figs.length}', _roomId(x.guest), _roomId(x.rom), 0].join(':');

  /// which programs are in, and which one is the main one (the overview's real free room belongs to that)
  String roomSig() => jsonEncode([
        emu != null ? emuNm(emu!) : '',
        emuRemove,
        doom != null,
        launch,
        [for (final x in extras) E.extraName(x)],
        if (doom != null) doomMusic,
        _roomContE(emu),
        [for (final x in extras) _roomContX(x)],
      ]);

  bool t18Here() =>
      (emu != null && (emu!.t18 || emu!.guest != null)) || extras.any((x) => E.extraKind(x) == 't18' || E.extraKind(x) == 'tama') || (emuInstalled() && RegExp('t18|tama').hasMatch(F.emuType(rom)));

  /// test25 T18_FEW: when the programs do not fit, it is tried again with 6 spare blocks for T18Emu and 256 KB for
  /// each TamaEmu before saying "no room".
  Future<({int k, String err})> roomFit() async {
    final r = await roomFit1();
    if (r.k == 0 || t18Few || !t18Here()) return r;
    t18Few = true;
    final r2 = await roomFit1();
    if (r2.k == 0 && r2.err.isEmpty) return r2;
    t18Few = false;
    return r;
  }

  /// test17: in a start device the first program (at 0x0A0000) changes how much room the others need. When the
  /// choice does not fit, every other program is tried as the first one; the smallest shortfall is reported.
  Future<({int k, String err})> roomFit1() async {
    final m0 = await roomTry();
    if (m0.k == 0 && m0.err.isEmpty) return (k: 0, err: '');
    if (!launch) return (k: m0.k, err: ''); // outside a start device only the room counts (the menu may still be off)
    if (doomMain() || clean) return m0;
    final snap = _snap();
    int? best = m0.k != 0 ? m0.k : null;
    final err = m0.err;
    final names = [for (final x in snap.extras) E.extraName(x)];
    for (var i = 0; i < snap.extras.length; i++) {
      if (!canMain(snap.extras[i])) continue;
      _back(snap);
      _mute = _Mute();
      try {
        await makeMain(i);
      } finally {
        _mute = null;
      }
      final m = await roomTry();
      if (m.k == 0 && m.err.isEmpty) {
        toast('${names[i]} is now the first entry of the menu, only this way everything fits.');
        _renderEmu();
        return (k: 0, err: '');
      }
      if (m.k != 0 && (best == null || m.k < best)) best = m.k;
    }
    _back(snap);
    _renderEmu();
    return best != null ? (k: best, err: '') : (k: 0, err: err);
  }

  // ---------------------------------------------------------------- packed firmwares (spec 3, step 3)
  /// 1.7.5 PACK_WARN: a packed colour Tama runs slower, so saving or writing a ROM with one asks first: the names
  /// of the firmwares that end up packed in [built] (the page then asks "Note: the firmware of {n} gets packed ...").
  List<String> packedTamas(Uint8List built) {
    final l = <String>[], mc = romEmuCfg(built);
    if (mc != null && E.lzCount(built, mc.lzOff) > E.packFew) l.add(E.tamaName(emu?.guest, mc.dev));
    final f = fe != null ? F.feldFind(built, fe!.stub) : null;
    if (f != null) l.addAll(E.appsPacked(built, _entries(F.feldApps(built, fe!.stub).apps)));
    return l;
  }

  /// PACK_WARN: the main TamaEmu packs 2 or 3 rarely read blocks (room for its own writes).
  bool mainFew() {
    if (emuPack) return false; // packed by choice: the checkbox says it
    final e = emu;
    if (e != null) {
      if (e.guest == null || e.v1 || e.t7 || e.t18 || !E.devices.containsKey(e.dev)) return false;
      try {
        return (E.packMain(e.guest!, e.dev, null, false).lzBlocks ?? 0) > 0;
      } catch (_) {
        return false;
      }
    }
    if (emuRemove) return false;
    final c = romEmuCfg(rom);
    return c != null && c.lzOff != 0 && E.lzCount(rom, c.lzOff) > 0;
  }

  // ---------------------------------------------------------------- the overview (spec 3.4)
  String groupSig(String g) => jsonEncode([
        for (final x in extras)
          if (groupKind(x.kind) == g) [E.extraName(x), x.keys ?? x.keyMap, x.inv, x.clock, x.nfc, _optJson(x.opt), x.sess != false]
      ]);

  String _oldNm() {
    final n0 = fe != null ? F.feldApps(rom, fe!.stub).name0 : '';
    if (n0.isNotEmpty) return n0;
    final n = mainName(rom);
    return n.isNotEmpty ? n : 'EMU';
  }

  /// The name of the installed main program as the list shows it.
  String installedName() => _oldNm();

  PlanChip _planEmus(bool emuOn, int kind) {
    final em = emu, xs = extras;
    final mainNm = em != null ? emuNm(em) : (emuOn ? _oldNm() : '');
    final v = <(String, bool)>[];
    if (mainNm.isNotEmpty) v.add((mainNm, !doomMain())); // with DOOM as the main program the emulator goes to the menu
    if (em == null && kind == 2 && emuRemove && !paraMainTaken) v.add(('${_oldNm()} will be removed', false));
    for (final x in xs.where((x) => !OWN_CHIP.contains(x.kind) && x.kind != 'doom')) {
      v.add(('${v.isNotEmpty ? ', ' : ''}${E.extraName(x)}', false));
    }
    if (v.isEmpty) return PlanChip.text('Emulators', 'not included', 'off');
    final isNew = em != null || xs.any((x) => !OWN_CHIP.contains(x.kind) && x.fresh) || (extrasDirty && groupSig('emu') != sig0['emu']);
    final upd = emuUpPending() || emuAutoDirty() || (extrasUp?.contains('emu') ?? false), gone = em == null && kind == 2 && emuRemove;
    if (isNew || upd || !gone) v.add((' · ${isNew ? 'new' : (upd ? 'gets updated' : 'stays')}', false));
    return PlanChip('Emulators', v, isNew || upd ? 'new' : (gone ? 'del' : 'keep'));
  }

  PlanChip _planWolf() {
    final xs = extras.where((y) => y.kind == 'wolf').toList();
    if (xs.isEmpty) return PlanChip.text('Wolfenstein 3D', wolfInit ? 'will be removed' : 'not included', wolfInit ? 'del' : 'off');
    final what = xs.map((x) {
      final inf = E.wolfInfo(x.pack);
      final sod = inf?.sod ?? false, share = inf?.shareware ?? true, eps = inf?.episodes ?? 1;
      return sod ? 'Spear of Destiny' : '${share ? 'Shareware' : 'Full version'}${eps > 1 ? ', $eps episodes' : ''}';
    }).join(' + ');
    final fresh = xs.any((x) => x.fresh);
    return PlanChip.text('Wolfenstein 3D', '${fresh ? 'new' : (wolfKeysDirty ? 'gets updated' : 'stays')}, $what', fresh || wolfKeysDirty ? 'new' : 'keep');
  }

  PlanChip _planGroup(String g, String label) {
    final xs = extras.where((x) => x.kind == g).toList(), s0 = sig0[g], was = s0 != null && s0.isNotEmpty && s0 != '[]';
    if (xs.isEmpty) return PlanChip.text(label, was ? 'will be removed' : 'not included', was ? 'del' : 'off');
    final isNew = xs.any((x) => x.fresh), upd = !isNew && (groupSig(g) != s0 || (extrasUp?.contains(g) ?? false));
    return PlanChip.text(label, '${xs.map(E.extraName).join(', ')} · ${isNew ? 'new' : (upd ? 'gets updated' : 'stays')}', isNew || upd ? 'new' : 'keep');
  }

  /// test18: what the DOOM chip of the overview says: the episodes, the own entries of extra WADs (Sigil) and the
  /// map packs in it (one-humanity)
  String doomChip(DoomData d) {
    final sel = d.ok.where((e) => d.sel.contains(e)).toList(), base = sel.where((e) => !_isPQ(e)).toList();
    final own = sel.where(_isPQ).map((e) => d.titles[e] ?? '');
    final main = d.d2 ? (d.whole ? 'DOOM II' : '') : (d.whole ? 'E${d.eps.join(', E')}' : (base.isNotEmpty ? 'E${base.join(', E')}' : ''));
    final packs = d.pwads.where((p) => p.eps.isEmpty).map((p) => p.title).toList();
    return [main.isNotEmpty && packs.isNotEmpty && (d.whole || base.isNotEmpty) ? '$main (${packs.join(', ')})' : main, ...own].where((s) => s.isNotEmpty).join(', ');
  }

  /// The usage summary of renderPlan: chips, the flash bar's segments, warnings and the rule line.
  Plan plan() {
    final kind = appInstalled();
    final emuOn = emu != null || (kind == 2 && !emuRemove && doom == null);
    final doomOn = doom != null || (doomFree() && doomXs().isNotEmpty) || (kind == 1 && !emuRemove && (emu == null || launch));
    final menuOld = fe != null ? F.feldFind(rom, fe!.stub) : null;
    final d = doom;
    final chips = <PlanChip>[
      PlanChip.text('Characters', changed.isNotEmpty ? '${changed.length} changed' : 'unchanged', changed.isNotEmpty ? 'new' : 'keep'),
      _planEmus(emuOn, kind),
      _planGroup('gb', 'Game Boy'),
      _planGroup('sms', 'Master System / Game Gear'),
      _planGroup('pm', 'Pokémon mini'),
      _planGroup('ab', 'Arduboy'),
      _planWolf(),
    ];
    {
      final extra = d != null ? '${doomFree() ? doomChip(d) : 'E$doomEp'}${doomMusic ? ' + Music' : ''}' : '';
      final st = doomOn ? '${d != null ? 'new' : 'stays'}${extra.isNotEmpty ? ', $extra' : ''}' : (kind == 1 ? 'will be removed' : 'not included');
      chips.add(PlanChip.text('DOOM', st, d != null ? 'new' : (doomOn ? 'keep' : (kind == 1 ? 'del' : 'off'))));
    }
    final menuOn = menuWanted();
    final parts = [
      if (launch) 'Start device',
      if (feld) 'Several saves (with field choice)',
      if (bag) 'Items and Tamapoints',
      if (tama) 'Change Tama (level, care, character)',
      if (gplay) 'Play time earns Tamapoints',
    ].join(', ');
    final menuSame = feld == feldInit && bag == bagInit && tama == tamaInit && gplay == gplayInit && saves == savesInit && launch == launchInit;
    if (clean) chips[0] = PlanChip.text('Characters', 'Without the Paradise (clean ROM)', cleanInit ? 'keep' : 'new');
    chips.add(PlanChip.text('Menu', menuOn ? '$parts${feldStale && menuSame ? ' (gets updated)' : ''}' : (menuOld != null ? 'will be removed' : 'not included'),
        menuOn ? ((menuSame && !feldStale) ? 'keep' : 'new') : (menuOld != null ? 'del' : 'off')));
    final sixIn = S6.sixInfo(rom) != null;
    {
      final n = {...eyeShift.keys, ...mouthShift.keys, ...poseAdj.keys}.length;
      if (n != 0) chips.add(PlanChip.text('Eyes and mouth', '$n changed', 'new'));
    }
    if (texts.isNotEmpty) chips.add(PlanChip.text('Names', '${texts.length} changed', 'new'));
    if (sixIn || six != null || sixWant) chips.add(PlanChip.text('More fields', sixIn ? 'stays' : 'new', sixIn ? 'keep' : 'new'));
    // Flash: from 0x111000 to the end
    final base = clean ? 0x10000 : 0x111000;
    const end = 0x1000000;
    final total = end - base, segs = <PlanSeg>[];
    final assetsN = clean ? 0 : estimateEnd() - base + (six != null && !sixIn ? 0xB9000 : 0);
    if (assetsN != 0) segs.add(PlanSeg('fw', 'Firmware and characters', assetsN));
    var doomSize = 0, emuSize = 0;
    if (doomFree()) {
      doomSize = doomXs().fold(0, (n, x) => n + E.extraSize(x));
    } else if (d != null) {
      doomSize = doomEpSize(d.fit[doomEp]) + (0xD48000 - 0xCA0000);
    } else if (doomOn) {
      doomSize = rd32(rom, 0x830000).toSigned(32) + (0xD48000 - 0xCA0000);
    }
    if (emu != null) {
      emuSize = emu!.size;
    } else if (emuOn) {
      final c7 = E.t7Cfg(rom), c18 = E.t18Cfg(rom);
      if (c18 != null) {
        emuSize = c18.map.where((b) => b != 0xFFFF).length << 16;
      } else if (c7 != null) {
        emuSize = c7.romLen + c7.figs.fold(0, (n, f) => n + f.len);
      } else {
        emuSize = rd32(rom, 0xA0000 + 0x140 + 12).toSigned(32);
      }
    }
    final gs = {'wolf': 0, 'gb': 0, 'sms': 0, 'pm': 0, 'ab': 0};
    for (final x in extras) {
      if (x.kind == 'doom') continue;
      if (OWN_CHIP.contains(x.kind)) {
        gs[x.kind!] = gs[x.kind]! + E.extraSize(x);
      } else {
        emuSize += E.extraSize(x); // more emulators: program, save, data
      }
    }
    if (doomOn) segs.add(PlanSeg('doom', 'DOOM', doomSize));
    if (emuOn || extras.any((x) => !OWN_CHIP.contains(x.kind))) segs.add(PlanSeg('emu', 'Emulator', emuSize));
    if (gs['gb'] != 0) segs.add(PlanSeg('gb', 'Game Boy', gs['gb']!));
    if (gs['sms'] != 0) segs.add(PlanSeg('sms', 'Master System / Game Gear', gs['sms']!));
    if (gs['pm'] != 0) segs.add(PlanSeg('pm', 'Pokémon mini', gs['pm']!));
    if (gs['ab'] != 0) segs.add(PlanSeg('ab', 'Arduboy', gs['ab']!));
    if (gs['wolf'] != 0) segs.add(PlanSeg('wolf', 'Wolfenstein 3D', gs['wolf']!));
    if (feld && !doomOn) {
      final ed = F.edition(rom);
      segs.add(PlanSeg('slots', 'Field saves', ed != null ? ed.profile.fields.length * 0x58000 : 0));
    }
    // NEON_BAR: Neon Planets: its save lies between 0xD80000 and 0xF00000 (programs may use the MB behind it)
    final neonBar = !clean && ctx != null && SV.family(ctx!.editionId) == 'neon';
    final save = clean ? 0 : (neonBar ? 0xF00000 - 0xD80000 : (launch ? 0xF00000 : end) - 0xD29000);
    if (save != 0) segs.add(PlanSeg('save', 'Save', save));
    if (neonBar) segs.add(PlanSeg('resv', 'reserved', 0x10000)); // the rescue start's block
    var used = segs.fold<int>(0, (a, x) => a + x.size);
    // test17 ROOM_REAL: in a start device the free part is what the last trial build really left
    final rfOk = launch && roomFree != null && roomFree!.sig == roomSig();
    final rf = rfOk && roomFree!.kb >= 0 ? roomFree!.kb * 1024 : -1;
    var trial = false;
    if (rf >= 0) {
      final fix = total - used - rf;
      PlanSeg? e;
      for (final x in segs) {
        if (x.key == 'emu') {
          e = x;
          break;
        }
      }
      if (fix > 0) {
        segs.add(PlanSeg('resv', 'reserved', fix));
      } else if (e != null) {
        e.size = e.size + fix > 0 ? e.size + fix : 0;
      }
      used = total - rf;
    } else if (launch && !rfOk) {
      trial = true;
    }
    segs.add(PlanSeg('free', 'free', total - used > 0 ? total - used : 0));
    final warn = <String>[];
    if (oldT7.isNotEmpty) warn.add('${oldT7.join(', ')}: old version, the save can be lost when the battery is changed. Write it again now with "Keep saves".');
    if (t18Broken && extras.any((x) => x.kind == 't18' && x.keepOff != null)) warn.add('Tama Meets is damaged. Remove Tama Meets and add the firmware again, then write without "Keep saves".');
    final rule = clean
        ? 'Without the Paradise: all programs go to the menu, almost the whole flash is theirs.'
        : launch
            ? 'Start device: emulators and DOOM fit together as long as there is room.'
            : appRoom()
                ? 'Emulator or DOOM: only one of the two fits into the ROM. The menu works with both.'
                : 'This edition has no room for emulator and DOOM (its character data is larger). The menu works.';
    return Plan(chips, segs, total, warn, rule, trial);
  }

  /// app.js baseName(): the loaded name without extension and without the endings the Studio adds.
  String baseName() => name.replaceFirst(RegExp(r'\.[^.]+$'), '').replaceFirst(RegExp(r'(_paramix|_emu|_t7|_t18|_doom_E\d|_felder|_fields|_4fields|_6fields|_items|_start|_clean)+$'), '');
}

class _Snap {
  _Snap(this.emu, this.extras, this.emuRemove, this.mainPick, this.emuOpt, this.mainGuest);
  final MainEmu? emu;
  final List<E.Extra> extras;
  final bool emuRemove;
  final Object? mainPick;
  final E.EmuOpt emuOpt;
  final ({Uint8List g, String dev})? mainGuest;
}
