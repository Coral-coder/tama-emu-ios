// LAB (temporary). Drives a dump with a script and saves screens:  drive <dump> <outdir> <state-in|-> <state-out|-> <script>
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
            let now: u64 = std::env::var("LAB_NOW").ok().and_then(|v| v.parse().ok()).unwrap_or(60_000_000);
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
                "q" => { let mut o=[0i32;8]; tama_core::tama_pet(t, o.as_mut_ptr()); println!("pet found {} id {:04X} stage {} hunger {} happy {} sick {} level {} block {:08X}", o[0],o[1],o[2],o[3],o[4],o[5],o[6],o[7]); }
                "R1" | "L1" => { tama_core::tama_turn(t, (w == "R1") as i32); run(0.1); }
                "rs" | "ls" => {
                    let (x, y) = if w == "rs" { (0x20, 0x21) } else { (0x21, 0x20) };
                    tama_core::tama_press(t, x); run(0.05); tama_core::tama_press(t, y); run(0.05);
                    tama_core::tama_release(t, x); run(0.05); tama_core::tama_release(t, y); run(0.3);
                }
                "r" | "l" => {
                    let (x, y) = if w == "r" { (0x20, 0x21) } else { (0x21, 0x20) };
                    tama_core::tama_press(t, x); run(0.02); tama_core::tama_press(t, y); run(0.02);
                    tama_core::tama_release(t, x); run(0.02); tama_core::tama_release(t, y); run(0.3);
                }
                "d" => { let mut d=[0u32;3]; tama_core::tama_debug(t, d.as_mut_ptr()); println!("pc {:08X} sys300 {:X} watchdog {} running {} sleeping {}", d[0], d[1], d[2], tama_core::tama_running(t), tama_core::tama_sleeping(t)); }
                "R" => tama_core::tama_reset(t),
                "U" => { let mut b = vec![0u8; 4096]; let n = tama_core::tama_link_take(t, b.as_mut_ptr(), 4096); println!("uart out {} bytes: {:02X?}", n, &b[..(n as usize).min(48)]); }
                "W" => { let mut pl = [0u32; 2]; tama_core::tama_pet_places(t, pl.as_mut_ptr()); let v = [3u8, 11u8]; println!("write {}", tama_core::tama_block_write(t, pl[0] + 0x1C, v.as_ptr(), 2)); }
                "Z" => tama_core::tama_auto_care(t, 7),
                "F" => println!("care {}", tama_core::tama_care(t, 7)),
                "D" => { let a1 = CString::new(format!("{}/sram{}.bin", a[2], n)).unwrap(); let a2 = CString::new(format!("{}/flash{}.bin", a[2], n)).unwrap(); tama_core::tama_debug_dump(t, a1.as_ptr(), a2.as_ptr()); n += 1; }
                "s" => { shot(t, &format!("{}/{:03}.ppm", a[2], n)); n += 1; }
                _ if w.starts_with("Blk") => { let mut b = vec![0u8; 4096]; let r = tama_core::tama_block(t, b.as_mut_ptr()); if r == 1 { std::fs::write(format!("{}/{}.blk", a[2], &w[3..]), &b).unwrap(); } else { println!("no block"); } }
                _ if w.starts_with("Ram") => { let n = tama_core::tama_mem_size(t, 0); let mut b = vec![0u8; n as usize]; tama_core::tama_mem_read(t, 0, 0, b.as_mut_ptr(), n); std::fs::write(format!("{}/{}.ram", a[2], &w[3..]), &b).unwrap(); }
                _ if w.starts_with('X') || w.starts_with('x') || w.starts_with('m') || w.starts_with('f') => {
                    let (o, v) = w[1..].split_once('=').unwrap();
                    let o = u32::from_str_radix(o, 16).unwrap();
                    let v: Vec<u8> = (0..v.len() / 2).map(|i| u8::from_str_radix(&v[2 * i..2 * i + 2], 16).unwrap()).collect();
                    match &w[..1] {
                        "X" => println!("blockwrite {}", tama_core::tama_block_write(t, o, v.as_ptr(), v.len() as u32)),
                        "x" => { let mut p=[0i32;8]; tama_core::tama_pet(t, p.as_mut_ptr()); tama_core::tama_mem_write(t, 0, (p[7] as u32 - 0x1800_0000) + o, v.as_ptr(), v.len() as u32); }
                        "f" => { tama_core::tama_mem_freeze(t, 0, o, v.as_ptr(), v.len() as u32); }
                        _ => { tama_core::tama_mem_write(t, 0, o, v.as_ptr(), v.len() as u32); }
                    }
                }
                _ if w.starts_with('T') => tama_core::tama_advance(t, w[1..].parse().unwrap()),
                _ if w.starts_with("care") => println!("care {}", tama_core::tama_care(t, w[4..].parse().unwrap())),
                "sec" => println!("seconds {}", tama_core::tama_seconds(t)),
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
