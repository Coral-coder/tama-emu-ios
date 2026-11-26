// Check of lib/paramix/build_state.dart and compose_full.dart against the Studio's page (tool/paramix_check/compose.js,
// which runs the real app.js under jsdom).
//   DUMPS=<folder with water.bin ...> dart run tool/paramix_check/compose_check.dart [shard/of]
// Prints one line per step that has a result: "<case> <step>: <value>", the same lines as compose.js. The cases are
// in compose_cases.json, the steps are explained in compose_cases.md. Each step does with BuildState what the page's
// handler behind the control does.

// ignore_for_file: avoid_print, non_constant_identifier_names, library_prefixes, constant_identifier_names

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tama_tools/paramix/build_state.dart';
import 'package:tama_tools/paramix/compose_full.dart';
import 'package:tama_tools/paramix/core_more.dart' as C;
import 'package:tama_tools/paramix/doom_port.dart' as D;
import 'package:tama_tools/paramix/emu_build.dart' as E;
import 'package:tama_tools/paramix/feld.dart' as F;
import 'package:tama_tools/paramix/six.dart' as S6;

import 'compose_syn.dart' as S;

late final String ps;
Uint8List bin(String f) => File('$ps/$f').readAsBytesSync();
String sha(List<int> b) => sha256.convert(b).toString();
String shaS(String s) => sha256.convert(utf8.encode(s)).toString().substring(0, 16);
String H(Uint8List? b) => b == null ? '-' : '${b.length}:${sha(b).substring(0, 16)}';
String bo(bool? v) => v == null ? '-' : (v ? '1' : '0');
Uint8List ascii(String s) => Uint8List.fromList(latin1.encode(s));
String str(Uint8List b) => latin1.decode(b);

final dumps = <String, Uint8List>{};
Uint8List dump(String n) => dumps[n] ??= File('${Platform.environment['DUMPS']}/$n.bin').readAsBytesSync();

// ------------------------------------------------------------ synthetic inputs by a short text
final synMemo = <String, Uint8List>{};
Uint8List syn(String spec) {
  final m = synMemo[spec];
  if (m != null) return m;
  final p = spec.split(':');
  int n(int i) => int.parse(p[i]);
  Uint8List b;
  switch (p[0]) {
    case 'tama':
      b = S.tamaFw(p[1], n(2), n(3));
    case 't7':
      b = S.t7Rom(p[1] == 'friends', n(2));
    case 't18':
      b = S.t18Fw(n(1), p[2] == '1', n(3));
    case 'v1':
      b = S.v1Rom(n(1), n(2));
    case 'v3':
      b = S.v3Rom(n(1));
    case 'gb':
      b = S.gbRom(n(1), n(2), p[3], n(4));
    case 'sms':
      b = S.smsRom(n(1), n(2), n(3));
    case 'pm':
      b = S.pmRom(n(1), n(2));
    case 'pmbios':
      b = S.pmBios(n(1));
    case 'ab':
      b = ascii(S.abHexText(S.rndBytes(n(1), n(2)), '\n'));
    case 'wolf':
      b = S.wolfPack(n(1), n(2), n(3));
    case 'fig':
      b = S.t7Fig(n(1), n(2), n(3));
    case 'wad':
      b = ascii('FAKEWAD ${p.sublist(1).join(' ')}'); // episodes, KB with music, KB without, seed
    case 'rnd':
      b = S.rndBytes(n(1), n(2));
    case 'junk':
      b = S.rndBytes(n(1), n(2));
      b[0] = 0x12;
    default:
      throw ArgumentError('syn $spec');
  }
  return synMemo[spec] = b;
}

/// the synthetic converter: a "WAD" is the text `FAKEWAD episodes KB-with-music KB-without seed`
class FakeDoom implements DoomPort {
  @override
  List<String> wadEpisodes(Uint8List w) => str(w).split(' ')[1].split('');
  @override
  Uint8List wadMerge(Uint8List base, List<({Uint8List data, bool slot})> pw) => base;
  @override
  Uint8List wadSub(Uint8List src, String eps, bool music, [Set<String>? only]) {
    final q = str(src).split(' ');
    return ascii(['FAKESUB', eps, music ? 1 : 0, q[2], q[3], q[4]].join(' '));
  }

