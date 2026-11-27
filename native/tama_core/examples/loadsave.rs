// Opens a save file with a dump (as the app does) and reports whether the game carries on with it.
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        let s = CString::new(a[2].clone()).unwrap();
        println!("open_save {}", tama_core::tama_open_save(t, s.as_ptr()));
        println!("sync_clock pages {}", tama_core::tama_sync_clock(t, 60_000_000));
        let cps = tama_core::tama_cycles_per_second();
        let mut fb = vec![0u16; 128 * 128];
        for i in 0..20 { tama_core::tama_run(t, cps, 600000); if i == 6 { tama_core::tama_press(t, 0x0B); } if i == 7 { tama_core::tama_release_all(t); } }
        tama_core::tama_screen(t, fb.as_mut_ptr());
        println!("running {}, lit pixels {}, seconds {}", tama_core::tama_running(t), fb.iter().filter(|&&v| v != 0).count(), tama_core::tama_seconds(t));
    }
}
