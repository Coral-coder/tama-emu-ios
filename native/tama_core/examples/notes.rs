// The melody as the core reports it: every change of the note with the console's clock, run in
// uneven portions as an app does. The times must not depend on the portions.
//   notes <dump> <seconds> <portion ms>
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let secs: u64 = a[2].parse().unwrap();
    let portion: u64 = a[3].parse().unwrap();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        let cps = tama_core::tama_cycles_per_second();
        let (mut at, mut hz) = ([0u64; 64], [0f32; 64]);
        let mut last = 0u64;
        let mut i = 0u64;
        while tama_core::tama_clock(t) < secs * cps {
            // portions of uneven length around the one asked for
            let ms = portion / 2 + (i * 7919) % portion.max(1);
            i += 1;
            tama_core::tama_run(t, cps * ms.max(1) / 1000, 60_000);
            let n = tama_core::tama_note_events(t, at.as_mut_ptr(), hz.as_mut_ptr(), 64);
            for k in 0..n as usize {
                let ms = at[k] as f64 / cps as f64 * 1000.0;
                println!("{:9.1} ms  (+{:6.1})  {:7.1} Hz", ms, (at[k] - last) as f64 / cps as f64 * 1000.0, hz[k]);
                last = at[k];
            }
        }
    }
}
