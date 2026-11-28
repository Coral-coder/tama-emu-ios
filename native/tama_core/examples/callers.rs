// Who calls a function, and with what? Runs a dump for `cycles`, then steps `steps` instructions
// and counts (lr, r0, r1) each time the program counter is at `at`.
//   callers <dump> <cycles> <steps> <at hex>
use std::collections::HashMap;
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let cycles: u64 = a[2].parse().unwrap();
    let steps: u64 = a[3].parse().unwrap();
    let at = u32::from_str_radix(&a[4], 16).unwrap();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        tama_core::tama_run(t, cycles, 600_000);
        let mut seen: HashMap<(u32, u32, u32), u64> = HashMap::new();
        let mut pcs: HashMap<u32, u64> = HashMap::new();
        for _ in 0..steps {
            let m = tama_core::machine(t);
            let pc = m.cpu.regs.pc;
            *pcs.entry(pc & !0xFF).or_default() += 1;
            if pc == at {
                *seen.entry((m.cpu.regs.get_reg(14), m.cpu.regs.get_reg(0), m.cpu.regs.get_reg(1))).or_default() += 1;
            }
            tama_core::step_one(t);
        }
        let mut v: Vec<_> = seen.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1));
        for ((lr, r0, r1), n) in v.iter().take(20) {
            println!("{n:8}  lr {lr:08X}  r0 {r0:08X}  r1 {r1:08X}");
        }
        let mut v: Vec<_> = pcs.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1));
        for (pc, n) in v.iter().take(14) {
            println!("page {pc:08X}: {n}");
        }
    }
}
