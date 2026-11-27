//! Tamagotchi Paradise on a jailbroken Kindle (written for the Paperwhite 3, DP75SDI: i.MX6,
//! 1072 x 1448 e-ink, 8 bit grey framebuffer, capacitive touch).
//!
//!   tama_kindle <dump.bin> [save file]
//!
//! The game's 128 x 128 screen is drawn eight times as large in grey, the three keys A B C are
//! fields on the touchscreen below it, the cross at the top right ends the program. The clock is
//! the Kindle's. TAMA_KEY=<hex> gives another device key, TAMA_FPS=<n> another refresh limit.

use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::unix::io::AsRawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn on_signal(_: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

const PIN_A: u32 = 0x09;
const PIN_B: u32 = 0x0B;
const PIN_C: u32 = 0x0A;

// ---------------------------------------------------------------- the e-ink framebuffer
const FBIOGET_VSCREENINFO: u32 = 0x4600;
const FBIOGET_FSCREENINFO: u32 = 0x4602;
/// MXCFB_SEND_UPDATE of the Kindle's i.MX6 kernels (Paperwhite 2 and 3, Voyage, Basic 2 ...):
/// _IOW('F', 0x2E, struct mxcfb_update_data), 72 bytes.
const MXCFB_SEND_UPDATE: u32 = 0x4048_462E;
const WAVE_GC16: u32 = 2;
const WAVE_AUTO: u32 = 257;
const TEMP_USE_AMBIENT: i32 = 0x1000;

#[repr(C)]
#[derive(Default)]
struct Update {
    top: u32,
    left: u32,
    width: u32,
    height: u32,
    waveform_mode: u32,
    update_mode: u32,
    update_marker: u32,
    hist_bw_waveform_mode: u32,
    hist_gray_waveform_mode: u32,
    temp: i32,
    flags: u32,
    alt_phys_addr: u32,
    alt_width: u32,
    alt_height: u32,
    alt_region: [u32; 4],
}

struct Fb {
    file: File,
    mem: *mut u8,
    len: usize,
    w: usize,
    h: usize,
    line: usize,
    bpp: usize,
    marker: u32,
    refresh_failed: bool,
}

impl Fb {
    fn open() -> Result<Fb, String> {
        // TAMA_FAKE=<file.pgm>: no Kindle, a Paperwhite's screen in memory, written out at the end
        if std::env::var("TAMA_FAKE").is_ok() {
            let (w, h, line) = (1072usize, 1448usize, 1088usize);
            let mem = Box::leak(vec![0u8; line * h].into_boxed_slice()).as_mut_ptr();
            let file = File::open("/dev/null").map_err(|e| e.to_string())?;
            return Ok(Fb { file, mem, len: line * h, w, h, line, bpp: 1, marker: 1, refresh_failed: true });
        }
        let file = OpenOptions::new().read(true).write(true).open("/dev/fb0").map_err(|e| format!("/dev/fb0: {e}"))?;
        let fd = file.as_raw_fd();
        let mut var = [0u32; 64];
        let mut fix = [0u8; 256];
        unsafe {
            if libc::ioctl(fd, FBIOGET_VSCREENINFO as _, var.as_mut_ptr()) != 0 || libc::ioctl(fd, FBIOGET_FSCREENINFO as _, fix.as_mut_ptr()) != 0 {
                return Err("the framebuffer does not answer".into());
            }
        }
        let (w, h, bpp) = (var[0] as usize, var[1] as usize, var[6] as usize);
        // struct fb_fix_screeninfo: line_length follows id[16], smem_start (a long), smem_len,
        // type, type_aux, visual, three u16 and padding
        let o = if cfg!(target_pointer_width = "64") { 48 } else { 44 };
        let line = u32::from_ne_bytes([fix[o], fix[o + 1], fix[o + 2], fix[o + 3]]) as usize;
        if bpp != 8 && bpp != 16 && bpp != 32 {
            return Err(format!("a framebuffer of {bpp} bits per pixel is not supported"));
        }
        let len = line * var[3].max(var[1]) as usize;
        let mem = unsafe { libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd, 0) };
        if mem == libc::MAP_FAILED {
            return Err("the framebuffer cannot be mapped".into());
        }
        Ok(Fb { file, mem: mem as *mut u8, len, w, h, line, bpp: bpp / 8, marker: 1, refresh_failed: false })
    }

    #[inline]
    fn put(&mut self, x: usize, y: usize, grey: u8) {
        let o = y * self.line + x * self.bpp;
        if x >= self.w || y >= self.h || o + self.bpp > self.len {
            return;
        }
        unsafe {
            match self.bpp {
                1 => *self.mem.add(o) = grey,
                2 => {
                    let v = ((grey as u16 >> 3) << 11) | ((grey as u16 >> 2) << 5) | (grey as u16 >> 3);
                    (self.mem.add(o) as *mut u16).write_unaligned(v)
                }
                _ => (self.mem.add(o) as *mut u32).write_unaligned(0xFF00_0000 | (grey as u32) << 16 | (grey as u32) << 8 | grey as u32),
            }
        }
    }

    fn fill(&mut self, x: usize, y: usize, w: usize, h: usize, grey: u8) {
        for yy in y..(y + h).min(self.h) {
            for xx in x..(x + w).min(self.w) {
                self.put(xx, yy, grey);
            }
        }
    }

    fn frame(&mut self, x: usize, y: usize, w: usize, h: usize, t: usize, grey: u8) {
        self.fill(x, y, w, t, grey);
        self.fill(x, y + h - t, w, t, grey);
        self.fill(x, y, t, h, grey);
        self.fill(x + w - t, y, t, h, grey);
    }

    /// Shows what was drawn in the rectangle. `full` flashes the area once (no ghosts left).
    fn refresh(&mut self, x: usize, y: usize, w: usize, h: usize, full: bool) {
        let mut u = Update {
            top: y as u32,
            left: x as u32,
            width: w.min(self.w - x) as u32,
            height: h.min(self.h - y) as u32,
            waveform_mode: if full { WAVE_GC16 } else { WAVE_AUTO },
            update_mode: full as u32,
            update_marker: self.marker,
            hist_bw_waveform_mode: 0,
            hist_gray_waveform_mode: 0,
            temp: TEMP_USE_AMBIENT,
            ..Default::default()
        };
        self.marker = self.marker.wrapping_add(1).max(1);
        let r = unsafe { libc::ioctl(self.file.as_raw_fd(), MXCFB_SEND_UPDATE as _, &mut u as *mut Update) };
        if r != 0 && !self.refresh_failed {
            self.refresh_failed = true;
            eprintln!("the screen refresh was refused ({}): this Kindle wants another refresh call", std::io::Error::last_os_error());
        }
    }
}

