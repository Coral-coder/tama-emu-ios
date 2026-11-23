// The memory tool's core: read, write, hold (the game cannot change a held value).
use std::ffi::CString;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        tama_core::tama_auto_date(t, 120);
        let cps = tama_core::tama_cycles_per_second();
        tama_core::tama_run(t, cps * 5, 600000);
        println!("sizes: sram {} flash {} pram {}", tama_core::tama_mem_size(t, 0), tama_core::tama_mem_size(t, 1), tama_core::tama_mem_size(t, 2));
        // find a byte the game keeps changing
        let mut a0 = vec![0u8; 131072]; tama_core::tama_mem_read(t, 0, 0, a0.as_mut_ptr(), 131072);
        tama_core::tama_run(t, cps / 2, 600000);
        let mut a1 = vec![0u8; 131072]; tama_core::tama_mem_read(t, 0, 0, a1.as_mut_ptr(), 131072);
        let busy = (0x1000..131072).find(|&i| a0[i] != a1[i] && a1[i] != 0x5A).unwrap();
        let v = [0x5Au8];
        tama_core::tama_mem_freeze(t, 0, busy as u32, v.as_ptr(), 1);
        tama_core::tama_run(t, cps * 2, 600000);
        let mut b = [0u8]; tama_core::tama_mem_read(t, 0, busy as u32, b.as_mut_ptr(), 1);
        println!("busy byte at 0x{:X}: held at 0x5A, after 2 s it is 0x{:02X} ({})", 0x18000000 + busy, b[0], if b[0] == 0x5A { "held" } else { "NOT held" });
        tama_core::tama_mem_unfreeze_all(t);
        let w = [1u8, 2, 3, 4];
        tama_core::tama_mem_write(t, 1, 0xEFF000, w.as_ptr(), 4);
        let mut r = [0u8; 4]; tama_core::tama_mem_read(t, 1, 0xEFF000, r.as_mut_ptr(), 4);
        println!("flash write/read: {:?}", r);
    }
}
