// Every native operation of the recompiler against Capybara, instruction by instruction.
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let n: u64 = a.get(2).map(|s| s.parse().unwrap()).unwrap_or(50_000_000);
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        tama_core::tama_sync_clock(t, 30_000_000);
        tama_core::tama_auto_date(t, 120);
        let m = tama_core::machine(t);
        let mut bad = 0;
        for i in 0..n {
            if i % 20_000_000 == 5_000_000 { tama_core::tama_press(t, 0x0B); }
            if i % 20_000_000 == 6_000_000 { tama_core::tama_release_all(t); }
            if let Some(e) = tama_core::recomp::verify_step(m) {
                println!("{}", e);
                bad += 1;
                if bad > 12 { break; }
            }
        }
        println!("done, {} differences", bad);
    }
}