// 5 x 7 letters for the keys
const GLYPH_A: [u8; 7] = [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001];
const GLYPH_B: [u8; 7] = [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110];
const GLYPH_C: [u8; 7] = [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110];
const GLYPH_X: [u8; 7] = [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001];

fn glyph(fb: &mut Fb, g: &[u8; 7], cx: usize, cy: usize, s: usize, grey: u8) {
    let (x0, y0) = (cx.saturating_sub(5 * s / 2), cy.saturating_sub(7 * s / 2));
    for (r, bits) in g.iter().enumerate() {
        for c in 0..5 {
            if bits & (0x10 >> c) != 0 {
                fb.fill(x0 + c * s, y0 + r * s, s, s, grey);
            }
        }
    }
}

// ---------------------------------------------------------------- the touchscreen
const EV_KEY: u16 = 1;
const EV_ABS: u16 = 3;
const ABS_X: u16 = 0x00;
const ABS_Y: u16 = 0x01;
const ABS_MT_POSITION_X: u16 = 0x35;
const ABS_MT_POSITION_Y: u16 = 0x36;
const ABS_MT_TRACKING_ID: u16 = 0x39;
const BTN_TOUCH: u16 = 0x14A;

struct Touch {
    file: File,
    max_x: i32,
    max_y: i32,
    x: i32,
    y: i32,
    down: bool,
}

fn abs_max(fd: i32, axis: u16) -> i32 {
    // EVIOCGABS(axis): struct input_absinfo { value, minimum, maximum, fuzz, flat, resolution }
    let mut info = [0i32; 6];
    let req: u32 = 0x8018_4540 + axis as u32;
    if unsafe { libc::ioctl(fd, req as _, info.as_mut_ptr()) } == 0 {
        info[2]
    } else {
        0
    }
}

