# Paramix Studio: what the page glue does (specification for the native screens)

Source: `third_party/paramix-studio/src/app.js` (3633 lines, Studio 1.7.6), `src/index.html`
(controls) and `README.md`. All line references are `app.js:NNN` unless another file is named.
The English texts quoted are the values of the `en` table. Note: the i18n tables are **in app.js**
(`T.de` app.js:14, `T.en` app.js:134, 684 English keys), not in index.html; index.html only carries
`data-t="<key>"` attributes that `applyLang` (app.js:350) fills in.

Module aliases used by app.js and in this document:

| Alias | Module | Defined |
|---|---|---|
| `C` | `ParamixCore` (core.js) | app.js:5 |
| `E` | `ParamixEmu` (emu.js) | app.js:6 |
| `D` | `ParamixDoom` (doom.js) | app.js:7 |
| `F` | `ParamixFeld` (feld.js) | app.js:8 |
| `S6` | `ParamixSix` (six.js) | app.js:9 |
| `W` | `ParamixWolf` (wolf.js) | app.js:2218 |
| `FL` | `ParamixFlash` (flash.js) | app.js:2797 |
| `SV` | `ParamixSaves` (saves.js) | app.js:3108 |
| `ParamixVisit` | visit.js | app.js:2837, 2855 |

Conventions of the page that the native screens have to replace:

- `toast(msg, err)` (app.js:380): message for 5 s, error (red) for 9 s. While `toast.mute` is an
  object, nothing is shown and an error text is stored in `toast.mute.err` instead. Trial builds
  (`roomTry`, app.js:1811) rely on this: **every "validation message" of `composeRom` is a toast**,
  so a native port needs the same "collect instead of show" switch.
- `busy(fn)` (app.js:381): modal "One moment …" overlay around an async function.
- `confirm(...)` / `alert(...)`: blocking browser dialogs. `confirm` is called from inside
  `composeRom` (app.js:2716), `packOk` (app.js:3190), the save import (app.js:3382, 3388, 3389) and
  the device write (app.js:2932, 2958, 2965, 2968, 3023, 3027).
- `em(x)` (app.js:344): turns a module error into display text. In English only one rewrite exists
  (`MSG_EN`, app.js:341): `"<X> only fits packed"` becomes `"<X> only fits packed (big save): in the
  Emulator tab switch on "Pack the firmware" in its row, or remove another program"`. Otherwise
  the module's English `Error.message` is shown unchanged. German uses the regex table `MSG_DE`
  (app.js:251-338); that table is the complete list of module messages the page expects.
- `lang` (`'de'`/`'en'`, app.js:245-247) is passed into the patchers as `{ lang }` (it selects the
  texts the programs show on the device), so the native code must pass it too.
- Several build inputs are **read straight from DOM controls** rather than from `state`:
  `$('doomEp').value`, `$('doomMusic').checked`, `$('optColors').checked`, `$('devOnly').checked`,
  `$('devKeep').checked`, `$('dPoseOnly').checked`, `$('saveFor').value`, `$('paraSlot').value`,
  `$('figField').value`, `$('petLevel')`, `$('petChar')`, `$('petCare')`, `$('visEd')`. Native
  screens need equivalent view-model fields (listed in section 1.6).

---

## 1. State

### 1.1 The `state` object as created (app.js:364)

| Field | Initial | Holds |
|---|---|---|
| `ctx` | `null` | The opened ROM (see 1.2). Set by `loadRom` (app.js:420). `ctx.rom` is replaced in place by the pet editor (app.js:3449) and by "Clear slot" (app.js:3266). |
| `name` | `''` | File name of the loaded ROM (app.js:420); base of the output name (`baseName`, app.js:409). |
| `changed` | `new Map()` | sprite index -> new encoded sprite entry (`Uint8Array`). Reset on load (app.js:420), then pre-filled by `C.spriteAlign` (app.js:422). Written by `applySheet` (app.js:635), `insertDim` (app.js:862-879), egg insert (app.js:935-936), number test (app.js:2442); entries deleted by "Restore original" (app.js:841) and by `applySheet` when a sheet equals the original (app.js:632, 635). |
| `dim` | `null` | Loaded card (`C.smaLoad` / `C.dimLoad` result, app.js:981). **Not** reset on ROM load. |
| `open` | `null` | `{ kind: 'fig'|'spr', idx }` of the open drawer (app.js:728); `null` on close (app.js:827) and on load. |
| `zoom` | `2` | Drawer zoom 1/2/3 (app.js:830). |
| `decoded` | `new Map()` | Decode cache: index -> `{ src, dec }` (`decode`, app.js:372). Reset on load. |
| `eyeOffsets` | `new Map()` | group -> `[eyeBig, eyeSmall]` or `'hide'`, for card characters inserted with an eye layer (app.js:882). Reset on load. Used by `currentDataPack` (app.js:891). |
| `eyeRects` | `new Map()` | card character object -> eye rectangle or `null` (`eyeRectFor`, app.js:846). Not reset on load. |
| `eyeLayer` | `false` | Switch for the "eye layer" way of inserting card characters. **Never set to true anywhere in app.js**: the eye-layer branch of `insertDim` (app.js:867-883) and the eye editor (app.js:943-963) are unreachable from the UI. |
| `fields` | `[]` | `C.fieldSets(ctx)` (app.js:468): `[{ type, name, chars:[{id,stage,group}], maps, overlays, closeups }]`. |
| `charNames` | `new Map()` | group -> character name from the text table (app.js:470). |

### 1.2 `state.ctx`

Normal ROM: the return value of `C.openRom(buf)` (core.js:640): `{ rom, root, files, entries, groups,
adult, egg, assetEnd, limit, editionId, edition }`. `files[0]` is the data pack (character table,
composites), `files[2]` the third archive file; `groups` are the first sprite indices of the
characters (6 sprites each: body, eyes, mouth, small body, small eyes, small mouth); `adult` the
first adult group, `egg` the egg sprite index or -1; `limit` the end of the room for assets.

Clean ROM (start device without the Paradise; `F.isClean(buf)`, app.js:416-417):
`{ rom: buf, entries: [], files: [], groups: [], edition: FL.EDITIONS[ed.id] || ed.id || '?', limit: 0,
clean: true }` with `ed = F.edition(buf)`. There is **no `editionId`** in this case, so everything
that uses `state.ctx.editionId` (app.js:1081, 3406, 3412-3414, 3459) gets `undefined`; the native
screens should hide the Paradise save section for a clean ROM instead of relying on that.

### 1.3 Fields set by `loadRom` (app.js:412-475)

Every load sets (in this order):

| Field | Value at load | Changed later by |
|---|---|---|
| `clean`, `cleanInit` | `F.isClean(buf)` (app.js:419) | `cleanOn` checkbox (app.js:2514); `launchOn` off sets `clean=false` (app.js:2507). |
| `pmBios` | `undefined` (app.js:425) | `pmBiosNow` lazily from the extras (app.js:2112); PM BIOS pick/remove (app.js:2155, 2165, 2168). |
| `pmKeys`, `abKeys` | `null` (app.js:425) | lazily by `pmKeysNow`/`abKeysNow` (app.js:2110, 2174). |
| `emu` | `null` | Newly chosen **main** program, see 1.4. |
| `t7save` | `null` | Imported/edited T7Emu save of the main program (`Uint8Array`), app.js:1231, 3366. Cleared by "undo" (app.js:1551, 2014). |
| `t7saveX` | `null` | `{ i, save }`: T7Emu save for extra `i` (app.js:1231, 3364). Reset to `null` whenever the extras list changes (app.js:1574, 1774, 1879, 1903). |
| `saveIn` | `null` | `{ key: 'm'|index, kind: 'v1'|'tama', data? }` imported V1Emu/TamaEmu save (app.js:3372, 3383, 3391). |
| `emuRemove` | `false` | "Take the program at 0x0A0000 out" (an emulator, or DOOM when DOOM is built in). Set by × on the main row (app.js:1608), `doomOut` (app.js:1537), "Remove DOOM" (app.js:2336-2337), `paraMainSync` (app.js:1710), × on a `fromPara` extra (app.js:1574). Cleared by `emuRemoveClear` (app.js:1659, only when DOOM is not installed), `doomBack` (app.js:1538), WAD pick when not `doomFree()` (app.js:2390). |
| `doom` | `null` | Result of `doomCompute` (see 1.5). `null` again when an emulator is chosen outside a start device (app.js:1775, 1904, 1997-2006, 3390). |
| `doomKeys` | `null` | `{ fire, fwd, back, use, mod, run, invert }`; filled lazily in `renderDoom` (app.js:2317) from the first DOOM extra, `D.doomKeysGet(rom)` or `D.KEYS_DEFAULT`; edited by `keysChanged` (app.js:2328). |
| `six` | `null` | Bytes of the second (Land/Water/Sky) ROM (app.js:2536). |
| `sixName` | `''` | Its file name. |
| `sixWant` | `false` | Checkbox "All 6 fields" ticked (app.js:2523, 2536). |
| `sixOff` | `false` | Built-in extra fields are to be taken out (app.js:2522). |
| `petDirty` | `false` | The Paradise save inside `ctx.rom` was edited (app.js:3449). |
| `texts` | `new Map()` | text index -> new name (app.js:502). Cleared by "Reset all" (app.js:529). |
| `eyeShift`, `mouthShift` | `new Map()` | group -> `[dx, dy]` (app.js:813-814), each clamped to -16..16. |
| `poseAdj` | `new Map()` | group -> Map(`"ox:oy"` -> `{ ox, oy, d:[dx,dy] }`) for "This pose only" (app.js:806-809). |
| `poseCache` | `null` | Cache of `C.facePoses` (app.js:755). |
| `face.g` (module variable, app.js:753) | `-1` | Which figure the pose preview shows. |
| `dlcT`, `figT` | `'main'` | Target of the next download-content / figure file dialog: `'main'` or an index into `state.extras` (app.js:1569, 1570, 1596, 1597). |
| `dlcOpen` | `false` | Unused leftover. |
| `mainGuest` | `null` | `{ g, dev }`: the installed main TamaEmu's firmware with its save read back from the ROM (`mainGuestLoad`, app.js:1445). Moved into `state.emu` on the first change (app.js:1204, 1563). |
| `emuPack` | computed (app.js:426) | "Pack the firmware" for the main TamaEmu: true when `romEmuCfg(buf)` has `version >= 5`, an `lzOff`, and (`!E.PACK_ASK` or `E.lzCount(buf, c.lzOff) > E.PACK_FEW` (8)). Toggled at app.js:1561; forced on by a save import (app.js:3389). |
| `sixPlanet` | `si.version >= 5 ? si.planet : true` (`si = S6.sixInfo(buf)`, app.js:427) | checkbox (app.js:2529). |
| `sixMenu` | `si.version >= 6 ? si.fieldMenu : true` (app.js:427) | checkbox (app.js:2530). |
| `emuAuto` | `E.autoGet(buf, stubList(buf))`, or `E.autoGetOld(buf, l)` when that is `null` (app.js:428); in a v9 start device overwritten by `!!fa.auto` (app.js:451) | checkboxes (app.js:1545, 1549, 1554, 2010). |
| `emuClock` | `E.emuClockGet(buf)`, `null` -> `true` (app.js:429) | app.js:1556, 2011. |
| `emuSess` | `E.emuSessGet(buf)`, `null` -> `true` (app.js:430) | app.js:1557. |
| `emuNfc` | `E.emuNfcGet(buf)`, `null` -> `true` (app.js:431) | app.js:1558, 2012. |
| `emuOpt` | `E.emuOptGet(buf) || { vol: 0, dim: 0, off: 0 }` (app.js:432) | `optInto` (app.js:1565); swapped in `makeMain` (app.js:1769-1770). |
| `feld`, `bag`, `tama`, `gplay` | flags of the installed menu: `f = F.feldFind(buf, fe.stub)`; `f.flags & F.F_FIELDS / F_BAG / F_TAMA / F_GPLAY` (app.js:434) | checkboxes (app.js:2503, 2540-2542); all four forced `false` when the start device is switched on (app.js:2508); `feld = true` when six fields are chosen (app.js:2525, 2536). |
| `saves` | `true` always (app.js:434) | never changed. Passed to `F.feldApply` as `saves`. |
| `feldInit`, `bagInit`, `tamaInit`, `gplayInit`, `savesInit` | copies of the above (app.js:435) | never; used for "changed?" tests. |
| `launch`, `launchInit` | `f.version >= 2 && (f.flags & F.F_LAUNCH)` (app.js:436) | `launchOn` checkbox (app.js:2506). |
| `launchMap` | `null` (app.js:436) | `C.launcherChanges(ctx)` on first use (`launchMapGet`, app.js:371). |
| `t18Few` | `false` (app.js:437) | set by `roomFit` when only the "few spares" layout fits (app.js:1838-1841). |
| `exitKey`, `exitKeyInit` | `exitGet(buf)` (0..3, app.js:437) | select (app.js:2504). |
| `extras` | read back programs of the menu, see 4.3 (app.js:438); `[]` without a menu | every add/remove in the emulator and game tabs. |
| `extrasDirty` | `false` | set on any change to `extras` or to a per-program setting. |
| `extrasUp` | `extrasOld(buf, apps)`: `Set` of chip groups whose program in the ROM is older than the embedded one, or `false` (app.js:439, 1645) | never cleared (a save of the ROM rebuilds them; the flag stays until the next load). |
| `wolfInit` | extras contain a `wolf` (app.js:440) | - |
| `wolfKeysDirty` | `false` | `wolfKeysApply` (app.js:2222). |
| `oldT7` | names of T7Emus for which `E.t7Outdated` is true (app.js:443-444) | - |
| `t18Broken` | a T18Emu in the menu with >= 8 mapped blocks that are all 0xFF (app.js:445-446) | - |
| `sig0` | `{ emu, gb, sms, pm, ab }`: `groupSig(g)` of the loaded extras (app.js:447) | - (baseline for "gets updated"). |
| `cleanClock` | `true`; for a clean ROM `!F.feldApps(buf, fe.stub).noClock` (app.js:449) | checkbox (app.js:2520). |
| `mainPick` | only assigned here when the ROM is a start device **and** `fa.v9`: the extra whose `off === fa.mainSrc - 0x10000000 + 0x11000`, else `null` (app.js:450-451) | star buttons (`pick`, app.js:1544), `paraMainSync`, `doomFreeSync`, removals. Value: an element of `state.extras`, the string `'emu'` (the newly chosen main program `state.emu`), or `null`. |
| `feldStale` | menu in the ROM differs from what this Studio would build with the same options (trial rebuild, app.js:453-464) | - |
| `fields`, `charNames` | app.js:466-471 | - |

**Trap (upstream):** the long statement on app.js:426 contains a `//` comment in the middle of the
line. Everything after it on that line is commented out and therefore **not executed on load**:
`state.t18Main = null; state.t18Dirty = false; state.t18Pics = E.t18PicsRead(buf);
state.t18PicsDirty = false; state.itemT = 'main'; state.progOpen = new Set(); state.mainPick = null;
state.mainDirty = false; state.roomFree = null; state.paraMainTaken = false;`. Consequences in the
page as shipped: these ten fields keep their value from the previously loaded ROM (they start as
`undefined`), the grow-up pictures already in a ROM are never read back (`state.t18Pics` stays
`undefined` until the user picks pictures), and `mainPick` is only reset for a v9 start device.
A native port should do what the line obviously intends (reset all ten, read `E.t18PicsRead(buf)`),
but must know that the byte-exact reference behaviour of the JS page is "not reset".

Also **not** reset by `loadRom`: `gbKeys`, `gbInv`, `smsKeys`, `smsInv`, `pmInv`, `abInv`,
`wolfKeys` (only `pmKeys`/`abKeys` are nulled), `stampSet`, `dim`, `dimSel`, `eyeRects`, `saved`,
`tamaPacked`, and the module variables `petSave`, `petName`, `petFromRom` (app.js:3396, 3410),
`g_slotIn` (app.js:3270), `lastRoom`, `lastFree` (app.js:1804).

Other fields that only appear later:

| Field | Set at | Meaning |
|---|---|---|
| `t18Main` | app.js:1243 | `E.t18FromRom(rom)`: firmware (with save) of the installed main T18Emu, edited in place by the item functions. |
| `t18Dirty` | app.js:1245 | items/points of the installed main T18Emu changed. |
| `t18Pics`, `t18PicsDirty` | app.js:1259, 1979-1986 | Map adult id -> picture (`E.t18PicMake`), and "changed". |
| `itemT` | app.js:1406 | target of the MyMeets file dialog. |
| `progOpen` | app.js:1521 | Set of opened program rows (`'main'`, `'doom'`, `'x<i>'`). |
| `mainDirty` | app.js:1544, 1545, 1554, 2520 | main program pick / autostart / clean clock changed (start device). |
| `roomFree` | app.js:1815, 1032 | `{ sig, kb }` free KB of the last successful trial build (`kb: -1` = unknown). |
| `paraMainTaken` | app.js:1710 | the Paradise's main emulator was moved into `extras` (clean ROM / start device without room at 0x0A0000). |
| `gbKeys`, `smsKeys`, `pmKeys`, `abKeys` | `*KeysNow` | arrays of 9 button codes, one per input (see 2.7). |
| `gbInv`, `smsInv`, `pmInv`, `abInv` | `*KeysNow` | "Wheel reversed". |
| `wolfKeys` | app.js:2220 | `{ fire, fwd, back, use, mod, run, invert, turn }`. |
| `stampSet` | `stampMark` (app.js:1913) | `{ 'main'|index: value }` save-flag byte to carry to the device after a stamp card/mail change. |
| `dimSel` | app.js:964-966 | selected card character index (string). |
| `tamaPacked` | app.js:2613 | `appsPlace` had to pack a TamaEmu (clean build). Written only. |
| `saved` | app.js:2792 | `changed.size` at the last download (for the "unsaved changes" prompt, app.js:3629). |

### 1.4 `state.emu` (the newly chosen main program at 0x0A0000)

| Kind | Shape | Created at |
|---|---|---|
| TamaEmu (colour Tama) | `{ guest, dev, size, big, kept? }`; `dev` one of `pc`, `idl`, `ps`, `4u`, `4u-plain` (`E.DEVICES`, emu.js:31); `size = pk.blob.length`, `big = pk.big` from `E.packMain(guest, dev, null, !!state.emuPack)`; `kept: true` when it is the installed firmware re-read from the ROM/device | app.js:2006, 1204, 1563, 1765, 3003, 3390 |
| T7Emu | `{ t7: true, dev: 't7', rom, figs: [{ name, data }], size }`, `size = t7Size` (rom + figures, app.js:1194) | app.js:2003, 1192, 1767 |
| T18Emu | `{ t18: true, dev: 't18', rom, size, items? }`; `size` = number of non-0xFF 64 KB blocks among the first 128, `<< 16` | app.js:2000, 1764, 3351 |
| V1Emu / V3Emu | `{ v1: true, dev: 'v1', rom, size: rom.length + 0x2000 }` | app.js:1997, 1766 |

`emuX(em)` (app.js:1788) converts it to the "extra" form, `emuNm(em)` (app.js:1789) gives its name
(`E.v1Name`, `E.t7XName`, `E.extraName({kind:'t18'})`, `E.tamaName(guest, dev)`).

### 1.5 `state.extras` entries (programs of the menu) and `state.doom`

Entries are plain objects passed as they are to `E.appsPlace`. `E.extraKind(x)` gives the kind
(`x.kind`, or `'t7'` when there is no `kind`).

| Kind | Fields from the ROM (app.js:438) | Extra fields added by the UI |
|---|---|---|
| T7Emu (no `kind`) | `rom`, `figs`, `clock` | `fresh`, `sess` |
| `tama` | `guest`, `dev`, `clock`, `nfc`, `opt`, `pack` | `fresh`, `sess`, `carry`, `fromParaMain` |
| `t18` | `fw`, `clock`, `opt`, `keepOff` (= its offset in the loaded ROM: stays in place) | `items`, `saveImp`, `fresh`, `fromParaMain` |
| `v1` | `rom`, `clock` | `fresh`, `sess` |
| `gb` | `rom`, `keys`, `inv`, `save` | `fresh`, `sess` |
| `sms` | `rom`, `title`, `gg`, `keys`, `inv`, `save` | same |
| `pm` | `rom`, `title`, `keys`, `inv`, `save`, `bios` | same |
| `ab` | `rom`, `title`, `keys`, `inv`, `save` | same |
| `wolf` | `pack`, `keys`, `save` | `fresh` |
| `doom` | `mcu`, `keys`, `keys0` (JSON of the keys as read), `save`, `name`, `region` | `wadSrc` (the `state.doom` object it was made from), `ep` (`'1'..'4'`, `'all'`, `'P<i>'`, `'Q<i>'`), `size`, `title`, `d2`, `fromPara` |

