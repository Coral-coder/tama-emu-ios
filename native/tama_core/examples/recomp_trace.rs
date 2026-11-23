// Recompiler groundwork: runs the firmware (awake, with key presses so menus and animations run)
// and maps the code it executes: distinct instructions, basic blocks, where they live (PRAM or
// XIP flash), and how much of the run the hottest blocks cover.
use std::collections::HashMap;
use std::ffi::CString;
use tama_core::emulator::cpu::disasm::Disassembler;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let secs: u64 = a.get(2).map(|s| s.parse().unwrap()).unwrap_or(20);
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        let now = (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() - 1_735_689_600) as u64;
        tama_core::tama_sync_clock(t, now);
        tama_core::tama_auto_date(t, 120);
        let cps = tama_core::tama_cycles_per_second();
        let mut ins: HashMap<u32, u64> = HashMap::new();
        let mut blocks: HashMap<u32, u64> = HashMap::new();
        let m = tama_core::machine(t);
        let end = m.cpu.cycles + cps * secs;
        let mut last = 0u32;
        let mut step = 0u64;
        while m.cpu.cycles < end && m.is_running {
            let pc = m.cpu.regs.pc;
            // a new block starts wherever the previous instruction did not fall through
            if pc != last.wrapping_add(2) && pc != last.wrapping_add(4) { *blocks.entry(pc).or_default() += 1; }
            *ins.entry(pc).or_default() += 1;
            last = pc;
            tama_core::step_one(t);
            step += 1;
            // press A, B, C and turn the wheel now and then: menus, games, animations
            if step % 40_000_000 == 0 { let pin = [0x09u32, 0x0B, 0x0A][(step / 40_000_000 % 3) as usize]; tama_core::tama_press(t, pin); }
            if step % 40_000_000 == 4_000_000 { tama_core::tama_release_all(t); }
            if tama_core::tama_sleeping(t) == 1 { tama_core::tama_wake(t); }
        }
        let tot: u64 = ins.values().sum();
        let pram = ins.keys().filter(|&&p| p < 0x10000).count();
        println!("{} instructions executed, {} distinct ({} in PRAM, {} in XIP flash), {} block entries",
            tot, ins.len(), pram, ins.len() - pram, blocks.len());
        let mut v: Vec<u64> = ins.values().cloned().collect(); v.sort_unstable_by(|a, b| b.cmp(a));
        for share in [0.5, 0.9, 0.99, 0.999] {
            let mut acc = 0u64; let mut n = 0;
            for c in &v { acc += c; n += 1; if acc as f64 >= tot as f64 * share { break; } }
            println!("{:5.1}% of the run is in the hottest {} instructions", share * 100.0, n);
        }
        // which kinds of instruction the hot code uses (what the translator must handle)
        let mut hot: Vec<(u32, u64)> = ins.iter().map(|(a, b)| (*a, *b)).collect();
        hot.sort_unstable_by(|a, b| b.1.cmp(&a.1));
        let mut kinds: HashMap<String, (u64, u32)> = HashMap::new();
        for (pc, n) in hot.iter().take(6415) {
            let w = [m.bus.read_u16(*pc, &mut m.periph, &m.cpu.nvic), m.bus.read_u16(pc.wrapping_add(2), &mut m.periph, &m.cpu.nvic)];
            let d = Disassembler::disassemble(*pc, &w);
            let k = if d.mnemonic.starts_with("THUMB") { format!("{} {:04X}", d.mnemonic, w[0] & 0xFFF0) } else { d.mnemonic.split('.').next().unwrap().to_string() };
            let e = kinds.entry(k).or_default(); e.0 += n; e.1 += 1;
        }
        let mut kv: Vec<_> = kinds.into_iter().collect(); kv.sort_by(|a, b| b.1 .0.cmp(&a.1 .0));
        println!("{} kinds in the hottest 6415:", kv.len());
        for (k, (n, c)) in kv.iter().take(70) { println!("  {:24} {:5.2}%  ({} sites)", k, *n as f64 * 100.0 / tot as f64, c); }
        let lo = ins.keys().filter(|&&p| p >= 0x1000_0000).min().unwrap_or(&0);
        let hi = ins.keys().filter(|&&p| p >= 0x1000_0000).max().unwrap_or(&0);
        println!("XIP code seen from {:#X} to {:#X}", lo, hi);
    }
}
