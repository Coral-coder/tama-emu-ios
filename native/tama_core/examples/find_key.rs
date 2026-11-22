//! Finds the device key of Paradise dumps with the core's search, boots each with it and saves
//! a few screens as PPM.  cargo run --release --example find_key -- <outdir> <dump>...
use std::ffi::CString;
use tama_core::*;

fn main() {
    let mut a = std::env::args().skip(1);
    let out = a.next().expect("outdir");
    for dump in a {
        let c = CString::new(dump.clone()).unwrap();
        let t0 = std::time::Instant::now();
        let mut k = 0u32;
        let th = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4) as u32;
        let ok = unsafe { tama_find_key(c.as_ptr(), th, &mut k) };
        if ok != 1 {
            println!("{dump}: no key ({:.0} s)", t0.elapsed().as_secs_f64());
            continue;
        }
        println!("{dump}: KEY {k:08X} in {:.0} s", t0.elapsed().as_secs_f64());
        let t = tama_new();
        let r = unsafe { tama_load(t, c.as_ptr(), k, 1) };
        println!("  boot -> {r}");
        let per = tama_cycles_per_second();
        let mut fb = vec![0u16; 128 * 128];
        let name = std::path::Path::new(&dump).file_stem().unwrap().to_string_lossy().to_string();
        let t1 = std::time::Instant::now();
        for s in 0..12u32 {
            unsafe { tama_run(t, per, 60_000) };
            if s % 4 == 3 {
                unsafe { tama_screen(t, fb.as_mut_ptr()) };
                let mut ppm = b"P6 128 128 255\n".to_vec();
                for &p in &fb {
                    ppm.push((((p >> 11) & 31) * 255 / 31) as u8);
                    ppm.push((((p >> 5) & 63) * 255 / 63) as u8);
                    ppm.push(((p & 31) * 255 / 31) as u8);
                }
                std::fs::write(format!("{out}/{name}_{s:02}.ppm"), ppm).unwrap();
            }
        }
        println!("  12 console seconds in {:.1} s on this machine", t1.elapsed().as_secs_f64());
        unsafe { tama_free(t) };
    }
}
