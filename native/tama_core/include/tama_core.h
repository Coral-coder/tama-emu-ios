// C interface of native/tama_core (the Capybara Tamagotchi Paradise emulator, GPL-3.0).
#pragma once
#include <stdint.h>

typedef struct Tama Tama;

Tama *tama_new(void);
void tama_free(Tama *t);
/// 1 bootable, 0 encrypted (key missing or wrong), -1 error.
int32_t tama_load(Tama *t, const char *dump, uint32_t key, int32_t has_key);
/// 1 save applied, 0 new game, -1 error.
int32_t tama_open_save(Tama *t, const char *path);
/// 1 written, 0 nothing to write, -1 error.
int32_t tama_write_save(Tama *t);
uint64_t tama_run(Tama *t, uint64_t cycles, uint32_t budget_ms);
uint64_t tama_cycles_per_second(void);
int32_t tama_running(const Tama *t);
/// 128 x 128 RGB565; returns 1 when it changed.
int32_t tama_screen(Tama *t, uint16_t *out);
/// Pins: A 0x09, B 0x0B, C 0x0A, wheel press 0x08, encoder 0x20 / 0x21.
void tama_press(Tama *t, uint32_t pin);
void tama_release(Tama *t, uint32_t pin);
float tama_note(Tama *t);
uint32_t tama_sounds(const Tama *t);
int32_t tama_sleeping(const Tama *t);
/// Local time in seconds since 2025-01-01 (the firmware's epoch).
int32_t tama_sync_clock(Tama *t, uint64_t local_secs_since_2025);
void tama_auto_date(Tama *t, uint32_t seconds);
void tama_advance(Tama *t, uint32_t seconds);
