// Where does a dump's firmware go? Runs it in steps and prints the debug words.
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        let r = tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        println!("load {r}");
        let cps = tama_core::tama_cycles_per_second();
        let mut scr = vec![0u16; 128 * 128];
        for i in 0..8 {
            let done = tama_core::tama_run(t, cps / 2, 3000);
            let mut d = [0u32; 16];
            tama_core::tama_debug(t, d.as_mut_ptr());
            tama_core::tama_screen(t, scr.as_mut_ptr());
            let lit = scr.iter().filter(|&&v| v != 0).count();
            println!("{i}: done {done} running {} sleeping {} dbg {:X?} lit {lit}", tama_core::tama_running(t), tama_core::tama_sleeping(t), &d[..8]);
        }
    }
}
