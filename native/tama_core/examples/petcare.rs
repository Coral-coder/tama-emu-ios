// The care bits on a saved state:  petcare <dump> <state> <outdir> <bits> [seconds]
// Restores the state (a pet on its field, saved with drive's state-out), saves the screen
// (before.ppm), calls tama_care(bits), gives the dial one step (a pet only takes up a new
// behaviour when it goes back to idling; one step does not zoom), runs on for `seconds` (15) and
// saves the screen again (after.ppm). Bits: 1 feed, 2 play, 4 cure, 8 clean (poop), 16 sleep,
// 32 wake, 64 cheer up. Examples: 8 on a field with poop; 16 by day, 32 on a sleeping pet;
// 71 (feed, play, cure, cheer) on a hungry, crying or sick pet.
use std::ffi::CString;

fn shot(t: *mut tama_core::Tama, path: &str) {
    let mut fb = vec![0u16; 128 * 128];
    unsafe { tama_core::tama_screen(t, fb.as_mut_ptr()) };
    let mut ppm = b"P6 128 128 255\n".to_vec();
    for p in fb {
        let p = p as u32;
        ppm.push((((p >> 11) & 31) * 255 / 31) as u8);
        ppm.push((((p >> 5) & 63) * 255 / 63) as u8);
        ppm.push(((p & 31) * 255 / 31) as u8);
    }
    std::fs::write(path, ppm).unwrap();
}

unsafe fn etat(t: *mut tama_core::Tama, quand: &str) {
    let mut o = [0i32; 8];
    tama_core::tama_pet(t, o.as_mut_ptr());
    let mut places = [0u32; 2];
    tama_core::tama_pet_places(t, places.as_mut_ptr());
    let mut b = vec![0u8; 4096];
    tama_core::tama_block(t, b.as_mut_ptr());
    // the poop count: +0x3C in the pet's record, +0x3D on Neon (record at 0x114, level at 0x88,
    // and the settings ring of Neon: the block is not at 0xEFE000)
    let pet = places[0] as usize;
    println!(
        "{quand}: pet {} character {:04X} hunger {} happiness {} sick {} poop(+0x3C,+0x3D) {} {}",
        o[0], o[1], o[3], o[4], o[5], b[pet + 0x3C], b[pet + 0x3D]
    );
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 5 {
        eprintln!("petcare <dump> <state> <outdir> <bits> [seconds]");
        return;
    }
    let bits: u32 = a[4].parse().unwrap();
    let secs: f64 = a.get(5).map_or(15.0, |s| s.parse().unwrap());
    unsafe {
        let t = tama_core::tama_new();
        let p = CString::new(a[1].clone()).unwrap();
        tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
        let s = CString::new(a[2].clone()).unwrap();
        if tama_core::tama_restore(t, s.as_ptr()) != 0 {
            eprintln!("no state");
            return;
        }
        let cps = tama_core::tama_cycles_per_second() as f64;
        let run = |secs: f64| {
            tama_core::tama_run(t, (cps * secs) as u64, 600000);
        };
        run(2.0);
        shot(t, &format!("{}/before.ppm", a[3]));
        etat(t, "before");
        println!("tama_care({bits}) = {}", tama_core::tama_care(t, bits));
        run(1.0);
        tama_core::tama_turn(t, 1);
        run(secs);
        shot(t, &format!("{}/after.ppm", a[3]));
        etat(t, "after");
    }
}
