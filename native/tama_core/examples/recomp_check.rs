// The recompiler against Capybara's interpreter: the same dump, the same keys at the same
// console times; compares screens, sounds, sleep, the pet's clock, and the time each took.
use std::ffi::CString;
use std::time::Instant;
unsafe fn boot(path: &str, on: bool) -> *mut tama_core::Tama {
    let t = tama_core::tama_new();
    let p = CString::new(path).unwrap();
    tama_core::tama_load(t, p.as_ptr(), 0x5AAF34FB, 1);
    tama_core::tama_sync_clock(t, 30_000_000);
    tama_core::tama_auto_date(t, 120);
    tama_core::set_recomp(t, on);
    t
}
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let secs: u64 = a.get(2).map(|s| s.parse().unwrap()).unwrap_or(60);
    unsafe {
        let (i, r) = (boot(&a[1], false), boot(&a[1], true));
        let cps = tama_core::tama_cycles_per_second();
        let (mut fi, mut fr) = (vec![0u16; 128 * 128], vec![0u16; 128 * 128]);
        let (mut ti, mut tr) = (0f64, 0f64);
        let (mut same, mut total) = (0, 0);
        for tenth in 0..secs * 10 {
            for (t, f, tm) in [(i, &mut fi, &mut ti), (r, &mut fr, &mut tr)] {
                // keys: A, B, C and the wheel in turn every 3 s (menus, games, animations)
                if tenth % 30 == 5 { tama_core::tama_press(t, [0x09u32, 0x0B, 0x0A, 0x0B][(tenth / 30 % 4) as usize]); }
                if tenth % 30 == 6 { tama_core::tama_release_all(t); }
                if tenth % 70 == 20 { tama_core::tama_turn(t, 1); }
                let s = Instant::now();
                tama_core::tama_run(t, cps / 10, 600000);
                *tm += s.elapsed().as_secs_f64();
                tama_core::tama_screen(t, f.as_mut_ptr());
            }
            total += 1;
            if fi == fr { same += 1; }
            if tenth % 100 == 99 {
                println!("{:3} s: screens equal {}/{}  sound {:.0}/{:.0}  asleep {}/{}  pc {:08X}/{:08X}",
                    (tenth + 1) / 10, same, total, tama_core::tama_note(i), tama_core::tama_note(r),
                    tama_core::tama_sleeping(i), tama_core::tama_sleeping(r), tama_core::machine(i).cpu.regs.pc, tama_core::machine(r).cpu.regs.pc);
            }
        }
        println!("interpreter {:.1} s, recompiler {:.1} s ({:.2}x)", ti, tr, ti / tr);
        let ram = |t: *mut tama_core::Tama| tama_core::machine(t).bus.sram.data.clone();
        let (ri, rr) = (ram(i), ram(r));
        let diff = ri.iter().zip(rr.iter()).filter(|(a, b)| a != b).count();
        println!("work RAM bytes that differ at the end: {} of {}", diff, ri.len());
    }
}