  @override
  Uint8List gbaExtras(Uint8List wad) => Uint8List(0);
  @override
  Future<Uint8List> convert(Uint8List sub, Uint8List extras) async {
    final q = str(sub).split(' '), eps = q[1].split(''), music = q[2] == '1', kb = int.parse(music ? q[3] : q[4]), seed = int.parse(q[5]);
    final lumps = <(String, Uint8List)>[('PLAYPAL', S.rndBytes(768, seed)), ('COLORMAP', S.rndBytes(34 * 256, seed + 1))];
    for (final e in eps) {
      final c = e.codeUnitAt(0);
      lumps.addAll([(e == 'M' ? 'MAP01' : 'E${e}M1', Uint8List(0)), ('THINGS', S.rndBytes(300, seed + 10 + c)), ('DATA$e', S.rndBytes(kb * 1024, seed + 20 + c + (music ? 100 : 0)))]);
    }
    lumps.add(('TEX1', S.rndBytes(0x8000, seed + 2)));
    return S.doomWad(lumps);
  }
}

late final BuildAssets assets;
late final BuildAssets assetsNoPort;

// ------------------------------------------------------------ what the state looks like
String keysJ(Object? k) => k == null ? '-' : (k is List ? k.join('.') : jsonEncode(k));
String figsS(List<E.T7Fig>? f) => f == null ? '-' : f.map((x) => '${x.name}:${H(x.data)}').join(',');
String xStr(E.Extra x) {
  final k = E.extraKind(x);
  return [
    k,
    E.extraName(x),
    H(x.rom ?? x.guest ?? x.fw ?? (x.kind == 'wolf' ? x.pack : null) ?? x.mcu),
    'figs=${figsS(x.figs)}',
    'keys=${keysJ(x.keys ?? x.keyMap)}',
    'inv=${bo(x.inv)}',
    'clock=${bo(x.clock)}',
    'nfc=${bo(x.nfc)}',
    'sess=${bo(x.sess)}',
    'opt=${x.opt != null ? [x.opt!.vol, x.opt!.dim, x.opt!.off].join('/') : '-'}',
    'pack=${bo(x.kind == 'tama' ? x.packed : null)}',
    'keepOff=${x.keepOff == null ? '-' : x.keepOff!.toRadixString(16)}',
    'title=${x.title != null && x.title!.isNotEmpty ? x.title : '-'}',
    'gg=${bo(x.gg)}',
    'save=${H(x.save)}',
    'bios=${H(x.bios)}',
    'region=${x.region != null && x.region != 0 ? x.region : '-'}',
    'ep=${x.ep ?? '-'}',
    'size=${x.kind == 'doom' ? (x.size != null && x.size != 0 ? x.size : '-') : '-'}',
    'fresh=${bo(x.fresh)}',
    'para=${bo(x.fromPara)}${bo(x.fromParaMain)}',
    'carry=${bo(x.carry)}',
    'keys0=${x.keys0 ?? '-'}',
    'wad=${bo(x.wadSrc != null)}'
  ].join(' ');
}