/// Every input device that reports multi-touch positions (the Paperwhite's cyttsp panel).
fn touches() -> Vec<Touch> {
    let mut v = vec![];
    for i in 0..8 {
        let Ok(file) = OpenOptions::new().read(true).custom_flags_nonblock().open(format!("/dev/input/event{i}")) else { continue };
        let fd = file.as_raw_fd();
        let (mut mx, mut my) = (abs_max(fd, ABS_MT_POSITION_X), abs_max(fd, ABS_MT_POSITION_Y));
        if mx <= 0 || my <= 0 {
            mx = abs_max(fd, ABS_X);
            my = abs_max(fd, ABS_Y);
        }
        if mx <= 0 || my <= 0 {
            continue;
        }
        // EVIOCGRAB: the Kindle's own interface does not see the taps while the game runs
        unsafe { libc::ioctl(fd, 0x4004_4590u32 as _, 1 as libc::c_int) };
        v.push(Touch { file, max_x: mx, max_y: my, x: 0, y: 0, down: false });
    }
    v
}

trait NonBlock {
    fn custom_flags_nonblock(&mut self) -> &mut Self;
}
impl NonBlock for OpenOptions {
    fn custom_flags_nonblock(&mut self) -> &mut Self {
        use std::os::unix::fs::OpenOptionsExt;
        self.custom_flags(libc::O_NONBLOCK)
    }
}

// ---------------------------------------------------------------- the game
struct Layout {
    scale: usize,
    gx: usize,
    gy: usize,
    keys: [(usize, usize, usize, usize, u32); 3],
    exit: (usize, usize, usize, usize),
}

fn layout(fb: &Fb) -> Layout {
    let scale = (fb.w / 128).min(fb.h * 2 / 3 / 128).max(1);
    let side = 128 * scale;
    let gx = (fb.w - side) / 2;
    let gy = (fb.h / 12).max(8);
    let ky = gy + side + fb.h / 24;
    let kh = (fb.h - ky).saturating_sub(fb.h / 24).min(fb.h / 5).max(40);
    let kw = fb.w / 3;
    let m = kw / 12;
    Layout {
        scale,
        gx,
        gy,
        keys: [(m, ky, kw - 2 * m, kh, PIN_A), (kw + m, ky, kw - 2 * m, kh, PIN_B), (2 * kw + m, ky, kw - 2 * m, kh, PIN_C)],
        exit: (fb.w - gy, 0, gy, gy),
    }
}

fn draw_chrome(fb: &mut Fb, l: &Layout, held: u32) {
    let (w, h) = (fb.w, fb.h);
    fb.fill(0, 0, w, h, 0xFF);
    let side = 128 * l.scale;
    fb.frame(l.gx.saturating_sub(6), l.gy.saturating_sub(6), side + 12, side + 12, 3, 0x00);
    draw_keys(fb, l, held);
    let e = l.exit;
    glyph(fb, &GLYPH_X, e.0 + e.2 / 2, e.1 + e.3 / 2, (e.2 / 14).max(2), 0x60);
}

fn draw_keys(fb: &mut Fb, l: &Layout, held: u32) {
    for (i, &(x, y, w, h, pin)) in l.keys.iter().enumerate() {
        let on = held == pin;
        fb.fill(x, y, w, h, if on { 0x00 } else { 0xFF });
        fb.frame(x, y, w, h, 6, 0x00);
        let g = [&GLYPH_A, &GLYPH_B, &GLYPH_C][i];
        glyph(fb, g, x + w / 2, y + h / 2, (h / 14).max(3), if on { 0xFF } else { 0x00 });
    }
}

