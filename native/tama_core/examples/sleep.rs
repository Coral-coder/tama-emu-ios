// Lets the console fall asleep, presses a key, checks it wakes and keeps running.
use std::ffi::CString;
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
        tama_core::tama_auto_date(t, 90);
        let cps = tama_core::tama_cycles_per_second();
        tama_core::tama_run(t, cps * 13, 600000);
        tama_core::tama_press(t, 0x0B);
        tama_core::tama_run(t, cps / 8, 600000);
        tama_core::tama_release(t, 0x0B);
        let mut dark = 0;
        for s in 0..400 {
            let d = tama_core::tama_run(t, cps, 600000);
            if s % 20 == 0 {
                println!("{s:4}s ran {d} sleeping {} lit {}", tama_core::tama_sleeping(t), lit(t));
            }
            dark = if lit(t) == 0 { dark + 1 } else { 0 };
            if dark >= 3 {
                println!("dark at {s}s");
                for _ in 0..6 { tama_core::tama_run(t, cps / 7, 600000); let mut d=[0u32;3]; tama_core::tama_debug(t, d.as_mut_ptr()); println!("  pc {:08X} sys300 {:X} pmu {:X}", d[0], d[1], d[2]); }
                for _ in 0..3 { let d = tama_core::tama_run(t, cps, 600000); println!("  asleep ran {d} lit {}", lit(t)); }
                println!("press -> wake");
                tama_core::tama_press(t, 0x0B);
                tama_core::tama_run(t, cps / 8, 600000);
                tama_core::tama_release(t, 0x0B);
                for _ in 0..3 { let d = tama_core::tama_run(t, cps, 600000); println!("  after 1st press ran {d} sleeping {} lit {}", tama_core::tama_sleeping(t), lit(t)); }
                let mut fb = vec![0u16; 128 * 128]; tama_core::tama_screen(t, fb.as_mut_ptr());
                std::fs::write(&a[2], fb.iter().flat_map(|p| p.to_le_bytes()).collect::<Vec<u8>>()).unwrap();
                println!("press again");
                tama_core::tama_press(t, 0x0B);
                tama_core::tama_run(t, cps / 8, 600000);
                tama_core::tama_release(t, 0x0B);
                for _ in 0..60 { let d = tama_core::tama_run(t, cps / 4, 600000); if tama_core::tama_sleeping(t) == 1 { println!("FALSE SLEEP"); } let _ = d; } for _ in 0..3 { let d = tama_core::tama_run(t, cps, 600000); println!("  awake ran {d} sleeping {} lit {}", tama_core::tama_sleeping(t), lit(t)); }
                break;
            }
        }
    }
}
