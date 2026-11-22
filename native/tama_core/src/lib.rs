//! Native core of the Tama app.
//!
//! The Tamagotchi Paradise emulator is Capybara by infinition (GPL-3.0,
//! third_party/capybara): an ARMv7-M core with the Sonix SNC73410 peripherals, running the real
//! firmware from a 16 MB flash dump. Its `emulator` module is compiled here as it is; this file
//! only adds a C ABI for the app (Dart FFI on iOS and Android).

#![allow(clippy::missing_safety_doc)]

#[path = "../../../third_party/capybara/src/emulator/mod.rs"]
pub mod emulator;
#[path = "../../../third_party/capybara/src/touches.rs"]
pub mod touches;

use std::ffi::{c_char, CStr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use emulator::peripherals::snsys::CYCLES_PAR_SECONDE;
use emulator::{Machine, StepResult};

pub struct Tama {
    m: Machine,
}

unsafe fn path_of(p: *const c_char) -> Option<PathBuf> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok().map(PathBuf::from)
}

#[no_mangle]
pub extern "C" fn tama_new() -> *mut Tama {
    Box::into_raw(Box::new(Tama { m: Machine::new() }))
}

#[no_mangle]
pub unsafe extern "C" fn tama_free(t: *mut Tama) {
    if !t.is_null() {
        let mut b = Box::from_raw(t);
        let _ = b.m.ecrire_sauvegarde();
    }
}

/// Loads a 16 MB dump with its device key (has_key 0: try without). Returns 1 when the firmware
/// can boot, 0 when it stays encrypted (key needed), -1 on error.
#[no_mangle]
pub unsafe extern "C" fn tama_load(t: *mut Tama, dump: *const c_char, key: u32, has_key: i32) -> i32 {
    let t = &mut *t;
    let Some(p) = path_of(dump) else { return -1 };
    t.m.device_key = if has_key != 0 { Some(key) } else { None };
    match t.m.load_firmware_file(&p) {
        Ok(r) => {
            // The dumps were read with a weak battery flag set: without this the firmware shows its
            // battery message and switches off (as Capybara does on load).
            t.m.remplacer_la_pile();
            if r.bootable { 1 } else { 0 }
        }
        Err(_) => -1,
    }
}

/// Follows a save file (the game's flash pages). Returns 1 when it existed and was applied,
/// 0 for a new game, -1 on error. The firmware restarts on the save.
#[no_mangle]
pub unsafe extern "C" fn tama_open_save(t: *mut Tama, path: *const c_char) -> i32 {
    let t = &mut *t;
    let Some(p) = path_of(path) else { return -1 };
    let r = t.m.ouvrir_sauvegarde(p);
    t.m.remplacer_la_pile();
    let running = t.m.is_running;
    t.m.reset();
    t.m.is_running = running;
    match r {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(_) => -1,
    }
}

/// Writes the save when the game changed its flash. 1 written, 0 nothing to do, -1 error.
#[no_mangle]
pub unsafe extern "C" fn tama_write_save(t: *mut Tama) -> i32 {
    let t = &mut *t;
    if !t.m.sauvegarde_a_ecrire() {
        return 0;
    }
    match t.m.ecrire_sauvegarde() {
        Ok(()) => 1,
        Err(_) => -1,
    }
}

/// Runs the console for up to `cycles` CPU cycles (96 000 000 per second), at most `budget_ms`
/// of real time. Returns the cycles done.
#[no_mangle]
pub unsafe extern "C" fn tama_run(t: *mut Tama, cycles: u64, budget_ms: u32) -> u64 {
    let t = &mut *t;
    if !t.m.is_running {
        return 0;
    }
    let start = t.m.cpu.cycles;
    let t0 = Instant::now();
    let limit = Duration::from_millis(budget_ms.max(1) as u64);
    while t.m.cpu.cycles - start < cycles && t0.elapsed() < limit {
        if !matches!(t.m.run_frame(), StepResult::Ok(_)) {
            break;
        }
    }
    t.m.cpu.cycles - start
}

#[no_mangle]
pub extern "C" fn tama_cycles_per_second() -> u64 {
    CYCLES_PAR_SECONDE
}

