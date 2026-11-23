//! Recompiler, stage 1: blocks of pre-decoded instructions.
//!
//! The code the firmware runs is cut into blocks the first time it runs (straight-line runs of
//! up to 32 instructions, read from PRAM or the XIP window). A block keeps each instruction's
//! halfwords and length, so running it again needs no fetch, no region lookup and no length
//! decoding; instructions are then executed by Capybara's own Thumb executors, so every
//! instruction behaves exactly as in the interpreter. Later stages replace the hottest kinds
//! with native operations (docs/recompiler.md).
//!
//! Nothing is stored: blocks are built on the device from the ROM that is loaded.

use crate::emulator::cpu::registers::Mode;
use crate::emulator::cpu::thumb16::Thumb16;
use crate::emulator::cpu::thumb32::Thumb32;
use crate::emulator::{Machine, StepResult};

/// One pre-decoded instruction. The common forms run natively (each mirrors Capybara's code for
/// that form: same result, flags and cycles); everything else goes to Capybara's executor.
#[derive(Clone, Copy)]
enum Op {
    Capy { w1: u16, w2: u16, long: bool },
    /// MOVS / CMP / ADDS / SUBS rd, #imm8
    Imm8 { op: u8, rd: u8, imm: u32 },
    /// ADDS / SUBS rd, rn, rm|#imm3
    AddSub3 { sub: bool, rd: u8, rn: u8, rm: u8, imm: Option<u32> },
    /// LDR rd, [pc, #imm] with a constant from read-only flash
    LdrConst { rd: u8, val: u32 },
    /// LDR rd, [pc, #imm] from PRAM (may change)
    LdrLit { rd: u8, addr: u32 },
    /// LDR / STR (B) rd, [rn, #imm]
    LdStImm { ld: bool, byte: bool, rd: u8, rn: u8, imm: u32 },
    /// LDR / STR rd, [sp, #imm]
    LdStSp { ld: bool, rd: u8, imm: u32 },
    /// ADD rd, sp|pc, #imm (ADR); the pc form is folded into a constant
    AddSp { rd: u8, imm: u32 },
    Const1 { rd: u8, val: u32 },
    /// ADD / SUB sp, #imm
    AdjSp { sub: bool, imm: u32 },
    /// NOP and the hints (no effect here)
    Nop,
    /// B<cond> / B
    Bcc { cond: u16, target: u32 },
    B { target: u32 },
    /// MOVW / MOVT
    MovW { rd: u8, imm: u32 },
    MovT { rd: u8, imm: u32 },
    /// LSL / LSR / ASR rd, rm, #imm5 (exec_decalage)
    ShiftImm { op: u8, rd: u8, rm: u8, imm5: u32 },
    /// 16-bit data processing (exec_alu)
    Alu { op: u8, rdn: u8, rm: u8 },
    /// ADD / CMP / MOV / BX / BLX with high registers (exec_high_reg)
    HiReg { op: u8, rdn: u8, rm: u8, blx: bool },
    /// LDR / STR (B, H, SB, SH) rd, [rn, rm] (exec_ldr_str_reg)
    LdStReg { op: u8, rd: u8, rn: u8, rm: u8 },
    /// LDRH / STRH rd, [rn, #imm] (exec_ldr_str_half)
    LdStHalf { ld: bool, rd: u8, rn: u8, imm: u32 },
    /// 32-bit data processing, modified immediate or shifted register (exec_donnees)
    Dp32 { op: u8, s: bool, rn: u8, rd: u8, src: Src },
    /// 32-bit LDR / STR (B, H, signed) (exec_transfert)
    Xfer32 { w1: u16, w2: u16 },
    /// BL
    Bl { target: u32, lr: u32 },
}

/// Second operand of a 32-bit data-processing instruction.
#[derive(Clone, Copy)]
enum Src {
    /// imm12 with imm12[11:10] == 00: the value; the carry stays
    ImmKeep(u32),
    /// rotated immediate: the value and its carry
    ImmCarry(u32, bool),
    Reg { rm: u8, amount: u32, kind: u32 },
}

/// Op flags: may move the pc elsewhere; may raise an interrupt or start an IT block.
const BR: u8 = 1;
const SIDE: u8 = 2;

impl Op {
    #[inline(always)]
    fn flags(&self) -> u8 {
        match *self {
            Op::Capy { .. } => BR | SIDE,
            Op::Bcc { .. } | Op::B { .. } | Op::Bl { .. } => BR,
            Op::HiReg { op, rdn, .. } => {
                if op == 3 || (op != 1 && rdn == 15) { BR } else { 0 }
            }
            Op::Dp32 { rd, .. } => {
                if rd == 15 { BR } else { 0 }
            }
            Op::Xfer32 { w1, w2 } => {
                if ((w2 >> 12) & 0xF) == 15 || (w1 & 0xF) == 15 { BR | SIDE } else { SIDE }
            }
            Op::LdStImm { ld: false, .. } | Op::LdStSp { ld: false, .. } | Op::LdStHalf { ld: false, .. } => SIDE,
            Op::LdStReg { op, .. } if op <= 2 => SIDE,
            _ => 0,
        }
    }