`sess: false` is copied from the ROM by `sessKeep` (app.js:1504) only when it is off.

`state.doom` = result of `doomCompute(w, pwads, keepSel)` (app.js:2342-2382):
`{ wad, wadM, pwads: [{ name, data, info }], eps, fit, ok, sel: Set, titles, whole, d2 }` with
`fit[key] = { music, plain, sizeM, sizeP, mcuM, mcuP, linkSaved? }`; keys are episode digits,
`'all'` (whole WAD), `'P<i>'` (own episode of an extra WAD) and `'Q<i>'` (DOOM II map pack alone).

### 1.6 View state that lives in the DOM

`doomEp` (select, default first option), `doomMusic` (checkbox, default checked), `optColors`
(unchecked), `devOnly` and `devKeep` (both checked), `dPoseOnly` (unchecked, reset when another
figure is opened, app.js:745), `figField` (`''` = all), `namesFind` (search text), `saveFor`,
`paraSlot`, `visEd` (persisted in `localStorage['pmxVisitEd']`, default `water`, app.js:2847-2848),
language (`localStorage['paramix-lang']`), rescue header (`localStorage['pmxRescueHdr']`,
app.js:3092), the image being written (IndexedDB `pmxStash`, key `last`, app.js:3066-3071).

### 1.7 Derived predicates used everywhere

| Function | Line | Meaning |
|---|---|---|
| `menuWanted()` | 369 | `feld || bag || tama || gplay || launch`. |
| `sixActive()` | 480 | not a start device and (six fields installed and not `sixOff`, or `six`, or `sixWant`). |
| `appInstalled()` | 1115 | 0 for a clean ROM; `F.appKind(rom)` when the ROM is a start device (`F.isLaunch(r, fe.stub)`) or when `E.installedOrigs(r, E.sceneTable(r))` is truthy; else 0. 1 = DOOM, 2 = emulator. Any exception -> 0. |
| `emuInstalled()` / `doomInstalled()` | 1123 / 1124 | `appInstalled() === 2` / `=== 1`. |
| `a0Free()` | 1147 | `F.appKind(rom)` is non-zero, or the 4 KB at 0xA0000 are all 0xFF. False in editions whose firmware reaches past 0x0A0000 (Tropical, Glacier, Neon Planets, Jade Forest wave 2). |
| `appRoom()` | 1148 | `!a0Free() || estimateEnd() <= 0x830000`. |
| `doomFree()` | 1686 | `state.clean`, or start device (`state.launch`) of an edition where `!a0Free()`: DOOM is then a menu program (an extra) instead of the fixed program at 0x0A0000. |
| `doomMain()` | 1662 | not `doomFree()` and (`state.doom`, or installed DOOM that is not removed and (`launch` or no `state.emu`)). |
| `mainV9()` | 1661 | the embedded menu program (`F.embedded().feld`) has version >= 9 (word after the `FELD` magic 0x444C4546). |
| `cleanCan()` | 2512 | the embedded clean menu (`F.embedded().feldc`) has version >= 10. |
| `clockOff()` | 1506 | `state.clean && state.cleanClock === false`. |
| `stubList(rom)` | 1126 | list of `[offset, stub]` candidates for the autostart switch: `[E.STUB_OFF, E.embedded().stub]`, `[E.STUB_OFF, F.embedded().stub]`, and `[f.stubOff, fe.stub]` when the menu's stub sits elsewhere. |
| `romEmuCfg(rom)` | 3169 | `SV.emuCfg(rom.subarray(0xA0000, 0xA1000))` when `F.appKind(rom) === 2 && F.emuType(rom) === 'tama'`, else `null`. |
| `romExtras(rom)` | 3193 | `E.appsRead(rom, F.feldApps(rom, fe.stub).apps)` or `[]`. |

---

## 2. Screens and controls

### 2.0 Top bar and global behaviour

| Control | Type | English label | State | Action |
|---|---|---|---|---|
| `btnHelp` | button | "Help" | always | toggles `helpBox` (app.js:2830); `helpClose` hides it. Help texts: keys `h1t`..`h9t`, `h1`..`h9`, table `hk1`/`hv1`..`hk7`/`hv7`. |
| `btnDevice` | button | "Device" | always | toggles the device panel and calls `devRender()` (app.js:2829). |
| `btnOpen` | button | "Open ROM" | always | file dialog `fileRom` -> `busy(() => loadRom(file))` (app.js:2420-2421). |
| `btnSave` | button | "Save new ROM" | disabled until a ROM is loaded (app.js:423) | section 3. |
| language `DE`/`EN` | buttons | - | - | sets `lang`, stores it, `applyLang()` re-renders everything (app.js:361). |
| start screen `drop` | drop zone | "Drop a ROM here or click" / "Land, Water, Sky, Jade Forest, Tropical and Glacier are recognised." | until a ROM is loaded | click/Enter/Space -> `fileRom`. Dropping files anywhere on the page: a file of exactly 16 777 216 bytes, or a `.bin` larger than 4 MB, is loaded as ROM; otherwise, with a ROM open, `uploadFiles(files)` (app.js:2427-2432). |
| `romname` | text | file name | - | app.js:424 |
| `info` line | text | "Edition", "Sprites", "Characters", "changed", "Room for characters" + meter + "N KB" | - | `renderInfo` (app.js:537): `end = estimateEnd()`, `total = ctx.limit - C.ASSET_BASE`, `used = end - C.ASSET_BASE`, `free = ctx.limit - end`, meter width `min(100, used/total*100)` %, red when `free < 0`, KB = `free / 1024 | 0`. Clean ROM: only "Edition: <ed> · Without the Paradise (clean ROM)". |
| `plan` box | - | "Your new ROM" | - | `renderPlan` (section 3.4). |
| leaving the page | - | "There are unsaved changes." | when `state.changed.size` and `state.saved !== state.changed.size` (app.js:3629) | - |

Tabs (app.js:594-597): `figs` "Characters", `all` "All sprites", `names` "Names", `dim` "Card",
`emu` "Emulator", `doom` "DOOM", `gb` "Game Boy / Color", `sms` "Master System / Game Gear", `pm`
"Pokémon mini", `ab` "Arduboy", `wolf` "Wolf3D", `feld` "Menu", `save` "Save". Order in the page:
figs, all, names, dim, emu, doom, gb, sms, pm, ab, wolf, feld, save.

`cleanTabs()` (app.js:588): while `state.clean` the tabs `figs`, `all`, `names`, `dim` are hidden
(`CLEAN_TABS`, app.js:587); if the selected tab is one of them the `emu` tab is selected. Called
on load and whenever `launchOn`/`cleanOn` change.

### 2.1 Tab `figs` (Characters)

Hint: "A character is made of body, eyes and mouth, each large and small. Click a character for its sheet."

| Control | Type | Label | Shown/enabled | Action |
|---|---|---|---|---|
| `figField` | select | "Field:"; options "all" (value `''`) + one per `state.fields` entry (`value = f.type`, text `f.name`) | always | `applyFieldPick` (app.js:673): hides tiles whose group is not in `f.chars`; shows `btnZipField` and `btnFieldIn` only when a field is selected. |
| `btnZipField` | button | "Field as ZIP" | field selected | app.js:680-694: for every character of the field `sheetOf('fig', group)` as `figur_NNNN.png`; for every index in `maps`, `overlays`, `closeups` `sprite_NNNN.png`; `contents.txt`; `field.json` = `{ paramix: 'field', edition, type, name, chars:[{id,stage,group}], maps, overlays, closeups }`; `C.zipBuild(files)`; download `<baseName>_<field name lower>.zip`. Toast "{f}: {n} characters and {s} pictures as ZIP." |
| `btnFieldIn` | button | "Load field from ZIP" | field selected | file `fileField` (.zip). app.js:698-718: `C.zipRead(bytes, inflateRaw)`, `field.json` must have `paramix === 'field'` else error "Not a field ZIP (field.json missing)."; then, position by position (min of both lengths), `applySheet('fig', dst.chars[i].group, png of meta.chars[i].group)`, and the same for `maps`, `overlays`, `closeups` with `'spr'`. Errors matching `/^eye image too detailed/` are counted (`eyes`), others collected. Toast "{src} applied to {dst}: {n} parts." + "{k} characters stay original, their eye images are too big here." + "Skipped: ..." |
| `btnZipFigs` | button | "All characters as ZIP" | always | `zipSheets('fig')` (app.js:719): every group as `figur_NNNN.png`, download `<baseName>_figuren.zip`. |
| `btnUpload` | button | "Upload sheets (PNG or ZIP)" | always | `fileSheets` (multiple) -> `uploadFiles` (app.js:644), see 6. |
| `btnNumbers` | button | "Number test ROM" | always | app.js:2437-2447: for every group `g`: `big = C.numberImage(String(g), 64, 64, 4)`, `small = C.numberImage(String(g), 32, 32, 2)`; part 0 = 20 x `big`, part 3 = 24 x `small` via `C.spriteEncode(orig, subs, C.partOptions(k))`; parts 1, 2, 4, 5 = `C.spriteBlank(orig, C.partOptions(k))`; all into `state.changed`. Toast "Every character now shows its number. ..." |
| grid `gridFigs` | tiles | `#<group>` + name + role | one per `ctx.groups` | tile picture = `decode(i).subs[0]`; caption `[state.charNames.get(g), groupRole(g)]`; pink dot when any of the 6 parts is in `state.changed`; click -> `openDrawer('fig', g)`. Roles (`groupRole`, app.js:605): first group "Fallback", `ctx.egg + 6` "Baby", `ctx.adult` "first adult". |

**Drawer** (`openDrawer`, app.js:727): title "Character #N" / "Sprite #N"; sheet image
`sheetOf(kind, idx)` (app.js:614): character = `C.groupSheet([0..5].map(k => decode(idx+k).subs))`,
sprite = `C.sheetFromSubs(decode(idx).subs)`.

| Control | Label | Enabled | Action |
|---|---|---|---|
| `dDown` | "Download sheet" | always | PNG of the sheet, name `figur_NNNN.png` / `sprite_NNNN.png` (4 digits, app.js:618). |
| `dUp` | "Upload sheet" | disabled for a sprite added by six fields (`sixAdded`, app.js:621: `S6.sixInfo(rom)` has `kind === 'gen3'` and `i >= si.sprites`) | `fileOne` (.png) -> `applySheet(kind, idx, decodePng(file))`; success toast "Applied: 1"; error toast "{f}: {e}". |
| `dReset` | "Restore original" | only when the item is changed | deletes the index (or the 6 indices) from `state.changed`; toast "Original restored." |
| zoom 1x/2x/3x | - | - | `state.zoom` |
| `dClose`, scrim, Escape | "Close" | - | `closeDrawer` |
| meta list | - | - | "Sheet {w}×{h} px. Keep the size, otherwise the grid no longer fits."; for characters "Rows: body (20), eyes (20), mouth (18), small body (24), small eyes (14), small mouth (14).", "Eyes keep their byte size, otherwise the fallback character hatches. Eyes that are too detailed are rejected.", "If all colours come from the original, the game keeps recolouring the character per tama. New colours become fixed (up to 8 colours plus outline)." and the role text; for sprites "Cell {w}×{h}, {n} images, grid {iw}×{ih}", "{c}, palette sets: {p}" (from `C.spriteHeader`), "Field picture of the extra fields, cannot be changed.", "Several palette sets (colour variants): uploads use the original colours." (app.js:734-742). |

Face editor (only for characters, `dEyes`, app.js:749-826):

| Control | Label | Action |
|---|---|---|
| preview `dEyeCv` | - | `eyePreview(g)` (app.js:763): poses from `C.facePoses(files[0], base, base+1, base+2)` with `base = g` (big) or `g + 3` (small); without poses falls back to `C.eyeFirst(files[0], g, g+1)`. Draws body sub `f.bs`, then eye and mouth layers at `lay.dx + ((b.w - e.w) >> 1) + shift`, pixels with alpha < 128 skipped; shift = global shift (halved for the small figure with `half`, app.js:886) + per-pose adjustment. Shown at 3x. |
| `dPosePrev` / `dPoseNext` | ◀ ▶, "Pose {i} of {n}" | `poseStep(-1/+1)` (app.js:822); disabled with fewer than 2 poses. |
| `dFaceBig` / `dFaceSmall` | "Big" / "Small" | `faceSize` (app.js:824): sets `face.small`, pose = `firstPose` (first pose with eye sub 0 and mouth sub 0, app.js:762). |
| arrows `data-eye`, `dEyeReset` | "Move the eyes" ← → ↑ ↓ ↺ | `faceMove('eye', dx, dy[, reset])` (app.js:801). |
| arrows `data-mouth`, `dMouthReset` | "Move the mouth" | `faceMove('mouth', ...)`; row hidden when the pose has no mouth layer. |
| `dPoseOnly` | checkbox "This pose only" | off: arrows change `state.eyeShift` / `state.mouthShift` for the group (hint "Applies on the field to Tamas that hatch or grow after writing. The small figure moves half as far."). On: they change `state.poseAdj` for the layer shown, only if `l.ox >= 0` (hint "The arrows move eyes or mouth only in the pose shown. ..."). Disabled when there are no poses. |
| `dEyeVal`, `dMouthVal` | text | `shTxt` (app.js:752): `"+dx / +dy"` or empty. |

All values are clamped to -16..16 (`clamp16`, app.js:799); a zero vector removes the entry.

`applySheet(kind, idx, img)` (app.js:622-638) is the one entry point for edited sheets:
1. sprite added by six fields -> throws "Field picture of the extra fields, cannot be changed.".
2. `opts = { allowMoreColors: optColors.checked }`.
3. character: `C.groupFromSheet(img)` gives 6 lists of sub images; sprite:
   `C.subsFromSheet(img, d.subs[0].w, d.subs[0].h, d.subs.length)`.
4. per part: unchanged against the current decode -> skip; equal to the original
   (`C.sameImage` against `C.spriteDecode(ctx.entries[i]).subs`) -> remove from `changed`; else
   `C.spriteEncode(orig, subs, Object.assign({}, opts, partOpts(i)))` where `partOpts(i)` =
   `C.partOptions(i - g)` for a sprite inside a character group, `{}` otherwise (app.js:601).
5. nothing is committed until every part encoded (a character is never half replaced).

### 2.2 Tab `all` (All sprites)

Hint "Backgrounds, menus, items, fonts."

| Control | Type | Label | Action |
|---|---|---|---|
| `btnZipAll` | button | "All sprites as ZIP" | `zipSheets('spr')`: every entry as `sprite_NNNN.png`, download `<baseName>_sprites.zip`. |
| `btnUpload2` | button | "Upload sheets (PNG or ZIP)" | same as `btnUpload`. |
| `optColors` | checkbox, default off | "Allow more colours (up to 256)" | read by `applySheet` as `allowMoreColors`. |
| grid `gridAll` | tiles | `#<i>` + `<w>×<h>` (`h.sw * max(1,h.iw)` x `h.sh * max(1,h.ih)` from `C.spriteHeader`) | click -> `openDrawer('spr', i)`. Tiles of six-field pictures are greyed with tooltip "Field picture of the extra fields, cannot be changed." (app.js:578). |

### 2.3 Tab `names`

Hint "Change names: capitals, digits, space and . & ' ! ? /. Applies to every language with Latin
letters on the device." Three lists built by `renderNames` (app.js:507):

| List | Rows | Max length |
|---|---|---|
| "Fields" (`namesFields`) | `fieldTexts(rom, sixActive())` (app.js:481): for field `i < 3` text index `14 + i`; for an extra field named LAND/WATER/SKY text index `64 + k`; a base field named LAND/WATER/SKY whose text at `64 + k` equals its own also gets `64 + k` (both edited together). With `six` given: names cut to 3 when six is inactive, or extended by `['SKY']` (edition id 4, Jade) / `['LAND','WATER','SKY']` (id >= 5) when the ROM has only 3. Current name = `C.textGet(rom, own)`. | 11 |
| "Tamas" (`namesChars`) | `C.charTable(ctx.files[0])` entries with `1000 < id < 9000`, one row per distinct `c.name` text index with a non-empty `C.textGet`. | 12 |
| "Items" (`namesItems`) | `F.itemCatalog(rom)`, one row per distinct `it.text` not already used; filtered by the search box (upper-cased, matches the name or the edited value). | 22 |

Row (`nameRow`, app.js:496): text input with the current or edited value; on change
`v = C.textClean(input)`; empty or equal to the original deletes the edit, otherwise
`state.texts.set(i, v)` for every index of the row; `renderPlan()`.

| Control | Label | Action |
|---|---|---|
| `namesFind` | search, placeholder "Search" | re-renders the lists. |
| `namesUndo` | "Reset all" | `state.texts = new Map()`. |

### 2.4 Tab `dim` (Card)

| Control | Label | Action |
|---|---|---|
| `btnDim` | "Load card" | `fileDim`: `state.dim = C.smaDetect(raw) ? C.smaLoad(raw) : C.dimLoad(raw)`; `state.dimSel = undefined`; no characters -> error "Unknown card: no characters on this card"; exception -> "Unknown card: {e}" (app.js:979-983). |
| hint | "Dump of a character card (4 MB) or a TamaSma card (1 or 2 MB). Card characters best replace adults. Baby, child and teen share their eyes and stay original." | |
| before a card is loaded | "Load a card to see its characters." | |
| card character select | "Card character"; options "No. {index}" + " (Baby)" | default: first non-baby (app.js:965). |
| target select | "replaces character"; options "Character #{g}" + role | default `ctx.adult`. |
| insert button | "Insert" | `insertDim(ch, g)` (app.js:854). With `state.eyeLayer` false (always): `parts = C.dimCharParts(ch)`; parts 0 and 3 = `C.spriteEncode(orig, parts[k], C.partOptions(k))`, parts 1, 2, 4, 5 = `C.spriteBlank(orig, C.partOptions(k))`; `state.eyeOffsets.delete(g)`. Toast "Card character {d} now sits in character {g}." |
| egg button | "Insert the card’s egg" | only when `dim.eggs.length && ctx.egg >= 0`: `e = C.dimEggSubs(dim.eggs)`; `changed.set(egg, C.spriteEncode(entries[egg], e.small, {}))`, `changed.set(egg + 3, C.spriteEncode(entries[egg + 3], e.big, {}))`. Toast "Egg replaced." |
| card grid | tiles "No. N" (+ "Baby") | select that character. Picture `c.frames.idle1` (babies at 3x). |

The eye-layer variant (`C.dimEyePreset`, `C.dimGuessEye`, `C.dimCharPartsWithEyes`,
`C.eyeVariants`, `C.eyeRectAt`, texts "Pink frame = eye. ...", "Character has no visible eyes",
"The eyes were too detailed, the character keeps no eye layer.") exists in the code but is switched
off (`state.eyeLayer` is never true).

### 2.5 Tab `emu` (Emulator)

Static part: button `btnEmu` "Choose firmware or ROM" (disabled when `!appRoom()`), hint
"Colour tamas (TamaEmu), Tama-Go and Friends (T7Emu), Meets and On (T18Emu), first Tamagotchis and
Digimon (V1Emu), Connection V3 (V3Emu). The first is the main program, every further one goes to
the menu. The filled star marks the main program, a click on an empty star makes another one the
main program. Bring your own files.", the program list `appsList`, and the status text `emuStat`.

Controls that exist in index.html but are **always hidden** by `renderEmu` since 1.6.8
(app.js:1157, 1180-1186): `btnEmuOff`, `btnEmuUndo`, `btnT7Fig`, `t7Figs`, `emuAutoRow`
(`emuAuto`), `emuClockRow` (`emuClock`), `emuNfcRow` (`emuNfc`), `emuDlc` (`btnDlc`, `dlcList`).
`appsBox` with `btnApp` "Add another emulator" has the `hidden` attribute in index.html:408 and is
never unhidden. Their handlers still exist (app.js:1798, 1889, 1915, 2010-2014) but cannot be
reached; the native screens do not need them. Everything is done through `btnEmu` and the rows.

