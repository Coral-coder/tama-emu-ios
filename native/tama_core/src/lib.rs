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
    // the firmware's pin-read function (found by its bytes): read on the screen's TE pin, it is
    // the wait for the next frame, which the run skips instead of emulating poll after poll
    lecture_broche: Option<u32>,
    lecture_cherchee: u64,
    attentes_sautees: u64,
    // sound, followed as Capybara does: the voice table is looked up at the start of every sound
    son_jouait: bool,
    derniere_recherche: u64,
    note_perimee: f32,
    perimee_jusqu: u64,
    note: f32,      // the note playing now
    note_vue: f32,  // the last note heard during the last run (short notes are not lost)
    sons: u32,      // sounds started so far (the app notices calls with it)
    // the date screens of a new start, confirmed by themselves (the form is filled in from the clock)
    auto_jusqu: u64,
    auto_prochain: u64,
    auto_relache: u64,
    auto_n: u32,
    drapeau: u32,               // address of the sound flag (0: not looked up yet)
    veille_depuis: Option<u64>, // since when the core sits parked, powered off
    redemarrages: u32,
    reveils: u32,
    veilles_sautees: u64, // console cycles skipped while asleep (for the record)
    // the dial: queued steps, played on the encoder lines in emulated time
    tours: std::collections::VecDeque<bool>,
    phase: u8,
    phase_a: u64,
    // the pet's record in RAM (the settings block's working copy) and the care kept up by itself
    bloc: Option<(usize, usize)>, // (RAM offset of the block, offset of the pet in it)
    soins_auto: u32,
    soins_a: u64,
    boucle: (u32, u64, u32, u32), // a spin loop (pc, since, hits, frames): waiting for the watchdog
}

unsafe fn path_of(p: *const c_char) -> Option<PathBuf> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok().map(PathBuf::from)
}

#[no_mangle]
pub extern "C" fn tama_new() -> *mut Tama {
    Box::into_raw(Box::new(Tama {
        m: Machine::new(),
        lecture_broche: None,
        lecture_cherchee: 0,
        attentes_sautees: 0,
        son_jouait: false,
        derniere_recherche: 0,
        note_perimee: 0.0,
        perimee_jusqu: 0,
        note: 0.0,
        note_vue: 0.0,
        sons: 0,
        auto_jusqu: 0,
        auto_prochain: 0,
        auto_relache: 0,
        auto_n: 0,
        drapeau: 0,
        veille_depuis: None,
        boucle: (0, 0, 0, 0),
        redemarrages: 0,
        veilles_sautees: 0,
        reveils: 0,
        tours: std::collections::VecDeque::new(),
        phase: 0,
        phase_a: 0,
        bloc: None,
        soins_auto: 0,
        soins_a: 0,
    }))
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
    let t0 = Instant::now();
    let limit = Duration::from_millis(budget_ms.max(1) as u64);
    t.note_vue = 0.0;
    let mut done: u64 = 0;
    while done < cycles && t0.elapsed() < limit {
        // Deep sleep: the core is parked until the clock block's alarm (or a key) wakes it, and
        // only the seconds counter runs. Running the parked loop instruction by instruction would
        // burn the phone's battery for nothing: the time is skipped ahead instead, a tenth of a
        // second at a time, so the alarm rings on time and the firmware wakes as on the toy.
        if t.saut_de_veille() {
            // straight to the alarm (or 10 s at a time): nothing else can happen while parked
            let pas = (cycles - done).min(t.cycles_avant_alarme()).min(10 * CYCLES_PAR_SECONDE as u64).max(1);
            t.m.periph.snsys.tick(pas as u32);
            if t.m.periph.snsys.reveil_demande {
                // the clock's alarm woke it, not a key: the power block says so (a key wake left
                // its flag standing would make the firmware light the screen as for a key)
                use emulator::peripherals::PmuController as Pmu;
                let st = &mut t.m.periph.pmu.status;
                *st = (*st & !Pmu::FLAG_WAKEUP_PIN) | Pmu::FLAG_RTC | Pmu::FLAG_WAKEUP_INT;
            }
            t.m.cpu.cycles += pas;
            done += pas;
            t.veilles_sautees += pas;
            continue;
        }
        let avant = t.m.cpu.cycles;
        if !t.tranche() {
            break;
        }
        let apres = t.m.cpu.cycles;
        if apres < avant {
            // a wake from deep sleep resets the core, and its cycle counter with it
            t.reveils += 1;
            done += apres;
            t.recaler();
        } else {
            done += apres - avant;
        }
        t.suivre_le_son();
        t.date_auto();
        t.suivre_la_veille();
        t.tourner();
        t.soigner();
    }
    done
}

impl Tama {
    /// Bytes of the firmware's GPIO pin-read function (r0 = port << 4 | pin), the same in every
    /// edition (Water, Land, Sky, Jade: 0x5D0C, Tropical, Glacier: 0x58C4, Neon: 0x5CEC).
    const LECTURE_BROCHE: [u8; 10] = [0x87, 0xB0, 0x8D, 0xF8, 0x1B, 0x00, 0x05, 0x91, 0x04, 0x92];
    /// The screen's TE line, port 1 pin 10, as the firmware names it.
    const BROCHE_TE: u32 = 0x1A;