List<String> stateLines(BuildState s) {
  final o = <String>[];
  void m(String name, Object v) => o.add('$name $v');
  final c = s.ctx;
  m(
      'ctx',
      c == null
          ? 'clean ed=${s.edition}'
          : ['ed=${c.edition}', 'id=${c.editionId}', 'entries=${c.entries.length}', 'groups=${c.groups.length}', 'adult=${c.adult}', 'egg=${c.egg}', 'limit=${c.limit.toRadixString(16)}', 'assetEnd=${c.assetEnd.toRadixString(16)}'].join(' '));
  final ck = s.changed.keys.toList()..sort();
  m('changed', '${s.changed.length}:${shaS(ck.map((i) => '$i=${H(s.changed[i])}').join(','))}');
  m(
      'flags',
      [
        'clean=${bo(s.clean)}${bo(s.cleanInit)}',
        'launch=${bo(s.launch)}${bo(s.launchInit)}',
        'feld=${bo(s.feld)}${bo(s.feldInit)}',
        'bag=${bo(s.bag)}${bo(s.bagInit)}',
        'tama=${bo(s.tama)}${bo(s.tamaInit)}',
        'gplay=${bo(s.gplay)}${bo(s.gplayInit)}',
        'saves=${bo(s.saves)}',
        'exit=${s.exitKey}/${s.exitKeyInit}',
        'six=${bo(s.sixPlanet)}${bo(s.sixMenu)}${bo(s.sixWant)}${bo(s.sixOff)}${bo(s.six != null)}',
        'stale=${bo(s.feldStale)}',
        'cleanClock=${bo(s.cleanClock)}',
        't18Few=${bo(s.t18Few)}',
        'paraMain=${bo(s.paraMainTaken)}'
      ].join(' '));
  final em = s.emu;
  m('emu', em == null ? '-' : [em.v1 ? 'v1' : (em.t7 ? 't7' : (em.t18 ? 't18' : 'tama')), em.dev, H(em.guest ?? em.rom), 'size=${em.size}', 'big=${bo(em.big)}', 'kept=${bo(em.kept)}', 'figs=${em.t7 ? figsS(em.figs) : '-'}'].join(' '));
  final mp = s.mainPick;
  m(
      'main',
      [
        'remove=${bo(s.emuRemove)}',
        'pack=${bo(s.emuPack)}',
        'auto=${bo(s.emuAuto)}',
        'clock=${bo(s.emuClock)}',
        'sess=${bo(s.emuSess)}',
        'nfc=${bo(s.emuNfc)}',
        'opt=${[s.emuOpt.vol, s.emuOpt.dim, s.emuOpt.off].join('/')}',
        'pick=${mp == BuildState.pickEmu ? 'emu' : (mp != null ? s.extras.indexOf(mp as E.Extra) : '-')}',
        'mainDirty=${bo(s.mainDirty)}',
        'guest=${bo(s.mainGuest != null)}'
      ].join(' '));
  m('extras', ['n=${s.extras.length}', 'dirty=${bo(s.extrasDirty)}', 'up=${s.extrasUp != null ? (s.extrasUp!.toList()..sort()).join(',') : '-'}', 'wolf=${bo(s.wolfInit)}${bo(s.wolfKeysDirty)}', 'oldT7=${s.oldT7.join(',')}', 't18Broken=${bo(s.t18Broken)}'].join(' '));
  for (var i = 0; i < s.extras.length; i++) {
    m('x$i', xStr(s.extras[i]));
  }
  final d = s.doom;
  final fk = d == null ? <String>[] : (d.fit.keys.toList()..sort());
  m(
      'doom',
      '${d == null ? '-' : ['eps=${d.eps.join()}', 'ok=${d.ok.join(',')}', 'sel=${(d.sel.toList()..sort()).join(',')}', 'whole=${bo(d.whole)}', 'd2=${bo(d.d2)}', 'fit=${fk.map((k) => '$k:${bo(d.fit[k]!.music)}${bo(d.fit[k]!.plain)}:${d.fit[k]!.sizeM}:${d.fit[k]!.sizeP}').join(',')}'].join(' ')}'
          ' keys=${s.doomKeys != null ? jsonEncode(s.doomKeys) : '-'} ep=${s.doomEp} music=${bo(s.doomMusic)}');
  String g(List<int>? k, bool? inv) => k != null ? '${k.join('.')}/${bo(inv)}' : '-';
  m('games', ['gb=${g(s.gbKeys, s.gbInv)}', 'sms=${g(s.smsKeys, s.smsInv)}', 'pm=${g(s.pmKeys, s.pmInv)}', 'ab=${g(s.abKeys, s.abInv)}', 'bios=${H(s.pmBios)}', 'wolf=${s.wolfKeys != null ? jsonEncode(s.wolfKeys) : '-'}'].join(' '));
  final tk = s.texts.keys.toList()..sort();
  m('texts', tk.isEmpty ? '-' : tk.map((i) => '$i=${s.texts[i]}').join('|'));
  final nk = s.charNames.keys.toList()..sort();
  m('fields', '${s.fields.length}:${shaS(jsonEncode([for (final f in s.fields) f.toJson()]))} names=${nk.length}:${shaS(nk.map((g) => '$g=${s.charNames[g]}').join('|'))}');
  m('room', s.roomFree != null ? 'kb=${s.roomFree!.kb}' : '-');
  return o;
}

// ------------------------------------------------------------ the steps
const optU = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0]; // the brightness select: 5 % .. 100 %

