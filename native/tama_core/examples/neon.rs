// Follows a console left alone second by second: asleep or not, where its core is, the alarm,
// sounds. Prints every change.
use std::ffi::CString;
use std::time::Instant;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let secs: u64 = a.get(2).map(|s| s.parse().unwrap()).unwrap_or(1200);
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        let now = (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() - 1_735_689_600) as u64;
        tama_core::tama_sync_clock(t, now);
        tama_core::tama_auto_date(t, 120);
        let cps = tama_core::tama_cycles_per_second();
        let mut last = String::new();
        let t0 = Instant::now();
        for s in 0..secs {
            let a = Instant::now();
            tama_core::tama_run(t, cps, 600000);
            let ms = a.elapsed().as_millis();
            let mut d = [0u32; 3];
            tama_core::tama_debug(t, d.as_mut_ptr());
            let st = format!("sleeping={} idle={} note={:.0} dbg={:?}", tama_core::tama_sleeping(t), tama_core::tama_idle_seconds(t), tama_core::tama_note(t), &d[..3]);
            let key = format!("{} {}", tama_core::tama_sleeping(t), tama_core::tama_idle_seconds(t) > 0);
            if key != last || s % 60 == 0 || tama_core::tama_note(t) > 0.0 { println!("{s:5} s ({ms} ms): {st}"); last = key; }
        }
        println!("total {:.1} s", t0.elapsed().as_secs_f64());
    }
}