    /// Looks for the pin-read function in program memory (once the boot has filled it).
    fn chercher_lecture(&mut self) {
        let now = self.m.cpu.cycles;
        if self.lecture_broche.is_some() || now < self.lecture_cherchee {
            return;
        }
        self.lecture_cherchee = now + 2 * CYCLES_PAR_SECONDE as u64;
        let m = &mut self.m;
        let mut code = vec![0u8; 0x10000];
        for i in (0..0x10000u32).step_by(2) {
            let w = m.bus.read_u16(i, &mut m.periph, &m.cpu.nvic);
            code[i as usize] = w as u8;
            code[i as usize + 1] = (w >> 8) as u8;
        }
        let sig = Self::LECTURE_BROCHE;
        let mut trouve = (0..code.len() - sig.len()).step_by(2).filter(|&i| code[i..i + sig.len()] == sig);
        if let (Some(a), None) = (trouve.next(), trouve.next()) {
            self.lecture_broche = Some(a as u32);
        }
    }

    /// One slice of the console, instruction by instruction (what Capybara's run_frame does),
    /// except that a read of the TE pin skips the time until the pin changes. False when the
    /// core stopped.
    fn tranche(&mut self) -> bool {
        if !self.m.is_running {
            return false;
        }
        self.chercher_lecture();
        let lecture = self.lecture_broche.unwrap_or(u32::MAX);
        for _ in 0..self.m.instructions_per_frame {
            if self.m.cpu.regs.pc == lecture && self.m.cpu.regs.get_reg(0) == Self::BROCHE_TE {
                self.attendre_te();
            }
            match self.m.step() {
                StepResult::Ok(_) => {}
                _ => {
                    self.m.is_running = false;
                    return false;
                }
            }
        }
        true
    }

    /// The firmware polls the TE pin for the next frame: the peripherals run on without the
    /// core until the pin changes, an interrupt is due, or a millisecond went by (the SysTick
    /// must not lose a tick). On the toy the core does nothing else meanwhile either.
    fn attendre_te(&mut self) {
        const PAS: u32 = 2048;
        let masque = 1u32 << 10;
        let avant = self.m.periph.port1.entrees & masque;
        let mut fait = 0u32;
        while fait < CYCLES_PAR_SECONDE as u32 / 1000 {
            self.entretenir(PAS);
            fait += PAS;
            let n = &self.m.cpu.nvic;
            if self.m.periph.port1.entrees & masque != avant || n.systick_pending || n.en_attente || self.m.periph.snsys.reveil_demande {
                break;
            }
        }
        self.m.cpu.cycles += fait as u64;
        self.attentes_sautees += fait as u64;
    }

    /// What Capybara's core does with the cycles of its instructions (entretenir_peripheriques).
    fn entretenir(&mut self, e: u32) {
        use emulator::peripherals::{adc_pile, gpio_port};
        let c = &mut self.m.cpu;
        let p = &mut self.m.periph;
        c.nvic.tick_systick(e);
        if p.port1.tick(e) {
            c.nvic.request_irq(gpio_port::PORT1_IRQ);
        }
        if let Some(irq) = p.tic.tick(e) {
            c.nvic.request_irq(irq);
        }
        if p.adc_pile.irq_a_lever | p.adc_pile.tick(e) {
            p.adc_pile.irq_a_lever = false;
            c.nvic.request_irq(adc_pile::IRQ);
        }
        if p.timers.tick(e) {
            c.nvic.request_irq(16);
        }
        p.uart.tick(e, CYCLES_PAR_SECONDE as u32);
        if p.uart.irq_pending {
            c.nvic.request_irq(37);
        }
        p.snsys.tick(e);
    }

    /// Plays the queued dial steps: each step is the two encoder lines in quadrature (A down,
    /// B down, A up, B up), 12 ms of console time apart, so the firmware sees every edge.
    fn tourner(&mut self) {
        let now = self.m.cpu.cycles;
        let Some(&droite) = self.tours.front() else { return };
        if now < self.phase_a {
            return;
        }
        let (a, b) = if droite { (0x20, 0x21) } else { (0x21, 0x20) };
        match self.phase {
            0 => self.m.appuyer(a),
            1 => self.m.appuyer(b),
            2 => self.m.relacher(a),
            _ => self.m.relacher(b),
        }
        self.phase += 1;
        self.phase_a = now + CYCLES_PAR_SECONDE as u64 / 1000 * 12;
        if self.phase == 4 {
            self.phase = 0;
            self.tours.pop_front();
        }
    }

