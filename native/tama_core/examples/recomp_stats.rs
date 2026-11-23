// Which instructions still go to Capybara's executor in the recompiler (build with --features stats).
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        tama_core::tama_sync_clock(t, 30_000_000);
        tama_core::tama_auto_date(t, 120);
        let cps = tama_core::tama_cycles_per_second();
        for i in 0..100 {
            if i % 30 == 5 { tama_core::tama_press(t, 0x0B); }
            if i % 30 == 6 { tama_core::tama_release_all(t); }
            tama_core::tama_run(t, cps / 10, 600000);
        }
        tama_core::print_recomp_stats(t);
    }
}
