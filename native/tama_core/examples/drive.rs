// Drives a dump with a script and saves screens:  drive <dump> <outdir> <state-in|-> <state-out|-> <script>
// script words: wN run N seconds (decimals ok), A B C P press a key, r l turn the wheel, s save a screen.
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
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        let cps = tama_core::tama_cycles_per_second();
        if a[3] != "-" {
            let s = CString::new(a[3].clone()).unwrap();
            println!("restore {}", tama_core::tama_restore(t, s.as_ptr()));
        } else {
            let now = (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() - 1_735_689_600) as u64;
            tama_core::tama_sync_clock(t, now);
            tama_core::tama_auto_date(t, 120);
        }
        let run = |secs: f64| { tama_core::tama_run(t, (cps as f64 * secs) as u64, 600000); };
        let mut n = 0;
        for w in a[5].split_whitespace() {
            match w {
                "A" | "B" | "C" | "P" => {
                    let pin = match w { "A" => 0x09, "B" => 0x0B, "C" => 0x0A, _ => 0x08 };
                    tama_core::tama_press(t, pin); run(0.15); tama_core::tama_release(t, pin); run(0.6);
                }
                "r" | "l" => {
                    let (x, y) = if w == "r" { (0x20, 0x21) } else { (0x21, 0x20) };
                    tama_core::tama_press(t, x); run(0.02); tama_core::tama_press(t, y); run(0.02);
                    tama_core::tama_release(t, x); run(0.02); tama_core::tama_release(t, y); run(0.3);
                }
                "d" => { let mut d=[0u32;3]; tama_core::tama_debug(t, d.as_mut_ptr()); println!("pc {:08X} sys300 {:X} watchdog {} running {} sleeping {}", d[0], d[1], d[2], tama_core::tama_running(t), tama_core::tama_sleeping(t)); }
                "R" => tama_core::tama_reset(t),
                "s" => { shot(t, &format!("{}/{:03}.ppm", a[2], n)); n += 1; }
                _ if w.starts_with('w') => run(w[1..].parse().unwrap()),
                _ => panic!("bad word {w}"),
            }
        }
        if a[4] != "-" {
            let s = CString::new(a[4].clone()).unwrap();
            println!("snapshot {}", tama_core::tama_snapshot(t, s.as_ptr()));
        }
    }
}
