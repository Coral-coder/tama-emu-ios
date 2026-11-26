// Runs a dump for a while and writes the save file as the app does (for checks of the save tools).
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        let s = CString::new(a[2].clone()).unwrap();
        tama_core::tama_open_save(t, s.as_ptr());
        tama_core::tama_sync_clock(t, 30_000_000);
        tama_core::tama_auto_date(t, 120);
        let cps = tama_core::tama_cycles_per_second();
        for i in 0..40 { if i % 5 == 2 { tama_core::tama_press(t, 0x0B); } if i % 5 == 3 { tama_core::tama_release_all(t); } tama_core::tama_run(t, cps, 600000); }
        println!("write {}", tama_core::tama_write_save(t));
    }
}
