// Runs a dump for a while, presses keys, prints the notes heard.
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        println!("load {}", tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1));
        let cps = tama_core::tama_cycles_per_second();
        let mut last = -1.0f32;
        for step in 0..(30 * 60) {
            if step % 120 == 60 { tama_core::tama_press(t, 0x0B); }
            if step % 120 == 66 { tama_core::tama_release(t, 0x0B); }
            if step % 240 == 100 { tama_core::tama_press(t, 0x09); }
            if step % 240 == 106 { tama_core::tama_release(t, 0x09); }
            tama_core::tama_run(t, cps / 60, 1000);
            let n = tama_core::tama_note(t);
            if (n - last).abs() > 0.5 { println!("{:6.2}s note {:7.1} sounds {}", step as f32 / 60.0, n, tama_core::tama_sounds(t)); last = n; }
        }
    }
}
