// Finds the "sound playing" flag of an edition: watches the voice table and the RAM bytes that
// change with it.
use tama_core::emulator::{Machine, StepResult};
fn u8a(m: &Machine, a: u32) -> u8 { m.bus.sram.data[(a - 0x1800_0000) as usize] }
fn u32a(m: &Machine, a: u32) -> u32 { let i = (a - 0x1800_0000) as usize; let d = &m.bus.sram.data; u32::from_le_bytes([d[i], d[i+1], d[i+2], d[i+3]]) }
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let mut m = Machine::new();
    m.device_key = Some(0x5AAF34FB);
    m.load_firmware_file(&a[1]).unwrap();
    m.remplacer_la_pile();
    let cps = tama_core::tama_cycles_per_second();
    let mut frames = 0u64;
    let mut hist: Vec<(bool, Vec<u8>)> = Vec::new();
    let lo = 0x1801_4000u32;
    let n = 0x1000u32;
    let mut last_loc = 0u64;
    while m.cpu.cycles < cps * 40 {
        let t = m.cpu.cycles / (cps / 10);
        // press B every 3 s
        if t % 30 == 10 { m.appuyer(0x0B) } else if t % 30 == 12 { m.relacher(0x0B) }
        if !matches!(m.run_frame(), StepResult::Ok(_)) { break }
        frames += 1;
        if m.cpu.cycles - last_loc > cps / 4 { m.localiser_les_voix(); last_loc = m.cpu.cycles; }
        let active = m.voix.iter().any(|&b| u32a(&m, b) == 0x05B8_D800 && u8a(&m, b + 8) != 0 && u32a(&m, b + 0xC) > 0);
        if frames % 4 == 0 {
            hist.push((active, (0..n).map(|i| u8a(&m, lo + i)).collect()));
        }
    }
    let on = hist.iter().filter(|h| h.0).count();
    println!("voices {:x?} samples {} active {}", m.voix, hist.len(), on);
    // bytes that are non-zero exactly when a voice is active
    let mut best: Vec<(usize, u32)> = Vec::new();
    for i in 0..n as usize {
        let tp = hist.iter().filter(|h| h.0 && h.1[i] != 0).count() * 1000 / on.max(1);
        let tn = hist.iter().filter(|h| !h.0 && h.1[i] == 0).count() * 1000 / (hist.len() - on).max(1);
        best.push((tp.min(tn), lo + i as u32));
    }
    best.sort();
    for b in &best { if b.1 == 0x1801_4284 || b.1 == 0x1801_428C { println!("known {:08X} score {}", b.1, b.0); } }
    for b in best.iter().rev().take(5) { println!("{:08X} score {}", b.1, b.0); }
}