    /// The settings block in flash: Neon keeps a ring of five pages (the highest number at
    /// +0xAD0 is the newest), the others 0xEFE000 (copy at 0xEFF000).
    fn bloc_flash(&self) -> Option<&[u8]> {
        let f = &self.m.bus.flash.data;
        let ok = |a: usize| {
            if a + 0x1000 > f.len() {
                return false;
            }
            let p = &f[a..a + 0x1000];
            let c = crc16_arc(&p[4..]);
            u16::from_le_bytes([p[0], p[1]]) == c && u16::from_le_bytes([p[2], p[3]]) == !c
        };
        let neon = f.len() >= 0xD86000 && u32::from_le_bytes([f[0xD85000], f[0xD85001], f[0xD85002], f[0xD85003]]) < 0x100;
        if neon {
            let mut best: Option<usize> = None;
            for i in 0..5 {
                let a = 0xD86000 + i * 0x1000;
                if !ok(a) {
                    continue;
                }
                let seq = |a: usize| u32::from_le_bytes([f[a + 0xAD0], f[a + 0xAD1], f[a + 0xAD2], f[a + 0xAD3]]);
                if best.is_none_or(|b| (seq(a).wrapping_sub(seq(b)) as i32) > 0) {
                    best = Some(a);
                }
            }
            return best.map(|a| &f[a..a + 0x1000]);
        }
        [0xEFE000usize, 0xEFF000].into_iter().find(|&a| ok(a)).map(|a| &f[a..a + 0x1000])
    }

    /// Flash addresses of the valid settings blocks (Neon: its newest ring page; the others: the
    /// block and its copy).
    fn blocs_flash_adresses(&self) -> Vec<usize> {
        let Some(p) = self.bloc_flash() else { return Vec::new() };
        let f = &self.m.bus.flash.data;
        let base = p.as_ptr() as usize - f.as_ptr() as usize;
        let neon = base >= 0xD86000 && base < 0xD8B000;
        if neon {
            return vec![base];
        }
        [0xEFE000usize, 0xEFF000]
            .into_iter()
            .filter(|&a| {
                let q = &f[a..a + 0x1000];
                let c = crc16_arc(&q[4..]);
                u16::from_le_bytes([q[0], q[1]]) == c
            })
            .collect()
    }

    /// Writes bytes into the settings block: its working copy in RAM and the save in flash (the
    /// checksum made right), so a restart keeps the change.
    fn ecrire_bloc(&mut self, offset: usize, octets: &[u8]) -> bool {
        if offset < 4 || offset + octets.len() > 0x1000 {
            return false;
        }
        let Some((o, _)) = self.trouver_bloc() else { return false };
        self.m.bus.sram.data[o + offset..o + offset + octets.len()].copy_from_slice(octets);
        for a in self.blocs_flash_adresses() {
            let flash = &mut self.m.bus.flash;
            let p = &mut flash.data[a..a + 0x1000];
            p[offset..offset + octets.len()].copy_from_slice(octets);
            let c = crc16_arc(&p[4..]);
            p[0..2].copy_from_slice(&c.to_le_bytes());
            p[2..4].copy_from_slice(&(!c).to_le_bytes());
            flash.pages_salies.insert(a / 0x1000);
            flash.revision = flash.revision.wrapping_add(1);
        }
        true
    }

    /// Where the pet's record sits in this edition's settings block.
    fn place_du_tama(&self) -> usize {
        let f = &self.m.bus.flash.data;
        let id = |a: usize| if a + 4 <= f.len() { u32::from_le_bytes([f[a], f[a + 1], f[a + 2], f[a + 3]]) } else { u32::MAX };
        if id(0xD85000) < 0x100 || (5..=7).contains(&id(0xD29000)) {
            0x114 // Tropical, Glacier, Neon Planets
        } else if id(0xD49000) == 4 {
            0x108 // Jade Forest
        } else {
            0x104 // Land, Water, Sky
        }
    }

    /// Finds the settings block's working copy in RAM (once): the place where nearly all of its
    /// 4 KB match the flash copy (the clock differs).
    fn trouver_bloc(&mut self) -> Option<(usize, usize)> {
        if let Some(b) = self.bloc {
            return Some(b);
        }
        let page = self.bloc_flash()?.to_vec();
        let ram = &self.m.bus.sram.data;
        // a few marks to try first: non-zero bytes past the header
        let marques: Vec<usize> = (0x20..0x1000).filter(|&i| page[i] != 0 && page[i] != 0xFF).take(32).collect();
        if marques.len() < 4 {
            return None;
        }
        let mut o = 0;
        while o + 0x1000 <= ram.len() {
            if marques.iter().filter(|&&i| ram[o + i] == page[i]).count() >= marques.len() * 3 / 4 {
                let same = (4..0x1000).filter(|&i| ram[o + i] == page[i]).count();
                if same > 0x1000 * 9 / 10 {
                    let b = (o, self.place_du_tama());
                    self.bloc = Some(b);
                    return Some(b);
                }
            }
            o += 1;
        }
        None
    }

    /// Care kept up by itself (fed, played with, cured), checked every 10 s of console time.
    fn soigner(&mut self) {
        if self.soins_auto == 0 {
            return;
        }
        let now = self.m.cpu.cycles;
        if now < self.soins_a {
            return;
        }
        self.soins_a = now + 10 * CYCLES_PAR_SECONDE as u64;
        let f = self.soins_auto;
        self.soins(f);
    }

