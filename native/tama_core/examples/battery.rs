// How the console spends a long stretch alone (the app in the background): wall time to emulate
// it, how much was skipped asleep, and the wake-ups and sounds on the way.
use std::ffi::CString;
use std::time::Instant;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let minutes: u64 = a.get(2).map(|s| s.parse().unwrap()).unwrap_or(30);
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        let now = (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() - 1_735_689_600) as u64;
        tama_core::tama_sync_clock(t, now);
        tama_core::tama_auto_date(t, 120);
        let cps = tama_core::tama_cycles_per_second();
        tama_core::tama_run(t, cps * 13, 600000);
        tama_core::tama_press(t, 0x0B);
        tama_core::tama_run(t, cps / 8, 600000);
        tama_core::tama_release(t, 0x0B);
        let t0 = Instant::now();
        let mut was_up = true; let mut sounds = 0; let mut quiet = 0u64; let mut awake_s = 0;
        for s in 0..minutes * 60 {
            tama_core::tama_run(t, cps, 600000);
            let up = tama_core::tama_sleeping(t) == 0;
            if up { awake_s += 1; }
            was_up = up;
            let n = tama_core::tama_note(t);
            if n > 0.0 { if quiet >= 3 { sounds += 1; println!("{:5} s: sound {:.0} Hz", s, n); } quiet = 0; } else { quiet += 1; }
        }
        let el = t0.elapsed().as_secs_f64();
        let mut d = [0u32; 3]; tama_core::tama_debug(t, d.as_mut_ptr());
        println!("wakes from deep sleep: {}", d[2]);
        println!("{} console minutes in {:.1} s ({:.0}x real time); awake {} s; skipped asleep {:.0} s; {} sounds",
            minutes, el, (minutes * 60) as f64 / el, awake_s, tama_core::tama_skipped(t) as f64 / cps as f64, sounds);
    }
}