    #[inline(always)]
    fn len(&self) -> u32 {
        match self {
            Op::Capy { long: true, .. } | Op::MovW { .. } | Op::MovT { .. } | Op::Dp32 { .. } | Op::Xfer32 { .. } | Op::Bl { .. } => 4,
            _ => 2,
        }
    }
}

struct Block {
    /// each op with its length and flags, worked out once
    ops: Vec<(Op, u8, u8)>,
    /// The bytes the block was built from (checked again for PRAM, which the firmware fills).
    bytes: Vec<u8>,
}

const MAX_OPS: usize = 32;

/// Block index + 1 for every halfword address of PRAM (64 KB) and the XIP window (1 MB).
const PRAM_SLOTS: usize = 0x1_0000 / 2;
const XIP_SLOTS: usize = 0x10_0000 / 2;

pub struct Recomp {
    #[cfg(feature = "stats")]
    pub stats: std::collections::HashMap<u16, u64>,
    blocks: Vec<Block>,
    slots: Vec<u32>,
    xip: u32,
    /// Cycles not yet given to the peripherals (serviced every 256, as Capybara does).
    pub pending: u32,
    pub built: u64,
    pub ran: u64,
}

/// Why a block run stopped.
pub enum Exit {
    /// Ran out of the budget or left the block normally: carry on.
    Ok,
    /// The interpreter must take the next instruction (exception, IT block, special address).
    Slow,
    /// The core stopped (halt, undefined instruction).
    Stopped,
}

fn long(w: u16) -> bool {
    (w & 0xF800) == 0xE800 || (w & 0xF800) == 0xF000 || (w & 0xF800) == 0xF800
}

impl Default for Recomp {
    fn default() -> Self {
        Self { #[cfg(feature = "stats")] stats: Default::default(), blocks: Vec::new(), slots: vec![0; PRAM_SLOTS + XIP_SLOTS], xip: 0, pending: 0, built: 0, ran: 0 }
    }
}

impl Recomp {
    pub fn clear(&mut self) {
        self.blocks.clear();
        self.slots.iter_mut().for_each(|s| *s = 0);
        self.pending = 0;
    }

    #[inline(always)]
    fn slot(pc: u32) -> Option<usize> {
        if pc < 0x1_0000 {
            Some((pc >> 1) as usize)
        } else if (0x1000_0000..0x1010_0000).contains(&pc) {
            Some(PRAM_SLOTS + ((pc - 0x1000_0000) >> 1) as usize)
        } else {
            None
        }
    }

    fn code_bytes(m: &Machine, pc: u32, n: usize) -> Option<&[u8]> {
        use crate::emulator::mmu::map;
        if pc < map::PRAM_END {
            m.bus.pram.data.get(pc as usize..pc as usize + n)
        } else if (map::ICACHE_BASE..map::ICACHE_END).contains(&pc) {
            let o = m.periph.xip.flash_offset(pc - map::ICACHE_BASE);
            m.bus.flash.data.get(o..o + n)
        } else {
            None
        }
    }

    fn build(m: &Machine, pc: u32) -> Option<Block> {
        let mut ops = Vec::with_capacity(MAX_OPS);
        let mut at = pc;
        let mut len = 0usize;
        while ops.len() < MAX_OPS {
            let Some(b) = Self::code_bytes(m, at, 4) else { break };
            let w1 = u16::from_le_bytes([b[0], b[1]]);
            let w2 = u16::from_le_bytes([b[2], b[3]]);
            let l = long(w1);
            let op = Self::decode(m, at, w1, w2, l);
            ops.push((op, op.len() as u8, op.flags()));
            let n = if l { 4 } else { 2 };
            at = at.wrapping_add(n);
            len += n as usize;
            // an IT instruction makes the next ones conditional: the interpreter takes those
            if (w1 & 0xFF00) == 0xBF00 && (w1 & 0x000F) != 0 {
                break;
            }
        }
        if ops.is_empty() {
            return None;
        }
        let bytes = Self::code_bytes(m, pc, len)?.to_vec();
        Some(Block { ops, bytes })
    }

