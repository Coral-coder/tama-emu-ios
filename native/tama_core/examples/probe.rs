// Where does a dump's firmware go wrong? Steps it until the program counter leaves the memory
// that holds code, and prints the last places it was (addresses and registers only).
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        let r = tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        println!("load {r}");
        let mut last = std::collections::VecDeque::new();
        let mut n: u64 = 0;
        loop {
            let m = tama_core::machine(t);
            let pc = m.cpu.regs.pc;
            let ok = pc >= 0xFFFF_FFF0 || pc < 0x0100_0000 || (0x1000_0000..0x1100_0000).contains(&pc) || (0x1800_0000..0x1802_0000).contains(&pc) || (0x6000_0000..0x6100_0000).contains(&pc) || (0x2000_0000..0x2002_0000).contains(&pc);
            if !ok || n > 400_000_000 {
                println!("after {n} steps pc {pc:08X} lr {:08X} sp {:08X}", m.cpu.regs.get_reg(14), m.cpu.regs.get_reg(13));
                break;
            }
            if last.back() != Some(&pc) {
                last.push_back(pc);
                if last.len() > 24 {
                    last.pop_front();
                }
            }
            tama_core::step_one(t);
            n += 1;
        }
        for pc in last {
            print!("{pc:08X} ");
        }
        println!();
        let m = tama_core::machine(t);
        for i in 0..13 {
            print!("r{i}={:08X} ", m.cpu.regs.get_reg(i));
        }
        println!();
    }
}
