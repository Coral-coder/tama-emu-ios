# Tama recompiler (in progress)

Goal: run the Paradise firmware several times faster than Capybara's interpreter, for battery
and frame rate (iPhone, Apple Watch, Android), without changing what the game does.

## Measured (tool: `native/tama_core/examples/recomp_trace.rs`, Water, 20 s awake with keys)

- 428 M instructions executed, only 20 245 distinct (6 914 in PRAM, 13 331 in XIP flash).
- 50 % of the run is in 94 instructions, 90 % in 887, 99 % in 3 344, 99.9 % in 6 415.
- About 85 host instructions per emulated instruction today (callgrind); half of it is the
  interpreter's fetch / decode / dispatch, not the instruction's work.
- The firmware's wait for the screen (TE pin poll) is already skipped (2-5x on awake time).

## Design: translate on load, run blocks

- Blocks are translated on the device from the ROM that is loaded, the first time they run hot
  (no firmware or translated firmware is stored in the repository or the app; Paramix-modified
  ROMs work the same).
- iOS and watchOS allow no executable memory, so a block becomes a compact array of
  pre-decoded operations (registers, immediates, shifts and flags resolved once) run by a tight
  loop: no fetch, no decode, no per-instruction peripheral bookkeeping.
- Hot instruction kinds (loads/stores, MOV/MOVW/MOVT, add/sub/compare, logic, shifts,
  branches, BL/BX, PUSH/POP, IT blocks) get native operations. Everything else falls back to
  Capybara's own executor for that one instruction, so coverage is complete from day one.
- Cycles are summed per block; the peripherals (SysTick, TE, timers, UART, clock) are serviced
  at block ends as Capybara does every 256 cycles; interrupts are taken at block boundaries.
- Code in PRAM is copied there by the firmware at boot: a block from PRAM is dropped when the
  firmware writes over its bytes (write watch on PRAM pages).
- Memory: SRAM and PRAM accessed directly, MMIO through Capybara's bus.

## Checking

- Lockstep test: the translated run and the interpreter run side by side from the same state;
  registers, flags and memory are compared after every block, on every edition.
- The existing traces (sounds, sleep and wake times, screens) must come out the same.

## Milestones

1. Coverage tracer and instruction census (done).
1b. Stage 1, pre-decoded blocks run by Capybara's executors (done, on by default): 1.40-1.46x
   faster on Water, Neon, Glacier, Jade (examples/recomp_check.rs: same screens, sounds and
   sleep/wake times; a few dozen bytes of work RAM differ after 20 s, from frame timing).
2. Stage 2, native operations (done, on): branches, BL, immediate and register data
   processing (16 and 32 bit), shifts, high registers, every load/store form, SP adjust,
   MOVW/MOVT, literal loads folded into constants. 92 % of executed instructions native.
   examples/recomp_verify.rs runs each native op against Capybara from the same state:
   0 differences over 60 M instructions on Water, Neon, Tropical. 1.80-1.82x the
   interpreter on Water, Glacier, Jade; Neon's 4-minute sleep/wake trace is unchanged.
3. Lockstep tester on all editions; fix until it matches for minutes of play.
4. Switch the app's core to it (phone, watch, Android), measure battery and frame rate.
