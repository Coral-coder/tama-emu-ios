# The cases of compose.js / compose_check.dart

`compose_cases.json` is written by `node tool/paramix_check/compose_cases_gen.js`. A case is
`[name, steps]`. Both checks run the steps in order and print `<case> <step number> <step>: <value>`
for every step that has a result, a line `toast:` when the step showed a message, and `confirm:`
for a question the page asked (always answered with yes).

compose.js does each step on the page (jsdom): it calls the handler of the control named below.
compose_check.dart does the same with `BuildState`.

| Step | Page (compose.js) | BuildState (compose_check.dart) |
|---|---|---|
| `open <edition>` | a new page, `fileRom` with the dump | `BuildState.load` |
| `openSyn <syn>` | a new page, `fileRom` with synthetic bytes | `BuildState.load` (throws) |
| `reopen` | a new page, `fileRom` with the ROM the last `save` gave | `BuildState.load` |
| `set feld/bag/tama/gplay <bool>` | checkbox `feldOn` ... | field `feld` ... |
| `set launch/clean/cleanClock <bool>` | `launchOn`, `cleanOn`, `cleanClock` | `setLaunch`, `setClean`, `setCleanClock` |
| `set sixOn/sixPlanet/sixMenu <bool>` | `sixOn`, `sixPlanet`, `sixMenu` | `setSixOn`, fields |
| `set exit <0..3>` | select `exitKey` | `setExitKey` |
| `sixSrc <edition>` / `sixBad <syn>` | `fileSix` | `setSixSource` |
| `name fields/chars/items <row> <text>` | the input of that row of the Names tab | `nameRows`, `setName` |
| `names` | the three lists (count, names, lengths) | `nameRows` |
| `fw <syn> [file name]` | `fileEmu` ("Choose firmware or ROM") | `chooseFirmware` |
| `gb/sms/pm/ab <syn> [file name]` | `fileGb`, `fileSms`, `filePm`, `fileAb` | the handler's tests, then `addExtra` / `setPmBios` / `addArduboy` |
| `wolf <syn>` | `fileWolf` (ParamixWolf.build replaced: the pack is the input) | `addWolf` |
| `wad <syn>` | `fileWad` (doomCompute over the synthetic converter) | `doomCompute` with the same converter, `setDoom` |
| `doomEp`, `doomMusic`, `doomSel <ep> <bool>`, `doomWhole <bool>` | `doomEp`, `doomMusic`, the boxes of `doomEpsBox` | `setDoomEp`, `setDoomMusic`, `doom.sel` / `doom.whole` + `doomSelChanged` |
| `doomKeys {..}` | `kFire` ... `kInv` (keysChanged) | `setDoomKeys` |
| `doomOff` | `btnDoomOff` | `doomOff` |
| `inv gb/sms/pm/ab <bool>` | `gbInv` ... | `setGameKeys` |
| `wolfKey <name> <value>` | `wkFire` ... | `setWolfKeys` |
| `row <main/doom/x0..> star/del/undo` | the ☆, × or ↺ button of that row of the program list | `pick` / `mainChecked`, `removeExtra` / `removeMain` / `undoMain` / `doomOut`, `undoMain` / `doomBack` |
| `row <..> check <label> <bool>`, `row <..> sel <label> <index>` | the row opened (▾), the checkbox or select with that label | `setMainAuto`, `setMainClock`, `setMainSess`, `setMainNfc`, `setEmuPack`, `setMainOpt`, `setExtra` |
| `row <..> fig <syn> [file name]` | "Add figures" of the row, `fileT7Fig` | `addFigures` |
| `numbers` | `btnNumbers` ("Number test ROM") | the same pictures with core_more.dart |
| `raw t7save/t7saveX/saveIn/eye/mouth/blank/carry/t18pics ...` | written into the page's state object | the same fields |
| `plan` | the text of the "Your new ROM" box | `plan().text` |
| `state` | the page's state object, as lines of names, numbers and hashes | the same from `BuildState` |
| `save` | `btnSave`: sha256 of the download and the toast, or `!` and the message | `composeFull`, `packedTamas` |

Where the page's control is disabled or missing the step prints `disabled`, `nocontrol`, `norow`,
`nodetail` or `nobutton`; the Dart side computes the same from the rules of renderFeld / renderApps
/ renderDoom (they are in compose_check.dart, a screen needs them too).

Synthetic inputs (`<syn>`, the same seeded generators as emu.js / emu_check.dart):
`tama:<dev>:<percent used>:<seed>`, `t7:go|friends:<seed>`, `t18:<seed>:<sanrio>:<percent>`,
`v1:<bytes>:<seed>`, `v3:<seed>`, `gb:<size code>:<colour byte>:<title>:<seed>`,
`sms:<bytes>:<region>:<seed>`, `pm:<bytes>:<seed>`, `pmbios:<seed>`, `ab:<bytes>:<seed>` (as .hex text),
`wolf:<bytes>:<flags>:<seed>` (a data pack), `fig:<bytes>:<used>:<seed>`, `rnd:<bytes>:<seed>`,
`wad:<episodes>:<KB with music>:<KB without>:<seed>` (a stand-in for a WAD: the synthetic converter
makes the "converted" data of that size from it).