Future<void> run(String name, List steps, List<String> out) async {
  BuildState? s0;
  Uint8List? last;
  var lastName = '';
  final port = FakeDoom();
  var useAssets = assets;
  void say(int i, String op, Object v) => out.add('$name $i $op: ${'$v'.replaceAll('\n', ' | ')}');
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i] as List, op = step[0] as String, a = step.sublist(1);
    final confirms = <String>[];
    s0?.confirm = (q) {
      confirms.add(q);
      return true;
    };
    final n0 = s0?.messages.length ?? 0;
    final sBefore = s0;
    Object? res;
    BuildState st() => s0!;
    void load(Uint8List buf, String fname) {
      try {
        s0 = BuildState.load(buf, useAssets, name: fname);
        final s = s0!;
        s.messages.add(BuildMessage(s.ctxClean ? 'ROM without the Paradise (${s.edition}) loaded: ${s.extras.length} programs.' : '${s.edition} loaded: ${s.ctx!.entries.length} sprites, ${s.ctx!.groups.length} characters.'));
      } on ComposeError catch (e) {
        s0?.messages.add(BuildMessage(e.message, true));
      }
    }

    switch (op) {
      case 'open':
        load(dump(a[0] as String), a.length > 1 ? a[1] as String : '${a[0]}.bin');
      case 'openSyn':
        load(syn(a[0] as String), 'x.bin');
      case 'reopen':
        if (last == null) {
          res = 'nothing built';
        } else {
          load(last, lastName);
        }
      case 'set':
        final s = st(), v = a[1];
        final fe = s.fe, ed = F.edition(s.rom), la = s.launch;
        // the page's disabled states of the Menu tab (renderFeld)
        bool off;
        switch (a[0]) {
          case 'feld':
            off = fe == null || !F.canFields(s.rom) || la;
            if (!off) s.feld = v as bool;
          case 'bag':
            off = fe == null || ed == null || la;
            if (!off) s.bag = v as bool;
          case 'tama':
            off = fe == null || ed == null || la;
            if (!off) s.tama = v as bool;
          case 'gplay':
            off = fe == null || ed == null || la || s.clean || s.ctxClean;
            if (!off) s.gplay = v as bool;
          case 'launch':
            off = fe == null || ed == null || s.ctxClean || (s.launchInit && C.isLauncher(s.ctx!)) || S6.sixInfo(s.rom) != null;
            if (!off) await s.setLaunch(v as bool);
          case 'clean':
            off = fe == null || ed == null || s.ctxClean || s.assets.flash == null || !s.cleanCan();
            if (!off) await s.setClean(v as bool);
          case 'cleanClock':
            off = false;
            s.setCleanClock(v as bool);
          case 'sixOn':
            off = fe == null || s.assets.six == null;
            if (!off) s.setSixOn(v as bool);
          case 'sixPlanet':
            off = fe == null || s.assets.six == null;
            if (!off) s.sixPlanet = v as bool;
          case 'sixMenu':
            off = fe == null || s.assets.six == null;
            if (!off) s.sixMenu = v as bool;
          case 'exit':
            off = false;
            s.setExitKey(v as int);
          default:
            throw ArgumentError('set ${a[0]}');
        }
        if (off) res = 'disabled';
      case 'sixSrc':
        st().setSixSource(dump(a[0] as String), '${a[0]}.bin');
      case 'sixBad':
        st().setSixSource(syn(a[0] as String), 'x.bin');
      case 'name':
        final rows = st().nameRows(), l = a[0] == 'fields' ? rows.fields : (a[0] == 'chars' ? rows.chars : rows.items), k = a[1] as int;
        if (k >= l.length) {
          res = 'norow';
        } else {
          final r = l[k], v = C.textClean(a[2] as String);
          st().setName(r.idx, r.name, a[2] as String);
          res = v != null && v.isNotEmpty && v != r.name ? v : r.name;
        }
      case 'names':
        final rows = st().nameRows();
        res = [rows.fields, rows.chars, rows.items].map((l) => '${l.length}:${shaS(l.map((r) => '${r.name}/${r.max}').join('|'))}').join(' ');
      case 'fw':
        await st().chooseFirmware(syn(a[0] as String), a.length > 1 ? a[1] as String : 'fw.bin');
      case 'gb':
        final g = syn(a[0] as String), f = a.length > 1 ? a[1] as String : 'game.gb';
        if (!E.gbDetect(g)) {
          st().toast('$f: not a Game Boy game', true);
        } else {
          await st().addExtra(g, f);
        }
      case 'sms':
        final g = syn(a[0] as String), f = a.length > 1 ? a[1] as String : 'game.sms';
        if (!E.smsDetect(g, f)) {
          st().toast('$f: not a Master System or Game Gear game', true);
        } else {
          await st().addExtra(g, f);
        }
      case 'pm':
        final g = syn(a[0] as String), f = a.length > 1 ? a[1] as String : 'game.min';
        if (E.pmBiosDetect(g)) {
          st().setPmBios(g);
        } else if (E.pmTooBig(g)) {
          st().toast('$f: bigger than 1 MB, that does not work', true);
        } else if (!E.pmDetect(g)) {
          st().toast('$f: not a Pokémon mini game', true);
        } else {
          st().pmBiosNow();
          await st().addExtra(g, f);
        }
      case 'ab':
        final raw = syn(a[0] as String), f = a.length > 1 ? a[1] as String : 'game.hex';
        if (RegExp(r'\.hex$', caseSensitive: false).hasMatch(f)) {
          final b = E.abHex(raw);
          if (b == null) {
            st().toast(raw.length > 0x16000 ? '$f: too big for the Arduboy' : '$f: not an Arduboy game', true);
          } else {
            await st().addArduboy(b, f);
          }
        }
      case 'wolf':
        await st().addWolf(syn(a[0] as String));
      case 'wad':
        final s = st();
        // fileWad: DOOM_LAUNCH: without room at 0x0A0000 DOOM goes only into the menu of a start device
        if (!s.ctxClean && !s.launch && !s.a0Free()) {
          s.toast('In this edition DOOM works in a start device only (Menu tab).', true);
        } else {
          try {
            s.setDoom(await s.doomCompute(port, syn(a[0] as String)));
          } catch (e) {
            s.doom = null;
            s.toast('WAD not recognised: ${em(e)}', true);
            s.sync();
          }
        }
      case 'doomEp':
        st().setDoomEp(a[0] as String);
      case 'doomMusic':
        final s = st(), d = s.doom;
        // renderDoom: the box is disabled without a conversion that has room for the music
        DoomFit? fm;
        if (d != null) {
          final multi = s.doomFree() && (d.ok.length > 1 || d.ok.any((e) => e.startsWith('P') || e.startsWith('Q')) || (d.fit['all']?.plain ?? false));
          if (multi) {
            if (d.whole) {
              fm = d.fit['all'];
            } else {
              for (final e in d.ok) {
                if (d.sel.contains(e) && d.fit[e]!.music) {
                  fm = d.fit[e];
                  break;
                }
              }
            }
          } else {
            fm = d.fit[s.doomEp];
          }
        }
        if (fm == null || !fm.music) {
          res = 'disabled';
        } else {
          s.setDoomMusic(a[0] as bool);
        }
      case 'doomSel':
      case 'doomWhole':
        final s = st(), d = s.doom;
        final multi = d != null && s.doomFree() && (d.ok.length > 1 || d.ok.any((e) => e.startsWith('P') || e.startsWith('Q')) || (d.fit['all']?.plain ?? false));
        if (!multi) {
          res = 'nocontrol';
        } else if (op == 'doomWhole') {
          if (d.fit['all'] == null) {
            res = 'nocontrol';
          } else if (d.d2) {
            res = 'disabled';
          } else {
            d.whole = a[0] as bool;
            s.doomSelChanged();
          }
        } else {
          final e = a[0] as String, pq = e.startsWith('P') || e.startsWith('Q');
          if (!d.ok.contains(e) || (d.whole && !pq)) {
            res = 'nocontrol';
          } else {
            if (a[1] as bool) {
              d.sel.add(e);
            } else {
              d.sel.remove(e);
            }
            s.doomSelChanged();
          }
        }
      case 'doomKeys':
        final s = st();
        if (s.doomKeys == null) {
          res = 'hidden';
        } else {
          s.setDoomKeys({for (final e in (a[0] as Map).entries) e.key as String: e.value as Object});
          res = 'check=${D.doomKeysCheck(s.doomKeys!)}';
        }
      case 'doomOff':
        final s = st(), d = s.doom;
        final has = s.doomFree() ? s.doomXs().any((x) => x.wadSrc == null) : s.doomInstalled();
        if (s.doomFree() ? s.doomXs().isEmpty : (!has || s.emuRemove || d != null)) {
          res = 'hidden';
        } else {
          s.doomOff();
        }
      case 'inv':
        final s = st(), k = a[0] as String, v = a[1] as bool;
        final keys = k == 'gb' ? s.gbKeysNow() : (k == 'sms' ? s.smsKeysNow() : (k == 'pm' ? s.pmKeysNow() : s.abKeysNow()));
        s.setGameKeys(k, keys, v);
      case 'wolfKey':
        final s = st(), k = {...s.wolfKeysNow()};
        k[a[0] as String] = a[1] as Object;
        s.setWolfKeys(k);
      case 'row':
        res = await row(st(), a);
      case 'numbers':
        numbers(st());
        st().toast('Every character now shows its number. Save the ROM and try it out.');
      case 'raw':
        final s = st();
        switch (a[0]) {
          case 't7save':
            s.t7save = syn(a[1] as String);
          case 't7saveX':
            s.t7saveX = (i: a[1] as int, save: syn(a[2] as String));
          case 'saveIn':
            s.saveIn = a[2] == 'v1' ? SaveIn(a[1] as Object, 'v1', syn(a[3] as String)) : SaveIn(a[1] as Object, 'tama');
          case 'eye':
            s.eyeShift[s.ctx!.groups[a[1] as int]] = (a[2] as int, a[3] as int);
          case 'mouth':
            s.mouthShift[s.ctx!.groups[a[1] as int]] = (a[2] as int, a[3] as int);
          case 'blank':
            final k = a[2] as int, idx = s.ctx!.groups[a[1] as int] + k;
            s.changed[idx] = C.spriteBlank(s.ctx!.entries[idx], C.partOptions(k));
          case 'carry':
            s.extras[a[1] as int].carry = true;
          case 't18pics':
            final px = S.rndBytes(48 * 48 * 4, a[1] as int);
            for (var k = 3; k < px.length; k += 4) {
              px[k] = 255;
            }
            s.t18Pics = {a[2] as int: E.t18PicMake(C.Rgba(48, 48, px))};
            s.t18PicsDirty = true;
          default:
            throw ArgumentError('raw ${a[0]}');
        }
      case 'plan':
        res = st().plan().text;
      case 'state':
        for (final l in stateLines(st())) {
          say(i, 'state', l);
        }
      case 'noport':
        useAssets = assetsNoPort; // the build without a WAD converter: the data of doomCompute is used
      case 'compose':
        final s = st();
        try {
          final c = await composeFull(s);
          res = c.same ? 'same' : '${sha(c.rom)} ${c.name} fresh=${c.fresh.map((r) => '${r.$1.toRadixString(16)}-${r.$2.toRadixString(16)}').join(',')} free=${c.res?.free ?? '-'}';
        } on ComposeError catch (e) {
          res = '! ${e.message}';
        }
        s.messages.length = n0 < s.messages.length ? n0 : s.messages.length;
      case 'save':
        final s = st();
        try {
          final c = await composeFull(s);
          if (c.same) {
            res = '! Nothing changed yet.';
          } else {
            // packOk: the page asks before it saves a ROM with a packed colour Tama
            final l = s.packedTamas(c.rom);
            if (l.isNotEmpty) {
              confirms.add(
                  'Note: the firmware of ${l.join(', ')} gets packed so it fits. Packed, the game runs slower. For full speed put fewer programs into the ROM and switch off "Pack the firmware".\n\nContinue anyway?');
            }
            for (final q in confirms) {
              say(i, 'confirm', q);
            }
            confirms.clear();
            last = c.rom;
            lastName = c.name;
            final keep = Platform.environment['KEEP'];
            if (keep != null) File('$keep/$name.$i.dart.bin').writeAsBytesSync(c.rom);
            res = '${sha(c.rom)} ${c.res != null ? 'Saved: ${c.name}\n${s.changed.length} sprites changed, ${c.res!.free ~/ 1024} KB still free.' : 'Saved: ${c.name}'}';
          }
        } on ComposeError catch (e) {
          for (final q in confirms) {
            say(i, 'confirm', q);
          }
          confirms.clear();
          res = '! ${e.message}';
        }
        s.messages.length = n0 < s.messages.length ? n0 : s.messages.length;
      default:
        throw ArgumentError('step $op');
    }
    for (final q in confirms) {
      say(i, 'confirm', q);
    }
    if (res != null) say(i, op, res);
    final s = s0;
    if (s != null && s.messages.length > (op == 'open' || op == 'reopen' || op == 'openSyn' ? (s.messages.isNotEmpty && identical(s, sBefore) ? n0 : 0) : n0)) say(i, 'toast', s.messages.last.text);
  }
}

