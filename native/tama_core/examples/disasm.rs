// Writes a range of memory as the console sees it after `steps` console cycles (the windows and
// the program RAM are set up by then), to look at it with a disassembler.
//   disasm <dump> <steps> <from hex> <length hex> <out file>
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let steps: u64 = a[2].parse().unwrap();
    let from = u32::from_str_radix(&a[3], 16).unwrap();
    let len = u32::from_str_radix(&a[4], 16).unwrap();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        // `steps` counts console cycles here: the run, as the app does it
        tama_core::tama_run(t, steps, 600_000);
        let m = tama_core::machine(t);
        let out: Vec<u8> = (0..len).map(|i| m.bus.read_u8(from + i, &mut m.periph, &m.cpu.nvic)).collect();
        std::fs::write(&a[5], out).unwrap();
    }
}