    /// The native form of an instruction at `at`, or Capybara's executor.
    pub(crate) fn decode(m: &Machine, at: u32, w1: u16, w2: u16, l: bool) -> Op {
        let capy = Op::Capy { w1, w2: if l { w2 } else { 0 }, long: l };
        if l {
            // (Capybara tests the branch forms first: with w2 bit 15 set it is a branch)
            if ((w1 & 0xFBF0) == 0xF240 || (w1 & 0xFBF0) == 0xF2C0) && (w2 & 0x8000) == 0 {
                let rd = ((w2 >> 8) & 0xF) as u8;
                let imm = ((w1 & 0xF) as u32) << 12 | (((w1 >> 10) & 1) as u32) << 11 | (((w2 >> 12) & 7) as u32) << 8 | (w2 & 0xFF) as u32;
                if rd >= 13 {
                    return capy;
                }
                return if (w1 & 0x0080) != 0 { Op::MovT { rd, imm } } else { Op::MovW { rd, imm } };
            }
            match w1 >> 8 {
                0xF8 | 0xF9 => return Op::Xfer32 { w1, w2 },
                0xEA | 0xEB => {
                    let op = ((w1 >> 5) & 0xF) as u8;
                    if !matches!(op, 0 | 1 | 2 | 3 | 4 | 8 | 10 | 11 | 13 | 14) {
                        return capy;
                    }
                    let amount = ((((w2 >> 12) & 7) << 2) | ((w2 >> 6) & 3)) as u32;
                    return Op::Dp32 {
                        op,
                        s: (w1 & 0x10) != 0,
                        rn: (w1 & 0xF) as u8,
                        rd: ((w2 >> 8) & 0xF) as u8,
                        src: Src::Reg { rm: (w2 & 0xF) as u8, amount, kind: ((w2 >> 4) & 3) as u32 },
                    };
                }
                0xE8 | 0xE9 => return capy,
                _ => {}
            }
            if (w1 & 0xF800) == 0xF000 && (w2 & 0xD000) == 0xD000 {
                let s = ((w1 >> 10) & 1) as u32;
                let j1 = ((w2 >> 13) & 1) as u32;
                let j2 = ((w2 >> 11) & 1) as u32;
                let i1 = !(j1 ^ s) & 1;
                let i2 = !(j2 ^ s) & 1;
                let mut imm25 = (s << 24) | (i1 << 23) | (i2 << 22) | (((w1 & 0x3FF) as u32) << 12) | (((w2 & 0x7FF) as u32) << 1);
                if (imm25 & 0x0100_0000) != 0 {
                    imm25 |= 0xFE00_0000;
                }
                let ret = at.wrapping_add(4);
                return Op::Bl { target: (ret as i32).wrapping_add(imm25 as i32) as u32, lr: ret | 1 };
            }
            // (branches, MOVW/MOVT, hints, ADDW/SUBW, multiplies, bit fields... come first in
            // Capybara; none of them has w1 & 0xFA00 == 0xF000 with w2 bit 15 clear)
            if (w1 & 0xFA00) == 0xF000 && (w2 & 0x8000) == 0 {
                let op = ((w1 >> 5) & 0xF) as u8;
                if !matches!(op, 0 | 1 | 2 | 3 | 4 | 8 | 10 | 11 | 13 | 14) {
                    return capy;
                }
                let imm12 = ((((w1 >> 10) & 1) as u32) << 11) | ((((w2 >> 12) & 7) as u32) << 8) | (w2 & 0xFF) as u32;
                let src = if imm12 & 0xC00 == 0 {
                    let imm8 = imm12 & 0xFF;
                    Src::ImmKeep(match (imm12 >> 8) & 3 {
                        0 => imm8,
                        1 => (imm8 << 16) | imm8,
                        2 => (imm8 << 24) | (imm8 << 8),
                        _ => imm8 * 0x0101_0101,
                    })
                } else {
                    let v = (0x80 | (imm12 & 0x7F)).rotate_right((imm12 >> 7) & 0x1F);
                    Src::ImmCarry(v, (v & 0x8000_0000) != 0)
                };
                return Op::Dp32 { op, s: (w1 & 0x10) != 0, rn: (w1 & 0xF) as u8, rd: ((w2 >> 8) & 0xF) as u8, src };
            }
            return capy;
        }
        let w = w1;
        match w >> 12 {
            0x0 | 0x1 if (w >> 11) & 3 != 3 => {
                Op::ShiftImm { op: ((w >> 11) & 3) as u8, rd: (w & 7) as u8, rm: ((w >> 3) & 7) as u8, imm5: ((w >> 6) & 0x1F) as u32 }
            }
            0x4 if (w & 0x0C00) == 0x0000 => Op::Alu { op: ((w >> 6) & 0xF) as u8, rdn: (w & 7) as u8, rm: ((w >> 3) & 7) as u8 },
            0x4 if (w & 0x0C00) == 0x0400 => {
                let h1 = (w >> 7) & 1;
                let h2 = (w >> 6) & 1;
                Op::HiReg {
                    op: ((w >> 8) & 3) as u8,
                    rdn: ((w & 7) | (h1 << 3)) as u8,
                    rm: (((w >> 3) & 7) | (h2 << 3)) as u8,
                    blx: (w & 0x0080) != 0,
                }
            }
            0x5 => Op::LdStReg { op: ((w >> 9) & 7) as u8, rd: (w & 7) as u8, rn: ((w >> 3) & 7) as u8, rm: ((w >> 6) & 7) as u8 },
            0x8 => Op::LdStHalf { ld: (w & 0x0800) != 0, rd: (w & 7) as u8, rn: ((w >> 3) & 7) as u8, imm: (((w >> 6) & 0x1F) as u32) * 2 },
            0x1 if (w & 0x1800) == 0x1800 => {
                // ADDS / SUBS three registers or imm3 (exec_add_sub)
                let rn = ((w >> 3) & 7) as u8;
                let rd = (w & 7) as u8;
                let imm = if (w & 0x0400) != 0 { Some(((w >> 6) & 7) as u32) } else { None };
                Op::AddSub3 { sub: (w & 0x0200) != 0, rd, rn, rm: ((w >> 6) & 7) as u8, imm }
            }
            0x2 | 0x3 => Op::Imm8 { op: ((w >> 11) & 3) as u8, rd: ((w >> 8) & 7) as u8, imm: (w & 0xFF) as u32 },
            0x4 if (w & 0x0800) != 0 => {
                let rd = ((w >> 8) & 7) as u8;
                // the pc seen by the instruction: address + 4, word aligned
                let addr = ((at + 4) & !3) + ((w & 0xFF) as u32) * 4;
                if addr >= 0x1000_0000 {
                    if let Some(b) = Self::code_bytes(m, addr, 4) {
                        return Op::LdrConst { rd, val: u32::from_le_bytes([b[0], b[1], b[2], b[3]]) };
                    }
                    return capy;
                }
                Op::LdrLit { rd, addr }
            }
            0x6 | 0x7 => {
                let byte = (w & 0x1000) != 0;
                let imm5 = ((w >> 6) & 0x1F) as u32;
                Op::LdStImm { ld: (w & 0x0800) != 0, byte, rd: (w & 7) as u8, rn: ((w >> 3) & 7) as u8, imm: if byte { imm5 } else { imm5 * 4 } }
            }
            0x9 => Op::LdStSp { ld: (w & 0x0800) != 0, rd: ((w >> 8) & 7) as u8, imm: ((w & 0xFF) as u32) * 4 },
            0xA => {
                let rd = ((w >> 8) & 7) as u8;
                let imm = ((w & 0xFF) as u32) * 4;
                if (w & 0x0800) != 0 { Op::AddSp { rd, imm } } else { Op::Const1 { rd, val: ((at + 4) & !3) + imm } }
            }
            0xB if (w & 0xFF00) == 0xB000 => Op::AdjSp { sub: (w & 0x0080) != 0, imm: ((w & 0x7F) as u32) * 4 },
            0xB if (w & 0xFF0F) == 0xBF00 => Op::Nop,
            0xD if ((w >> 8) & 0xF) < 0xE => {
                let imm8 = (w & 0xFF) as i8 as i32;
                Op::Bcc { cond: (w >> 8) & 0xF, target: (at as i32 + 4 + imm8 * 2) as u32 }
            }
            0xE if (w & 0x0800) == 0 => {
                let mut imm11 = (w & 0x07FF) as i32;
                if (imm11 & 0x0400) != 0 {
                    imm11 |= !0x07FF;
                }
                Op::B { target: (at as i32 + 4 + imm11 * 2) as u32 }
            }
            _ => capy,
        }
    }

