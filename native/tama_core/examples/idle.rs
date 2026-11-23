// What the console does while awake with the screen off: where its program counter sits.
use std::ffi::CString;
use std::collections::HashMap;
fn lit(t: *mut tama_core::Tama) -> usize {
    let mut fb = vec![0u16; 128 * 128];
    unsafe { tama_core::tama_screen(t, fb.as_mut_ptr()) };
    fb.iter().filter(|&&p| p != 0).count()
}
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
        tama_core::tama_run(t, cps * 13, 600000);
        tama_core::tama_press(t, 0x0B);
        tama_core::tama_run(t, cps / 8, 600000);
        tama_core::tama_release(t, 0x0B);
        // to the first sleep, then to the next wake
        let mut s = 0;
        while tama_core::tama_sleeping(t) == 0 && s < 300 { tama_core::tama_run(t, cps, 600000); s += 1; }
        while tama_core::tama_sleeping(t) == 1 && s < 900 { tama_core::tama_run(t, cps, 600000); s += 1; }
        println!("woke at {s} s, lit {}", lit(t));
        let mut h: HashMap<u32, u32> = HashMap::new();
        let mut d = [0u32; 3];
        for i in 0..3000 {
            tama_core::tama_run(t, cps / 100, 600000);
            tama_core::tama_debug(t, d.as_mut_ptr());
            *h.entry(d[0] & !0xF).or_default() += 1;
            if i % 500 == 0 { println!("  t+{}s pc {:08X} sys300 {:X} sleeping {} lit {}", i / 100, d[0], d[1], tama_core::tama_sleeping(t), lit(t)); }
        }
        let mut v: Vec<_> = h.into_iter().collect();
        v.sort_by_key(|x| std::cmp::Reverse(x.1));
        for (pc, n) in v.iter().take(10) { println!("{:08X}: {}", pc, n); }
    }
}