    /// Feeds (bit 1), plays (bit 2), cures (bit 4): the pet's record in RAM, as the game's own
    /// meal, game and medicine would leave it (hunger 6, happiness 20, not sick).
    fn soins(&mut self, quoi: u32) -> bool {
        let Some((o, t)) = self.trouver_bloc() else { return false };
        let ram = &mut self.m.bus.sram.data;
        let p = o + t;
        if ram[p + 4] == 0 && ram[p + 5] == 0 {
            return false; // no pet (yet)
        }
        if quoi & 1 != 0 && ram[p + 0x1C] < 6 {
            ram[p + 0x1C] = 6;
        }
        if quoi & 2 != 0 && ram[p + 0x1D] < 20 {
            ram[p + 0x1D] = 20;
        }
        if quoi & 4 != 0 {
            ram[p + 0x10] = 0;
        }
        true
    }

    /// Console cycles until the clock block's alarm rings (no alarm: a long time).
    fn cycles_avant_alarme(&self) -> u64 {
        use emulator::peripherals::SnSysRegisters as Sys;
        let s = &self.m.periph.snsys;
        let echeance = s.read_reg(Sys::ALARME);
        if echeance == 0 || s.secondes > echeance {
            return u64::MAX;
        }
        // it rings once the counter has gone past the deadline; the part of the current second
        // already counted is not known here, so the last second goes by in tenths
        let secondes = (echeance - s.secondes) as u64;
        (secondes * CYCLES_PAR_SECONDE as u64).max(CYCLES_PAR_SECONDE as u64 / 10)
    }

    /// Whether the run can skip ahead: asleep, no alarm pending, nothing to press or turn.
    fn saut_de_veille(&self) -> bool {
        self.en_veille() && !self.m.periph.snsys.reveil_demande && self.tours.is_empty() && self.auto_relache == 0
            && self.m.periph.uart.rx_in.is_empty()
    }

    /// Deep sleep, on every edition: Capybara knows Water's sleep loop (0x23D0); the others park
    /// elsewhere in PRAM (Neon: 0x224C) after asking the clock block to power the core off (bit 0
    /// of 0x45000300). Either way only a key (or the alarm) wakes the console.
    fn garee(&self) -> bool {
        self.m.periph.snsys.read_reg(0x300) & 1 != 0 && self.m.cpu.regs.pc < 0x4000
    }

    /// Parked for half a second at least (the boot also runs a moment in PRAM with the bit set).
    fn en_veille(&self) -> bool {
        self.m.en_veille_profonde()
            || (self.garee() && self.veille_depuis.is_some_and(|d| self.m.cpu.cycles.saturating_sub(d) > CYCLES_PAR_SECONDE as u64 / 2))
    }

    fn suivre_la_veille(&mut self) {
        if self.garee() {
            if self.veille_depuis.is_none() {
                self.veille_depuis = Some(self.m.cpu.cycles);
            }
        } else {
            self.veille_depuis = None;
        }
        // The firmware ends some jobs ("reset all") by spinning until the chip's watchdog restarts
        // it; Capybara has no watchdog. Two seconds in the same few bytes of code is that spin.
        let pc = self.m.cpu.regs.pc;
        let now = self.m.cpu.cycles;
        let b = &mut self.boucle;
        b.3 += 1;
        if pc >= 0x1000_0000 && pc.abs_diff(b.0) <= 8 {
            b.2 += 1;
        }
        if now.saturating_sub(b.1) > 2 * CYCLES_PAR_SECONDE as u64 {
            // nearly every look in two seconds found the core in the same few bytes: a spin
            let spin = b.3 > 20 && b.2 * 10 >= b.3 * 9;
            *b = (pc, now, 0, 0);
            if spin {
                self.redemarrages += 1;
                self.m.reset();
                self.m.is_running = true;
                self.recaler();
                return;
            }
        }
        // tells the core it sleeps, so its clock alarm wakes it on every edition (Capybara only
        // recognises Water's sleep loop)
        if !self.m.periph.pmu.deep_sleep_active && self.en_veille() {
            self.m.periph.pmu.deep_sleep_active = true;
        }
    }

    /// A key wakes a sleeping console (the core restarts, as on the toy).
    fn reveiller(&mut self) -> bool {
        if !self.en_veille() {
            return false;
        }
        self.m.periph.pmu.deep_sleep_active = true;
        let r = self.m.reveiller_par_broche();
        if r {
            self.recaler();
        }
        r
    }

    /// The core was reset (its cycle counter restarted): the deadlines kept in cycles follow.
    fn recaler(&mut self) {
        let now = self.m.cpu.cycles;
        self.veille_depuis = None;
        self.bloc = None;
        self.boucle = (0, now, 0, 0);
        self.m.periph.pmu.deep_sleep_active = false;
        self.derniere_recherche = 0;
        self.perimee_jusqu = 0;
        if self.auto_jusqu > 0 {
            self.auto_jusqu = now + 60 * CYCLES_PAR_SECONDE as u64;
        }
        self.auto_prochain = 0;
        self.phase_a = now;
        self.soins_a = now;
        if self.auto_relache != 0 {
            self.auto_relache = now + 1;
        }
    }

    fn pixel(&self, x: usize, y: usize) -> (i32, i32, i32) {
        let v = self.m.periph.display.vram.get(y * 128 + x).copied().unwrap_or(0) as i32;
        (((v >> 11) & 31) * 255 / 31, ((v >> 5) & 63) * 255 / 63, (v & 31) * 255 / 31)
    }

