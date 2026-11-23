// What the firmware reads from one peripheral page right after an alarm wakes it from deep sleep
// (the game started with a key press, then left alone). Args: dump, page in hex.
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let page = u32::from_str_radix(&a[2], 16).unwrap();
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
        let mut s = 0;
        while tama_core::tama_sleeping(t) == 0 && s < 300 { tama_core::tama_run(t, cps, 600000); s += 1; }
        println!("asleep at {s} s");
        tama_core::tama_debug_trace(t, page, 0);
        let mut n = 0;
        while tama_core::tama_sleeping(t) == 1 && n < 6000 { tama_core::tama_run(t, cps / 10, 600000); n += 1; }
        println!("woke after {} s", n / 10);
        tama_core::tama_run(t, cps * 3, 600000);
        tama_core::tama_debug_trace(t, 0, 1);
    }
}