#### Status text `emuStat` (`renderEmu`, app.js:1149-1187), first match:

1. `!E.embedded()` -> "This build does not contain the emulator program."
2. `state.emu`: V1 -> "First Tamagotchi or Digimon recognised (V1Emu)." or, when
   `E.v3Detect(rom)`, "Tamagotchi Connection V3 recognised (V3Emu)."; T7 -> "V7 ROM recognised
   (T7Emu). It is built in on save." or, when `E.t7Kind(rom) === 'friends'`, "Tamagotchi Friends
   recognised (T7Emu, test). It is built in on save. There are no figures for it."; T18 -> "TG18
   firmware recognised (T18Emu, Meets/On). It is built in on save."; TamaEmu -> "Firmware
   recognised ({size}). It is built in on save." with `size = E.DEVICES[dev].label`.
3. `state.emuRemove` -> "The emulator is removed on save."
4. installed: "This ROM contains T7Emu." / "... T7Emu with Tamagotchi Friends." (installed T7 with
   `E.t7Cfg(rom).romLen === 0xC0000`) / "This ROM contains T18Emu." / "This ROM contains an
   emulator.", plus " Saving puts in the new emulator version. With "Keep saves" the save stays."
   when `emuUpPending()`.
5. otherwise, with extras: "In the ROM as further programs: {n}. No need to choose them again.";
   without: "No emulator chosen."