    fn proche(&self, x: usize, y: usize, c: (i32, i32, i32)) -> bool {
        let p = self.pixel(x, y);
        (p.0 - c.0).abs() < 30 && (p.1 - c.1).abs() < 30 && (p.2 - c.2).abs() < 30
    }

    /// The "set current date / time" notice, or the form under it (year, month, ... with + OK <-).
    /// 1: the notice, 2: the date form, 0: anything else.
    fn ecran_de_date(&self) -> u8 {
        let blanc = (255, 255, 255);
        let cyan = (0, 182, 255);
        let avis = self.proche(2, 2, cyan) && self.proche(2, 64, cyan) && self.proche(125, 125, cyan) && self.proche(64, 64, blanc)
            && self.proche(64, 8, blanc) && self.proche(64, 100, blanc) && self.proche(20, 64, blanc);
        let marine = (0, 0, 98);
        let formulaire = self.proche(2, 2, (0, 52, 139)) && self.proche(124, 4, (0, 52, 139)) && self.proche(5, 124, marine)
            && self.proche(64, 100, marine) && self.proche(64, 124, (222, 0, 197)) && self.proche(64, 115, (255, 129, 230))
            // not the birthday form (month and day only: dark blue where the date form has its rows)
            && !self.proche(64, 70, marine) && !self.proche(30, 88, (0, 170, 255));
        if formulaire {
            return 2;
        }
        if avis {
            1
        } else {
            0
        }
    }

    /// While the date screens of a new start show, presses OK (B) every 1.5 s: the firmware fills
    /// the form from its clock, which follows the phone.
    fn date_auto(&mut self) {
        let now = self.m.cpu.cycles;
        if self.auto_relache != 0 && now >= self.auto_relache {
            self.m.relacher(0x0B);
            self.auto_relache = 0;
        }
        if now >= self.auto_jusqu || now < self.auto_prochain || self.auto_relache != 0 {
            return;
        }
        let e = self.ecran_de_date();
        if e == 2 {
            self.auto_n |= 1 << 8; // the form was seen
        }
        if e == 1 && self.auto_n & (1 << 8) != 0 {
            self.auto_jusqu = 0; // a notice after the date form (the birthday): that one is the player's
            return;
        }
        if e != 0 {
            let cps = CYCLES_PAR_SECONDE as u64;
            self.auto_n += 1;
            if self.auto_n & 0xFF > 20 {
                self.auto_jusqu = 0;
                return;
            }
            self.m.appuyer(0x0B);
            self.auto_relache = now + cps / 8;
            self.auto_prochain = now + cps * 3 / 2;
        }
    }

    /// Capybara's note tracking (app.rs, note_jouee): the voice table is searched at the start of
    /// each sound (and again every half second while it gave nothing), and the stale note left
    /// from the previous sound is held as silence for up to 50 ms.
    /// The firmware's "a sound is playing" flag. Capybara knows Water's (and Jade's, 8 further);
    /// Tropical and Glacier keep the same variables 0xE4 bytes higher.
    fn drapeau_son(&mut self) -> u32 {
        if self.drapeau == 0 {
            let f = &self.m.bus.flash.data;
            let id = |a: usize| if a + 4 <= f.len() { u32::from_le_bytes([f[a], f[a + 1], f[a + 2], f[a + 3]]) } else { u32::MAX };
            let decalage = if (5..=7).contains(&id(0xD29000)) {
                0xE4
            } else if id(0xD49000) == 4 {
                8
            } else {
                0
            };
            self.drapeau = Machine::SON_EN_COURS + decalage;
        }
        self.drapeau
    }

    fn sram_u8(&self, a: u32) -> u8 {
        self.m.bus.sram.data.get(a.wrapping_sub(0x1800_0000) as usize).copied().unwrap_or(0)
    }

    fn sram_u32(&self, a: u32) -> u32 {
        let i = a.wrapping_sub(0x1800_0000) as usize;
        let d = &self.m.bus.sram.data;
        if i + 4 > d.len() {
            return 0;
        }
        u32::from_le_bytes([d[i], d[i + 1], d[i + 2], d[i + 3]])
    }

    fn son_en_cours(&mut self) -> bool {
        let a = self.drapeau_son();
        self.sram_u8(a) != 0
    }

    /// Capybara's note_courante, with this edition's flag.
    fn note_courante(&mut self) -> f32 {
        if !self.son_en_cours() {
            return 0.0;
        }
        for &base in &self.m.voix {
            if self.sram_u32(base) != 0x05B8_D800 || self.sram_u8(base + 8) == 0 {
                continue;
            }
            let hauteur = Machine::hauteur_de_voix(self.sram_u32(base + 4));
            if hauteur > 0.0 && self.sram_u32(base + 0xC) > 0 {
                return hauteur;
            }
        }
        0.0
    }