#[no_mangle]
pub unsafe extern "C" fn tama_running(t: *const Tama) -> i32 {
    (*t).m.is_running as i32
}

/// Copies the 128 x 128 screen as RGB565 into out (16384 values). Returns 1 when it changed.
#[no_mangle]
pub unsafe extern "C" fn tama_screen(t: *mut Tama, out: *mut u16) -> i32 {
    let t = &mut *t;
    let d = &mut t.m.periph.display;
    let n = d.vram.len().min(128 * 128);
    std::ptr::copy_nonoverlapping(d.vram.as_ptr(), out, n);
    let changed = d.dirty;
    d.dirty = false;
    changed as i32
}

/// Pins: A 0x09, B 0x0B, C 0x0A, wheel press 0x08, encoder 0x20 / 0x21.
#[no_mangle]
pub unsafe extern "C" fn tama_press(t: *mut Tama, pin: u32) {
    (*t).m.appuyer(pin);
}

#[no_mangle]
pub unsafe extern "C" fn tama_release(t: *mut Tama, pin: u32) {
    (*t).m.relacher(pin);
}

/// The note the console plays now in Hz, 0 when silent.
#[no_mangle]
pub unsafe extern "C" fn tama_note(t: *mut Tama) -> f32 {
    let t = &mut *t;
    if t.m.voix.is_empty() {
        t.m.localiser_les_voix();
    }
    if !t.m.son_en_cours() {
        return 0.0;
    }
    t.m.note_courante()
}

#[no_mangle]
pub unsafe extern "C" fn tama_sleeping(t: *const Tama) -> i32 {
    (*t).m.en_veille_profonde() as i32
}

/// Snapshot of the whole machine (CPU, memories, peripherals) to a file. 0 ok, -1 error.
#[no_mangle]
pub unsafe extern "C" fn tama_snapshot(t: *const Tama, path: *const c_char) -> i32 {
    let Some(p) = path_of(path) else { return -1 };
    match (*t).m.instantane().ecrire(&p) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn tama_restore(t: *mut Tama, path: *const c_char) -> i32 {
    let Some(p) = path_of(path) else { return -1 };
    match emulator::etat::Instantane::lire(&p) {
        Ok(s) => {
            (*t).m.restaurer(&s);
            0
        }
        Err(_) => -1,
    }
}

// ---- device key search (the dump's AES IV mask; about four billion candidates) ----

static KEY_PROGRESS: AtomicU64 = AtomicU64::new(0);
static KEY_STOP: AtomicBool = AtomicBool::new(false);

/// Searches the device key of a dump (blocking; call it on a background thread). Returns 1 and
/// writes the key when found, 0 when not found or stopped.
#[no_mangle]
pub unsafe extern "C" fn tama_find_key(dump: *const c_char, threads: u32, out_key: *mut u32) -> i32 {
    let Some(p) = path_of(dump) else { return 0 };
    let Ok(buf) = std::fs::read(p) else { return 0 };
    KEY_PROGRESS.store(0, Ordering::Relaxed);
    KEY_STOP.store(false, Ordering::Relaxed);
    let prog = Arc::new(AtomicU64::new(0));
    let stop = Arc::new(AtomicBool::new(false));
    let (p2, s2) = (Arc::clone(&prog), Arc::clone(&stop));
    let watcher = std::thread::spawn(move || {
        while !s2.load(Ordering::Relaxed) {
            KEY_PROGRESS.store(p2.load(Ordering::Relaxed), Ordering::Relaxed);
            if KEY_STOP.load(Ordering::Relaxed) {
                s2.store(true, Ordering::Relaxed);
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    });
    let found = emulator::sonix::recherche_cle::chercher(&buf, threads.max(1) as usize, Arc::clone(&prog), Arc::clone(&stop));
    stop.store(true, Ordering::Relaxed);
    let _ = watcher.join();
    match found {
        Some(k) => {
            *out_key = k;
            1
        }
        None => 0,
    }
}

/// Candidates tried so far (of 4 294 967 296).
#[no_mangle]
pub extern "C" fn tama_find_key_progress() -> u64 {
    KEY_PROGRESS.load(Ordering::Relaxed)
}

#[no_mangle]
pub extern "C" fn tama_find_key_stop() {
    KEY_STOP.store(true, Ordering::Relaxed);
}
