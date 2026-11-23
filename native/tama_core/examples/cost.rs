// Wall time per console second, awake and asleep: what the battery pays.
use std::ffi::CString;
use std::time::Instant;
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
        let (mut aw, mut asl, mut na, mut ns) = (0f64, 0f64, 0, 0);
        for s in 0..300 {
            let t0 = Instant::now();
            tama_core::tama_run(t, cps, 600000);
            let e = t0.elapsed().as_secs_f64() * 1000.0;
            if tama_core::tama_sleeping(t) == 0 { aw += e; na += 1 } else { asl += e; ns += 1 }
            if s < 40 || s % 30 == 0 { println!("{s}: {:.1} ms sleeping={}", e, tama_core::tama_sleeping(t)); }
        }
        println!("awake {na} s at {:.1} ms each; asleep {ns} s at {:.2} ms each", aw / na.max(1) as f64, asl / ns.max(1) as f64);
    }
}