/// A step on a row of the program list (renderApps): what its buttons and settings do.
Future<Object?> row(BuildState s, List a) async {
  final key = a[0] as String, what = a[1] as String;
  final dm = s.doomMain(), lp = s.starFree(), has = s.emuInstalled(), em = s.emu;
  final dIn = s.doomInstalled(), dGone = dIn && s.doom == null && (s.emuRemove || (!s.launch && em != null));
  final mp = s.mainPick;
  final doomIsMain = dm && !(lp && mp != null);
  if (key == 'doom') {
    if (!dm && !dGone) return 'norow';
    if (what == 'del') {
      if (!dm) return 'nobutton';
      s.doomOut();
    } else if (what == 'undo') {
      if (dm) return 'nobutton';
      s.doomBack();
    } else if (what == 'star') {
      if (!dm) return 'nobutton';
      if (!lp || doomIsMain) return 'disabled';
      s.pick(null);
    } else if (what == 'check' && a[2] == 'emuAuto') {
      if (!dm) return 'nodetail';
      if (s.launch && !(lp && doomIsMain && !s.clean)) return 'nodetail';
      s.setMainAuto(a[3] as bool);
    } else {
      return 'nocontrol';
    }
    return null;
  }
  if (key == 'main') {
    final gone = em == null && has && s.emuRemove && !s.paraMainTaken;
    if (em == null && !(has && !s.emuRemove) && !gone) return 'norow';
    if (what == 'del') {
      if (gone) return 'nobutton';
      if (em != null) {
        s.undoMain();
      } else {
        s.removeMain();
      }
    } else if (what == 'undo') {
      if (!gone) return 'nobutton';
      s.undoMain();
    } else if (what == 'star') {
      if (gone) return 'nobutton';
      if (em == null || !lp || mp == BuildState.pickEmu) return 'disabled';
      s.pick(BuildState.pickEmu);
    } else if (what == 'fig') {
      final st = s.t7State();
      final go = em != null ? (em.t7 && E.t7Kind(em.rom) == 'go') : (st != null && st.rom!.length != 0xC0000);
      if (gone || !go) return 'nobutton';
      s.addFigures([(a.length > 3 ? a[3] as String : 'fig.bin', syn(a[2] as String))]);
    } else if (what == 'check' || what == 'sel') {
      if (gone) return 'nodetail';
      final v = a[3];
      switch (a[2]) {
        case 'emuAuto':
          s.setMainAuto(v as bool);
        case 'emuClock':
          s.setMainClock(v as bool);
        case 'emuSess':
          s.setMainSess(v as bool);
        case 'emuNfc':
          s.setMainNfc(v as bool);
        case 'emuPack':
          await s.setEmuPack(v as bool);
        case 'optVol':
          s.setMainOpt(vol: v as int);
        case 'optDim':
          s.setMainOpt(dim: optU[v as int]);
        case 'optScr':
          s.setMainOpt(off: v as int);
        default:
          return 'nocontrol';
      }
    } else {
      return 'nocontrol';
    }
    return null;
  }
  final i = int.parse(key.substring(1));
  if (i >= s.extras.length) return 'norow';
  final x = s.extras[i], xMain = lp && identical(mp, x);
  if (what == 'del') {
    s.removeExtra(i);
  } else if (what == 'star') {
    if (lp) {
      if (xMain) return 'disabled';
      s.pick(x);
    } else {
      if (!(!dm && s.canMain(x))) return 'disabled';
      await s.mainChecked(i);
    }
  } else if (what == 'fig') {
    if (!(x.kind == null && E.t7Kind(x.rom) == 'go')) return 'nobutton';
    s.addFigures([(a.length > 3 ? a[3] as String : 'fig.bin', syn(a[2] as String))], i);
  } else if (what == 'check' || what == 'sel') {
    if ((x.kind == 'wolf' || x.kind == 'doom') && !xMain) return 'nodetail';
    final v = a[3];
    switch (a[2]) {
      case 'emuAuto':
        if (!xMain) return 'nocontrol';
        s.setMainAuto(v as bool);
      case 'emuClock':
        s.setExtra(i, clock: v as bool);
      case 'emuSess':
        s.setExtra(i, sess: v as bool);
      case 'emuNfc':
        s.setExtra(i, nfc: v as bool);
      case 'emuPack':
        s.setExtra(i, pack: v as bool);
      case 'optVol':
        s.setExtra(i, vol: v as int);
      case 'optDim':
        s.setExtra(i, dim: optU[v as int]);
      case 'optScr':
        s.setExtra(i, off: v as int);
      default:
        return 'nocontrol';
    }
  } else {
    return 'nocontrol';
  }
  return null;
}

