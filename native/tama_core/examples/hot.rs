// Where an awake console spends its instructions (hottest PCs, disassembled), and which
// peripheral registers the hottest code reads.
use std::collections::HashMap;
use std::ffi::CString;
use tama_core::emulator::cpu::disasm::Disassembler;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        let now = (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() - 1_735_689_600) as u64;
        tama_core::tama_sync_clock(t, now);
        tama_core::tama_auto_date(t, 120);
        let cps = tama_core::tama_cycles_per_second();
        tama_core::tama_run(t, cps * 15, 600000);
        let m = tama_core::machine(t);
        let mut h: HashMap<u32, u64> = HashMap::new();
        let mut callers: HashMap<(u32, u32), u64> = HashMap::new();
        for _ in 0..20_000_000u64 {
            let pc = m.cpu.regs.pc;
            if pc == 0x2714 { *callers.entry((m.cpu.regs.lr, m.cpu.regs.get_reg(0))).or_default() += 1; }
            *h.entry(pc).or_default() += 1; tama_core::step_one(t);
        }
        let mut c: Vec<_> = callers.into_iter().collect(); c.sort_by(|a, b| b.1.cmp(&a.1));
        for ((lr, r0), n) in c.iter().take(8) { println!("0x2714 called from {:08X} with r0={:#X}: {} times", lr, r0, n); }
        if a.get(2).is_some() { return; }
        let mut v: Vec<_> = h.into_iter().collect(); v.sort_by(|a, b| b.1.cmp(&a.1));
        let tot: u64 = v.iter().map(|x| x.1).sum();
        let mut top: Vec<_> = v.iter().take(60).cloned().collect();
        top.sort();
        for (pc, n) in &top {
            let w = [m.bus.read_u16(*pc, &mut m.periph, &m.cpu.nvic), m.bus.read_u16(*pc + 2, &mut m.periph, &m.cpu.nvic)];
            let d = Disassembler::disassemble(*pc, &w);
            println!("{:08X} {:5.2}%  {} {}", pc, *n as f64 * 100.0 / tot as f64, d.mnemonic, d.operands);
        }
    }
}
