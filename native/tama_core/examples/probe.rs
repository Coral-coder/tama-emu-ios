// Does a dump boot? Runs it for a while and writes its screen as PPM pictures.
//   probe <dump> <seconds> <out prefix>
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let secs: u64 = a.get(2).and_then(|v| v.parse().ok()).unwrap_or(10);
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        println!("load {}", tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1));
        let cps = tama_core::tama_cycles_per_second();
        let mut wh = [0u32; 2];
        tama_core::tama_screen_size(t, wh.as_mut_ptr());
        let mut scr = vec![0u16; (wh[0] * wh[1]) as usize];
        // probe <dump> <seconds> <out> <second>:<pin hex> ...  presses a key for half a second
        let keys: Vec<(u64, u32)> = a.iter().skip(4).filter_map(|k| k.split_once(':')).map(|(s, p)| (s.parse().unwrap(), u32::from_str_radix(p, 16).unwrap())).collect();
        for i in 0..secs {
            for &(s, pin) in &keys {
                if s == i {
                    tama_core::tama_press(t, pin);
                    tama_core::tama_run(t, cps / 2, 20000);
                    tama_core::tama_release(t, pin);
                }
            }
            let t0 = std::time::Instant::now();
            let done = tama_core::tama_run(t, cps, 20000);
            let mut d = [0u32; 4];
            tama_core::tama_debug(t, d.as_mut_ptr());
            tama_core::tama_screen_full(t, scr.as_mut_ptr(), scr.len() as u32);
            let mut seen = std::collections::HashSet::new();
            for &v in &scr {
                seen.insert(v);
            }
            println!("{i}: {} ms, done {done}, running {}, sleeping {}, pc {:08X}, {} colours", t0.elapsed().as_millis(), tama_core::tama_running(t), tama_core::tama_sleeping(t), d[0], seen.len());
            if let Some(out) = a.get(3) {
                let mut ppm = format!("P6\n{} {}\n255\n", wh[0], wh[1]).into_bytes();
                for &v in &scr {
                    ppm.extend_from_slice(&[((v >> 11) as u8 & 31) << 3, ((v >> 5) as u8 & 63) << 2, (v as u8 & 31) << 3]);
                }
                std::fs::write(format!("{out}{i:02}.ppm"), ppm).unwrap();
            }
        }
    }
}
