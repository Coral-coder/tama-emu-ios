// After an alarm wake (game started with a key, then left alone): each second, is the screen lit
// (pixels not black), did it change, where is the core, any sound.
use std::ffi::CString;
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
        tama_core::tama_press(t, 0x0B); tama_core::tama_run(t, cps / 8, 600000); tama_core::tama_release(t, 0x0B);
        let mut fb = vec![0u16; 128 * 128];
        for wake in 0..2 {
            while tama_core::tama_sleeping(t) == 0 { tama_core::tama_run(t, cps, 600000); }
            while tama_core::tama_sleeping(t) == 1 { tama_core::tama_run(t, cps / 10, 600000); }
            println!("-- wake {wake}");
            let mut s = 0;
            while tama_core::tama_sleeping(t) == 0 && s < 60 {
                let mut changes = 0;
                for _ in 0..10 { tama_core::tama_run(t, cps / 10, 600000); if tama_core::tama_screen(t, fb.as_mut_ptr()) != 0 { changes += 1; } }
                let lit = fb.iter().filter(|&&v| v != 0).count();
                let mut d = [0u32; 3]; tama_core::tama_debug(t, d.as_mut_ptr());
                println!("{s:3} s: lit px {lit:5}, changed {changes}/10, pc {:08X}, note {:.0}", d[0], tama_core::tama_note(t));
                s += 1;
            }
        }
    }
}