    fn suivre_le_son(&mut self) {
        let joue = self.son_en_cours();
        let now = self.m.cpu.cycles;
        let demi = CYCLES_PAR_SECONDE as u64 / 2;
        if joue && (!self.son_jouait || (self.m.voix.is_empty() && now.saturating_sub(self.derniere_recherche) > demi)) {
            self.m.localiser_les_voix();
            self.derniere_recherche = now;
        }
        if joue && !self.son_jouait {
            self.sons = self.sons.wrapping_add(1);
            self.note_perimee = self.note_courante();
            self.perimee_jusqu = now + CYCLES_PAR_SECONDE as u64 / 20;
        }
        self.son_jouait = joue;
        let mut note = self.note_courante();
        if note > 0.0 && now < self.perimee_jusqu {
            if (note - self.note_perimee).abs() < 0.5 {
                note = 0.0;
            } else {
                self.perimee_jusqu = 0;
            }
        }
        self.note = note;
        if note > 0.0 {
            self.note_vue = note;
        }
    }
}

/// Sounds the console started so far (a counter: the app sees a call for attention with it).
#[no_mangle]
pub unsafe extern "C" fn tama_sounds(t: *const Tama) -> u32 {
    (*t).sons
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
    let t = &mut *t;
    if t.reveiller() {
        return; // the press wakes the console, as on the toy
    }
    t.m.appuyer(pin);
}

#[no_mangle]
pub unsafe extern "C" fn tama_release(t: *mut Tama, pin: u32) {
    (*t).m.relacher(pin);
}

/// The note the console plays now in Hz, 0 when silent.
#[no_mangle]
pub unsafe extern "C" fn tama_note(t: *mut Tama) -> f32 {
    let t = &*t;
    if t.note > 0.0 { t.note } else { t.note_vue }
}

#[no_mangle]
pub unsafe extern "C" fn tama_sleeping(t: *const Tama) -> i32 {
    (*t).en_veille() as i32
}