    /// Runs one native operation (pc already moved past it). The cycles it took.
    #[inline(always)]
    pub(crate) fn native(op: &Op, m: &mut Machine) -> u32 {
        let r = &mut m.cpu.regs;
        match *op {
            Op::Imm8 { op, rd, imm } => {
                let v = r.r[rd as usize];
                match op {
                    0 => {
                        r.r[rd as usize] = imm;
                        r.set_nz(imm);
                    }
                    1 => {
                        let (res, borrow) = v.overflowing_sub(imm);
                        nzcv(r, res, !borrow, ((v ^ imm) & (v ^ res) & 0x8000_0000) != 0);
                    }
                    2 => {
                        let (res, carry) = v.overflowing_add(imm);
                        r.r[rd as usize] = res;
                        nzcv(r, res, carry, (!(v ^ imm) & (v ^ res) & 0x8000_0000) != 0);
                    }
                    _ => {
                        let (res, borrow) = v.overflowing_sub(imm);
                        r.r[rd as usize] = res;
                        nzcv(r, res, !borrow, ((v ^ imm) & (v ^ res) & 0x8000_0000) != 0);
                    }
                }
                1
            }
            Op::AddSub3 { sub, rd, rn, rm, imm } => {
                let a = r.r[rn as usize];
                let b = imm.unwrap_or(r.r[rm as usize]);
                if sub {
                    let (res, borrow) = a.overflowing_sub(b);
                    r.r[rd as usize] = res;
                    nzcv(r, res, !borrow, ((a ^ b) & (a ^ res) & 0x8000_0000) != 0);
                } else {
                    let (res, carry) = a.overflowing_add(b);
                    r.r[rd as usize] = res;
                    nzcv(r, res, carry, (!(a ^ b) & (a ^ res) & 0x8000_0000) != 0);
                }
                1
            }
            Op::LdrConst { rd, val } => {
                r.r[rd as usize] = val;
                2
            }
            Op::LdrLit { rd, addr } => {
                let v = m.bus.read_u32(addr, &mut m.periph, &m.cpu.nvic);
                m.cpu.regs.r[rd as usize] = v;
                2
            }
            Op::LdStImm { ld, byte, rd, rn, imm } => {
                let addr = r.r[rn as usize].wrapping_add(imm);
                match (ld, byte) {
                    (true, false) => {
                        let v = m.bus.read_u32(addr, &mut m.periph, &m.cpu.nvic);
                        m.cpu.regs.r[rd as usize] = v;
                    }
                    (true, true) => {
                        let v = m.bus.read_u8(addr, &mut m.periph, &m.cpu.nvic) as u32;
                        m.cpu.regs.r[rd as usize] = v;
                    }
                    (false, false) => {
                        let v = r.r[rd as usize];
                        m.bus.write_u32(addr, v, &mut m.periph, &mut m.cpu.nvic);
                    }
                    (false, true) => {
                        let v = r.r[rd as usize] as u8;
                        m.bus.write_u8(addr, v, &mut m.periph, &mut m.cpu.nvic);
                    }
                }
                2
            }
            Op::LdStSp { ld, rd, imm } => {
                let addr = r.get_sp().wrapping_add(imm);
                if ld {
                    let v = m.bus.read_u32(addr, &mut m.periph, &m.cpu.nvic);
                    m.cpu.regs.r[rd as usize] = v;
                } else {
                    let v = r.r[rd as usize];
                    m.bus.write_u32(addr, v, &mut m.periph, &mut m.cpu.nvic);
                }
                2
            }
            Op::AddSp { rd, imm } => {
                r.r[rd as usize] = r.get_sp().wrapping_add(imm);
                1
            }
            Op::Const1 { rd, val } => {
                r.r[rd as usize] = val;
                1
            }
            Op::AdjSp { sub, imm } => {
                let sp = r.get_sp();
                r.set_sp(if sub { sp.wrapping_sub(imm) } else { sp.wrapping_add(imm) });
                1
            }
            Op::Nop => 1,
            Op::Bcc { cond, target } => {
                if Thumb16::eval_condition(cond, r) {
                    r.pc = target;
                    2
                } else {
                    1
                }
            }
            Op::B { target } => {
                r.pc = target;
                2
            }
            Op::MovW { rd, imm } => {
                r.r[rd as usize] = imm;
                1
            }
            Op::MovT { rd, imm } => {
                r.r[rd as usize] = (r.r[rd as usize] & 0xFFFF) | (imm << 16);
                1
            }
            Op::ShiftImm { op, rd, rm, imm5 } => {
                let v = r.r[rm as usize];
                let res = match op {
                    0 => {
                        if imm5 == 0 {
                            v
                        } else {
                            r.set_flag_c((v & (1 << (32 - imm5))) != 0);
                            v << imm5
                        }
                    }
                    1 => {
                        let sh = if imm5 == 0 { 32 } else { imm5 };
                        r.set_flag_c((v & (1 << (sh - 1))) != 0);
                        if sh >= 32 { 0 } else { v >> sh }
                    }
                    _ => {
                        let sh = if imm5 == 0 { 32 } else { imm5 };
                        r.set_flag_c((v & (1 << (sh - 1))) != 0);
                        let si = v as i32;
                        if sh >= 32 {
                            if si < 0 { 0xFFFF_FFFF } else { 0 }
                        } else {
                            (si >> sh) as u32
                        }
                    }
                };
                r.r[rd as usize] = res;
                r.set_nz(res);
                1
            }
            Op::Alu { op, rdn, rm } => {
                let vm = r.r[rm as usize];
                let vd = r.r[rdn as usize];
                let cin = r.flag_c();
                let mut c = cin;
                let mut v = r.flag_v();
                let mut wb = true;
                let res = match op {
                    0 => vd & vm,
                    1 => vd ^ vm,
                    2 | 3 | 4 | 7 => {
                        let kind = match op { 2 => 0, 3 => 1, 4 => 2, _ => 3 };
                        let (x, cc) = shift_by_reg(vd, vm & 0xFF, kind, cin);
                        c = cc;
                        x
                    }
                    5 => {
                        let (x, cc, o) = add_with_carry(vd, vm, cin);
                        c = cc;
                        v = o;
                        x
                    }
                    6 => {
                        let (x, cc, o) = add_with_carry(vd, !vm, cin);
                        c = cc;
                        v = o;
                        x
                    }
                    8 => {
                        wb = false;
                        vd & vm
                    }
                    9 => {
                        let (x, cc, o) = add_with_carry(!vm, 0, true);
                        c = cc;
                        v = o;
                        x
                    }
                    10 => {
                        wb = false;
                        let (x, cc, o) = add_with_carry(vd, !vm, true);
                        c = cc;
                        v = o;
                        x
                    }
                    11 => {
                        wb = false;
                        let (x, cc, o) = add_with_carry(vd, vm, false);
                        c = cc;
                        v = o;
                        x
                    }
                    12 => vd | vm,
                    13 => vd.wrapping_mul(vm),
                    14 => vd & !vm,
                    _ => !vm,
                };
                if wb {
                    r.r[rdn as usize] = res;
                }
                nzcv(r, res, c, v);
                1
            }
            Op::HiReg { op, rdn, rm, blx } => {
                let read = |r: &crate::emulator::cpu::registers::Registers, x: u8| if x == 15 { r.pc.wrapping_add(2) } else { r.get_reg(x) };
                let vm = read(r, rm);
                match op {
                    0 => {
                        let vd = read(r, rdn);
                        r.set_reg(rdn, vd.wrapping_add(vm));
                        1
                    }
                    1 => {
                        let vd = read(r, rdn);
                        let (res, borrow) = vd.overflowing_sub(vm);
                        nzcv(r, res, !borrow, ((vd ^ vm) & (vd ^ res) & 0x8000_0000) != 0);
                        1
                    }
                    2 => {
                        r.set_reg(rdn, vm);
                        1
                    }
                    _ => {
                        if blx {
                            r.lr = r.pc | 1;
                        }
                        r.pc = vm & !1;
                        2
                    }
                }
            }
            Op::LdStReg { op, rd, rn, rm } => {
                let addr = r.r[rn as usize].wrapping_add(r.r[rm as usize]);
                let vd = r.r[rd as usize];
                let (bus, periph, nvic) = (&mut m.bus, &mut m.periph, &mut m.cpu.nvic);
                let load = match op {
                    0 => {
                        bus.write_u32(addr, vd, periph, nvic);
                        None
                    }
                    1 => {
                        bus.write_u16(addr, vd as u16, periph, nvic);
                        None
                    }
                    2 => {
                        bus.write_u8(addr, vd as u8, periph, nvic);
                        None
                    }
                    4 => Some(bus.read_u32(addr, periph, nvic)),
                    5 => Some(bus.read_u16(addr, periph, nvic) as u32),
                    6 => Some(bus.read_u8(addr, periph, nvic) as u32),
                    3 => Some(bus.read_u8(addr, periph, nvic) as i8 as i32 as u32),
                    _ => Some(bus.read_u16(addr, periph, nvic) as i16 as i32 as u32),
                };
                if let Some(v) = load {
                    m.cpu.regs.r[rd as usize] = v;
                }
                2
            }
            Op::LdStHalf { ld, rd, rn, imm } => {
                let addr = r.r[rn as usize].wrapping_add(imm);
                if ld {
                    let v = m.bus.read_u16(addr, &mut m.periph, &m.cpu.nvic) as u32;
                    m.cpu.regs.r[rd as usize] = v;
                } else {
                    let v = r.r[rd as usize] as u16;
                    m.bus.write_u16(addr, v, &mut m.periph, &mut m.cpu.nvic);
                }
                2
            }
            Op::Dp32 { op, s, rn, rd, src } => {
                let vn = if rn == 0xF { 0 } else { r.get_reg(rn) };
                let cin = r.flag_c();
                let (v2, sc) = match src {
                    Src::ImmKeep(v) => (v, cin),
                    Src::ImmCarry(v, c) => (v, c),
                    Src::Reg { rm, amount, kind } => shift_c(r.get_reg(rm), amount, kind, cin),
                };
                let mut c = sc;
                let mut v = r.flag_v();
                let res = match op {
                    0 => vn & v2,
                    1 => vn & !v2,
                    2 => vn | v2,
                    3 => vn | !v2,
                    4 => vn ^ v2,
                    8 => {
                        let (x, cc, o) = add_with_carry(vn, v2, false);
                        c = cc;
                        v = o;
                        x
                    }
                    10 => {
                        let (x, cc, o) = add_with_carry(vn, v2, cin);
                        c = cc;
                        v = o;
                        x
                    }
                    11 => {
                        let (x, cc, o) = add_with_carry(vn, !v2, cin);
                        c = cc;
                        v = o;
                        x
                    }
                    13 => {
                        let (x, cc, o) = add_with_carry(vn, !v2, true);
                        c = cc;
                        v = o;
                        x
                    }
                    _ => {
                        let (x, cc, o) = add_with_carry(!vn, v2, true);
                        c = cc;
                        v = o;
                        x
                    }
                };
                if !(rd == 0xF && matches!(op, 0 | 4 | 8 | 13)) {
                    r.set_reg(rd, res);
                }
                if s {
                    nzcv(r, res, c, v);
                }
                1
            }
            Op::Xfer32 { w1, w2 } => {
                let is_ldr = (w1 & 0x0010) != 0;
                let size = (w1 >> 5) & 3;
                let signed = (w1 & 0x0100) != 0;
                let rn = (w1 & 0xF) as u8;
                let rd = ((w2 >> 12) & 0xF) as u8;
                let base = if rn == 0xF { r.pc & !3 } else { r.get_reg(rn) };
                let mut wbk: Option<(u8, u32)> = None;
                let addr = if (w1 & 0x0080) != 0 {
                    base.wrapping_add((w2 & 0x0FFF) as u32)
                } else if (w2 & 0x0800) != 0 {
                    let imm8 = (w2 & 0xFF) as u32;
                    let off = if (w2 & 0x0200) != 0 { base.wrapping_add(imm8) } else { base.wrapping_sub(imm8) };
                    if (w2 & 0x0100) != 0 && rn != 0xF {
                        wbk = Some((rn, off));
                    }
                    if (w2 & 0x0400) != 0 { off } else { base }
                } else {
                    base.wrapping_add(r.get_reg((w2 & 0xF) as u8) << ((w2 >> 4) & 3))
                };
                let vd = r.get_reg(rd);
                let (bus, periph, nvic) = (&mut m.bus, &mut m.periph, &mut m.cpu.nvic);
                if is_ldr {
                    let v = match (size, signed) {
                        (0, false) => bus.read_u8(addr, periph, nvic) as u32,
                        (0, true) => bus.read_u8(addr, periph, nvic) as i8 as i32 as u32,
                        (1, false) => bus.read_u16(addr, periph, nvic) as u32,
                        (1, true) => bus.read_u16(addr, periph, nvic) as i16 as i32 as u32,
                        _ => bus.read_u32(addr, periph, nvic),
                    };
                    m.cpu.regs.set_reg(rd, v);
                } else {
                    match size {
                        0 => bus.write_u8(addr, vd as u8, periph, nvic),
                        1 => bus.write_u16(addr, vd as u16, periph, nvic),
                        _ => bus.write_u32(addr, vd, periph, nvic),
                    }
                }
                if let Some((x, v)) = wbk {
                    m.cpu.regs.set_reg(x, v);
                }
                2
            }
            Op::Bl { target, lr } => {
                r.lr = lr;
                r.pc = target;
                3
            }
            Op::Capy { .. } => 0,
        }
    }

