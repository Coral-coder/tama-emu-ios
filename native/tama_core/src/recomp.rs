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

#[derive(Clone, Copy)]
struct Op {
    w1: u16,
    w2: u16,
    long: bool,
}

struct Block {
    ops: Vec<Op>,
    /// The bytes the block was built from (checked again for PRAM, which the firmware fills).
    bytes: Vec<u8>,
}

const MAX_OPS: usize = 32;

/// Block index + 1 for every halfword address of PRAM (64 KB) and the XIP window (1 MB).
const PRAM_SLOTS: usize = 0x1_0000 / 2;
const XIP_SLOTS: usize = 0x10_0000 / 2;

pub struct Recomp {
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
        Self { blocks: Vec::new(), slots: vec![0; PRAM_SLOTS + XIP_SLOTS], xip: 0, pending: 0, built: 0, ran: 0 }
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
            ops.push(Op { w1, w2: if l { w2 } else { 0 }, long: l });
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
                let b = &self.blocks[ix as usize - 1];
                if Self::code_bytes(m, pc, b.bytes.len()) != Some(&b.bytes[..]) {
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
            let mut expect = pc;
            for op in &block.ops {
                if m.cpu.regs.pc != expect || done >= budget {
                    break;
                }
                let regs = &mut m.cpu.regs;
                let r = if op.long {
                    regs.pc = regs.pc.wrapping_add(4);
                    Thumb32::execute(op.w1, op.w2, regs, &mut m.bus, &mut m.periph, &mut m.cpu.nvic)
                } else {
                    regs.pc = regs.pc.wrapping_add(2);
                    Thumb16::execute(op.w1, regs, &mut m.bus, &mut m.periph, &mut m.cpu.nvic)
                };
                expect = expect.wrapping_add(if op.long { 4 } else { 2 });
                done += 1;
                match r {
                    StepResult::Ok(c) => {
                        m.cpu.cycles += c as u64;
                        if m.periph.dma.irq_a_lever {
                            m.periph.dma.irq_a_lever = false;
                            m.cpu.nvic.request_irq(crate::emulator::peripherals::dma::IRQ);
                        }
                        self.pending += c as u32;
                        if self.pending >= 256 {
                            let e = self.pending;
                            self.pending = 0;
                            service(m, e);
                        }
                    }
                    StepResult::Halt => {
                        m.cpu.is_halted = true;
                        return (done, Exit::Stopped);
                    }
                    _ => return (done, Exit::Stopped),
                }
                // an interrupt raised by this instruction, or an IT block starting: hand over
                if m.cpu.regs.itstate & 0x0F != 0 || (m.cpu.nvic.en_attente && m.cpu.regs.mode == Mode::Thread && m.cpu.regs.primask == 0) {
                    break;
                }
            }
        }
        (done, Exit::Ok)
    }
}
