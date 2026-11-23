// Finds the GPIO pin-read function (Water: 0x5D0C) in every edition's program memory by its bytes.
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        let cps = tama_core::tama_cycles_per_second();
        tama_core::tama_run(t, cps * 3, 600000);
        let m = tama_core::machine(t);
        let mut code = vec![0u8; 0x10000];
        for i in (0..0x10000u32).step_by(2) { let w = m.bus.read_u16(i, &mut m.periph, &m.cpu.nvic); code[i as usize] = w as u8; code[i as usize + 1] = (w >> 8) as u8; }
        let sig: [u8; 10] = [0x87, 0xB0, 0x8D, 0xF8, 0x1B, 0x00, 0x05, 0x91, 0x04, 0x92];
        let hits: Vec<usize> = (0..code.len() - 10).filter(|&i| code[i..i + 10] == sig).collect();
        println!("{:?}", hits.iter().map(|h| format!("{:#X}", h)).collect::<Vec<_>>());
        if a.get(2).is_some() { for i in (0x5D0C..0x5D30).step_by(1) { print!("{:02X} ", code[i]); } println!(); }
    }
}