    /// Runs blocks from the current pc for up to `budget` instructions (fewer when something
    /// needs the interpreter). `service` gives elapsed cycles to the peripherals. Returns the
    /// instructions done and why it stopped.
    pub fn run(&mut self, m: &mut Machine, budget: u32, stop_at: u32, service: &mut dyn FnMut(&mut Machine, u32)) -> (u32, Exit) {
        let xip = m.periph.xip.flash_offset(0) as u32;
        if xip != self.xip {
            self.clear();
            self.xip = xip;
        }
        let mut done = 0u32;
        while done < budget {
            let pc = m.cpu.regs.pc;
            if pc >= 0xFFFF_FFF0 || pc == 0 || pc == stop_at || m.cpu.regs.itstate & 0x0F != 0 || m.periph.snsys.reveil_demande {
                return (done, Exit::Slow);
            }
            if m.cpu.nvic.en_attente && m.cpu.regs.mode == Mode::Thread && m.cpu.regs.primask == 0 {
                return (done, Exit::Slow);
            }
            let Some(slot) = Self::slot(pc) else { return (done, Exit::Slow) };
            let mut ix = self.slots[slot];
            if ix != 0 && pc < 0x1_0000 {
                // PRAM: the firmware may have written new code here
                // (the first and last bytes: code copied over a block changes them)
                let b = &self.blocks[ix as usize - 1];
                let n = b.bytes.len();
                let k = n.min(8);
                let p = &m.bus.pram.data;
                let at = pc as usize;
                if p.get(at..at + k) != Some(&b.bytes[..k]) || p.get(at + n - k..at + n) != Some(&b.bytes[n - k..]) {
                    ix = 0;
                }
            }
            if ix == 0 {
                let Some(b) = Self::build(m, pc) else { return (done, Exit::Slow) };
                self.blocks.push(b);
                ix = self.blocks.len() as u32;
                self.slots[slot] = ix;
                self.built += 1;
            }
            let block = &self.blocks[ix as usize - 1];
            self.ran += 1;
            // Within a block only branches move the pc elsewhere and only stores (and Capybara's
            // own forms) can raise an interrupt: those are the only places worth a look.
            // Cycles are summed and given to the peripherals at the end of the block.
            let mut next = pc;
            let mut cyc = 0u32;
            let mut stop = false;
            for (op, n, f) in &block.ops {
                let (n, f) = (*n as u32, *f);
                next = next.wrapping_add(n);
                m.cpu.regs.pc = next;
                #[cfg(feature = "stats")]
                if let Op::Capy { w1, .. } = *op {
                    let k = if long(w1) { w1 & 0xFFF0 } else { w1 & 0xFFC0 };
                    *self.stats.entry(k).or_default() += 1;
                } else {
                    *self.stats.entry(0).or_default() += 1;
                }
                let c = match *op {
                    Op::Capy { w1, w2, long } => {
                        let r = if long {
                            Thumb32::execute(w1, w2, &mut m.cpu.regs, &mut m.bus, &mut m.periph, &mut m.cpu.nvic)
                        } else {
                            Thumb16::execute(w1, &mut m.cpu.regs, &mut m.bus, &mut m.periph, &mut m.cpu.nvic)
                        };
                        match r {
                            StepResult::Ok(c) => c as u32,
                            StepResult::Halt => {
                                m.cpu.is_halted = true;
                                m.cpu.cycles += cyc as u64;
                                return (done, Exit::Stopped);
                            }
                            _ => {
                                m.cpu.cycles += cyc as u64;
                                return (done, Exit::Stopped);
                            }
                        }
                    }
                    _ => Self::native(op, m),
                };
                cyc += c;
                done += 1;
                if f & SIDE != 0 {
                    if m.periph.dma.irq_a_lever {
                        m.periph.dma.irq_a_lever = false;
                        m.cpu.nvic.request_irq(crate::emulator::peripherals::dma::IRQ);
                    }
                    // an interrupt raised by this instruction, or an IT block starting: hand over
                    if m.cpu.regs.itstate & 0x0F != 0 || (m.cpu.nvic.en_attente && m.cpu.regs.mode == Mode::Thread && m.cpu.regs.primask == 0) {
                        stop = true;
                    }
                }
                if stop || (f & BR != 0 && m.cpu.regs.pc != next) {
                    break;
                }
            }
            m.cpu.cycles += cyc as u64;
            self.pending += cyc;
            if self.pending >= 256 {
                let e = self.pending;
                self.pending = 0;
                service(m, e);
            }
        }
        (done, Exit::Ok)
    }
}

/// Debugging: runs one instruction both ways (the native operation, then Capybara's step from
/// the same registers) and reports a difference. Stores are written twice with the same value.
pub fn verify_step(m: &mut Machine) -> Option<String> {
    let pc = m.cpu.regs.pc;
    let ok_here = m.cpu.regs.itstate & 0x0F == 0 && !m.cpu.nvic.en_attente && !m.periph.snsys.reveil_demande && pc < 0xFFFF_FFF0 && pc != 0;
    let b = Recomp::code_bytes(m, pc, 4).map(|b| b.to_vec());
    let (Some(b), true) = (b, ok_here) else {
        m.step();
        return None;
    };
    let w1 = u16::from_le_bytes([b[0], b[1]]);
    let w2 = u16::from_le_bytes([b[2], b[3]]);
    let op = Recomp::decode(m, pc, w1, w2, long(w1));
    if let Op::Capy { .. } = op {
        m.step();
        return None;
    }
    // loads from peripherals could change them: not run twice
    if let Op::LdStImm { ld: true, rn, imm, .. } = op {
        let a = m.cpu.regs.r[rn as usize].wrapping_add(imm);
        if a >= 0x4000_0000 {
            m.step();
            return None;
        }
    }
    let saved = m.cpu.regs.clone();
    m.cpu.regs.pc = pc.wrapping_add(op.len());
    let c = Recomp::native(&op, m);
    let nat = m.cpu.regs.clone();
    m.cpu.regs = saved;
    let r = m.step();
    let capy_c = if let StepResult::Ok(c) = r { c as u32 } else { 999 };
    let g = &m.cpu.regs;
    if g.r != nat.r || g.get_sp() != nat.get_sp() || g.lr != nat.lr || g.pc != nat.pc || g.xpsr != nat.xpsr || capy_c != c {
        return Some(format!(
            "pc {:08X} w {:04X} {:04X}: native pc {:08X} xpsr {:08X} r {:X?} c {} / capybara pc {:08X} xpsr {:08X} r {:X?} c {}",
            pc, w1, w2, nat.pc, nat.xpsr, nat.r, c, g.pc, g.xpsr, g.r, capy_c
        ));
    }
    None
}

// The helpers of Capybara's executors (cpu/thumb16.rs, cpu/thumb32.rs), the same arithmetic.
fn add_with_carry(a: u32, b: u32, carry_in: bool) -> (u32, bool, bool) {
    let (s1, c1) = a.overflowing_add(b);
    let (res, c2) = s1.overflowing_add(carry_in as u32);
    (res, c1 || c2, ((a ^ res) & (b ^ res) & 0x8000_0000) != 0)
}

fn shift_by_reg(val: u32, amount: u32, kind: u32, carry_in: bool) -> (u32, bool) {
    if amount == 0 {
        return (val, carry_in);
    }
    match kind {
        0 => match amount {
            n if n < 32 => (val << n, (val >> (32 - n)) & 1 != 0),
            32 => (0, val & 1 != 0),
            _ => (0, false),
        },
        1 => match amount {
            n if n < 32 => (val >> n, (val >> (n - 1)) & 1 != 0),
            32 => (0, (val >> 31) & 1 != 0),
            _ => (0, false),
        },
        2 => {
            if amount < 32 {
                (((val as i32) >> amount) as u32, (val >> (amount - 1)) & 1 != 0)
            } else {
                (((val as i32) >> 31) as u32, (val >> 31) & 1 != 0)
            }
        }
        _ => {
            let n = amount % 32;
            if n == 0 {
                (val, (val >> 31) & 1 != 0)
            } else {
                let v = val.rotate_right(n);
                (v, (v >> 31) & 1 != 0)
            }
        }
    }
}

fn shift_c(rm: u32, shift: u32, kind: u32, carry_in: bool) -> (u32, bool) {
    match kind {
        0 => {
            if shift == 0 {
                (rm, carry_in)
            } else {
                (rm << shift, (rm >> (32 - shift)) & 1 != 0)
            }
        }
        1 => {
            let s = if shift == 0 { 32 } else { shift };
            if s == 32 {
                (0, (rm >> 31) & 1 != 0)
            } else {
                (rm >> s, (rm >> (s - 1)) & 1 != 0)
            }
        }
        2 => {
            let s = if shift == 0 { 32 } else { shift };
            if s >= 32 {
                (((rm as i32) >> 31) as u32, (rm >> 31) & 1 != 0)
            } else {
                (((rm as i32) >> s) as u32, (rm >> (s - 1)) & 1 != 0)
            }
        }
        _ => {
            if shift == 0 {
                (((carry_in as u32) << 31) | (rm >> 1), rm & 1 != 0)
            } else {
                let v = rm.rotate_right(shift);
                (v, (v >> 31) & 1 != 0)
            }
        }
    }
}

/// N, Z, C and V at once (what set_nz, set_flag_c and set_flag_v do one by one).
#[inline(always)]
fn nzcv(r: &mut crate::emulator::cpu::registers::Registers, res: u32, c: bool, v: bool) {
    r.xpsr = (r.xpsr & 0x0FFF_FFFF) | (res & 0x8000_0000) | (((res == 0) as u32) << 30) | ((c as u32) << 29) | ((v as u32) << 28);
}
