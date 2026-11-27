// Does the console's seconds counter keep real time? Runs N console seconds (awake with keys, then
// left alone) and prints how far the counter moved.
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
        let s0 = tama_core::tama_seconds(t);
        let mut ran = 0u64;
        for i in 0..60u64 { if i % 4 == 1 { tama_core::tama_press(t, 0x0B); } if i % 4 == 2 { tama_core::tama_release_all(t); } ran += tama_core::tama_run(t, cps, 600000); }
        // as the app does on screen: 16 ms slices, 12 ms budget; what the core ran against what was asked
        let (mut asked, mut got) = (0u64, 0u64);
        for i in 0..1500u64 { if i % 200 == 20 { tama_core::tama_press(t, 0x0B); } if i % 200 == 40 { tama_core::tama_release_all(t); } let w = cps * 16 / 1000; asked += w; got += tama_core::tama_run(t, w, 12); }
        println!("16 ms slices awake: asked {:.2} s, the core ran {:.2} s ({:.2}x)", asked as f64 / cps as f64, got as f64 / cps as f64, got as f64 / asked as f64);
        let s1 = tama_core::tama_seconds(t);
        println!("awake with keys: asked 60 s, ran {:.1} s of cycles, counter moved {} s", ran as f64 / cps as f64, s1 - s0);
        let mut ran = 0u64;
        for _ in 0..1800u64 { ran += tama_core::tama_run(t, cps, 600000); }
        let s2 = tama_core::tama_seconds(t);
        println!("left alone: asked 1800 s, ran {:.1} s of cycles, counter moved {} s", ran as f64 / cps as f64, s2 - s1);
        // as the app does in the background: one call for a whole minute
        let mut ran = 0u64;
        for _ in 0..30u64 { ran += tama_core::tama_run(t, cps * 60, 30); }
        let s3 = tama_core::tama_seconds(t);
        println!("minute slices, 30 ms budget: asked 1800 s, ran {:.1} s, counter moved {} s", ran as f64 / cps as f64, s3 - s2);
    }
}
