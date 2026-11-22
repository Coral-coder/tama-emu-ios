// Boots a dump fresh, optionally as a wake from deep sleep (alarm rang), runs it, saves screens.
use std::ffi::CString;
fn shot(t: *mut tama_core::Tama, path: &str) {
    let mut fb = vec![0u16; 128 * 128];
    unsafe { tama_core::tama_screen(t, fb.as_mut_ptr()) };
    let mut ppm = b"P6 128 128 255\n".to_vec();
    for p in fb {
        let p = p as u32;
        ppm.push((((p >> 11) & 31) * 255 / 31) as u8);
        ppm.push((((p >> 5) & 63) * 255 / 63) as u8);
        ppm.push(((p & 31) * 255 / 31) as u8);
    }
    std::fs::write(path, ppm).unwrap();
}
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let wake = a[3] == "wake";
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        println!("load {}", tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1));
        if wake { println!("wake {}", tama_core::tama_boot_awake(t)); }
        let now = (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() - 1_735_689_600) as u64;
        println!("clock {}", tama_core::tama_sync_clock(t, now));
        let cps = tama_core::tama_cycles_per_second();
        tama_core::tama_auto_date(t, 90);
        tama_core::tama_run(t, cps * 13, 600000);
        tama_core::tama_press(t, 0x0B);
        tama_core::tama_run(t, cps / 8, 600000);
        tama_core::tama_release(t, 0x0B);
        for k in 0..8 {
            tama_core::tama_run(t, cps * 4, 600000);
            shot(t, &format!("{}/{}-{}.ppm", a[2], a[3], k));
        }
    }
}
