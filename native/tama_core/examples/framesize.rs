// How many pixels does a dump's firmware send per frame? Gives the screen a larger buffer filled
// with a mark and counts what the frames overwrite.
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        let m = tama_core::machine(t);
        m.periph.display.vram = vec![0xDEAD; 128 * 256];
        tama_core::tama_run(t, tama_core::tama_cycles_per_second() * 8, 600_000);
        let m = tama_core::machine(t);
        let v = &m.periph.display.vram;
        let last = v.iter().rposition(|&x| x != 0xDEAD).map(|i| i + 1).unwrap_or(0);
        println!("pixels written: {last} = 128 x {} (+{}), frames {}, w {} h {}", last / 128, last % 128, m.periph.display.trames, m.periph.display.width, m.periph.display.height);
    }
}
