# Neon Planets "super ROM" (research, in progress)

Goal: Neon Planets with the classic fields (Land, Water, Sky, Jade Forest, Tropical, Glacier)
as well as its own planets, built from the user's own dumps (nothing of any ROM in this repo).

## What the dumps show (tool: Paramix core, counts only)

| Edition | characters by field (1-6 classic, 7 Cosmic, 8 New Tama, 9 Tama) | sprite groups | free after the assets |
|---|---|---|---|
| Land / Water / Sky | 22 each for fields 1-3 | 69 | 5.13 MB |
| Jade Forest | fields 1-4 | 91 | 2.55 MB |
| Tropical / Glacier | fields 1-6 | 135 | 0.96 MB |
| Neon Planets | fields 1-6 (22 each) **and** 7: 24, 8: 38, 9: 24 | 169 | 1.24 MB |

- Neon's character table already lists every classic field, but with 169 sprite groups for 220
  characters many classic characters share pictures: their own pictures have to come from the
  Tropical/Glacier dump (all six fields' characters) and the field pictures (maps, close-ups,
  scenes) from the Tropical/Glacier and Land/Water/Sky dumps, as Paramix's six fields does.
- Free flash on Neon outside the asset archive: 0x0B8000-0x110000 (0.34 MB, next to the
  firmware), 0xC48000-0xD85000 (1.24 MB, after the assets), 0xD8B000-0xE4E000 (0.76 MB),
  0xE51000-0xEC6000 (0.46 MB), 0xEC9000-0xEE6000 (0.11 MB), 0xEF7000-0x1000000 (1.04 MB,
  minus what the rescue start keeps). Pictures beyond the archive need a side region with
  pointers, like Paramix's region B at 0xF00000.
- Neon's firmware is a different build: of the Tropical patch sites Paramix uses (field
  backgrounds, child list, teen/adult/egg/scene/planet tables) only the wagon table code is found
  byte for byte in Neon (fw 0x43734). Every other site has to be found in Neon's own code.

## Plan

1. Map Neon's planet switch: trace (examples/recomp_trace.rs, the recompiler's block map) what
   runs and which tables are read when the planet changes; find Neon's equivalents of the
   background function, child list and per-field tables.
2. Decide the switch: a set byte as in Paramix six fields (Neon's 3 planets + 6 classic fields
   in the planet/field menu).
3. Builder (like six.js): copies the classic characters' pictures and field pictures from the
   user's Tropical/Glacier and Land/Water/Sky dumps into Neon's free regions, writes the helper
   page and patches the found sites; verifies by booting the result in the emulator on every
   field before anything goes to a toy.
4. Only then: write to a toy (Device page, with a backup first).