Appended lines: the use text when a main emulator is chosen or installed and not removed (`v3Use`,
`v1Use`, `t7Use`, `t18Use` or `emuUse`); "This firmware is big: the field switch of the menu has
no room next to it." when `state.emu.big`, or for an installed one when `rom[0xA0148] === 0 &&
rom[0xA014A] === 0x84`; "As the main program the firmware only fits partly packed. ..." when
`mainFew()` (app.js:3182). Then:

- `!appRoom()` replaces everything by "This edition has no room for it." and disables `btnEmu`.
- else `!a0Free()` appends, in a start device, "This edition has no room for a main program at
  0x0A0000: every program goes to the menu. The star chooses what starts when switched on.",
  otherwise "This edition has no room for a main program at 0x0A0000. Tama-Go, Friends, the old
  Tamas and the V3 go to the menu (A and C; switch on field switch or items in the Menu tab).
  Colour Tamas and TG18 work here in a start device only."
- else, outside a start device, without `state.emu`, when DOOM is chosen or installed and not
  removed: "Note: DOOM is chosen or built in. Choosing a firmware here drops DOOM."

#### `btnEmu` -> `fileEmu` (app.js:1990-2009)

1. `E.gbDetect(g)` -> `addExtra(g, name)`, `renderGb()`.
2. `E.smsDetect(g, name)` -> `addExtra`, `renderSms()`.
3. If there already is a program (`state.emu`, or an installed emulator not removed, or any extra),
   or it is a V1 ROM while DOOM is the main program, or `!a0Free()` -> `addExtra(g, name)`.
4. Otherwise it becomes the **main** program:
   - `E.v1Detect(g)` -> `state.emu = { v1, dev:'v1', rom:g, size:g.length + 0x2000 }`
   - `E.t18Detect(g)` -> `state.emu = { t18, dev:'t18', rom:g, size:<used blocks << 16> }`
   - `E.t7Detect(g)` -> `{ t7, dev:'t7', rom:g, figs }` where the figures of the previous T7Emu
     (chosen or installed, `t7State()` app.js:1189) are kept when `E.t7Kind(g) === 'go'`
   - else `dev = E.emuDetect(g)`, `pk = E.packMain(g, dev, null, !!state.emuPack)`,
     `state.emu = { guest:g, dev, size:pk.blob.length, big:pk.big }`; exception -> error
     "Firmware not recognised: {e}".
   After each: `extrasDedupe(null)`, `emuRemoveClear()`, and outside a start device
   `state.doom = null`; `renderDoom()`.
5. `renderEmu()`.

#### `addExtra(g, fname, preset)` (app.js:1861-1888): a further program for the menu

Detection order (first match): `preset` (Arduboy) / `E.gbDetect` (rejected with "{f}: Game Boy
Color only, that does not work" when `E.gbColorOnly(g) && !E.gbIsColor(g)`) / `E.pmDetect` /
`E.smsDetect(g, fname)` / `E.v1Detect` / `E.t7Detect` / `E.t18Detect` / `E.emuDetect` (accepted
only if `E.packGuest(g, dev)` or `E.packGuest(g, dev, { lz: true })` works). Objects created:

- gb: `{ kind:'gb', rom:g, keys:gbKeysNow().slice(), inv:state.gbInv !== false }`
- pm: `{ kind:'pm', rom:g, title:E.pmTitle(fname), keys:pmKeysNow().slice(), inv:state.pmInv !== false, bios:state.pmBios || null }`
- sms: `{ kind:'sms', rom:g, title:E.smsTitle(fname), gg:E.smsGameGear(g, fname), keys:smsKeysNow().slice(), inv:state.smsInv !== false }`
- v1: `{ kind:'v1', rom:g }`; t7: `{ rom:g }`; t18: `{ kind:'t18', fw:g }`; tama: `{ kind:'tama', guest:g, dev }`

Checks and messages, in order:

| Condition | Message (error toast) |
|---|---|
| nothing detected | outside a start device and the file is a colour Tama/TG18 firmware: "{f}: colour Tama and TG18 firmware go as a further program only in a start device. Otherwise remove the emulator above with × first."; in a start device: "{f}: neither a Tama-Go or Friends ROM nor a colour Tama or TG18 firmware."; else "{f}: not a Tama-Go or Friends ROM." |
| `state.extras.length >= E.APPX_MAX` (12) | "At most 12 more emulators." |
| same firmware as the main program or as another extra (`sameFw`, app.js:3121; the installed main is read with `E.t7FromRom` / `E.t18FromRom` / `E.v1FromRom` / `mainGuestLoad`) | "{n} is already in." |
| a T18Emu and there already is one (extra, chosen main, or installed main not removed) | "T18Emu goes only once per ROM." |
| not a start device, `!a0Free()`, kind tama or t18 | "{f}: colour Tamas and TG18 work in this edition in a start device only (Menu tab)." |

Then `x.fresh = true`, push, `extrasDirty = true`, `t7saveX = null`. Outside a start device a tama
or t18 extra is immediately made the main program (`makeMain(last)`, app.js:1883). Otherwise a
trial build `roomFit()` runs; on failure the extra is removed again and the toast is
"No room left for {n}: about {k} KB missing. (The top 64 KB stay free for the write protection.)"
(+ " Tip: "Pack the firmware" for TamaEmu saves room." when `E.PACK_OPT` and an unpacked tama extra
exists) or "More emulators: {e}".

#### Program list (`renderApps`, app.js:1517-1624)

Row = optional toggle ▾/▴ (tooltip "Settings and content"), name, tag, buttons, and an expandable
detail area. Tag texts: main = "Starts with A and C" (`progMain`), in a start device "First entry
of the menu" (`progMainL`); menu program = "Starts from the menu"; removed = "will be removed";
new adds " · new". `lp = state.launch && (doomMain() || state.clean) && mainV9()` = "the star can be
given to any program of the list".

Rows in display order:

1. **The picked main extra** (only when `lp` and `state.mainPick` is an extra): its `xRow` first.
2. **DOOM row** (key `doom`), when `doomMain()`: name "DOOM"; star (in `lp`: ★ when it is the main
   one, else ☆ -> `pick(null)`; otherwise fixed ★ "Main program"); `×` "Remove DOOM" ->
   `doomOut` (app.js:1537): `state.doom = null` if a WAD is chosen, else `emuRemove = true` and
   outside a start device `emu = null`. Detail: outside a start device a checkbox "Start when
   switched on" with hint "Hold the wheel for 2 s: back to the Paradise, it stays there." ->
   `state.emuAuto`; in a start device (`lp`, DOOM is main, not clean) the checkbox with hint
   "Starts at switching on instead of the menu. Hold B while switching on: menu." (`autoL`, also
   sets `mainDirty`). When DOOM is installed but going away (`dGone`): row "DOOM", "will be
   removed", button ↺ "Undo" -> `doomBack` (app.js:1538).
3. **Main row** (key `main`), one of:
   - `state.emu` set: name `emuNm(em)`; buttons: "Add figures (n)" for a Tama-Go
     (`em.t7 && E.t7Kind(em.rom) === 'go'`) -> `figT = 'main'`, `fileT7Fig`; "Add download
     content" for a TamaEmu with `dev` in `['idl','ps','4u','4u-plain']` (`DLC_DEV`, app.js:1196)
     -> `dlcT = 'main'`, `fileDlc`; star (`lp`: ★/☆ `pick('emu')`; DOOM is main: disabled ☆ with
     tooltip "DOOM is the main program. For another one remove DOOM first (×)."; else fixed ★);
     `×` "Undo" -> `undo` (app.js:1551): `emu = null`, `emuRemoveClear()`, `t7save = null`.
     Detail: `mainSet(d, em.dev)`; figures list + "pairHintT7" for Tama-Go; download stores for
     big TamaEmus; link hints; for T18: items, grow-up pictures, MixingMeets.
   - installed emulator, not removed: name = `F.feldApps(rom, stub).name0 || mainName(rom) ||
     'EMU'`; same buttons (figures when the installed T7 has `romLen !== 0xC0000`; download content
     loads `mainGuestLoad()` first); fixed ★; `×` "Remove emulator" -> `emu = null`,
     `emuRemove = true`. Detail: `mainSet(d, cfg ? cfg.dev : F.emuType(rom))`, figures +
     Gotchi Points for Tama-Go, items/pictures/bridge for T18, download stores (shows "Reading…"
     and loads `mainGuestLoad()` when not yet loaded).
   - installed emulator, removed, not `paraMainTaken`: row "will be removed" with ↺ "Undo".
4. **All other extras** (`xRow(x, i)`, app.js:1567-1590), name `E.extraName(x)`:
   - "Add figures (n)" for a Tama-Go extra -> `figT = i`; "Add download content" for a big
     TamaEmu extra -> `dlcT = i`.
   - star: in `lp` ★/☆ -> `pick(x)`; otherwise ☆ -> `busy(() => mainChecked(i))` when
     `!dm && canMain(x)` (app.js:1751), else disabled with tooltip: "Game Boy only in the menu",
     "Master System and Game Gear only in the menu", "Pokémon mini only in the menu", "Arduboy
     only in the menu", "Wolfenstein 3D only in the menu", "DOOM is the main program. For another
     one remove DOOM first (×).", or "Only in a start device".
   - `×` "Remove" (app.js:1574): clears `mainPick` if it was this one (`mainDirty = true`);
     `emuRemove = true` when `x.fromPara`; `doom = null` when `x.wadSrc`; removes it;
     `extrasDirty = true`; `t7saveX = null`; `dlcT = figT = 'main'`; `progOpen = new Set()`.
   - Detail (none for wolf and doom unless it is the picked main one):
     - autostart checkbox when it is the picked main program (`autoL`);
     - "Take the clock from the Paradise at the start" (hint "At every start the Paradise's time
       applies. The time in between is not played through.") -> `x.clock`; not for gb, sms, pm,
       ab, wolf, doom and not for a V1 ROM without a clock (`E.v1Clock(x.rom)` false). Disabled
       and unticked with hint "Only with "Set the clock at the start" (tab Menu)." when
       `clockOff()`;
     - "Remember where you left off" (hint "The next start continues right there. Without: the
       game starts anew and loads its own save, as the real device does.") -> `x.sess`, for kinds
       tama, t18, t7, v1, gb, sms, pm, ab (`SESS_KINDS`, app.js:1505);
     - volume/brightness/screen-off selects for tama and t18 -> `x.opt` (see `optInto` below);
     - "4U: emulate the NFC chip" (hint "The menu reacts to one press. Unticked it works as
       before.") -> `x.nfc`, for tama with dev `4u` / `4u-plain`;
     - "Pack the firmware" (hint "Saves room (about 1 MB for an iD L), but the game runs slower.")
       -> `x.pack`, for tama when `E.PACK_OPT`;
     - Tama-Go: figure chips, "Gotchi Points", link hint; big TamaEmu: download stores; link hints
       per kind; T18: items and MixingMeets.
     Every change sets `extrasDirty = true`.

Below the list: "No emulator yet. Choose firmware or ROM, every further one goes to the menu."
when empty; "More emulators start from the menu: switch on the field switch or items in the Menu
tab." when there are extras and `!menuWanted()`.

`mainSet(d, dev)` (settings of the main program, app.js:1553-1566):

| Control | Condition | State |
|---|---|---|
| "Start when switched on" (hint "Hold the wheel: back to the Paradise, it stays there. Back into the emulator: A and C, or the reset button."; in a v9 start device the `autoHintL` text) | not when DOOM is the main program, not in a clean ROM; in `lp` with `mainPick === 'emu'` the `autoL` variant | `emuAuto` (+ `mainDirty` in a start device) |
| "Take the clock from the Paradise at the start" | always; disabled when `clockOff()` | `emuClock` |
| "Remember where you left off" | always | `emuSess` |
| "4U: emulate the NFC chip" | dev `4u` / `4u-plain` | `emuNfc` |
| "Pack the firmware" | `E.PACK_OPT` and `E.DEVICES[dev]` exists | `emuPack`; additionally rebuilds `state.emu` with the new size: for a chosen firmware `E.packMain(guest, dev, null, v)`; for the installed one `mainGuestLoad()` then `state.emu = { guest: mg.g, dev: mg.dev, size, big, kept: true }`, `mainGuest = null` (app.js:1560-1564) |
| volume / brightness / screen off | dev set and not `t7`/`v1` | `emuOpt` |

`optInto(box, o, set)` (app.js:1496): "Volume": "normal", "quiet", "loud", "off" -> `o.vol` 0..3;
"Brightness": options `E.OPT_LV[i] + ' %'` for `i` in `[1,2,3,4,5,6,7,8,9,10,0]`, stored value
`o.dim` = that `i`; "Screen off after": "as on the Tama", "10 s", "20 s", "30 s", "1 Min", "2 Min",
"5 Min", "10 Min" -> `o.off` 0..7; hint "Also on the device: press the wheel briefly. A change made
there applies until you change it here again."

Star logic outside `lp`: `mainChecked(i)` (app.js:1780) = `makeMain(i)`; in a start device followed
by `roomTry()`, and on failure the previous state is restored with "As the first entry about {k} KB
of room are missing. It stays as it was." or "More emulators: {e}".
`makeMain(i)` (app.js:1759): builds `state.emu` from the extra (tama: `E.packMain`), removes the
extra, puts the old main program (chosen, or `installedX(rom)` app.js:1790) at the front of the
extras - except that outside a start device an old TamaEmu/T18Emu is dropped with "{n} is now the
main program instead of {o}." -, swaps `emuOpt`, resets `t7saveX`, `progOpen`, `dlcT`, `figT`,
`mainGuest`, drops `state.doom` outside a start device; toast "{n} is now the main program. The
saves of the swapped programs start anew." (not for a fresh one).

Per-program content:

- **Figures** (Tama-Go): chips with `E.t7FigName(f.name)` and × (app.js:1454-1465). `fileT7Fig`
  see section 6. For the main program a change makes `state.emu = st` (`t7State()`), so an
  installed T7Emu becomes a "newly chosen" one.
- **Gotchi Points** (`t7GpInto`, app.js:1222): number 0..999999, shown when the save
  (`t7GpSave`, app.js:1209: `state.t7save || SV.t7SaveOut(rom)` for main,
  `SV.t7SaveOut(rom, saveOff)` for an extra read from the ROM) has page 0 (`sv[0] & 1`) and the
  5 BCD bytes at 0x32..0x36 are valid; writing stores a copy in `state.t7save` or
  `state.t7saveX = { i, save }`. Hint "Goes into the ROM like an imported save: the Tama stays,
  the running state starts anew (choose DOWNLOAD on the device)."
- **Download content** (`dlcInto`, app.js:1467): one box per `E.dlcStores(guest)` store, title
  `t('dlcK' + st.kind)` + `used/total` ("Meals", "Snacks", "Clothing", "Accessories", "Items",
  "Daily items", "Wallpapers", "Games", "Destinations", "Letters", "Recipes", "Stamp card", "Happy
  mail", "Decorations", "Coupons", "Bingo", "Gashapon", "Characters"), each used slot with
  "remove" -> `g.set(E.dlcFree(g.guest, st.kind, x.slot))`, and when
  `E.SAVE_FLAG[dev].kind === st.kind` `stampMark(tg, 0)`; toast "{n} removed."; "{n} free".
  The target (`dlcTarget`, app.js:1198) writes back into `x.guest`, `state.emu.guest`, or turns the
  installed main firmware into `state.emu` (`kept: true`).
- **T18 items** (`t18ItemsInto`, app.js:1399): `it = E.t18Items(fw)`; without a save: "Items work
  once the game has run (read the ROM from the device)."; else button "Choose MyMeets files",
  "Tamapoints" number 0..65535 -> `E.t18Points(fw, n)`; per area (`food` "Food", `item` "Items",
  `acc` "Accessories", `dl` "Games and destinations") the used slots with picture, name (`t18Nm`),
  count select 1x/2x/3x -> `E.t18ItemCount(fw, a.key, x.n, n)` (hidden when `a.noCount`), "remove"
  -> `E.t18ItemDel(fw, a.key, x.n)`; box "Room": "remove own room" -> `E.t18RoomReset(fw)` or
  "built-in room". Every change calls the target's `set()`: `x.items = true; extrasDirty = true`,
  or `state.emu.items = true`, or `state.t18Dirty = true` for the installed main T18Emu
  (`t18Target`, app.js:1238). Hint `t18ItemsHint`.
- **Grow-up pictures** (`t18PicsInto`, app.js:1254; main T18Emu only): "Choose pictures",
  "Remove pictures" (-> `t18Pics = new Map()`, `t18PicsDirty = true`), thumbnails
  (`E.t18PicRgba(p)`, caption from `E.T18_ADULTS`), hint `t18PicsHint`.
- **MixingMeets bridge** and **pair hints** (`t18BridgeInto`, `pairInto`, app.js:1366-1398): pure
  text plus a browser bookmarklet (`pmxBridge`, app.js:1291-1362). Not portable as is; the texts
  are `mmTitle`, `mmHint2`, `pairTitle`, `pairHint`, `pairHintT7`, `pairHintPs`, `pairHintIdl`,
  `pairHintDigi` (V1 ROM whose `E.v1Name` starts with `DIGIMON`), `pairHintV3`.

### 2.6 Tab `doom`

| Control | Type | Label | Shown/enabled | Action |
|---|---|---|---|---|
| `btnWad` | button | "Choose DOOM.WAD" | disabled when `!appRoom()` | `fileWad` (app.js:2383): not clean, not a start device and `!a0Free()` -> error "In this edition DOOM works in a start device only (Menu tab)."; else `state.doom = await doomCompute(w, [])`; outside a start device `state.emu = null`; when not `doomFree()` `emuRemove = false`; `doomFreeSync()`. Error -> `state.doom = null`, "WAD not recognised: {e}". |
| `doomEp` | select | "Episode", options `E<n>` for the fitting base episodes (`d.ok` without P/Q keys), `E1` without a WAD | hidden in "multi" mode | `renderDoom()` |
| `doomEpsBox` | checkboxes | per fitting entry: `E<n> (<x.x> MB)` or the title of an own episode, with ", {m} MB less with DOOM" when `linkSaved >= 0x100000`; first a checkbox "Whole WAD as one entry (<x.x> MB)" when `d.fit.all` exists (disabled and ticked for DOOM II) | only in "multi" mode: `doomFree()` and a WAD chosen and (more than one fitting entry, or a P/Q entry, or the whole WAD fits) | toggles `d.sel` / `d.whole`, then `doomFreeSync(); renderEmu(); renderDoom()`. With "whole" ticked the base episodes are not listed. |
| `doomMusic` | checkbox, default on | "Music" | disabled (and unticked) when the relevant fit has no `music` (single: `d.fit[doomEp]`; multi: the whole WAD, or the first selected entry that has room for music) | app.js:2301-2303: every DOOM extra from a WAD gets `x.size = doomEpSize(...)`, `x.mcu = null`; `extrasDirty = true`. |
| `btnPwad` | button | "Choose extra WAD" | shown when a WAD is chosen | `filePwad` (multiple, app.js:2397): `info = D.pwadInfo(data, name)`; a DOOM II map pack with a DOOM I WAD -> "{n} is for DOOM II: choose DOOM2.WAD first."; the reverse -> "{n} is for DOOM or Ultimate DOOM: choose DOOM.WAD first."; then `doomCompute(d.wad, pwads, d.sel)` (same file name replaces), `whole` kept if still possible. |
| `btnPwadOff` | button | "Remove extra WADs" | shown when extra WADs are in | `doomCompute(d.wad, [], d.sel)`. |
| `btnDoomOff` | button | "Remove DOOM" | `doomFree()`: shown when there is a DOOM extra; else shown when DOOM is installed, not removed and no WAD chosen | app.js:2335: `doomFree()`: removes every DOOM extra (clears `mainPick`, `emuRemove = true` for `fromPara`), `doom = null`; else `doom = null`, outside a start device `emu = null`, `emuRemove = true`. |
| keys box `doomKeys` | - | "Buttons" | shown when a WAD is chosen or DOOM is in (`has && (doomFree() || !emuRemove)`) | see below |
| `kFire`, `kFwd`, `kBack`, `kMod` | selects A/B/C (values 1/2/4) | "Fire", "Forward", "Back", "Change weapon: hold + wheel" | disabled for an installed old DOOM without key block | `keysChanged` (app.js:2328) writes all seven controls into `state.doomKeys` |
| `kUse` | select A/B/C/"Wheel press" (8) | "Use" | same | same |
| `kRun`, `kInv` | checkboxes | "Run with 2x forward", "Wheel reversed" | same | same |
| `keysStat` | text | `em(D.doomKeysCheck(k))` in red, or "Always the same: A+C menu, B+C map. ..." (`kFixed`), or for an old DOOM "This DOOM is older and has no own button layout yet. Build it in again with the WAD." | | |

Defaults: `D.KEYS_DEFAULT = { fire: 1, fwd: 2, back: 4, use: 8, mod: 4, run: true, invert: true }`
(doom.js:488).

Status `doomStat` (`renderDoom`, app.js:2271-2327), first match: "This build does not contain the
DOOM program." (`!D.embedded()`); "No episode of this WAD fits into the ROM." (WAD chosen, nothing
fits); "WAD recognised ({eps}). DOOM is built in on save." (`eps` = "DOOM II" or `E1, E2, ...`)
+ "With: {n}." and, for extra WADs with own episodes, "Own episodes (like Sigil) only go without
the Paradise." (not `doomFree()`) or "Own episodes (like Sigil) go into the menu as their own
entry, tick them for that. ..." + per big pack "{n}: the maps {m} are probably too big ..." +
`doomUse`; "DOOM is removed on save."; "This ROM contains DOOM." + `doomUse`; "No WAD chosen.".
Multi mode appends "DOOM II goes into the menu as one entry. ..." / "All episodes in one entry
"DOOM", ..." / "Without the Paradise: each ticked episode goes into the menu as its own entry ...".
No music room: "This episode only fits without music.". `!appRoom()` replaces all by "This edition
has no room for it." and disables `btnWad`. Outside a start device, without a WAD, with an
emulator chosen or installed: "Note: an emulator is chosen or built in. Choosing a WAD here drops
the emulator."

`doomCompute(w, pwads, keepSel)` (app.js:2342) - see section 7, it is logic.

`doomFreeSync()` (app.js:1712) keeps `state.extras` in step with the DOOM tab when DOOM is a menu
program: one extra per wanted entry `{ kind:'doom', wadSrc:d, ep, size, keys }` (`region =
0xA0000` and `d2` for `'all'`, `title` for P/Q), a save of an entry with the same menu name
(`'DOOM'`, `'DOOM II'`, `'DOOM E<n>'`, or the title) is taken over, the star stays with DOOM; the
DOOM of a Paradise start device is turned into an extra with `doomParaX(rom)` (app.js:1693,
`fromPara: true`). When not `doomFree()` all `fromPara`/`wadSrc` extras are removed again.
`paraMainSync()` (app.js:1700) does the same for the Paradise's main emulator
(`installedX(rom)` -> extra with `fromParaMain: true`, `emuRemove = true`, `paraMainTaken = true`).

### 2.7 Tabs `gb`, `sms`, `pm`, `ab` (console games)

All four have the same structure: a pick button, the list of games of that kind (name
`E.extraName(x)` + size in KB + × "Remove" -> splice, `extrasDirty = true`), the note "More
emulators start from the menu: switch on the field switch or items in the Menu tab." when there
are games and `!menuWanted()`, the empty text "No game chosen yet.", and a key grid "Keys" with one
select per input. The inputs are the same nine everywhere (`GB_INS`, app.js:2024): "Key A", "Key
B", "Key C", "Wheel press", "Wheel up", "Wheel down", "A + C", "B + C", "A + B". The key array
(9 codes) and "Wheel reversed" are **one layout per kind for all games**: every change copies
`keys` and `inv` into all extras of the kind and sets `extrasDirty` (`*KeysApply`). The layout is
initialised lazily from the first extra of the kind that has 9 keys, else the default with
`inv = true` (`*KeysNow`). The pick buttons show "Open a ROM first (or read it from the device)."
without a ROM.

| | Game Boy | Master System / Game Gear | Pokémon mini | Arduboy |
|---|---|---|---|---|
| Pick button | `btnGb` "Choose games (.gb, .gbc)" | `btnSms` "Choose games (.sms, .gg)" | `btnPm` "Choose games (.min, .zip)" | `btnAb` "Choose games (.hex, .zip)" |
| File input | `fileGb` (multiple) | `fileSms` (multiple) | `filePm` (multiple) | `fileAb` (multiple) |
| Hint | `gbHint` | `smsHint` | `pmHint` | `abHint` |
| Button options (code, label) | `GB_BTNS` app.js:2023: 0 "–", 1 A, 2 B, 8 Start, 4 Select, 16 Right, 32 Left, 64 Up, 128 Down | `SMS_BTNS` app.js:2066: 0 "–", 16 "Button 1", 32 "Button 2", 64 "Pause / Start", 8 Right, 4 Left, 1 Up, 2 Down | `PM_BTNS` app.js:2109: 0 "–", 1 A, 2 B, 4 C, 64 Right, 32 Left, 8 Up, 16 Down, 128 Power, 256 Shake | `AB_BTNS` app.js:2173: 0 "–", 16 A, 32 B, 8 Right, 4 Left, 1 Up, 2 Down |
| Default keys | `E.GB_KEYS_DEFAULT` `[32,2,16,1,64,128,8,0,0]` | `E.SMS_KEYS_DEFAULT` `[4,16,8,32,1,2,64,0,0]` | `E.PM_KEYS_DEFAULT` `[32,2,64,1,8,16,4,0,256]` | `E.AB_KEYS_DEFAULT` `[4,32,8,16,1,2,0,0,0]` |
| "Not assigned: {n}" lists | A, B, Start | Button 1, Button 2 | A, B, C, Right, Left, Up, Down | A, B, Right, Left, Up, Down |
| Wheel reversed | `gbInv` | `smsInv` | `pmInv` | `abInv` |
| "Default" button | `btnGbKeysDef` | `btnSmsKeysDef` | `btnPmKeysDef` | `btnAbKeysDef` |
| State | `gbKeys`, `gbInv` | `smsKeys`, `smsInv` | `pmKeys`, `pmInv`, `pmBios` | `abKeys`, `abInv` |
| Render / handlers | app.js:2027-2064 | app.js:2069-2106 | app.js:2114-2170 | app.js:2176-2215 |

Pokémon mini only: `btnPmBios` "Choose own BIOS" (`filePmBios`), `btnPmBiosDel` "Remove own BIOS"
(shown when a BIOS is set), text "Own BIOS chosen, it is used for all Pokémon mini games." /
"Without an own BIOS the free BIOS of PokeMini runs. Some games run better with the real BIOS."
`pmBiosApply` (app.js:2113) copies `state.pmBios || null` into every pm extra.

A stored key code that is not among the options shows as "–" (0) (e.g. app.js:2045).

### 2.8 Tab `wolf` (Wolf3D)

| Control | Label | Action |
|---|---|---|
| `btnWolf` | "Choose game files" | `fileWolf` (multiple), section 6. |
| hint | "Choose all files of Wolfenstein 3D together: shareware (.WL1), full version (.WL6) or Spear of Destiny (.SOD). The game goes into the Paramix menu." | |
| list `wolfList` | per wolf extra: `E.wolfInfo(x.pack)` -> "SPEAR OF DESTINY  21 floors" or "WOLFENSTEIN 3D  Shareware/Full version, {n} episodes/1 episode" + "(N KB)"; × removes it. Empty: "No game files chosen yet." | |
| `wkFire`, `wkFwd`, `wkBack`, `wkMod` | selects A/B/C; `wkUse` also "Wheel press" | `wolfKeysNow()[field] = value; wolfKeysApply()` (app.js:2246-2248) |
| `wkTurn` | select 5°, 10°, 15°, 20°, 30°, 45° ("Turn per wheel step") | `keys.turn` |
| `wkRun`, `wkInv` | "Run with 2x forward", "Wheel reversed" | `keys.run`, `keys.invert` |
| `btnWolfKeysDef` | "Default" | `state.wolfKeys = Object.assign({}, E.WOLF_KEYS_DEFAULT)` = `{ fire:1, fwd:2, back:4, use:8, mod:4, run:true, invert:true, turn:15 }` |
| `wolfKeysStat` | `wolfKeysCheck` (app.js:2221): "Wolfenstein 3D: fire, forward and back need three different buttons" when two of fire/fwd/back are equal | |
| fixed hint | "Always the same: A+C menu. Back (the game is saved): as set in the Menu tab under "Back from programs"." | |

`wolfKeysApply` (app.js:2222) copies the keys into every wolf extra and, if there is one, sets
`extrasDirty` and `wolfKeysDirty`.

### 2.9 Tab `feld` (Menu)

`renderFeld` (app.js:2453-2502). `fe = F.embedded()`, `ed = F.edition(rom)`, `can =
F.canFields(rom)` (false for Neon Planets: `ed.profile.ring`), `la = state.launch`,
`si = S6.sixInfo(rom)`, `sixCan = !!S6.kindOf(rom)`, `jade = S6.kindOf(rom) === 'jade'`.

| Control | Type | Label / hint | Checked | Disabled / hidden | On change |
|---|---|---|---|---|---|
| `launchOn` | checkbox | "Start device for programs only" / "Only the setup of the Paradise stays (language, clock, continue or new). After it the menu with your emulators and DOOM always comes up. All pictures of the game go, which gives about 5 MB more room." | `state.launch` | disabled when `!fe`, `!ed`, the loaded ROM is clean, the ROM is already a start device with reduced pictures (`state.launchInit && C.isLauncher(ctx)`), or six fields are built in (tooltip "A start device does not go with six fields built in. Please load the original ROM.") | app.js:2505-2510: `state.launch = v`. Off: `clean = false`, `paraMainSync()`, `doomFreeSync()`, `cleanTabs()`. On: `launchMapGet()` (computes `C.launcherChanges(ctx)`), `feld = bag = tama = gplay = false`, `sixWant = false`, `six = null`. Then re-render info, menu, emulator, names. |
| `cleanOn` (row `cleanRow`) | checkbox | "Without the Paradise (clean ROM)" / "No Paradise on the device any more, only the menu with your programs. Almost the whole 16 MB is free." | `state.clean` | row hidden unless `la`; disabled when `!fe`, `!ed`, loaded ROM is clean, `!FL.embedded()` or `!cleanCan()` | app.js:2513-2519: `state.clean = v`; on: `six = null`, `sixWant = false`; `paraMainSync()`, `doomFreeSync()`; `roomFree = null`; `cleanTabs()`. |
| `cleanClock` (row `cleanClockRow`) | checkbox, default on | "Set the clock at the start" / "When the clock is missing (new batteries), the menu asks for it when switched on. Without: set the clock in the menu under SETTINGS or in each emulator itself." | `state.cleanClock !== false` | row hidden unless `state.clean` | `cleanClock = v`, `mainDirty = true` (app.js:2520). |
| `feldOn` | checkbox | "Several saves (with field choice)" | `feld && can && !la` | disabled when `!fe`, `!can` (Neon) or `la` | `state.feld = v` (app.js:2503). |
| `bagOn` | checkbox | "Items and Tamapoints" | `bag && !la` | disabled when `!fe`, `!ed` or `la` | `state.bag = v`. |
| `tamaOn` | checkbox | "Change Tama (level, care, character)" | `tama && !la` | same | `state.tama = v`. |
| hint | "Small menu in the ROM: switch between saves (a new save on a field of your choice), put items in the bag, set Tamapoints, change the Tama." | | | | |
| `gplayOn` (row `gplayRow`) | checkbox | "Play time earns Tamapoints" / "DOOM, Wolfenstein, Game Boy, Master System, Pokémon mini and Arduboy: 10 Tamapoints per minute of play, when going back to the Paradise." | `gplay && !off` with `off = la || state.clean || ctx.clean` | row hidden when `!F.GPLAY`; disabled when `!fe`, `!ed` or `off` | `state.gplay = v`. |
| `exitKey` | select 0..3 | "Back from programs" / "How to get from all programs (emulators and games) back to the Paradise or the menu."; options "Hold the wheel", "Hold wheel and A", "Hold wheel and C", "Hold the wheel 5 s" | `state.exitKey` | never | `state.exitKey = +v` (app.js:2504). |
| `sixOn` (row `sixRow`) | checkbox | Tropical/Glacier: "All 6 fields" / "Adds Land, Water and Sky to Tropical and Glacier. The field pictures come from your own Land, Water or Sky ROM. The lab games follow the field the Tama starts with in the menu."; Jade Forest: "Sky as 4th field" / "Jade Forest already has the Sky pictures." | `(sixIn && !sixOff) || six || sixWant` | row hidden unless `sixCan && !la`; disabled when `!fe` or `!S6.embedded()` | app.js:2521-2527: `sixOff = !v && !!S6.sixInfo(rom)`; `sixWant = v`; off: `six = null`; on: `feld = true` and, when no source is loaded and `S6.sixNeedsSource(rom)`, opens `fileSix`. Re-renders menu and names. |
| `btnSix` | button | "Choose Land, Water or Sky ROM" | - | hidden for Jade, and when the fields are built in, current and with the chosen options (`sixIn && !sixOld && sixSame(si)`) | `fileSix`, section 6. |
| `sixPlanet` (row `sixPlanetRow`) | checkbox, default on | "Planet to match the field" | `sixPlanet !== false` | row hidden unless `sixCan && !la` and six fields are in or wanted; disabled when `!fe` or `!S6.embedded()` | `state.sixPlanet = v`. |
| `sixMenu` | checkbox, default on | "Game menu Fields: all fields from level 4" | `sixMenu !== false` | same | `state.sixMenu = v`. |

`sixOld = si && (si.version < S6.VERSION (7) || S6.sixStale(si))`; `sixSame(si)` (app.js:2450):
installed planet/fieldMenu options equal the checkboxes.

Status `feldStat`, first match: "This build does not contain the menu." (`!fe`); "Edition not
recognised." (`!ed`); clean: "After switching on the menu comes up right away. On the first start
you set the clock, later under SETTINGS. Leave a program as usual." + (when the loaded ROM still
has the Paradise) "The Paradise and its save are lost when writing. Make a backup first."; start
device: "After switching on and setting the clock the menu comes up. Wheel selects, B starts.
Leave a program as usual, then the menu comes up again." + (reduced start device loaded) "This ROM
is a start device. Load the original ROM for a normal Paradise."; Neon (`ed.profile.ring`): "Neon
Planets: the game switches its planets itself. Items, Tamapoints, Tama and programs work." (+
`feldUse` when bag or tama is on); otherwise "Active field: {f}." (`F.fieldNow(rom)`) and, when
`can`, " Selectable: {s}." (`F.fieldNames(rom)`, cut to 3 when the extra fields go out, extended by
`Sky` or `Land, Water, Sky` when they come in) and " Saved: {s}." (`F.feldSlots(rom, fe.stub)`:
"Save {n}" when the menu has `F.F_SAVES` and version >= 6, else `F.NAMES[x.field]`); when `!can`:
"Field switch works with Land, Water, Sky (among each other) and Tropical, Glacier (among each
other).". Six-field lines (app.js:2487-2497): "Saving takes Land, Water and Sky out again. Several
saves keep working." / "Saving takes Sky out again. ..."; Jade: "Sky is built in and is updated
when you save." / "Sky is built in as the 4th field." / "The firmware of this ROM is changed, more
fields do not work here." (`!S6.sixCan(rom)`); Tropical/Glacier: "Field pictures taken from {n}." /
"All 6 fields are built in, but an older version. Choose your Land, Water or Sky ROM and everything
is updated when you save." / "Changing this setting needs your Land, Water or Sky ROM again." /
"All 6 fields are built in." / "The firmware of this ROM is changed, ..." / "All 6 fields still
need a Land, Water or Sky ROM." Last line when feld, bag or tama is on: "Open: hold A and C
together on the home screen. Wheel selects, B confirms, C goes back."

### 2.10 Tab `save` and 2.11 device panel

See section 5.

---

## 3. "Save new ROM"

`btnSave` (app.js:2787-2794):

1. `c = await composeRom()`; `null` -> stop (the reason was toasted).
2. `c.same` -> toast "Nothing changed yet." and stop.
3. `packOk(c.rom)` (app.js:3190): `packedTamas(rom)` (app.js:3172) lists the main TamaEmu when
   `E.lzCount(rom, cfg.lzOff) > E.PACK_FEW` and all `E.appsPacked(rom, apps)`; if not empty a
   confirm "Note: the firmware of {n} gets packed so it fits. Packed, the game runs slower. ...
   Continue anyway?" - No stops.
4. `download(c.rom, c.name)`; `state.saved = state.changed.size`.
5. Toast: with a sprite rebuild (`c.res`) "Saved: {name}\n{n} sprites changed, {kb} KB still free."
   (`kb = c.res.free / 1024 | 0`), otherwise "Saved: {name}".

The same `composeRom()` is used by "Write new ROM to the device" (section 5.2) and by every trial
build (`roomTry`). **It has side effects on `state`**: `extrasDedupe` can drop extras
(app.js:2594, 2649), `paraMainSync`/`doomFreeSync` rewrite the extras (app.js:2584), DOOM extras
get `keys`/`mcu` assigned (app.js:2604-2606, 2744-2746), `lastRoom`/`lastFree`/`tamaPacked` are
set, and it can show a `confirm` (app.js:2716; `roomSoon` skips trial builds while `sixOff` for
that reason, app.js:1029).

### 3.1 `composeRom()` for a ROM with the Paradise (app.js:2634-2786)

`src = state.ctx.rom`, `fe = F.embedded()`. Every step that fails shows an error toast and returns
`null`. Order:

**0. Clean?** `state.clean` -> `composeClean()` (3.2).

**1. Nothing to do?** (app.js:2636-2639) Returns `{ rom: src, name: state.name, res: null, same:
true }` when *all* of these hold: no changed sprites; no `t7save`, `emu`, `emuRemove`, `doom`; DOOM
keys unchanged (`keysDirty`: installed DOOM whose `D.doomKeysGet(rom)` differs from
`state.doomKeys`); `!emuUpPending()`; `!emuAutoDirty()` (app.js:1132: autostart, clock, session,
NFC, options differ from the ROM); no `six`; no pending six update (`sixUp`: installed fields older
than `S6.VERSION` or with other options and no source needed, or `sixDnaUp(si0)` app.js:2452);
not (`sixWant` without installed fields); `feld`/`bag`/`tama`/`gplay`/`saves`/`launch` equal their
`*Init`; `exitKey` equals `exitKeyInit`; not `feldStale`, `extrasDirty`, `mainDirty`, `extrasUp`,
`t7saveX`, `saveIn`, `sixOff`, `petDirty`, `t18Dirty`, `t18PicsDirty`; no texts, eye shifts, mouth
shifts, pose adjustments.

**2. Preparation** (app.js:2640-2650)
- `feldSaved = fe ? F.feldSlots(src, fe.stub) : []` (the saves the menu keeps).
- `doomL = state.launch && (state.doom || (doomInstalled() && !state.emuRemove))`: start device with
  DOOM as the program at 0x0A0000.
- `mainX` (an emulator that goes along as a *further* program): `emuX(state.emu)` when `doomL &&
  state.emu`; `await installedX(src)` when `doomL && state.doom && emuInstalled()`; else `null`.
  If set: `mainX.clock = emuClock !== false; mainX.nfc = emuNfc !== false; mainX.opt = emuOpt;
  mainX.sess = emuSess !== false`.
- `extrasDedupe(mainX)`; `extrasL = mainX ? [mainX, ...state.extras] : state.extras`.

**3. Early validations** (app.js:2651-2656)
- `state.emu && state.doom && !doomL` -> "Emulator and DOOM do not fit into one ROM together.
  Please choose only one."
- `state.doom && state.doomKeys && D.doomKeysCheck(state.doomKeys)` -> that message.
- `state.launch && !FL.embedded()` -> "This build does not contain the emulator program."
- `state.launch` and no program at all (`!(emu || doom || extras.length || (appInstalled() &&
  !emuRemove))`) -> "A start device needs at least one program (emulator or DOOM)."

**4. Characters and pictures** (app.js:2657-2662). `lmap = state.launch ? launchMapGet() : null`.
When there are changed sprites, a non-empty `lmap`, or any eye/mouth/pose shift:
`all = lmap ? new Map([...lmap, ...state.changed]) : state.changed`;
`res = C.buildRom(state.ctx, all, currentDataPack()); rom = res.rom`. Error -> "Too big for the
free space. {e}". `currentDataPack()` (app.js:887) returns `null` or a patched `files[0]`, built in
this order: for each `eyeOffsets` entry (dead path) `C.hideEyes` / `C.setEyeOffset(dp, g, g+1, 64,
32, x, y)` and `(dp, g+3, g+4, 32, 16, x, y)`; for each `mouthShift` `C.shiftEyes(dp, g, g+2, dx,
dy)` and `C.shiftEyes(dp, g+3, g+5, half(dx), half(dy))`; for each `poseAdj` map
`C.layersMove(dp, [...m.values()])`; for each `eyeShift` `C.shiftEyes(dp, g, g+1, dx, dy)` and
`C.shiftEyes(dp, g+3, g+4, half(dx), half(dy))`. Each call returns `{ dataPack }` (except
`layersMove`, which returns the pack).

**5. Names** (app.js:2664): `rom = C.textApply(rom, state.texts)` when there are edits. Error ->
"Too big for the free space. {e}".

**6. Take the old menu out** (app.js:2665): `rom = F.feldStrip(rom, { stub: fe.stub, oldStub:
E.embedded() && E.embedded().stub }, E)` (when `fe`).

**7. Take the old menu programs out** (app.js:2671): `old = E.appsRead(src, F.feldApps(src,
fe.stub).apps)`; `rom = E.appsClear(rom, old.filter(o => !extrasL.some(x => x.kind === 't18' &&
x.keepOff === o.off)))` (a T18Emu that stays in place is not cleared).

**8. Start device: free what removed programs left behind the save** (app.js:2673):
`ff = F.feldFind(rom, fe.stub)`; `rom = E.hiFree(rom, <keepOff of the kept T18Emus>, ff ? ff.off :
0)`.

**9. Remember the kept T18Emu's blocks** (app.js:2674-2675): `t18Keep = keptT18Ranges(extrasL,
rom)` (app.js:2547: for each kept T18Emu the 64 KB blocks of `E.t18Cfg(rom, keepOff).map` and
`.spare` that are not 0xFFFF, plus `[keepOff, keepOff + 0x10000]`); `t18Back(r)` copies those
ranges from the ROM of this moment back into `r`; `romMain0 = rom`.

**10. Main program at 0x0A0000** (app.js:2676-2688)
- Emulator replaces an installed DOOM (`state.emu && doomInstalled() && !doomL`): first
  `rom = t18Back(E.emuRemove(rom))`. Error -> "Emulator not built in: {e}".
- If `(state.emu && !doomL) || state.emuRemove`, with `emb = E.embedded()`:
  - `state.emu && doomL`: nothing (it is in `extrasL`).
  - V1: `rom = E.v1Patch(rom, emu.rom, E.v1Embedded(), emb.stub, { lang, clock: emuClock !== false })`
  - T7: `rom = E.t7Patch(rom, emu.rom, emu.figs, E.t7Embedded(), emb.stub, { lang })`
  - T18: `rom = E.t18Patch(rom, emu.rom, E.t18Embedded(), emb.stub, { lang, launch: !!state.launch,
    spares: state.t18Few ? 6 : undefined, holes: !!state.t18Few }).rom`
  - TamaEmu: `rom = E.emuPatch(rom, emu.guest, emb.app, emb.stub, { lang, pack: !!state.emuPack }).rom`
  - only `emuRemove`: `rom = t18Back(E.emuRemove(rom))`
  - a missing embedded program throws "This build does not contain the emulator program.".
  - Error with `e.needPack` -> "This firmware only fits here packed: switch on "Pack the firmware"
    in the row of TamaEmu."; any other -> "Emulator not built in: {e}".
  - Afterwards, if any byte inside `t18Keep` differs from `romMain0`: "Emulator not built in: the
    main program would need the room of Tama Meets. Remove Tama Meets first."

**11. Saves of the main program** (app.js:2689-2693)
- `state.t7save` and `F.emuType(rom) === 't7'` and `!doomL`: `rom = SV.t7SaveIn(rom, state.t7save)`.
- `state.saveIn.key === 'm'` and `!doomL`:
  - kind `v1` and the main is V1Emu: copy `saveIn.data` (0x2000 bytes) to 0xC0000;
    `fresh.push([0xC0000, 0xC2000])`.
  - kind `tama` and the main is TamaEmu: `g0 = rd32(rom, 0xA0148)`; `se = rd32(rom, 0xA0144) >= 3 ?
    rd32(rom, 0xA0140 + 152) : g0 + rd32(rom, 0xA014C)`; `fresh.push([0xC0000, 0x110000], [g0, se])`.
  `fresh` = address ranges that must come from the image even with "Keep saves".

**12. Newer emulator program** (app.js:2695): when `emuUpPending()` was true and
`F.appKind(rom) === 2`: by `F.emuType(rom)`: `E.v1Upgrade(rom, E.v1Embedded())` /
`E.t7Upgrade(rom, E.t7Embedded())` / `E.t18Upgrade(rom, E.t18Embedded(), E.embedded().stub)` /
`E.emuUpgrade(rom, E.embedded().app)`; a truthy result replaces `rom`.

**13. T18Emu content** (app.js:2696-2697)
- `t18Dirty && t18Main && !emu && !emuRemove` and the main is T18Emu:
  `rom = E.t18RomWriteGuest(rom, state.t18Main)`; `t18Fresh(rom, 0xA0000, fresh)` (app.js:1276: adds
  `[saveOff, saveOff + 0x24000]` and every spare block). Error -> "Emulator not built in: {e}".
- main is T18Emu and `t18Pics` has entries or `t18PicsDirty`: `rom = E.t18PicsWrite(rom, state.t18Pics)`.

**14. DOOM at its fixed place** (app.js:2698-2711)
- WAD chosen but nothing fits (`!doom.ok.length && !(doom.fit.all && doom.fit.all.plain)`) -> "No
  episode of this WAD fits into the ROM."
- `state.doom && !doomFree()`: `rom = (await D.doomBuild(rom, doom.wadM || doom.wad, { episode:
  doomEp.value, music: doomMusic.checked, keys: state.doomKeys || D.KEYS_DEFAULT }, { app: emb.app,
  xip: emb.xip, wasm: emb.wasm, stub: E.embedded().stub }, E)).rom` with `emb = D.embedded()`.
  Missing program -> "This build does not contain the DOOM program."; error -> "DOOM not built in:
  {e}".
- no new WAD, DOOM installed and kept, `state.doomKeys` set and `D.doomKeysGet(rom)` truthy:
  `D.doomKeysCheck(k)` (error -> message), `rom = D.doomKeysSet(rom, k)`.

**15. Six fields** (app.js:2713-2731)
- Taking them out (`state.sixOff && S6.sixInfo(rom)`): `base = F.fieldNames(S6.sixStrip(src))`,
  `now = F.fieldNow(src)`; the active field is not one of the base fields -> "The device is on {f}
  now. First switch to {s} in the menu."; stored saves exist -> confirm "The saves stored in the
  menu are deleted. Continue?" (No -> stop); `rom = S6.sixStrip(rom)`; `feldSaved = []`.
- `needSrc = S6.sixNeedsSource(rom)`; `sixWant && needSrc && !six && !S6.sixInfo(rom)` -> "All 6
  fields still need a Land, Water or Sky ROM."
- `sixHave = S6.sixInfo(rom)`; current version, options changed, source needed but missing ->
  "Changing this setting needs your Land, Water or Sky ROM again."
- Apply when `(six || (sixWant && !needSrc) || (!needSrc && sixHave))` and not already current
  (`sixHave.version >= S6.VERSION && sixSame(sixHave) && !S6.sixStale(sixHave)`):
  - `state.doom || doomInstalled() || state.emu` -> "Fields not built in: DOOM and the emulator do
    not fit with it"
  - any extras -> "Six fields do not go together with more emulators."
  - `rom = S6.sixApply(rom, state.six, S6.embedded(), { planet: sixPlanet !== false, fieldMenu:
    sixMenu !== false })`; error -> "Fields not built in: {e}".
- Then, whenever `S6.sixInfo(rom)`: `rom = S6.sixDna(rom, S6.embedded(), true)` (if `S6.DNA`);
  `rom = S6.sixHunt(rom)` (if `S6.HUNT`); `rom = S6.sixFix(rom)`.

**16. Programs of the menu** (app.js:2733-2763), only when `extrasL.length || state.launch`:
- `!fe || !menuWanted()` -> "More emulators start from the menu: switch on the field switch or
  items in the Menu tab."
- `!E.t7Embedded()` -> "This build does not contain the emulator program."
- `progs = { t7: E.t7Embedded(), tama: E.embedded() && E.embedded().app, t18: E.t18Embedded(), v1:
  E.v1Embedded() }`.
- DOOM as a menu program (`doomFree()`): for every DOOM extra: `D.embedded().appF` missing -> "This
  build does not contain the DOOM program."; `x.keys = copy of state.doomKeys` (if set);
  `D.doomKeysCheck(x.keys)` -> message; from a WAD: `x.mcu = doomMcuOf(x)` (app.js:1688:
  `fit[x.ep || doomEp.value]`, fallback `fit[ok[0]]` unless `ep === 'all'`; `mcuM` when music is
  ticked and fits, else `mcuP`), none -> "No episode of this WAD fits into the ROM."; then
  `progs.doom = { app: de.appF, xip: de.xipF }`.
- Start device: `rom = dlStrip(rom, fe)` (app.js:2562, removes stale copies of the flash app);
  `w = FL.withRescue(rom, FL.embedded())`; if truthy `rom = w`, `dlRes = true` (the **rescue block**
  at 0xFF0000 is part of the image and DOWNLOAD in the menu starts it).
- `r = E.appsPlace(rom, extrasL, progs, { lang, clock: emuClock !== false, nfc: emuNfc !== false,
  launch: !!state.launch, txSpare: state.t18Few ? 0x40000 : undefined, keep: F.appKind(rom) === 1 ?
  [[0x830000, 0xD48000]] : [], dlApp: state.launch && !dlRes ? FL.embedded() : null })`;
  `rom = r.rom; apps = r.list; appsLow = r.low; dl = dlRes ? DL_AT : r.dl; lastFree = r.freeKB`
  (`DL_AT = 0x10000000 + 0xFF0000 - 0x11000`, app.js:2561).
  **Packing** of TamaEmus in the menu happens inside `appsPlace` from `x.pack`; of the main one in
  `E.emuPatch` from `pack`.
- After placing: for each kept T18Emu with `x.items`: `t18Fresh(rom, x.keepOff, fresh)`;
  `state.t7saveX`: `rom = SV.t7SaveIn(rom, t7saveX.save, apps[t7saveX.i + (mainX ? 1 : 0)].off +
  0x10000)`; `state.saveIn` with a numeric key: `cx = E.extraCfg(rom, apps[key + shift].off)`; kind
  `v1`: copy the data to `cx.saveOff`, `fresh.push([cx.saveOff, cx.saveOff + 0x2000])`; kind `tama`:
  `fresh.push([cx.saveOff, cx.saveOff + 0x50000], [cx.guestOff, cx.spareEnd])`; for each extra with
  `x.carry` whose placed program is a TamaEmu the same two ranges.
- Error: with `e.room`: `lastRoom = e.missing` and "Does not fit together: there would be enough
  room in total, but not in one piece (the DOOM WAD needs one big piece). Remove a program or build
  DOOM without music." (`e.frag`) or "Not enough room: about {k} KB missing. Remove a program. (The
  top 64 KB stay free for the write protection.)", plus " Tip: "Pack the firmware" for TamaEmu saves
  room." when `e.packHint`; otherwise "More emulators: {e}".

**17. The menu** (app.js:2766-2771)
- `mainSrcOf()`: 0 unless start device with `mainPick` and `doomL`; then `apps[k].src` with `k` =
  0 for `'emu'` (if `mainX`) or `extrasL.indexOf(mainPick)`.
- `name0`: `'DOOM'` when `F.appKind(rom) === 1`; `E.tamaName(emu.guest, emu.dev)` for a new
  TamaEmu; the old `F.feldApps(src, fe.stub).name0` when the main program is untouched and of the
  same kind; else `mainName(rom)` (app.js:3112).
- If `fe && menuWanted()`: `rom = F.feldApply(rom, { fields: state.feld, bag: state.bag, tama:
  state.tama, gplay: state.gplay && !state.clean, saves: state.saves, launch: !!state.launch, apps,
  name0, appsLow, dl, mainSrc: mainSrcOf(), auto: !!state.emuAuto, fieldNames: fieldTexts(rom).map(x
  => x.name) }, feldSaved, { feld: fe.feld, stub: fe.stub }, E)`. Error -> "Menu not built in: {e}".
  (Without `menuWanted()` the menu stays stripped: that is how it is removed.)

**18. Settings of the main emulator** (app.js:2773): when `F.appKind(rom) === 2`:
`rom = E.emuSessSet(E.emuOptSet(E.emuNfcSet(E.emuClockSet(rom, emuClock !== false), emuNfc !==
false), emuOpt), emuSess !== false)`.

**19. Autostart** (app.js:2774-2782): when `F.appKind(rom) === 2`, or `=== 1` outside a start
device: `a = E.autoSet(rom, stubList(rom), !!state.emuAuto)`. If that is falsy, autostart is
wanted, `E.embedded()` exists and no menu is installed (`!F.feldFind(rom, fe.stub)`):
`rom = E.installApp(rom, rom.slice(0xA0000, 0xB0000), E.embedded().stub)` and `E.autoSet` again
(errors ignored). A truthy `a` replaces `rom`.

**20. "Back from programs"** (app.js:2783): when `state.exitKey || exitGet(rom)`:
`rom = exitSet(rom, state.exitKey || 0)` (app.js:1635, section 7).

**21. File name** (app.js:2784): `baseName()` (the loaded name without extension and without
trailing `_paramix`, `_emu`, `_t7`, `_t18`, `_doom_E<d>`, `_felder`, `_fields`, `_4fields`,
`_6fields`, `_items`, `_start`, `_clean`) + `_paramix` (changed sprites) + `_v1` / `_t7` / `_t18` /
`_emu` (new main emulator) + `_doom_E<doomEp>` (WAD chosen) + `_4fields` (Jade) / `_6fields` (six
fields in the result) or `_fields` (`state.feld`) + `_items` (`state.bag`) + `_start`
(`state.launch`) + `.bin`.

Returns `{ rom, name, res, fresh }`.

Notes on the items named in the request: the **"start device" (launch)** variant differs from the
normal one only by the reduced pictures (`launchMapGet()` merged in step 4), `E.hiFree` (step 8),
`dlStrip` + `FL.withRescue` (step 16), `launch: true` in `t18Patch` / `appsPlace` / `feldApply`,
and `_start` in the name. A normal ROM gets **no rescue block at save time**; it is added when
writing to the device (`rescueApp: FL.embedded()` in `d.write`, app.js:3035).

### 3.2 `composeClean()` (ROM without the Paradise, app.js:2580-2633)

1. `!fe || !FL.embedded() || !cleanCan()` -> "This build does not contain the emulator program."
2. `await paraMainSync(); doomFreeSync(); dxs = doomXs()`.
3. `keysDirty` = `state.doomKeys` differs from some DOOM extra's `keys0` (or its keys);
   `emuUp = !ctx.clean && emuUpPending()`.
4. Nothing to do (only when the **loaded** ROM is already clean): no `emu`, `doom`, `keysDirty`,
   `extrasDirty`, `mainDirty`, `extrasUp`, `feldStale`, `t7saveX`, `saveIn`, same `exitKey`, no
   `emuUp` -> `{ same: true }`.
5. `mainX = emuX(state.emu)`, or for a Paradise ROM with an installed emulator that is neither
   removed nor already taken along `await installedX(src)`; gets `clock`, `nfc`, `opt`, `sess` from
   the main settings. `extrasDedupe(mainX)`; `extrasL = mainX ? [mainX, ...extras] : extras`.
6. `!extrasL.length` -> "A start device needs at least one program (emulator or DOOM)."
   `!E.t7Embedded()` -> "This build does not contain the emulator program." `!F.edition(src)` ->
   "Edition not recognised."
7. `rom = F.cleanBase(src)` (0xFF-filled 16 MB with the device's ID page).
8. DOOM extras: as in step 16 above (`appF` missing -> "This build does not contain the DOOM
   program."; keys; `doomMcuOf`; "No episode of this WAD fits into the ROM.").
9. Loaded ROM already clean: copy `keptT18Ranges(extrasL, src)` from `src` into `rom`.
10. `progs = { t7, tama, t18, v1, doom: { app: de.appF, xip: de.xipF } | null }`;
    `r = E.appsPlace(rom, extrasL, progs, { lang, clock: emuClock !== false, nfc: emuNfc !== false,
    launch: true, clean: true, noClock: clockOff(), txSpare: state.t18Few ? 0x40000 : undefined,
    keep: F.cleanReserved(), dlApp: null })`; `rom = r.rom; apps = r.list; lastFree = r.freeKB;
    state.tamaPacked = !!r.lzUsed`.
11. Saves, with `at(k) = apps[k + (mainX ? 1 : 0)]`: `t7saveX` -> `SV.t7SaveIn(rom, save,
    at(i).off + 0x10000)`; `saveIn`: key `'m'` means `apps[0]` when there is a `mainX` (ignored
    otherwise), a number means `at(key)`; v1: copy to `cx.saveOff` + fresh range 0x2000; tama: fresh
    ranges `[saveOff, saveOff + 0x50000]`, `[guestOff, spareEnd]`; each `x.carry` TamaEmu the same
    (note: indexed with `apps[i]` over `extrasL`, app.js:2622); each kept T18Emu with `x.items`:
    `t18Fresh(rom, apps[k].off, fresh)`. Errors as in step 16.
12. Main program: `k` = 0 for `mainPick === 'emu'` with a `mainX` (-1 without); `extrasL.indexOf(
    mainPick)` when an extra is picked; with no pick: 0 when there is a `mainX` and the loaded ROM
    has the Paradise, else -1. `mainSrc = apps[k].src` or 0.
13. `rom = F.cleanApply(rom, { apps, dl: DL_AT, mainSrc, auto: !!state.emuAuto && !!mainSrc,
    noClock: state.cleanClock === false }, { feld: fe.feldc, stub: fe.stub })`. Error -> "Menu not
    built in: {e}".
14. `w = FL.withRescue(rom, FL.embedded())`; falsy -> "Menu not built in: rescue"; else `rom = w`.
15. `exitSet` as in step 20.
16. Name: `baseName()` + `_doom_E<doomEp>` (WAD chosen) + `_clean.bin`. Returns `{ rom, name, res:
    null, fresh }`.

### 3.3 Trial builds

- `roomTry()` (app.js:1811): `lastRoom = 0; lastFree = -1; toast.mute = {}`; runs `composeRom()`;
  returns `{ k: lastRoom, err }` where `err` is the muted message when the build failed for another
  reason than room; on success with `lastFree >= 0` stores `state.roomFree = { sig: roomSig(), kb:
  lastFree }`.
- `roomFit()` / `roomFit1()` (app.js:1835-1860): see section 7. Used after adding a program
  (app.js:1885, 2267).
- `roomSoon()` (app.js:1026): 400 ms after the last change in a start device, a quiet `roomTry()`
  for the free-space bar; a failed trial stores `kb: -1`.
- T18 save import runs `composeRom()` muted and undoes the import on any error (app.js:3354).

### 3.4 The "Your new ROM" box (`renderPlan`, app.js:1036-1112)

`kind = appInstalled()`; `emuOn = !!state.emu || (kind === 2 && !emuRemove && !state.doom)`;
`doomOn = !!state.doom || (doomFree() && doomXs().length > 0) || (kind === 1 && !emuRemove &&
(!state.emu || state.launch))`.

**Chips** (label, text, colour class `new`/`keep`/`del`/`off`):

| Chip | Text |
|---|---|
| "Characters" | "{n} changed" (`state.changed.size`, class `new`) or "unchanged" (`keep`). Clean: "Without the Paradise (clean ROM)" (`keep` when the loaded ROM was clean, else `new`). |
| "Emulators" (`planEmus`, app.js:987) | main name in bold (unless DOOM is the main program), "<old name> will be removed" when the installed one is taken out, then the names of all extras that are not gb/sms/pm/ab/wolf/doom, then " · new" / " · gets updated" / " · stays". `isNew` = `state.emu`, a fresh such extra, or `extrasDirty` with a changed `groupSig('emu')`; `upd` = `emuUpPending() || emuAutoDirty() || extrasUp.has('emu')`. Empty: "not included". |
| "Game Boy", "Master System / Game Gear", "Pokémon mini", "Arduboy" (`planGroup`, app.js:1017) | game names + " · new" (a fresh one) / " · gets updated" (`groupSig(g) !== sig0[g]` or `extrasUp.has(g)`) / " · stays"; none: "will be removed" when the loaded ROM had some, else "not included". |
| "Wolfenstein 3D" (`planWolf`, app.js:1001) | "new" / "gets updated" (`wolfKeysDirty`) / "stays" + ", " + per pack "Spear of Destiny" or "Shareware"/"Full version" (+ ", {n} episodes"); none: "will be removed" / "not included". |
| "DOOM" | on: "new" or "stays", plus for a chosen WAD `doomChip(d)` (app.js:1677, multi mode) or `E<doomEp>`, plus " + Music"; off: "will be removed" when DOOM was installed, else "not included". |
| "Menu" | on (`menuWanted()`): the list of "Start device", "Several saves (with field choice)", "Items and Tamapoints", "Change Tama (level, care, character)", "Play time earns Tamapoints" (+ " (gets updated)" when `feldStale` and the options are unchanged); class `keep` only when unchanged and not stale; off: "will be removed" when a menu is installed, else "not included". |
| "Eyes and mouth" | "{n} changed": number of distinct groups in `eyeShift`, `mouthShift`, `poseAdj`; only when > 0. |
| "Names" | "{n} changed" (`state.texts.size`); only when > 0. |
| "More fields" | "stays" when installed, else "new"; only when installed, `six` or `sixWant`. |

`groupSig(g)` (app.js:1014) = JSON of, per extra of the group, `[E.extraName(x), x.keys || null,
!!x.inv, x.clock, x.nfc, x.opt, x.sess !== false]`.

**Flash bar.** `base = state.clean ? 0x10000 : 0x111000`, `end = 0x1000000`, `total = end - base`.
Segments in this order (each "label N MB" in the legend, width `n / total`, zero-size ones
omitted; `MB(n)` app.js:1023 = 2 decimals below 1 MB, else 1, trailing zeros cut):

| Segment | Size |
|---|---|
| "Firmware and characters" | not clean: `estimateEnd() - base` + `0xB9000` when a six-fields source is chosen and the fields are not yet in. `estimateEnd()` (app.js:530): `C.ASSET_BASE + 16 + 48 + al(files[0].length) + al(pack) + al(files[2].length)` with `pack = 4 * entries.length` then, per entry, padded to 4 and `+ entry(i).length`; `al` = round up to 4; `entry(i)` (app.js:365) = changed entry, or the start-device replacement, or the original. Clean: `C.ASSET_BASE` (no segment). |
| "DOOM" (when `doomOn`) | `doomFree()`: sum of `E.extraSize(x)` over the DOOM extras. Else with a WAD: `fit[doomEp]` size (`sizeM` when music is ticked and fits, else `sizeP`) `+ (0xD48000 - 0xCA0000)`. Else installed: `u32 at 0x830000` (WAD length) `+ 0xA8000`. |
| "Emulator" (when `emuOn` or there is an extra outside gb/sms/pm/ab/wolf) | `state.emu.size`; or for an installed one: T18 `(mapped blocks) << 16` (`E.t18Cfg(rom).map`), T7 `romLen + sum of figure lengths` (`E.t7Cfg(rom)`), TamaEmu `u32 at 0xA0000 + 0x140 + 12`; plus `E.extraSize(x)` of every extra that is not doom and not gb/sms/pm/ab/wolf. |
| "Game Boy", "Master System / Game Gear", "Pokémon mini", "Arduboy", "Wolfenstein 3D" | sum of `E.extraSize(x)` per kind. |
| "Field saves" (when `state.feld && !doomOn`) | `F.edition(rom).profile.names.length * 0x58000`. |
| "Save" | clean: none; Neon Planets (`SV.family(ctx.editionId) === 'neon'`, not clean): `0xF00000 - 0xD80000`, followed by "reserved" `0x10000`; otherwise `(state.launch ? 0xF00000 : 0x1000000) - 0xD29000`. |
| "reserved" / correction (start device only) | when `state.roomFree` matches `roomSig()` and `kb >= 0`: `rf = kb * 1024`; `fix = total - used - rf`; `fix > 0` adds "reserved" `fix`; `fix <= 0` shrinks the "Emulator" segment by it (not below 0); `used = total - rf`. Without a matching result `roomSoon()` is scheduled. |
| "free" | `max(0, total - used)`. |

Below the bar: "{n}: old version, the save can be lost when the battery is changed. Write it again
now with "Keep saves"." (`state.oldT7`); "Tama Meets is damaged. Remove Tama Meets and add the
firmware again, then write without "Keep saves"." (`t18Broken` and a kept T18Emu still listed);
and one rule line: clean "Without the Paradise: all programs go to the menu, almost the whole flash
is theirs."; start device "Start device: emulators and DOOM fit together as long as there is
room."; `appRoom()` "Emulator or DOOM: only one of the two fits into the ROM. The menu works with
both."; else "This edition has no room for emulator and DOOM (its character data is larger). The
menu works."

`roomSig()` (app.js:1823) = JSON of `[main name, emuRemove, !!doom, launch, extra names]` + the
music box (when a WAD is chosen) + `roomCont` of the main program and of each extra (figure bytes /
count and identity ids of `guest`, `rom`, `fw`).

### 3.5 All messages of the build, by step

| Message (English) | Key | When |
|---|---|---|
| "Nothing changed yet." | `nothing` | `c.same` |
| "Emulator and DOOM do not fit into one ROM together. Please choose only one." | `doomBoth` | 3.1 step 3 |
| `D.doomKeysCheck` text ("fire, forward and back need three different buttons", "use needs its own button or the wheel") | - | steps 3, 14, 16, clean 8 |
| "This build does not contain the emulator program." | `emuMissing` | missing `FL.embedded()` (start device), missing `E.embedded()`/`v1`/`t7`/`t18` program, missing `E.t7Embedded()` for the menu programs, clean prerequisites |
| "A start device needs at least one program (emulator or DOOM)." | `launchNeed` | step 3, clean 6 |
| "Too big for the free space. {e}" | `tooBig` | `C.buildRom`, `C.textApply` |
| "Emulator not built in: {e}" | `emuFail` | `E.emuRemove`, patchers, `E.t18RomWriteGuest` |
| "This firmware only fits here packed: switch on "Pack the firmware" in the row of TamaEmu." | `packNeed` | patcher error with `needPack` |
| "... the main program would need the room of Tama Meets. Remove Tama Meets first." | `emuFail` + `t18Clash` | step 10 |
| "No episode of this WAD fits into the ROM." | `doomBig` | step 14, DOOM extras |
| "This build does not contain the DOOM program." | `doomMissing` | `D.embedded()` / `.appF` missing |
| "DOOM not built in: {e}" | `doomFail` | `D.doomBuild` |
| "The device is on {f} now. First switch to {s} in the menu." | `sixOffField` | step 15 |
| confirm "The saves stored in the menu are deleted. Continue?" | `sixOffSlots` | step 15 |
| "All 6 fields still need a Land, Water or Sky ROM." | `sixNeed` | step 15 |
| "Changing this setting needs your Land, Water or Sky ROM again." | `sixPlanetNeed` | step 15 |
| "Fields not built in: DOOM and the emulator do not fit with it" | `sixFail` + `sixApp` | step 15 |
| "Six fields do not go together with more emulators." | `appSix` | step 15 |
| "Fields not built in: {e}" | `sixFail` | `S6.sixApply` |
| "More emulators start from the menu: switch on the field switch or items in the Menu tab." | `appNeedMenu` | step 16 |
| "Not enough room: about {k} KB missing. Remove a program. (The top 64 KB stay free for the write protection.)" | `noRoomKB` | `E.appsPlace` error with `room` |
| "Does not fit together: there would be enough room in total, but not in one piece ..." | `noRoomFrag` | same, with `frag` |
| " Tip: "Pack the firmware" for TamaEmu saves room." | `packTip` | appended with `packHint` |
| "More emulators: {e}" | `appFail` | other `E.appsPlace` errors (e.g. "<name> only fits packed (big save): ...", "only one T18Emu", "T18Emu needs the area at 0x0F0000, ...") |
| "Menu not built in: {e}" | `feldFail` | `F.feldApply`, `F.cleanApply`, rescue |
| "Edition not recognised." | `feldUnknown` | clean 6 |
| "DOOM goes into the menu only once." | `doomOne` | clean, unreachable (`DOOM_EPS` is true) |
| confirm "Note: the firmware of {n} gets packed so it fits. ..." | `packWarn` | after the build, before download/write |
| "Saved: {name}\n{n} sprites changed, {kb} KB still free." / "Saved: {name}" | `saved` / `savedEmu` | success |

---

## 4. Loading a ROM (`loadRom`, app.js:412-475)

### 4.1 Detection

1. `F.isClean(buf)` (feld.js:868: 16 MB, starts with `SONIXDEV`, and the Studio's clean layout):
   clean context (1.2).
2. Otherwise `C.openRom(buf)`; an exception is shown as "This is not a Paradise dump: {e}" (module
   messages: "not a Paradise flash dump (SONIXDEV header missing)", "unexpected asset archive (N
   files)", ...) and nothing changes.
3. Edition name: `ctx.edition` (`EDITIONS[editionId]` in core.js, or "Edition N"); for a clean ROM
   `FL.EDITIONS[F.edition(buf).id]` (flash.js:53: 1 Land, 2 Water, 3 Sky, 4 Jade Forest, 5 Tropical,
   6 Glacier, 7 Tropical/Glacier, 8 Neon Planets).

There is no file size check in `loadRom` itself (only the drop handler filters by size). The file
dialog accepts `.bin`.

### 4.2 Fix-up of older sprites

Not clean: for every group `g` and `k` in 0..5: `f = C.spriteAlign(ctx.entries[g + k])`; a result
is put into `state.changed` (odd-length pictures of older Studio versions are padded). The ROM
therefore counts as changed right after loading in that case.

### 4.3 Read back from an already modified ROM

| What | How | Presets |
|---|---|---|
| Six fields | `S6.sixInfo(buf)` -> `{ kind, version, planet, fieldMenu, dna, sprites, ... }` | `sixPlanet`, `sixMenu` (app.js:427); the checkbox `sixOn` shows them as built in; `sixAdded` locks their pictures. |
| Autostart | `E.autoGet(buf, stubList(buf))`, fallback `E.autoGetOld` | `emuAuto` |
| Main emulator settings | `E.emuClockGet`, `E.emuSessGet`, `E.emuNfcGet`, `E.emuOptGet` (each `null` when absent) | `emuClock`, `emuSess`, `emuNfc`, `emuOpt` |
| "Pack the firmware" of the main TamaEmu | `romEmuCfg(buf)`, `E.lzCount(buf, c.lzOff) > E.PACK_FEW` | `emuPack` |
| Menu options | `f = F.feldFind(buf, F.embedded().stub)`; `f.flags`, `f.version` | `feld`, `bag`, `tama`, `gplay`, `launch` (+ `*Init`) |
| "Back from programs" | `exitGet(buf)` (app.js:1634) | `exitKey`, select value |
| Programs of the menu | `E.appsRead(buf, F.feldApps(buf, fe.stub).apps)`, mapped per kind (app.js:438, table in 1.5); DOOM entries keep `mcu`, `keys`, `save`, `name`, `region` and `keys0` | `extras`; `wolfInit`; `sig0` |
| Older programs | `extrasOld(buf, apps)` (app.js:1645) | `extrasUp` |
| Outdated T7Emu | `E.t7Outdated(buf)` for the main one (name `mainName(buf) || 'TAMA-GO'`), `E.t7Outdated(buf, x.off)` for extras | `oldT7` |
| Damaged T18Emu in the menu | `E.t18Cfg(buf, keepOff).map`: >= 8 mapped blocks all 0xFF | `t18Broken` |
| Clean ROM: clock at start | `F.feldApps(buf, fe.stub).noClock` | `cleanClock` |
| Start device (v9 menu): main program and autostart | `fa = F.feldApps(buf, fe.stub)`; `fa.v9`, `fa.auto`, `fa.mainSrc` | `emuAuto = !!fa.auto`; `mainPick` = the extra at `fa.mainSrc - 0x10000000 + 0x11000` or `null` |
| Is the menu up to date? | Clean: `F.cleanApply(buf, { apps, dl, mainSrc, auto, noClock, spot: F.cleanInfo(buf) }, { feld: fe.feldc, stub: fe.stub })` compared with `buf`. Else: `F.feldApply(F.feldStrip(buf, { stub, oldStub }, E), { fields, bag, tama, gplay, saves, launch, apps: fa.apps, name0: fa.name0, appsLow: <lowest app offset or 0>, dl: <u32 at f.off + 0x334 when version >= 7>, mainSrc: fa.mainSrc, auto: fa.auto, fieldNames: fieldTexts(buf).map(x => x.name) }, F.feldSlots(buf, fe.stub), { feld: fe.feld, stub: fe.stub }, E)`, the 64 KB flash app copy at `dl` copied back, compared with `buf`. Any exception -> not stale. | `feldStale` |
| Fields and character names | `C.fieldSets(ctx)`; `tt = F.textTabelle(buf)`; `C.charGroups(ctx)`; `F.zeichenkette(buf, tt, c.name)` | `fields`, `charNames` |
| Main emulator / DOOM present | not stored: evaluated live with `appInstalled()`, `F.emuType(rom)`, `E.t7Cfg`, `E.t18Cfg`, `romEmuCfg`, `D.doomKeysGet` | rows in the emulator tab, DOOM tab, plan |
| Saves | nothing is read at load. The save tab reads on demand (section 5): `savePrograms()`, `F.saveSlots`, `SV.paraFromImage`. The installed main TamaEmu firmware with its save is read lazily by `mainGuestLoad()` (`SV.emuGuestAsync`). | - |

After loading: `cleanTabs()`, `renderInfo()`, (not clean) `renderGrids()`, `renderNames()`,
`renderDim()`, then `renderEmu()`, `renderDoom()`, `renderFeld()`, `renderSave()`, `devRender()`.
Toast "{ed} loaded: {s} sprites, {f} characters." or "ROM without the Paradise ({ed}) loaded: {n}
programs."

---

## 5. Save tab and device panel

### 5.1 Save tab

Section "Programs":

| Control | Label | State |
|---|---|---|
| `saveFor` (row `saveForRow`) | "Program"; one option per `savePrograms()` entry: name + " (Main program)" for key `m` | row hidden without programs |
| `btnEmuOut` | "Export ({f})" | disabled without a program; `f` = `.sav` (tama, gb, sms), `.eep` (pm, ab), `.bin` (others), or ".sav / .bin" without a program (`saveExt`, app.js:3199) |
| `btnEmuIn` | "Import ({f})" | always enabled |
| `saveStat` | "Export takes the save of the chosen program out of this ROM. Import puts it into the ROM, then save the ROM or write it to the device." or "No program in this ROM yet. A TamaEmu save brings its emulator along, add T7Emu and T18Emu in the Emulator tab first." | |

`savePrograms()` (app.js:3200): the installed main emulator as `{ key: 'm', kind: F.emuType(rom),
name: mainName(rom) || 'EMU', saveOff: 0xC0000, off: 0xA0000 }`, then every `romExtras(rom)` entry
of a kind in `tama, t7, v1, t18, gb, sms, pm, ab, wolf` as `{ key: i, kind, name: x.name, saveOff:
x.saveOff, off: x.off }`. Only programs of the **loaded** ROM appear.

**Export** (`btnEmuOut`, app.js:3472-3529), by kind; `stamp()` = `YYYYMMDD-HHMM` (app.js:3109),
`slug` = program name lower-case with non-alphanumerics as `-`:

| Kind | Data | File name | Empty case |
|---|---|---|---|
| t7 | `SV.t7SaveOut(rom)` (main) or `SV.t7SaveOut(rom, p.saveOff)` | `t7emu-<slug>-<stamp>-save.bin` | "The Tama has no save yet." |
| v1 | `rom.slice(saveOff, saveOff + 0x2000)` | `v1emu-<slug>-<stamp>-save.bin` | first 0x1000 bytes all 0xFF -> "The Tama has no save yet." |
| tama | `cfg` = `romEmuCfg(rom)` or `SV.emuCfg(rom.subarray(off, off + 0x1000))`; `SV.emuGuestAsync((a, n) => rom.subarray(a, a + n), cfg)` (the whole firmware image with the save) | `<cfg.app>-[<slug>-]<stamp>.sav` | no cfg -> "This ROM has no emulator." |
| t18 | `E.t18FromRom(rom)` / `E.t18FromRom(rom, off)` | `t18emu-<stamp>-save.bin` | "No save yet." |
| ab | `x.save.slice(0x1000, 0x1400)` (`x = romExtras(rom)[key]`) | `<slug>-<stamp>.eep` | missing, shorter than 0x1400 or all 0xFF -> "No save yet." |
| pm | `x.save.slice(0x1000, 0x3000)` | `<slug>-<stamp>.eep` | same (0x3000) |
| gb | `x.save.slice(0x1000, 0x1000 + gbSaveLen(x.rom))` | `<slug>-<stamp>.sav` | length 0 -> "This game keeps no save on its cartridge."; all 0xFF -> "No save yet." |
| sms | `x.save.slice(0x1000, 0x1000 + smsSaveLen(sv))` | `<slug>-<stamp>.sav` | same |
| wolf | `x.save.slice(0, 0x10000)`; requires u32 at 0x1000 `=== 0x56533357` | `wolf3d-<slug>-<stamp>-save.bin` or `sod-...` (`E.wolfSod(x.pack)`) | "No save yet." |

Success: "{n} saved." No program selected: "This ROM has no emulator."

**Import** (`btnEmuIn` -> `fileEmuSav`, app.js:3296-3394). `g` = file bytes, `p` = selected
program.

1. Re-targeting (`SAVE_PICK`): `saveKindOf(g)` (app.js:3285) = `'t7'` when `SV.t7SaveCheck(g)`,
   `'t18'` when `E.t18Detect(g)`, `{ tama: E.emuDetect(g) }` for lengths 0x400000, 0x800000 or
   0x7FF800; otherwise `t18Part(g)` (app.js:3278: a T18Emu **app** save of length 0x290000 (goes to
   0x570000), 0x220000 or 0x220010 with 16 bytes skipped (0x5E0000), or a ZIP containing an 8 MB
   `flash.bin`). If the kind does not match the selected program (for tama also the device), the
   first matching program is selected; a just-added main T7Emu/T18Emu is also accepted. A T18 app
   save without a T18Emu -> "T18Emu is missing in the ROM: add the TG18 firmware in the Emulator
   tab first."
2. By program kind:
   - **ab**: `x = extraFor(p)` (app.js:3211; missing -> "This is not a fitting save for this
     program."); length must be 0x400 (else "This file does not fit {n}."); `sv = new
     Uint8Array(E.AB_SAVE).fill(0xFF)`, first 0x1000 bytes of the old `x.save` kept, file at 0x1000;
     `x.save = sv; extrasDirty = true`.
   - **pm**: same with length 0x2000 and a buffer of `E.PM_BIOS_AT` bytes.
   - **gb / sms**: 0x10000 buffer, first 0x1000 of the old save kept; `n = gbSaveLen(x.rom)` or
     `min(g.length, 0x8000)`; `n === 0` -> "This game keeps no save on its cartridge."; `g.length <
     n` or `> 0x20000 + 64` -> "This file does not fit {n}."; `0x1000..0x10000` filled with 0xFF,
     `g[0..n)` at 0x1000.
   - **wolf**: file must be 0x10000 bytes with u32 `0x56533357` at 0x1000; bytes from 0x1000 copied.
   - All four end with "Save for {n} taken over. Now save the ROM or write it to the device. A kept
     game state is dropped."
   - **t18**: an app save is overlaid on the firmware (`fw.set(part.data.subarray(0, 0x800000 -
     part.at), part.at)`); the result must pass `E.t18Detect` (else "This file does not fit {n}.").
     Main: `state.emu = { t18, dev:'t18', rom:g, size }`, `emuRemoveClear()`. Extra: `x.fw = g;
     delete x.keepOff; x.saveImp = true; extrasDirty = true`. Then a muted `composeRom()`; any error
     restores the previous state and is shown. Success: "Save for {n} taken over. Now save the ROM
     or write it to the device."
   - **T7 save** (`SV.t7SaveCheck(g)`): for an extra `state.t7saveX = { i: p.key, save: g }`
     ("Save for {n} taken over. ..."); otherwise the main T7Emu must be in the ROM or just chosen
     (else "T7Emu is missing in the ROM: add the Tama-Go ROM in the Emulator tab first.");
     `state.t7save = g`; "T7Emu save taken over. Now save the ROM or write it to the device."
   - **V1**: `g.length === 0x2000` and a v1 program selected: `state.saveIn = { key: p.key, kind:
     'v1', data: g }`.
   - **TamaEmu**: `dev = E.emuDetect(g); pk = E.packMain(g, dev)` (failure -> "This is not a
     fitting save for this program.").
     - Extra selected: `x = state.extras[p.key]` must be a tama of the same `dev` (special case
       app.js:3380: an extra built as `idl` whose firmware `E.emuDetect`s as the file's device is
       re-labelled). If `!x.pack && E.tamaNeedsLz(g, dev, E.MENU_ROOM_LEN)`: confirm "With this save
       the firmware only fits packed. Packed, the game runs slower. Switch on "Pack the firmware"
       and take it?" -> `x.pack = true`. Then `x.guest = g; extrasDirty = true; saveIn = { key:
       p.key, kind: 'tama' }`.
     - Otherwise it becomes the main program: `!appRoom()` -> "This ROM has no room for TamaEmu.";
       another device than the current main one -> confirm "The ROM has TamaEmu for {a}, the save
       is for {b}. Take it anyway?"; `!emuPack && E.mainNeedsPack(g, dev)` -> the pack confirm,
       `emuPack = true`, `pk = E.packMain(g, dev, null, true)`; `state.emu = { guest: g, dev, size,
       big }`; `emuRemoveClear()`; outside a start device `doom = null`; `saveIn = { key: 'm',
       kind: 'tama' }`; "TamaEmu save taken over ({d}). Now save the ROM or write it to the device."

Section "Paradise":

| Control | Label | State |
|---|---|---|
| `paraSlot` (row `paraSlotRow`) | "Slot"; options from `paraSlots()` = `F.saveSlots(rom, fe.stub)`: "{field} (active)" (value `live`), used slots by label, empty ones "{n} (empty)"; label = "Save {n}" when `ss.saves`, else the field name (`slotLabel`, app.js:3246) | row hidden when the menu keeps no saves |
| `btnParaOut` | "Export (.tamasave)" | always |
| `btnParaIn` | "Write to device (.tamasave)" | disabled unless a device is connected and idle |
| `btnSlotClear` | "Clear slot" | hidden without slots; enabled only when connected and a used, non-live slot is selected |
| hint | "Export takes the Paradise save out of this ROM. Write to device goes straight to the device, connect it above for that. Slot: which save." | |
| `btnPetOpen` | "Open Paradise save" (row label "Change save") | file `filePet` |
| `btnPetRom` | "Save in the ROM" | |
| `petLevel`, `petChar`, `petCare`, `btnPetSave`, `btnPetClose` (row `petRow`) | "Level", "Tama", "Fed, happy, healthy", "Save changed save", "Close" | row shown while a save is open |

- **Export** (app.js:3458): `ed = ctx.editionId`; live: `pages = SV.paraFromImage(rom, ed)`; a
  slot: `sv = await F.slotReadAsync((a, n) => rom.subarray(a, a + n), ss.f, i)` (none -> "There is
  no save in this slot."), `[a, b] = SV.region(ed)`, `got = F.slotPages(sv)`, every 4 KB page of
  `[a, b)` from `got` or 0xFF. Download `SV.paraEncode(pages, ed, null)` as `<edition
  slug>[-<slot label>]-<stamp>.tamasave` (`edSlug`, app.js:3110). Text "{n} saved. The clock is not
  included, set it in the app if needed."
- **Write to device**: `g_slotIn = paraSlotPick()`; file `fileSave`; continues in 5.2 ("Save to
  device").
- **Clear slot** (app.js:3257): confirm "{n} is deleted on the device. A new game starts there
  afterwards, the field can be chosen. Continue?"; device task: compare the menu's settings block on
  the device with the loaded ROM (`d.read(f.off, 0x1000)`, words at offsets 0, 8, 12, 16, 364, 368
  from `f.off + 0x140`; mismatch -> "The menu on the device does not match the loaded ROM. Load the
  ROM from the device first."); `at = F.slotAddr(f, i)`; `d.writeSectors(new Map([[at, 4 KB of
  0xFF]]), devProg, cancel, FL.embedded())`; the same page is blanked in `ctx.rom`; "Done: {n} is
  empty."
- **Pet editor** (`petOpen`, app.js:3411): from a file `SV.paraDecode(bytes)` (error text shown),
  from the ROM `{ stamp: 0, counter: 0, alarm: 0, status: 0, regs: [], pages:
  SV.paraFromImage(rom, ed), edition: ed }`. `SV.family(save edition) !== SV.family(ctx.editionId)`
  -> "The save is for another edition than the loaded ROM."; `pet = SV.paraPet(save, ed)` null ->
  "The settings block is missing in the save.". Level select 0..10 (current selected); character
  select "unchanged" + groups "Kid" (stage 3), "Teen" (4), "Adult" (5) from `F.characters(rom)`,
  option value `id:stage`, text = capitalised name + " (field)"; status "In the save: level {l},
  Tama {c}, hunger {h}/6, happiness {j}/20{, sick}.". Save (`btnPetSave`, app.js:3439): `ch` gets
  `level`, `id` + `stage`, `care: true` only where changed; empty -> "Nothing changed.". From the
  ROM: `nw = SV.paraPetSet(save, ed, ch)`, every 4 KB page of `nw.pages` copied into a copy of
  `ctx.rom`, `petDirty = true`, "Changed in the ROM. Now save the ROM or write it to the device
  (without "Keep saves", otherwise the device keeps its save).". From a file: download
  `SV.paraWrite(SV.paraPetSet(save, ed, ch), ed)` as `<name>-<stamp>.tamasave`, "{n} saved. Send it
  with "Save to device".".

### 5.2 Device panel (UART)

Title "Device over UART", hint `devHint`, warning "Writing to the device is at your own risk and
without liability. Read a backup first and keep the device switched on while writing." State object
`dv = { io, d, loaded, run, cancel }` (+ `rescue`, `stash`) (app.js:2798). `devRender`
(app.js:2799) sets the enabled states: everything needs `navigator.serial && FL.embedded()`
(else "This browser cannot talk to the dongle. ..."); `btnDump`, `btnSaveRead`, `btnSaveWrite`,
`btnParaIn`, rescue buttons need a connected device and no running task; `btnWrite` also needs a
loaded ROM ("To write, open a ROM first (or read one)."). `devTask(fn)` (app.js:2822) runs a task
with the progress bar (`devProg(phase, done, total)`, phases "Loading flash app", "Reading",
"Comparing", "Writing", "Checking", "Preparing") and ends with the last status text, "Cancelled."
or "Error: {e}" (`flMsg`).

The transport itself (Web Serial, `FL.serialOpen`, `FL.connect`, the `Paradise` device object with
`dump`, `read`, `crc`, `changed`, `usedSectors`, `write`, `writeSectors`, `clockRead`, `clockSet`,
`rescueTest`, `rescueRestore`) is in flash.js; the native app needs its own transport with the
same calls.

| Control | Label | Action |
|---|---|---|
| `btnConn` | "Connect" | closes a running visit; port chooser; `dv.io = await FL.serialOpen(port)`; `r = await FL.connect(dv.io, FL.embedded(), {}, devProg)`; `dv.d = r.dev; dv.loaded = r.loaded`; "Ready."; `rescueCheck()`. With a Prolific adapter (USB vendor 0x067B) and error code `noData`/`noAnswer` the PL2303 hint is appended. Info line "Connected: {ed}, {mb} MB{, flash app loaded}" / "Not connected." |
| `btnDump` | "Read ROM" | `img = await dv.d.dump(devProg, cancel)`; download as `paradise-<edition>-<YYYYMMDD-HHMMSS>.bin`; `loadRom(new File([img], name))`; "ROM read and saved as {n}. It is now open in the Studio." |
| `btnWrite` | "Write new ROM to the device" | below |
| `devOnly` | checkbox, default on, "Only write changes" | `onlyChanged` of `d.write` |
| `devKeep` | checkbox, default on, "Keep saves" | below |
| `btnDevStop` | "Cancel" | `dv.cancel = true` (shown while a task runs) |
| `btnResume` (row `rescueResume`) | "Continue writing" | shown when a stashed image exists: `dv.d.write(dv.stash, { onlyChanged: true, keep: null, rescueApp: FL.embedded() }, devProg, cancel)`; stash deleted; "Done: {w} sectors written. Switch the Paradise off and on." |
| `btnRescueTest`, `btnRescueBack` (row `rescueBox`) | "Test rescue start", "Write header back" | row only with `#rettung`/`#rescue` in the page address (developer test, app.js:3091-3105): `dv.d.rescueTest(FL.embedded(), ...)`, header kept in localStorage and downloaded; `dv.d.rescueRestore(hdr, ...)`. |
| `btnSaveRead` | "Back up save" | below |
| `btnSaveWrite` | "Save to device" | `g_slotIn = 'live'`; file `fileSave` |
| hint | "Back up takes the Paradise save with the clock and the save of TamaEmu or T7Emu. Only the Paradise save goes to the device." | |
| `visEd`, `btnVis` | edition select (Land, Water, Sky, Jade Forest, Tropics, Glacier; values `land`, `water`, `sky`, `jade`, `tropics`, `glacier`), "Start"/"Stop" | simulated visit: `VS.io = await FL.serialOpen(port)`; `VS.v = ParamixVisit.createVisitor({ edition, key: ParamixVisit.parseKey(FL.linkKey), send: b => VS.io.write(b), log })`; incoming data -> `VS.v.feed(d)`. Log events: `start` "Connected, exchanging data…", `sent` "The two are playing…", `done` "Visit done ({ed}). ..." (re-armed after 500 ms), `error` "The Paradise does not understand the data." (text `key`) or "Stopped: {e}. ..." (re-armed after 1 s). Not possible while the flasher holds the port ("Paramix Studio is still connected to the dongle. ..."). App.js:2835-2882. |