fn local_seconds_since_2025() -> u64 {
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&now, &mut tm);
        // 2025-01-01 00:00 UTC is 1735689600
        (now as i64 + tm.tm_gmtoff as i64 - 1_735_689_600).max(0) as u64
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("tama_kindle <dump.bin> [save file]\n  TAMA_KEY=<hex>  the device key when it is not the usual one\n  TAMA_FPS=<n>    screen refreshes per second at most (default 4)");
        std::process::exit(2);
    }
    let dump = args[1].clone();
    let save = args.get(2).cloned().unwrap_or_else(|| format!("{dump}.tamasave"));
    let key = std::env::var("TAMA_KEY").ok().and_then(|k| u32::from_str_radix(k.trim_start_matches("0x"), 16).ok()).unwrap_or(0x5AAF_34FB);
    let fps: u64 = std::env::var("TAMA_FPS").ok().and_then(|v| v.parse().ok()).filter(|&v| v > 0 && v <= 30).unwrap_or(4);

    let mut fb = match Fb::open() {
        Ok(f) => f,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    };
    let mut touch = touches();
    if touch.is_empty() {
        eprintln!("no touchscreen found under /dev/input: the game runs, but without keys");
    }
    unsafe {
        libc::signal(libc::SIGINT, on_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, on_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGHUP, on_signal as *const () as libc::sighandler_t);
    }

    let t = tama_core::tama_new();
    let cps = tama_core::tama_cycles_per_second();
    unsafe {
        let p = CString::new(dump.clone()).unwrap();
        match tama_core::tama_load(t, p.as_ptr(), key, 1) {
            1 => {}
            0 => {
                eprintln!("the firmware stays encrypted: the device key is missing or wrong (TAMA_KEY=<hex>)");
                std::process::exit(1);
            }
            _ => {
                eprintln!("{dump} could not be loaded");
                std::process::exit(1);
            }
        }
        let s = CString::new(save.clone()).unwrap();
        tama_core::tama_open_save(t, s.as_ptr());
        if tama_core::tama_sync_clock(t, local_seconds_since_2025()) > 0 {
            tama_core::tama_auto_date(t, 120);
        }
    }

    let l = layout(&fb);
    draw_chrome(&mut fb, &l, 0);
    let (w, h) = (fb.w, fb.h);
    fb.refresh(0, 0, w, h, true);
    println!("screen {} x {}, {} bytes a pixel, game {} times as large; {} touch device(s); save: {save}", fb.w, fb.h, fb.bpp, l.scale, touch.len());

    let mut screen = vec![0u16; 128 * 128];
    let mut shown = vec![0xFFu8; 128 * 128];
    let mut held: u32 = 0;
    let mut last = Instant::now();
    let mut last_frame = Instant::now() - Duration::from_secs(1);
    let mut last_save = Instant::now();
    let mut last_full = Instant::now();
    let mut partials = 0u32;
    let mut slow = 0u64;
    let mut buf = [0u8; 16 * 64];
    let ev = if cfg!(target_pointer_width = "64") { 24 } else { 16 };

    let started = Instant::now();
    let limit: Option<u64> = std::env::var("TAMA_SECONDS").ok().and_then(|v| v.parse().ok());
    while !STOP.load(Ordering::SeqCst) && limit.map_or(true, |s| started.elapsed().as_secs() < s) {
        // ---- taps
        let mut tap: Option<(bool, i32, i32)> = None;
        for td in touch.iter_mut() {
            while let Ok(n) = td.file.read(&mut buf) {
                if n < ev {
                    break;
                }
                for e in buf[..n].chunks_exact(ev) {
                    let o = ev - 8;
                    let kind = u16::from_ne_bytes([e[o], e[o + 1]]);
                    let code = u16::from_ne_bytes([e[o + 2], e[o + 3]]);
                    let value = i32::from_ne_bytes([e[o + 4], e[o + 5], e[o + 6], e[o + 7]]);
                    match (kind, code) {
                        (EV_ABS, ABS_MT_POSITION_X) | (EV_ABS, ABS_X) => td.x = value * w as i32 / (td.max_x + 1),
                        (EV_ABS, ABS_MT_POSITION_Y) | (EV_ABS, ABS_Y) => td.y = value * h as i32 / (td.max_y + 1),
                        (EV_ABS, ABS_MT_TRACKING_ID) => td.down = value >= 0,
                        (EV_KEY, BTN_TOUCH) => td.down = value != 0,
                        _ => {}
                    }
                }
                tap = Some((td.down, td.x, td.y));
            }
        }
        if let Some((down, x, y)) = tap {
            let (x, y) = (x.max(0) as usize, y.max(0) as usize);
            let inside = |r: (usize, usize, usize, usize)| x >= r.0 && x < r.0 + r.2 && y >= r.1 && y < r.1 + r.3;
            let mut now_held = 0;
            if down {
                if inside(l.exit) {
                    break;
                }
                for &(kx, ky, kw, kh, pin) in l.keys.iter() {
                    if inside((kx, ky, kw, kh)) {
                        now_held = pin;
                    }
                }
            }
            if now_held != held {
                unsafe {
                    if held != 0 {
                        tama_core::tama_release(t, held);
                    }
                    if now_held != 0 {
                        tama_core::tama_press(t, now_held);
                    }
                }
                held = now_held;
                draw_keys(&mut fb, &l, held);
                let k0 = l.keys[0];
                fb.refresh(0, k0.1, w, k0.3, false);
            }
        }

        // ---- the console, in real time
        let now = Instant::now();
        let gap = now - last;
        last = now;
        unsafe {
            if gap > Duration::from_secs(3) {
                // the Kindle slept: the game's clock catches up
                tama_core::tama_advance(t, gap.as_secs() as u32);
            } else {
                let want = (gap.as_micros() as u64).saturating_mul(cps) / 1_000_000;
                let done = tama_core::tama_run(t, want, 150);
                if done < want {
                    slow += want - done;
                }
            }
        }

        // ---- the screen: only what changed, a few times a second
        if last_frame.elapsed() >= Duration::from_millis(1000 / fps) && unsafe { tama_core::tama_screen(t, screen.as_mut_ptr()) } != 0 {
            let (mut x0, mut y0, mut x1, mut y1) = (128usize, 128usize, 0usize, 0usize);
            for y in 0..128 {
                for x in 0..128 {
                    let p = screen[y * 128 + x];
                    let (r, g, b) = (((p >> 11) & 31) as u32 * 255 / 31, ((p >> 5) & 63) as u32 * 255 / 63, (p & 31) as u32 * 255 / 31);
                    // 16 greys is what the panel shows
                    let grey = (((r * 77 + g * 150 + b * 29) >> 8) as u8) & 0xF0;
                    let grey = grey | (grey >> 4);
                    if shown[y * 128 + x] != grey {
                        shown[y * 128 + x] = grey;
                        x0 = x0.min(x);
                        y0 = y0.min(y);
                        x1 = x1.max(x);
                        y1 = y1.max(y);
                        fb.fill(l.gx + x * l.scale, l.gy + y * l.scale, l.scale, l.scale, grey);
                    }
                }
            }
            if x1 >= x0 && y1 >= y0 {
                // now and then the whole picture flashes once, that clears the ghosts
                let full = partials >= 40 && last_full.elapsed() > Duration::from_secs(20);
                if full {
                    fb.refresh(l.gx, l.gy, 128 * l.scale, 128 * l.scale, true);
                    partials = 0;
                    last_full = Instant::now();
                } else {
                    fb.refresh(l.gx + x0 * l.scale, l.gy + y0 * l.scale, (x1 - x0 + 1) * l.scale, (y1 - y0 + 1) * l.scale, false);
                    partials += 1;
                }
                last_frame = Instant::now();
            }
        }

        if last_save.elapsed() > Duration::from_secs(5) {
            unsafe { tama_core::tama_write_save(t) };
            last_save = Instant::now();
        }

        // ---- rest: long while the toy sleeps, short while it plays
        let asleep = unsafe { tama_core::tama_sleeping(t) } != 0 && held == 0;
        let mut fds: Vec<libc::pollfd> = touch.iter().map(|td| libc::pollfd { fd: td.file.as_raw_fd(), events: libc::POLLIN, revents: 0 }).collect();
        unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as _, if asleep { 1000 } else { 15 }) };
    }

    unsafe {
        tama_core::tama_write_save(t);
        for td in touch.iter() {
            libc::ioctl(td.file.as_raw_fd(), 0x4004_4590u32 as _, 0 as libc::c_int);
        }
    }
    let (w, h) = (fb.w, fb.h);
    if let Ok(out) = std::env::var("TAMA_FAKE") {
        let mut pgm = format!("P5\n{w} {h}\n255\n").into_bytes();
        for y in 0..h {
            pgm.extend_from_slice(unsafe { std::slice::from_raw_parts(fb.mem.add(y * fb.line), w) });
        }
        let _ = std::fs::write(out, pgm);
    }
    fb.fill(0, 0, w, h, 0xFF);
    fb.refresh(0, 0, w, h, true);
    if slow > cps {
        println!("the Kindle fell behind by {} s of game time in all", slow / cps);
    }
    println!("saved to {save}");
}
