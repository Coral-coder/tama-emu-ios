// A few awake console seconds, for a profiler.
use std::ffi::CString;
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
        tama_core::set_recomp(t, a.get(3).is_some());
        let secs: u64 = a.get(2).map(|s| s.parse().unwrap()).unwrap_or(3);
        tama_core::tama_run(t, cps * secs, 6000000);
    }
}
