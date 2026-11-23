// Is the emulator's flash the raw device image? Compares it with the dump after a run.
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        let cps = tama_core::tama_cycles_per_second();
        tama_core::tama_auto_date(t, 120);
        tama_core::tama_run(t, cps * 20, 600000);
        let m = tama_core::machine(t);
        let dump = std::fs::read(&a[1]).unwrap();
        let f = &m.bus.flash.data;
        println!("sizes {} {}", f.len(), dump.len());
        let mut regions: Vec<(usize, usize)> = vec![];
        for i in (0..dump.len().min(f.len())).step_by(4096) {
            if f[i..i + 4096] != dump[i..i + 4096] {
                if let Some(l) = regions.last_mut() { if l.1 == i { l.1 = i + 4096; continue; } }
                regions.push((i, i + 4096));
            }
        }
        for (s, e) in regions { println!("differs {:#X}..{:#X}", s, e); }
    }
}