`rescueCheck()` (app.js:3073): `dv.d.read(0, 16)`; `dv.rescue` = the first 8 bytes are not
`SONIXDEV`; `dv.stash` = the stashed 16 MB image if any; message (also as alert): in rescue with a
stash "The last write was cut off. The device is in the flash screen and waits. Press "Continue
writing"."; in rescue without "... Open the ROM again (or your backup) and write it to the
device."; not in rescue but a stash exists "The last write did not finish. Press "Continue writing"
so everything fits together again."

**Write new ROM** (`btnWrite`, app.js:2961-3043):

1. `c = await composeRom()` (null -> stop); `keep = devKeep.checked`; `packOk(c.rom)`.
2. Confirm "The new ROM is written to the device now. Keep the device switched on while writing.
   Write at your own risk?"; without keep additionally "Without "Keep saves" the save on the device
   is replaced by the one in the ROM. Write anyway?"
3. `cleanNew = F.isClean(c.rom)`: read sector 0 of the device; unless it already has the Studio's
   own table (`SONIXDEV` and `(h[8] & 1) === 0`) confirm "The device has the Paradise on it. It is
   deleted, with its save. Do you have a backup of the device? Go on?"
4. With keep: `saveCarry(dv.d, c)` (app.js:2920, section 7). `null` -> stop; an exception -> confirm
   "The device does not hold the loaded ROM. A program moves and its save on the device cannot be
   taken along. Read the ROM from the device first. Write anyway?"; when it changed something and
   carried saves, `composeRom()` runs again.