/// Snapshot of the whole machine (CPU, memories, peripherals) to a file. 0 ok, -1 error.
/// Writes the whole 16 MB flash as the toy holds it now: the original dump with the game's save
/// in it (0x1000.. and 0xEFE000..). Flashed to the real toy, it carries on with this save.
#[no_mangle]
pub unsafe extern "C" fn tama_export_flash(t: *const Tama, path: *const c_char) -> i32 {
    let Some(p) = path_of(path) else { return -1 };
    match std::fs::write(p, &(*t).m.bus.flash.data) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

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

// ---- clock: the game's time is the settings' clock origin (days and seconds since 2025-01-01,
// at +12 / +16 of a settings page with a CRC-16/ARC over bytes 4.. at +0 and its inverse at +2)
// plus the console's seconds counter. Setting the origin makes the game show the phone's time. ----

const SETTINGS_PAGES: [usize; 7] = [0xEFE000, 0xEFF000, 0xD86000, 0xD87000, 0xD88000, 0xD89000, 0xD8A000];

fn crc16_arc(d: &[u8]) -> u16 {
    let mut c: u16 = 0;
    for &b in d {
        c ^= b as u16;
        for _ in 0..8 {
            c = if c & 1 != 0 { (c >> 1) ^ 0xA001 } else { c >> 1 };
        }
    }
    c
}

/// Sets the game's clock to `local_secs_since_2025` (the phone's local time, seconds since
/// 2025-01-01 00:00). Call it after loading the dump and its save, before the console runs on.
/// Returns how many settings pages were set (0: no valid settings page).
#[no_mangle]
pub unsafe extern "C" fn tama_sync_clock(t: *mut Tama, local_secs_since_2025: u64) -> i32 {
    let t = &mut *t;
    let counter = t.m.periph.snsys.secondes as i64;
    let origin = local_secs_since_2025 as i64 - counter;
    if origin < 0 {
        return 0;
    }
    let (days, sec) = ((origin / 86400) as u32, (origin % 86400) as u32);
    let mut n = 0;
    for &a in SETTINGS_PAGES.iter() {
        let flash = &mut t.m.bus.flash;
        if a + 0x1000 > flash.data.len() {
            continue;
        }
        let p = &mut flash.data[a..a + 0x1000];
        let c = crc16_arc(&p[4..]);
        let stored = u16::from_le_bytes([p[0], p[1]]);
        let inv = u16::from_le_bytes([p[2], p[3]]);
        let d0 = u32::from_le_bytes([p[12], p[13], p[14], p[15]]);
        let s0 = u32::from_le_bytes([p[16], p[17], p[18], p[19]]);
        if stored != c || inv != !c || d0 > 40000 || s0 >= 86400 {
            continue;
        }
        p[12..16].copy_from_slice(&days.to_le_bytes());
        p[16..20].copy_from_slice(&sec.to_le_bytes());
        let c2 = crc16_arc(&p[4..]);
        p[0..2].copy_from_slice(&c2.to_le_bytes());
        p[2..4].copy_from_slice(&(!c2).to_le_bytes());
        flash.pages_salies.insert(a / 0x1000);
        flash.revision = flash.revision.wrapping_add(1);
        n += 1;
    }
    n
}

/// Time the app was not running the console (suspended by the phone): the console's seconds
/// counter jumps ahead by it, as the real clock chip keeps counting while the toy sleeps, and a
/// wake-up alarm that fell due in that time rings. The firmware works out the date (and how hungry
/// the pet got) from that counter.
#[no_mangle]
pub unsafe extern "C" fn tama_advance(t: *mut Tama, seconds: u32) {
    use emulator::peripherals::SnSysRegisters as Sys;
    let t = &mut *t;
    let s = &mut t.m.periph.snsys;
    let avant = s.secondes;
    s.secondes = s.secondes.saturating_add(seconds);
    let echeance = s.read_reg(Sys::ALARME);
    if echeance != 0 && avant <= echeance && s.secondes > echeance {
        s.declencher_reveil();
    }
}

/// Console cycles skipped while the firmware waited for the screen (TE pin), since the start.
#[no_mangle]
pub unsafe extern "C" fn tama_waits_skipped(t: *const Tama) -> u64 {
    (*t).attentes_sautees
}

/// Seconds the console will stay parked in deep sleep by itself (until its alarm; 3600 when no
/// alarm is set), 0 while it is awake. In the background nothing needs to run before then.
#[no_mangle]
pub unsafe extern "C" fn tama_idle_seconds(t: *mut Tama) -> u32 {
    let t = &*t;
    if !t.m.is_running || !t.saut_de_veille() {
        return 0;
    }
    (t.cycles_avant_alarme() / CYCLES_PAR_SECONDE as u64).min(3600) as u32
}

/// For the next `seconds` of console time, the date screens are confirmed by themselves (a new
/// start asks for the date; the form is already filled in from the clock, set from the phone).
#[no_mangle]
pub unsafe extern "C" fn tama_auto_date(t: *mut Tama, seconds: u32) {
    let t = &mut *t;
    t.auto_jusqu = t.m.cpu.cycles + seconds as u64 * CYCLES_PAR_SECONDE as u64;
    t.auto_prochain = 0;
    t.auto_n = 0;
}

/// (kept for experiments) A save-less start made to look like a wake from deep sleep.
#[no_mangle]
pub unsafe extern "C" fn tama_boot_awake(t: *mut Tama) -> i32 {
    use emulator::peripherals::SnSysRegisters as Sys;
    let t = &mut *t;
    let s = &mut t.m.periph.snsys;
    if s.secondes < 2 {
        s.secondes = 3600;
    }
    let c = s.secondes;
    s.write_reg(Sys::ALARME, c - 1);
    let st = s.read_reg(Sys::STATUT_ALARME) | Sys::ALARME_ARMEE;
    s.write_reg(Sys::STATUT_ALARME, st);
    s.declencher_reveil();
    s.reveil_demande = false;
    1
}

/// Wakes the console from its power-save sleep (as a key press does), so its screen stays on.
/// Returns 1 when it was asleep.
#[no_mangle]
pub unsafe extern "C" fn tama_wake(t: *mut Tama) -> i32 {
    (*t).reveiller() as i32
}

/// Debugging: the program counter, and the power-off request of the clock block (0x45000300).
#[no_mangle]
pub unsafe extern "C" fn tama_debug(t: *const Tama, out: *mut u32) {
    let t = &*t;
    *out = t.m.cpu.regs.pc;
    *out.add(1) = t.m.periph.snsys.read_reg(0x300);
    *out.add(2) = t.reveils;
}

/// Restarts the core, as the chip's watchdog does (the firmware waits for it after "reset all").
#[no_mangle]
pub unsafe extern "C" fn tama_reset(t: *mut Tama) {
    let t = &mut *t;
    t.m.reset();
    t.m.is_running = true;
    t.recaler();
}

/// Debugging: writes the work RAM and the flash save region to files.
#[no_mangle]
pub unsafe extern "C" fn tama_debug_dump(t: *const Tama, sram: *const c_char, flash: *const c_char) -> i32 {
    let t = &*t;
    let (Some(a), Some(b)) = (path_of(sram), path_of(flash)) else { return -1 };
    let _ = std::fs::write(a, &t.m.bus.sram.data);
    let _ = std::fs::write(b, &t.m.bus.flash.data);
    0
}

/// One step of the dial (right or left), queued and played in console time.
#[no_mangle]
pub unsafe extern "C" fn tama_turn(t: *mut Tama, right: i32) {
    let t = &mut *t;
    if t.tours.is_empty() && t.reveiller() {
        return; // the first touch wakes the console
    }
    if t.tours.len() < 32 {
        t.tours.push_back(right != 0);
    }
}

/// The pet, read live: out[0] found (1/0), [1] character, [2] stage, [3] hunger 0..6,
/// [4] happiness 0..20, [5] sick, [6] planet level, [7] RAM address of the settings block.
#[no_mangle]
pub unsafe extern "C" fn tama_pet(t: *mut Tama, out: *mut i32) {
    let t = &mut *t;
    let o = std::slice::from_raw_parts_mut(out, 8);
    o.fill(0);
    let Some((b, p)) = t.trouver_bloc() else { return };
    let ram = &t.m.bus.sram.data;
    let r = &ram[b + p..b + p + 0x20];
    let niveau = if p == 0x114 { 0x88 } else { 0x7C };
    o[0] = 1;
    o[1] = u16::from_le_bytes([r[4], r[5]]) as i32;
    o[2] = ((r[0x18] >> 2) & 7) as i32;
    o[3] = r[0x1C] as i32;
    o[4] = r[0x1D] as i32;
    o[5] = r[0x10] as i32;
    o[6] = (ram[b + niveau] & 15) as i32;
    o[7] = (0x1800_0000 + b) as i32;
}

/// Feeds (1), plays (2), cures (4) now. 1 done, 0 no pet found.
#[no_mangle]
pub unsafe extern "C" fn tama_care(t: *mut Tama, what: u32) -> i32 {
    (*t).soins(what) as i32
}

/// Care kept up by itself, every 10 s of console time: the same bits as tama_care (0: off).
#[no_mangle]
pub unsafe extern "C" fn tama_auto_care(t: *mut Tama, what: u32) {
    let t = &mut *t;
    t.soins_auto = what;
    t.soins_a = 0;
}

/// The settings block's working copy (4096 bytes into out), for looking into the game.
/// 1 when found.
#[no_mangle]
pub unsafe extern "C" fn tama_block(t: *mut Tama, out: *mut u8) -> i32 {
    let t = &mut *t;
    let Some((b, _)) = t.trouver_bloc() else { return 0 };
    std::ptr::copy_nonoverlapping(t.m.bus.sram.data[b..].as_ptr(), out, 0x1000);
    1
}

/// Lets go of every key and the dial (nothing stays held when the app looks away).
#[no_mangle]
pub unsafe extern "C" fn tama_release_all(t: *mut Tama) {
    let t = &mut *t;
    for p in [0x08, 0x09, 0x0A, 0x0B, 0x20, 0x21] {
        t.m.relacher(p);
    }
    t.tours.clear();
    t.phase = 0;
    t.auto_relache = 0;
}

/// Console cycles skipped while the console slept (not emulated: only its clock ran).
#[no_mangle]
pub unsafe extern "C" fn tama_skipped(t: *const Tama) -> u64 {
    (*t).veilles_sautees
}

/// Debugging: logs the accesses to one 4 KB page of registers (0 stops), and prints them.
#[no_mangle]
pub unsafe extern "C" fn tama_debug_trace(t: *mut Tama, page: u32, print: i32) {
    let t = &mut *t;
    if print != 0 {
        for e in &t.m.bus.mmio_trace.log {
            println!("pc {:08X} {} {:08X} = {:08X}", e.pc, if e.is_write { "W" } else { "R" }, e.addr, e.value);
        }
        t.m.bus.mmio_trace.log.clear();
    }
    t.m.bus.mmio_trace.log_page = if page != 0 { Some(page) } else { None };
}

/// The link port (the console's UART at 460800 baud, through which a real unit plays with
/// another): bytes the console sent, up to max into out. Returns how many.
#[no_mangle]
pub unsafe extern "C" fn tama_link_take(t: *mut Tama, out: *mut u8, max: u32) -> u32 {
    let t = &mut *t;
    let q = &mut t.m.periph.uart.tx_out;
    let n = q.len().min(max as usize);
    for i in 0..n {
        *out.add(i) = q.pop_front().unwrap_or(0);
    }
    n as u32
}

/// Bytes arriving on the link port (from the other console).
#[no_mangle]
pub unsafe extern "C" fn tama_link_give(t: *mut Tama, data: *const u8, n: u32) {
    let t = &mut *t;
    t.m.periph.uart.inject_rx_bytes(std::slice::from_raw_parts(data, n as usize));
}

/// Empties the link line both ways (when a link starts: the boot log waiting there is not for the
/// other console).
#[no_mangle]
pub unsafe extern "C" fn tama_link_clear(t: *mut Tama) {
    (*t).m.periph.uart.vider_la_ligne();
}

/// Writes n bytes at offset into the game's settings block (RAM and flash, checksum fixed). 1 ok.
#[no_mangle]
pub unsafe extern "C" fn tama_block_write(t: *mut Tama, offset: u32, data: *const u8, n: u32) -> i32 {
    let t = &mut *t;
    let d = std::slice::from_raw_parts(data, n as usize).to_vec();
    t.ecrire_bloc(offset as usize, &d) as i32
}

/// Where the pet's record and the planet level sit in the settings block: out[0] pet, out[1] level.
#[no_mangle]
pub unsafe extern "C" fn tama_pet_places(t: *mut Tama, out: *mut u32) {
    let t = &*t;
    let p = t.place_du_tama();
    *out = p as u32;
    *out.add(1) = if p == 0x114 { 0x88 } else { 0x7C };
}

/// The console's seconds counter (its clock is the settings' origin plus this).
#[no_mangle]
pub unsafe extern "C" fn tama_seconds(t: *const Tama) -> u32 {
    (*t).m.periph.snsys.secondes
}

/// Debugging (examples only): the machine inside.
#[doc(hidden)]
pub unsafe fn machine<'a>(t: *mut Tama) -> &'a mut Machine {
    &mut (*t).m
}

/// Debugging (examples only): one instruction as the run does it (TE waits skipped).
#[doc(hidden)]
pub unsafe fn step_one(t: *mut Tama) {
    let t = &mut *t;
    t.chercher_lecture();
    if Some(t.m.cpu.regs.pc) == t.lecture_broche && t.m.cpu.regs.get_reg(0) == Tama::BROCHE_TE {
        t.attendre_te();
    }
    t.m.step();
}