/// btnNumbers (spec 2.1): every character shows its number.
void numbers(BuildState s) {
  final c = s.ctx!;
  for (final g in c.groups) {
    final big = C.numberImage('$g', 64, 64, 4), small = C.numberImage('$g', 32, 32, 2);
    s.changed[g] = C.spriteEncodeOpts(c.entries[g], List.filled(20, big), C.partOptions(0));
    s.changed[g + 3] = C.spriteEncodeOpts(c.entries[g + 3], List.filled(24, small), C.partOptions(3));
    for (final k in const [1, 2, 4, 5]) {
      s.changed[g + k] = C.spriteBlank(c.entries[g + k], C.partOptions(k));
    }
  }
}

Future<void> main(List<String> args) async {
  ps = '${Directory.current.path}/third_party/paramix-studio';
  final sh = (args.isNotEmpty ? args[0] : '0/1').split('/').map(int.parse).toList();
  final only = Platform.environment['ONLY'] != null ? RegExp(Platform.environment['ONLY']!) : null;
  final live = Platform.environment['LIVE'] != null;
  final emu = EmuBinaries(
      emu: bin('emu/emu.bin'),
      stubTpl: bin('emu/stub_tpl.bin'),
      t7: bin('t7/t7.bin'),
      t7x: bin('t7/t7x.bin'),
      t18: bin('t18/t18.bin'),
      t18x: bin('t18/t18x.bin'),
      v1: bin('v1/v1.bin'),
      v3: bin('v3/v3.bin'),
      gb: bin('gb/gb.bin'),
      gbc: bin('gb/gbc.bin'),
      sms: bin('sms/sms.bin'),
      pm: bin('pm/pm.bin'),
      ab: bin('ab/ab.bin'),
      wolf: bin('wolf/wolf.bin'),
      wolfsod: bin('wolf/wolfsod.bin'));
  final feld = FeldEmbedded(stub: bin('feld/stub_feld_tpl.bin'), feld: bin('feld/feld.bin'), feldS: bin('feld/feld_s.bin'), feldc: bin('feld/feldc.bin'), feldcS: bin('feld/feldc_s.bin'));
  final doom = DoomEmbedded(app: bin('doom/doom_app.bin'), xip: bin('doom/doom_xip.bin'), appF: bin('doom/doomf_app.bin'), xipF: bin('doom/doomf_xip.bin'));
  assets = BuildAssets(emu: emu, feld: feld, six: bin('six/six.bin'), flash: bin('flash/flashapp.bin'), doom: doom, doomPort: FakeDoom());
  assetsNoPort = BuildAssets(emu: emu, feld: feld, six: bin('six/six.bin'), flash: bin('flash/flashapp.bin'), doom: doom);
  final cases = jsonDecode(File('${Directory.current.path}/tool/paramix_check/compose_cases.json').readAsStringSync()) as List;
  final lines = <String>[];
  var k = 0;
  for (final c in cases) {
    final name = c[0] as String;
    if (only != null && !only.hasMatch(name)) continue;
    if (k++ % sh[1] != sh[0]) continue;
    final out = <String>[];
    try {
      await run(name, c[1] as List, out);
    } catch (e, st) {
      out.add('$name HARNESS $e ${'$st'.split('\n').take(6).join(' / ')}');
    }
    lines.addAll(out);
    if (live) out.forEach(print);
  }
  if (!live) stdout.write(lines.isEmpty ? '' : '${lines.join('\n')}\n');
  exit(0);
}