5. With keep and not `cleanNew`: read the device's settings sector at 0xA0000; `dm` = magic at
   +0x140 (`0x43584D50` TamaEmu, `0x37584D50` T7Emu, `0x38584D50` T18Emu, `0x31584D50` V1Emu); `im`
   = the same in the image.
   - same program and `state.emu` set: `emuSame = await emuSameDev(dv.d, c.rom, dm)` (app.js:3148).
   - TamaEmu on both sides, not the same, carried at 0xA0000: if `SV.emuCfg` of device and image
     agree in `dev` and `saveOff` -> `emuSess = emuSame = true`.
   - TamaEmu on both sides, `state.emu.kept`, not the same: same cfg test; read the guest flash from
     the device (`SV.emuGuestAsync((a, n) => dv.d.read(a, n), dcfg)`); if its first 64 KB equal the
     Studio's firmware: copy the Studio's `E.dlcAreas(dev)` ranges into it, `E.saveFlag(g, dev,
     stampFor('main'))` when set, `state.emu = { guest: g, dev, size, big, kept: true }` (via
     `E.packMain`), `composeRom()` again, `emuSess = emuSame = true`.
   - T7Emu/V1Emu on the device and another main program in the image: `moved` = an extra of the
     image has the same ROM (`cx.romLen === rl` and `FL.crc32(c.rom, cx.romOff, cx.romLen) ===
     await dv.d.crc(ro, rl)`). `carried.has(0xA0000)` also counts as moved.
   - If the device has an emulator, it did not move, and (`dm !== im` or (`state.emu` and not
     `emuSame`)): confirm "Main program on the device: {o}. In the new ROM: {n}. So the save of {o}
     as the main program starts anew. To keep it, back it up first under "Save". Write anyway?"
     (`n` = the program's name, "{o} with a newly chosen firmware", or "no emulator").
6. With keep and T18 items changed (`t18Dirty` or an extra with `items`): confirm "T18Emu: items or
   Tamapoints changed. Its save on the device is replaced by the one in the ROM (as read), even
   with "Keep saves". Go on?"
7. Device task: `plan = keep ? FL.keepPlan(F, E, fe && { stub: fe.stub }, { emuChanged: !!state.emu
   && !emuSame && !emuSess, emuSess, carried, after: state.stampSet ? stampSess : null, t7Save:
   !!state.t7save, t7SaveX: state.t7saveX ? state.t7saveX.i : -1, t18Imp: extras.some(x =>
   x.saveImp), mine: studioSecs(ctx.rom, c.rom), fresh: c.fresh || [] }) : null`. For a T7Emu/T18Emu
   main program (not clean): `ck = await dv.d.clockRead()`; when `ck.ctrl & 0x80`: `img =
   E.t7Wall(img, ck.counter, new Date())` / `E.t18Wall(...)`. Then `r = await dv.d.write(img, {
   onlyChanged: devOnly.checked, keep: plan, rescueApp: FL.embedded(), t18Bases: t18Bases(img, fe),
   onImage: x => stashPut(x) }, devProg, cancel)`. Error code `noRescueRoom` -> alert "No room for
   the write protection ..."; `cancelledWrite` -> `rescueCheck()`. Success: stash deleted; "Done and
   checked: {w} sectors written{, {k} save sectors kept}. Restart the device (reset or battery)."
   or "Nothing to write, the device already has this ROM."; + "Write protection on: if a write is
   cut off, the device starts in the flash screen." when `r.rescue`; + `r.notes`.

**Back up save** (`btnSaveRead`, app.js:3531-3577): `ed = d.info.edition`; `[a, b] =
SV.region(ed)`; `used = await d.usedSectors(a, b, devProg, cancel)`; every page of the region 0xFF
or `await d.read(s, 0x1000)`; `clock = await d.clockRead()`; download `SV.paraEncode(pages, ed,
clock && (clock.ctrl & 0x80) ? clock : null)` as `<edition>-<stamp>.tamasave`. Then the sector at
0xA0000: a DOOM marker (`0x434D4450` anywhere in 0x140..0x400) means no emulator; T7Emu magic
(`E.T7_MAGIC`): read 0x4000 bytes at `SV.T7_EE`, `SV.t7SaveOut(part)` -> `t7emu-<stamp>-save.bin`;
further T7Emus where the loaded ROM has them and the device has the same program there (magic and
save offset at +0x150): read `saveOff + 0x1000`, 0x4000 bytes, `SV.t7SaveOut(part, x.saveOff)` ->
`t7emu-<name>-<stamp>-save.bin`; TamaEmu (`cfg = SV.emuCfg(sec)`): `SV.emuGuestAsync(read, cfg)` ->
`<cfg.app>-<stamp>.sav`, reading only the differing sectors (`d.changed(ctx.rom, ...)`) when the
loaded ROM has the same layout (`guestOff`, `guestSize`, `kind`, `map`). Status "Backed up: {n}." +
" Please set the clock on the device." when no clock was read.

**Save to device** (`fileSave`, app.js:3579-3603): `save = SV.paraDecode(bytes)` (error toast);
`chk = SV.paraCheck(save, d.info.edition)`; errors -> "Error: ..." with the texts `fl_saveOtherEd`
"the save is from another edition ({s}), the device is {d}", `fl_saveFamily` "the save does not fit
this edition", `fl_saveNoSettings` "the settings block is missing, this is not a complete Paradise
save"; warnings (`fl_saveOutside`, `fl_saveIncomplete`) are appended to the confirm.

- Live save: confirm "The save is written to the device ({ed}) and replaces the current one.
  Continue?"; task: 16 MB image of 0xFF with `chk.pages`; `diff = await d.changed(img, devProg,
  cancel, a & ~0xFFFF, b)`; only differing pages; `w = await d.writeSectors(map, devProg, cancel,
  FL.embedded())`; `v = SV.paraClock(save)`; `await d.clockSet(v)` when not null; "Done: {w} pages
  written. Clock taken over. / Please set the clock on the device. The device can be restarted."
- Into a slot (`slotWrite`, app.js:3606): without several saves (`!ss.saves`) the save's field must
  be the slot's (`F.fieldOfSettings(rom, chk.pages.get(0xEFE000)) === i`, else "The save is for
  {a}, the slot for {b}."); confirm "The save goes into {n} on the device and replaces the one
  there. Continue?"; task: menu settings block compared as in "Clear slot"; `heads` = `d.read(
  F.slotAddr(f, j), 0x1000)` for every slot; `s = F.slotBuild(chk.pages, i, a, b)`; `written =
  F.slotPlace(img, f, i, s, F.poolUsed(f, heads, i))`; first write: the header page (`written[0]`)
  as 0xFF and all other pages; second write: the header page. "Done: {n} replaced on the device."

Other device helpers: `devFree()` (app.js:1389, "Release UART": closes the port, "Dongle released.
Restart the Paradise so the game runs again."), `uartWarnInto`.

---

## 6. Input files per tool

| Input (id) | Opened by | Accept / multiple | Detection and handling | Messages for wrong files |
|---|---|---|---|---|
| `fileRom` | "Open ROM", start drop zone | `.bin`, single | `F.isClean`, else `C.openRom` (4.1). Drop: 16 777 216 bytes, or `.bin` > 4 MB. | "This is not a Paradise dump: {e}" |
| `fileSheets` | "Upload sheets (PNG or ZIP)", drop with a ROM open | `.png`, `.zip`, multiple | `uploadFiles` (app.js:644): ZIPs via `C.zipRead(bytes, inflateRaw)`; names must match `(figur|figure|sprite)_<digits>.png` (`parseName`, app.js:639); a character index must be in `ctx.groups`, a sprite index in range; then `applySheet`. | "No matching files. Expected: figur_0237.png or sprite_0014.png."; "Applied: {n}" + "Skipped: {list}" (first 6); per file "{f}: {e}" with the module text ("sheet must be WxH px, got WxH", "character sheet must be ...", "eye image too detailed: N bytes, at most M allowed", "subimage count does not match", ...) |
| `fileOne` | drawer "Upload sheet" | `.png` | `applySheet` on the open item | "{f}: {e}" |
| `fileField` | "Load field from ZIP" | `.zip` | `field.json` with `paramix: 'field'` | "Not a field ZIP (field.json missing)." |
| `fileDim` | "Load card" | `.bin` | `C.smaDetect(raw) ? C.smaLoad(raw) : C.dimLoad(raw)` (4 MB character card, 1 or 2 MB TamaSma card) | "Unknown card: {e}", "Unknown card: no characters on this card" |
| `fileEmu` | "Choose firmware or ROM" | `.bin`, `.sav` | order: `E.gbDetect`, `E.smsDetect(g, name)`, then main or menu (2.5): `E.v1Detect`, `E.t18Detect`, `E.t7Detect`, `E.emuDetect` (+ `E.pmDetect` inside `addExtra`) | "Firmware not recognised: {e}" (module: "firmware not recognised (expected a 4 MB or 8 MB image of a colour Tamagotchi)"); the `addExtra` messages of 2.5 |
| `fileApp` | (unreachable button) | `.bin` | `addExtra` | same |
| `fileT7Fig` | "Add figures" in a Tama-Go row | `.bin`, multiple | per file `E.t7FigDetect(raw)`, `d = E.t7FigData(raw)`; at most 16; no duplicate `E.t7FigName`; for the main program `E.t7Room(figs + new, rom.length) >= 0` (app.js:1890-1906) | "{f}: not a figure.", "No room for more figures.", "{f} is already in.", "No room left for {f}." |
| `fileDlc` | "Add download content" in a TamaEmu row (iD L, P's, 4U, 4U+) | `.jpg`, `.jpeg`, `.bin`, `.zip`, multiple | ZIP: only `.jpg`/`.jpeg` members. Per item: `rec = E.dlcRecord(data, dev)`; items from a ZIP whose bytes 0x34..0x3A start with `t4u_` are skipped silently unless the target is a 4U, or a P's with `rec[0xFF]` 2 or 3; `r = E.dlcAdd(guest, rec)`; target takes `r.guest`; `r.stamp` -> `stampMark(dlcT, E.SAVE_FLAG[dev].on)`. Afterwards, if the block count of `E.packGuest` changed (or an old main TamaEmu gets the packed layout) and the program had a save: "The memory of this emulator is laid out anew for it. Its save starts anew after writing." (app.js:1916-1943) | success "{n} now sits in {k}, slot {s}."; "{f}: {e}" with module texts ("no download content in the file", "content checksum does not match", "this content fits no store of this firmware", "content too big for its store", "made for the iD L, the P's does not take it", "only for the 8 MB firmware", "already added", "<store>: all slots used, remove one first", ...) |
| `fileT18Item` | "Choose MyMeets files" | `.txt`, `.bin`, `.zip`, multiple | `E.t18iScan(bytes)` per file / ZIP member; per record `E.t18ItemAdd(fw, r, 1)` (app.js:1944-1963) | "No items found in the files."; "{n} is for {m}, not for the Meets/On. It may not work there." (warning, still added); "{n}: no room left" (error message `full`); "{n} is now in {k}." |
| `fileT18Pic` | "Choose pictures" | `.png`, `.json`, `.zip`, multiple | JSON files map picture names to adult ids (Android set `erwachsen.json`; English firmware sets preferred when the firmware's param address is 0 or 0xF800D864); id = from the JSON or `E.t18AdultFind(name)`; must be in `E.T18_ADULTS`; `E.t18PicMake(await pngRgba(data))` (app.js:1964-1988) | "{f}: unknown name"; "{n} pictures taken." |
| `fileWad` | "Choose DOOM.WAD" | `.wad` | `doomCompute` (`D.wadEpisodes`, `D.wadSub`, `D.gbaExtras`, `D.convert`) | "In this edition DOOM works in a start device only (Menu tab)."; "WAD not recognised: {e}" ("not a WAD file", "no DOOM maps in the WAD ...", "WAD conversion failed", the literal German "E1 bis E4 fehlen" thrown at app.js:2346, "DOOM II only goes into a ROM without the Paradise.") |
| `filePwad` | "Choose extra WAD" | `.wad`, multiple | `D.pwadInfo(data, name)`, then `doomCompute` | "{n} is for DOOM II: choose DOOM2.WAD first.", "{n} is for DOOM or Ultimate DOOM: choose DOOM.WAD first.", "WAD not recognised: {e}" |
| `fileGb` | "Choose games (.gb, .gbc)" | `.gb`, `.gbc`, multiple | `E.gbDetect(g)` then `addExtra` | "{f}: not a Game Boy game"; "{f}: Game Boy Color only, that does not work" |
| `fileSms` | "Choose games (.sms, .gg)" | `.sms`, `.gg`, multiple | `E.smsDetect(g, name)` then `addExtra` | "{f}: not a Master System or Game Gear game" (`smsGG` exists in the table but is not used) |
| `filePm` | "Choose games (.min, .zip)" | `.min`, `.zip`, multiple | `pmFiles` (app.js:2142) unpacks ZIPs; per file: `E.pmBiosDetect` -> becomes the own BIOS; `E.pmTooBig`; `E.pmDetect`; `addExtra` | "{f}: bigger than 1 MB, that does not work"; "{f}: not a Pokémon mini game"; ZIP errors "{f}: {e}" |
| `filePmBios` | "Choose own BIOS" | `.min`, `.bin`, `.zip` | first file with `E.pmBiosDetect` | "{f}: not a Pokémon mini BIOS" |
| `fileAb` | "Choose games (.hex, .zip)" | `.hex`, `.zip`, multiple | only names ending `.hex`; `bin = E.abHex(data)`; `addExtra(bin, name, { kind:'ab', rom:bin, title:E.abTitle(name), keys, inv })` | `bin` null: "{f}: too big for the Arduboy" when the file is larger than 0x16000 bytes, else "{f}: not an Arduboy game" |
| `fileWolf` | "Choose game files" | `.wl1`, `.wl6`, `.sod`, multiple | all files as `{ name: bytes }` into `W.build(set)` -> `{ pack, sod }`; one Wolf3D and one Spear of Destiny at most (`E.wolfSod(pack)`); a second one of the same kind replaces the first ("There is only one Wolfenstein 3D and one Spear of Destiny in the menu, the new one replaces the old one."); then `roomFit` (app.js:2253-2270) | "Wolfenstein 3D: {e}" (module text); "At most 12 more emulators."; "No room left for {n}: ..." / "More emulators: {e}" |
| `fileSix` | "All 6 fields" (automatically) or "Choose Land, Water or Sky ROM" | `.bin` | `S6.sixSource(buf)` truthy -> `six = buf; sixName; sixWant = true; feld = true`; toast "Field pictures taken from {n}." | "{n} is not a Land, Water or Sky ROM." |
| `fileEmuSav` | save tab "Import" | `.sav`, `.bin`, `.eep` | 5.1 | "This is not a fitting save for this program.", "This file does not fit {n}.", "This game keeps no save on its cartridge.", "T7Emu is missing in the ROM: ...", "T18Emu is missing in the ROM: ...", "This ROM has no room for TamaEmu." |
| `filePet` | "Open Paradise save" | `.tamasave` | `SV.paraDecode` | module text ("not a Paradise save (.tamasave)", "unknown save version N", "save is cut off"); "The save is for another edition than the loaded ROM."; "The settings block is missing in the save." |
| `fileSave` | "Write to device (.tamasave)", "Save to device" | `.tamasave` | `SV.paraDecode`, `SV.paraCheck(save, device edition)` | 5.2 |

PNG decoding: `decodePng` (app.js:391) must give straight (non-premultiplied) RGBA without colour
space conversion; `pngRgba` (app.js:1268) is the plain variant for the T18 pictures. ZIP reading
needs a raw-deflate inflater passed to `C.zipRead` (`inflateRaw`, app.js:403).

---

## 7. Logic in app.js that is not glue (has to be ported)

Build pipeline and ROM logic:

| Function | Line | What it does |
|---|---|---|
| `composeRom` | 2634 | The whole build of a ROM with the Paradise (section 3.1). |
| `composeClean` | 2580 | The build of a ROM without the Paradise (section 3.2). |
| `currentDataPack` | 887 | Applies eye offsets, mouth/eye shifts and pose adjustments to the data pack. |
| `half` | 886 | Symmetric halving of a shift for the small figure. |
| `estimateEnd` | 530 | Size of the asset archive as it would be written (for room checks and the bar). |
| `entry` / `decode` | 365 / 372 | Current sprite entry (changed, start-device replacement or original) and its decode cache. |
| `launchMapGet` | 371 | Lazy `C.launcherChanges(ctx)`. |
| `fieldTexts` | 481 | Which text numbers hold the field names (also used for `feldApply.fieldNames`). |
| `applySheet` | 622 | Edited sheet -> encoded sprite entries, all-or-nothing, original detection. |
| `partOpts`, `sixAdded`, `parseName`, `sheetOf`, `sheetName` | 601, 621, 639, 614, 618 | Encoding options per part, locked pictures, upload file names. |
| `insertDim` | 854 | Card character into a group (both variants). |
| `eyeRectFor` | 846 | Eye rectangle preset or guess (dead path). |
| `faceMove`, `posesOf`, `poseKey`, `poseAdjGet`, `firstPose`, `clamp16` | 801, 754, 760, 761, 762, 799 | Eye/mouth shift model; the compositing in `eyePreview` (763) is needed for the preview. |
| `appInstalled`, `emuInstalled`, `doomInstalled` | 1115-1124 | What sits at 0x0A0000. |
| `stubList` | 1126 | Where the autostart stub can be. |
| `emuAutoDirty`, `emuClockDirty`, `emuUpPending` | 1132-1143 | "Settings/program differ from the ROM". |
| `a0Free`, `appRoom` | 1147-1148 | Room for a main program. |
| `t7State`, `t7Size` | 1189, 1194 | Current main T7Emu, its size. |
| `dlcTarget`, `figTarget`, `t18Target` | 1198, 1441, 1238 | Which firmware a content change goes to, and how it is written back into state. |
| `t7GpSave`, `t7GpGet`, Gotchi Points write | 1209, 1217, 1227-1231 | Gotchi Points: 5 BCD bytes at 0x32 of the T7 save. |
| `t18Fresh` | 1276 | Ranges of a T18Emu save that must come from the image. |
| `t18Nm` | 1282 | Name or number of a T18 item. |
| `mainGuestLoad` | 1445 | Reads the installed main TamaEmu firmware with its save. |
| `sessKeep`, `SESS_KINDS`, `clockOff` | 1504-1506 | Per-program session flag, clock switch of the clean ROM. |
| `exitOffs`, `exitGet`, `exitSet` | 1630-1644 | "Back from programs": word `0x5845 << 16 | mode` at +0x13C of every program's vector table (mode 0 restores the word at +0x138). |
| `extrasOld` | 1645 | Which menu programs are older than the embedded ones (compares bytes 0..0x13C and 0x800..0x10000). |
| `emuRemoveClear`, `mainV9`, `cleanCan`, `doomMain`, `doomFree`, `doomXs` | 1659, 1661, 2512, 1662, 1686, 1687 | Mode predicates. |
| `doomEpSize`, `doomChip`, `doomMcuOf`, `doomParaX` | 1674, 1677, 1688, 1693 | Size/label/converted data of a DOOM entry; the Paradise's DOOM as a menu program. |
| `paraMainSync`, `doomFreeSync` | 1700, 1712 | Keep `extras` consistent when DOOM and the main emulator become menu programs. |
| `curMainX`, `canMain`, `makeMain`, `mainChecked` | 1746-1786 | The star: which program is the main one. |
| `emuX`, `emuNm`, `installedX` | 1788-1796 | Main program as an extra, its name, the installed one read back. |
| `hasOldSave` | 1797 | Does the content target have a save that a new layout would drop. |
| `roomTry`, `roomMissing`, `roomFit`, `roomFit1`, `roomSig`, `roomCont`, `roomId`, `t18Here`, `roomSoon` | 1805-1860, 1026 | Trial builds; `roomFit1` tries every program as the first one in a start device and reports the smallest shortfall; `roomFit` retries with the "few spares" layout (`t18Few`). |
| `addExtra` | 1861 | Detection and all rules for a further program. |
| `fileEmu` handler | 1990 | Main or menu decision for a chosen firmware. |
| `fileT7Fig` handler | 1890 | Figure rules (16, duplicates, room). |
| `fileDlc` handler, `stampMark`, `stampFor` | 1916, 1913, 1914 | Download content incl. the 4U/P's filter and the stamp flag. |
| `fileT18Item`, `fileT18Pic` handlers | 1944, 1964 | Item import; picture naming and ranking. |
| `gbKeysNow/Apply`, `smsKeysNow/Apply`, `pmKeysNow/Apply`, `pmBiosNow/Apply`, `abKeysNow/Apply`, `wolfKeysNow/Check/Apply` | 2025-2026, 2067-2068, 2110-2113, 2174-2175, 2220-2222 | One key layout per kind; the button tables `GB_BTNS`, `SMS_BTNS`, `PM_BTNS`, `AB_BTNS`, `GB_INS` (2023-2024, 2066, 2109, 2173). |
| `pmFiles` | 2142 | Files of a pick, ZIPs opened. |
| `fileWolf` handler | 2253 | One Wolf3D / one SOD, replace, room check. |
| `doomCompute` | 2342 | All conversions of a WAD: merges map packs (`D.wadMerge`), episodes (`D.wadEpisodes`, up to E4 and `M`), per episode with and without music (`D.wadSub`, `D.gbaExtras`, `D.convert(sub, extras, emb.wasm)`), room limits (`D.REGION_OFF - D.WAD_OFF - 4` with the Paradise, `0xEFD000 - 0x111000 - 4` without), whole WAD, own episodes `P<i>`, DOOM II map packs `Q<i>`, link savings (`E.doomLinks`). Note: `D.convert` runs a WebAssembly module. |
| `keysChanged` | 2328 | DOOM keys from the controls. |
| `sixSame`, `sixDnaUp`, `sixActive` | 2450, 2452, 480 | Six-field state tests. |
| `keptT18Ranges` | 2547 | Flash ranges of a T18Emu that stays in place. |
| `dlStrip` | 2562 | Removes stale copies of the flash app (by the old copy, the rescue block content or the first 64 bytes of the embedded app) between 0x100000 and 0xFF0000. |
| `renderPlan` computation, `planEmus`, `planWolf`, `planGroup`, `groupKind`, `groupSig`, `MB` | 1036, 987, 1001, 1017, 1013, 1014, 1023 | Usage summary (section 3.4). |
| `baseName` and the name rules | 409, 2632, 2784 | Output file names. |
| `mainName` | 3112 | Name of the main emulator of a ROM. |
| `sameFw`, `extrasDedupe` | 3121, 3130 | "Same firmware" test (colour Tamas by blocks 0, 1, 0x40, 0x41) and removing duplicates. |
| `rd32`, `studioSecs` | 3139, 3140 | Little-endian read; 4 KB sectors that differ between two images. |
| `romEmuCfg`, `romExtras`, `romT7` | 3169, 3193, 3191 | Short readers. |
| `packedTamas`, `mainFew`, `packOk` | 3172, 3182, 3190 | Which firmwares end up packed (warning before save/write). |
| `savePrograms`, `saveExt`, `extraFor`, `saveProg`, `progDev` | 3200, 3199, 3211, 3219, 3291 | Programs with a save, and the extra in `state.extras` that belongs to a program of the loaded ROM. |
| `gbSaveLen`, `smsSaveLen` | 3207, 3209 | Cartridge RAM size (header byte 0x149, MBC2 = 0x200, at most 32 KB) / 8 or 32 KB. |
| `t18Part`, `saveKindOf`, `T18_PART` | 3278, 3285, 3277 | Recognising save files. |
| `fileEmuSav` handler | 3296 | Save import per kind (section 5.1), incl. the save buffer layouts (state in the first 0x1000 bytes, cartridge data from 0x1000). |
| `btnEmuOut` handler | 3472 | Save export per kind. |
| `btnParaOut` handler, `paraSlots`, `slotLabel`, `edSlug`, `stamp` | 3458, 3245, 3246, 3110, 3109 | Paradise save export, slots, names. |
| `petOpen`, `btnPetSave` handler | 3411, 3439 | Pet editor. |

Device-side logic (only needed if the native app writes to a device itself):

| Function | Line | What it does |
|---|---|---|
| `saveCarry` | 2920 | With "Keep saves": finds TamaEmu/T18Emu programs whose place changes (settings block bytes 0x148..end differ), checks that the device holds the loaded ROM (`d.crc` of each settings sector), pulls their flash from the device (`d.changed`, `d.read`), rebuilds the firmware (`SV.emuGuestAsync`, `E.t18FromRom`), merges the Studio's download items (`E.dlcAreas`, `E.saveFlag`) and puts it into `state.emu` / the matching extra (`carry`, `saveImp`). |
| `emuSameDev` | 3148 | Does the device hold the same emulator firmware as the image (layout bytes + CRC of code blocks / ROM). |
| `btnWrite` handler | 2961 | The write flow with all questions (section 5.2). |
| `stampSess` | 3046 | After the keep plan: carries the stamp-card flag into the run state of P's TamaEmus (`E.saveFlagGet`, `E.psSessStamp`). Note: it takes `fe = FL.embedded()` (the flash app bytes) and passes `fe.stub` (undefined) to `F.feldApps`, so in the shipped page only the program at 0xA0000 is reliably handled; check before porting. |
| `t18Bases` | 3059 | Offsets of T18Emu settings blocks in an image. |
| `stashPut/Get/Del`, `rescueCheck`, resume | 3066-3088 | Keeps the image being written until the write is complete; rescue state after connecting. |
| `btnSaveRead`, `fileSave` handlers, `slotWrite`, slot clear | 3531, 3579, 3606, 3257 | Save backup and restore over the device. |
| `devTask`, `devProg`, `flMsg`, `devRender` | 2822, 2816, 2815, 2799 | Task wrapper, progress text, error text, enabled states. |
| `visArm`, `visClose`, `visKey` | 2852, 2867, 2837 | Simulated visit over `ParamixVisit.createVisitor`. |

Browser-only code that is not to be ported: `pmxBridge` / `pmxBridgeHref` (app.js:1291-1364, a
bookmarklet that replaces `navigator.bluetooth` on mixing-meets.com with the UART dongle), the DOM
builders (`tile`, `paintTile`, `renderGrids`, `openDrawer`, `nameRow`, `checkInto`, `selectInto`,
`optInto`, `keySel`, `picCanvas`, the `*Into` list builders), `imgToCanvas`, `download`,
`applyLang`, `MSG_DE`/`storeDe` (German only).

Known oddities of the shipped page, for a faithful port:

1. app.js:426 - ten state resets are inside a `//` comment (section 1.3).
2. `state.eyeLayer` is never true (section 2.4).
3. `btnApp`, `btnEmuOff`, `btnEmuUndo`, `btnT7Fig`, `btnDlc`, `emuAuto`, `emuClock`, `emuNfc` exist
   in index.html but are never visible.
4. A clean context has no `editionId` (section 1.2).
5. `gbKeys`, `smsKeys`, `wolfKeys` survive loading another ROM; `pmKeys`, `abKeys` do not.
6. `state.saves` is always `true`; `state.dlcOpen`, `state.tamaPacked` are written but never read;
   the i18n keys `smsGG` and `doomOne` are never shown.
7. `doomCompute` throws the German literal "E1 bis E4 fehlen" in both languages (app.js:2346).
8. `stampSess` passes the flash app instead of the menu template (table above).
