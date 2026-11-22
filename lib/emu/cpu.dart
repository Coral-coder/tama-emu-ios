// E0C6S46 / E0C6S48 CPU core.
//
// A Dart port of TamaLIB by Jean-Christophe Rona (GPL-2.0-or-later), in the form patched by
// mameise for Paramix Studio's V1Emu (decode table, key interrupt masks, one-shot buzzer, the
// halted-CPU interrupt fix). Timing is driven by the host: run until the 32768 Hz tick counter
// reaches a target instead of sleeping.
//
// This program is free software; you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation; either version 2 of the
// License, or (at your option) any later version.

import 'dart:typed_data';

const int kTickFrequency = 32768;
const int kOsc1Frequency = kTickFrequency;
const int kOsc3Frequency = 1000000;

const int _t2hz = kTickFrequency ~/ 2;
const int _t4hz = kTickFrequency ~/ 4;
const int _t8hz = kTickFrequency ~/ 8;
const int _t16hz = kTickFrequency ~/ 16;
const int _t32hz = kTickFrequency ~/ 32;
const int _t64hz = kTickFrequency ~/ 64;
const int _t128hz = kTickFrequency ~/ 128;
const int _t256hz = kTickFrequency ~/ 256;

// Memory map (E0C6S48 sizes, which cover the E0C6S46 too)
const int memRamSize = 0x300;
const int memDisp1Addr = 0xE00;
const int memDisp1Size = 0x066;
const int memDisp2Addr = 0xE80;
const int memDisp2Size = 0x066;
const int memIoAddr = 0xF00;
const int memIoSize = 0x080;

// I/O registers
const int regClkIntFactorFlags = 0xF00;
const int regSwIntFactorFlags = 0xF01;
const int regProgIntFactorFlags = 0xF02;
const int regSerialIntFactorFlags = 0xF03;
const int regK00K03IntFactorFlags = 0xF04;
const int regK10K13IntFactorFlags = 0xF05;
const int regClockIntMasks = 0xF10;
const int regSwIntMasks = 0xF11;
const int regProgIntMasks = 0xF12;
const int regSerialIntMasks = 0xF13;
const int regK00K03IntMasks = 0xF14;
const int regK10K13IntMasks = 0xF15;
const int regClockTimerData1 = 0xF20;
const int regClockTimerData2 = 0xF21;
const int regProgTimerDataL = 0xF24;
const int regProgTimerDataH = 0xF25;
const int regProgTimerReloadDataL = 0xF26;
const int regProgTimerReloadDataH = 0xF27;
const int regK00K03InputPort = 0xF40;
const int regK00K03InputRelation = 0xF41;
const int regK10K13InputPort = 0xF42;
const int regR40R43BzOutputPort = 0xF54;
const int regP20P23IoPort = 0xF62;
const int regCpuOsc3Ctrl = 0xF70;
const int regLcdCtrl = 0xF71;
const int regLcdContrast = 0xF72;
const int regSvdCtrl = 0xF73;
const int regBuzzerCtrl1 = 0xF74;
const int regBuzzerCtrl2 = 0xF75;
const int regClkWdTimerCtrl = 0xF76;
const int regSwTimerCtrl = 0xF77;
const int regProgTimerCtrl = 0xF78;
const int regProgTimerClkSel = 0xF79;
const int regIoCtrl = 0xF7D;

const int _flagC = 0x1;
const int _flagZ = 0x2;
const int _flagD = 0x4;
const int _flagI = 0x8;

// Interrupt slots, in priority order
const int intProgTimer = 0;
const int intSerial = 1;
const int intK10K13 = 2;
const int intK00K03 = 3;
const int intStopwatch = 4;
const int intClockTimer = 5;
const List<int> _intVectors = [0x0C, 0x0A, 0x08, 0x06, 0x04, 0x02];

/// Callbacks from the CPU to the rest of the toy (LCD segments, buzzer).
abstract class CpuHost {
  void setLcdPin(int seg, int com, bool on);
  void setBuzzerFreq(int code);
  void enableBuzzer(bool on);
  void buzzerShot(bool on);

  /// The contact line (P20) for linked toys; true when another toy pulls it low.
  bool linkLineLowFromPeer() => false;

  /// This toy's drive of P20 changed (low = true) at [tick].
  void linkDriveChanged(bool low, int tick) {}
}

// Op table: [code, mask, shiftArg0, maskArg0, cycles] in TamaLIB's order (the first match wins).
const List<List<int>> _ops = [
  [0xE40, 0xFE0, 0, 0, 5], // 0 PSET
  [0x000, 0xF00, 0, 0, 5], // 1 JP
  [0x200, 0xF00, 0, 0, 5], // 2 JP C
  [0x300, 0xF00, 0, 0, 5], // 3 JP NC
  [0x600, 0xF00, 0, 0, 5], // 4 JP Z
  [0x700, 0xF00, 0, 0, 5], // 5 JP NZ
  [0xFE8, 0xFFF, 0, 0, 5], // 6 JPBA
  [0x400, 0xF00, 0, 0, 7], // 7 CALL
  [0x500, 0xF00, 0, 0, 7], // 8 CALZ
  [0xFDF, 0xFFF, 0, 0, 7], // 9 RET
  [0xFDE, 0xFFF, 0, 0, 12], // 10 RETS
  [0x100, 0xF00, 0, 0, 12], // 11 RETD
  [0xFFB, 0xFFF, 0, 0, 5], // 12 NOP5
  [0xFFF, 0xFFF, 0, 0, 7], // 13 NOP7
  [0xFF8, 0xFFF, 0, 0, 5], // 14 HALT
  [0xEE0, 0xFFF, 0, 0, 5], // 15 INC X
  [0xEF0, 0xFFF, 0, 0, 5], // 16 INC Y
  [0xB00, 0xF00, 0, 0, 5], // 17 LD X
  [0x800, 0xF00, 0, 0, 5], // 18 LD Y
  [0xE80, 0xFFC, 0, 0, 5], // 19 LD XP,r
  [0xE84, 0xFFC, 0, 0, 5], // 20 LD XH,r
  [0xE88, 0xFFC, 0, 0, 5], // 21 LD XL,r
  [0xE90, 0xFFC, 0, 0, 5], // 22 LD YP,r
  [0xE94, 0xFFC, 0, 0, 5], // 23 LD YH,r
  [0xE98, 0xFFC, 0, 0, 5], // 24 LD YL,r
  [0xEA0, 0xFFC, 0, 0, 5], // 25 LD r,XP
  [0xEA4, 0xFFC, 0, 0, 5], // 26 LD r,XH
  [0xEA8, 0xFFC, 0, 0, 5], // 27 LD r,XL
  [0xEB0, 0xFFC, 0, 0, 5], // 28 LD r,YP
  [0xEB4, 0xFFC, 0, 0, 5], // 29 LD r,YH
  [0xEB8, 0xFFC, 0, 0, 5], // 30 LD r,YL
  [0xA00, 0xFF0, 0, 0, 7], // 31 ADC XH
  [0xA10, 0xFF0, 0, 0, 7], // 32 ADC XL
  [0xA20, 0xFF0, 0, 0, 7], // 33 ADC YH
  [0xA30, 0xFF0, 0, 0, 7], // 34 ADC YL
  [0xA40, 0xFF0, 0, 0, 7], // 35 CP XH
  [0xA50, 0xFF0, 0, 0, 7], // 36 CP XL
  [0xA60, 0xFF0, 0, 0, 7], // 37 CP YH
  [0xA70, 0xFF0, 0, 0, 7], // 38 CP YL
  [0xE00, 0xFC0, 4, 0x030, 5], // 39 LD r,i
  [0xEC0, 0xFF0, 2, 0x00C, 5], // 40 LD r,q
  [0xFA0, 0xFF0, 0, 0, 5], // 41 LD A,Mn
  [0xFB0, 0xFF0, 0, 0, 5], // 42 LD B,Mn
  [0xF80, 0xFF0, 0, 0, 5], // 43 LD Mn,A
  [0xF90, 0xFF0, 0, 0, 5], // 44 LD Mn,B
  [0xE60, 0xFF0, 0, 0, 5], // 45 LDPX MX,i
  [0xEE0, 0xFF0, 2, 0x00C, 5], // 46 LDPX r,q
  [0xE70, 0xFF0, 0, 0, 5], // 47 LDPY MY,i
  [0xEF0, 0xFF0, 2, 0x00C, 5], // 48 LDPY r,q
  [0x900, 0xF00, 0, 0, 5], // 49 LBPX
  [0xF40, 0xFF0, 0, 0, 7], // 50 SET
  [0xF50, 0xFF0, 0, 0, 7], // 51 RST
  [0xF41, 0xFFF, 0, 0, 7], // 52 SCF
  [0xF5E, 0xFFF, 0, 0, 7], // 53 RCF
  [0xF42, 0xFFF, 0, 0, 7], // 54 SZF
  [0xF5D, 0xFFF, 0, 0, 7], // 55 RZF
  [0xF44, 0xFFF, 0, 0, 7], // 56 SDF
  [0xF5B, 0xFFF, 0, 0, 7], // 57 RDF
  [0xF48, 0xFFF, 0, 0, 7], // 58 EI
  [0xF57, 0xFFF, 0, 0, 7], // 59 DI
  [0xFDB, 0xFFF, 0, 0, 5], // 60 INC SP
  [0xFCB, 0xFFF, 0, 0, 5], // 61 DEC SP
  [0xFC0, 0xFFC, 0, 0, 5], // 62 PUSH r
  [0xFC4, 0xFFF, 0, 0, 5], // 63 PUSH XP
  [0xFC5, 0xFFF, 0, 0, 5], // 64 PUSH XH
  [0xFC6, 0xFFF, 0, 0, 5], // 65 PUSH XL
  [0xFC7, 0xFFF, 0, 0, 5], // 66 PUSH YP
  [0xFC8, 0xFFF, 0, 0, 5], // 67 PUSH YH
  [0xFC9, 0xFFF, 0, 0, 5], // 68 PUSH YL
  [0xFCA, 0xFFF, 0, 0, 5], // 69 PUSH F
  [0xFD0, 0xFFC, 0, 0, 5], // 70 POP r
  [0xFD4, 0xFFF, 0, 0, 5], // 71 POP XP
  [0xFD5, 0xFFF, 0, 0, 5], // 72 POP XH
  [0xFD6, 0xFFF, 0, 0, 5], // 73 POP XL
  [0xFD7, 0xFFF, 0, 0, 5], // 74 POP YP
  [0xFD8, 0xFFF, 0, 0, 5], // 75 POP YH
  [0xFD9, 0xFFF, 0, 0, 5], // 76 POP YL
  [0xFDA, 0xFFF, 0, 0, 5], // 77 POP F
  [0xFE0, 0xFFC, 0, 0, 5], // 78 LD SPH,r
  [0xFF0, 0xFFC, 0, 0, 5], // 79 LD SPL,r
  [0xFE4, 0xFFC, 0, 0, 5], // 80 LD r,SPH
  [0xFF4, 0xFFC, 0, 0, 5], // 81 LD r,SPL
  [0xC00, 0xFC0, 4, 0x030, 7], // 82 ADD r,i
  [0xA80, 0xFF0, 2, 0x00C, 7], // 83 ADD r,q
  [0xC40, 0xFC0, 4, 0x030, 7], // 84 ADC r,i
  [0xA90, 0xFF0, 2, 0x00C, 7], // 85 ADC r,q
  [0xAA0, 0xFF0, 2, 0x00C, 7], // 86 SUB r,q
  [0xD40, 0xFC0, 4, 0x030, 7], // 87 SBC r,i
  [0xAB0, 0xFF0, 2, 0x00C, 7], // 88 SBC r,q
  [0xC80, 0xFC0, 4, 0x030, 7], // 89 AND r,i
  [0xAC0, 0xFF0, 2, 0x00C, 7], // 90 AND r,q
  [0xCC0, 0xFC0, 4, 0x030, 7], // 91 OR r,i
  [0xAD0, 0xFF0, 2, 0x00C, 7], // 92 OR r,q
  [0xD00, 0xFC0, 4, 0x030, 7], // 93 XOR r,i
  [0xAE0, 0xFF0, 2, 0x00C, 7], // 94 XOR r,q
  [0xDC0, 0xFC0, 4, 0x030, 7], // 95 CP r,i
  [0xF00, 0xFF0, 2, 0x00C, 7], // 96 CP r,q
  [0xD80, 0xFC0, 4, 0x030, 7], // 97 FAN r,i
  [0xF10, 0xFF0, 2, 0x00C, 7], // 98 FAN r,q
  [0xAF0, 0xFF0, 0, 0, 7], // 99 RLC
  [0xE8C, 0xFFC, 0, 0, 5], // 100 RRC
  [0xF60, 0xFF0, 0, 0, 7], // 101 INC Mn
  [0xF70, 0xFF0, 0, 0, 7], // 102 DEC Mn
  [0xF28, 0xFFC, 0, 0, 7], // 103 ACPX
  [0xF2C, 0xFFC, 0, 0, 7], // 104 ACPY
  [0xF38, 0xFFC, 0, 0, 7], // 105 SCPX
  [0xF3C, 0xFFC, 0, 0, 7], // 106 SCPY
  [0xD0F, 0xFCF, 4, 0, 7], // 107 NOT
];
const int _opPset = 0;
const int _opEi = 58;
const int _opNone = 0xFF;

class _Decoded {
  // Per op code: index into _ops (0xFF = unknown), args, cycles.
  final Uint8List idx = Uint8List(4096);
  final Uint8List arg0 = Uint8List(4096);
  final Uint8List arg1 = Uint8List(4096);
  final Uint8List cycles = Uint8List(4096);

  _Decoded() {
    for (var op = 0; op < 4096; op++) {
      var i = 0;
      for (; i < _ops.length; i++) {
        if ((op & _ops[i][1]) == _ops[i][0]) break;
      }
      if (i == _ops.length) {
        idx[op] = _opNone;
        continue;
      }
      final o = _ops[i];
      idx[op] = i;
      cycles[op] = o[4];
      if (o[3] != 0) {
        arg0[op] = (op & o[3]) >> o[2];
        arg1[op] = op & ~(o[1] | o[3]) & 0xFFF;
      } else {
        arg0[op] = ((op & ~o[1]) & 0xFFF) >> o[2];
        arg1[op] = 0;
      }
    }
  }
}

final _Decoded _dec = _Decoded();

/// True when every word of the program decodes to a known instruction (an E0C6S4x ROM).
bool isKnownOpcode(int op) => _dec.idx[op & 0xFFF] != _opNone;

class Cpu {
  Cpu(this.program, this.host) {
    reset();
  }

  /// 12-bit program words.
  final Uint16List program;
  final CpuHost host;

  // Registers
  int pc = 0, nextPc = 0, x = 0, y = 0, a = 0, b = 0, np = 0, sp = 0, flags = 0;

  /// 4096 nibbles; only RAM, the two display areas and the I/O area are used.
  final Uint8List memory = Uint8List(4096);

  final Uint8List inputs = Uint8List(2);
  final Uint8List intFactor = Uint8List(6);
  final Uint8List intMask = Uint8List(6);
  final Uint8List intTriggered = Uint8List(6);

  int callDepth = 0;
  // Timers, in ticks. Dart ints are 64-bit, so these never wrap in practice.
  int clk2 = 0, clk4 = 0, clk8 = 0, clk16 = 0, clk32 = 0, clk64 = 0, clk128 = 0, clk256 = 0;
  int progTimerTs = 0;
  bool progTimerEnabled = false;
  int progTimerData = 0, progTimerRld = 0;
  int tickCounter = 0;
  bool halted = false;
  int cpuFrequency = kOsc1Frequency;
  int scaledCycleAcc = 0;
  int previousCycles = 0;
  bool bzShot = false;
  int bzShotEnd = 0;

  /// Paramix V1_KMASK_ALL: the K00-K03 / serial interrupt masks go where they belong.
  bool kmaskFix = true;

  /// Skip ahead while halted (no effect on what the program sees beyond a few ticks of phase).
  bool fastHalt = true;

  /// Set when an unknown op code is met.
  String? fault;

  bool _linkLow = false;

  void reset() {
    pc = _toPc(0, 1, 0);
    np = _toNp(0, 1);
    a = b = x = y = sp = 0;
    flags = 0;
    memory.fillRange(0, memory.length, 0);
    memory[regR40R43BzOutputPort] = 0xF;
    memory[regLcdCtrl] = 0x8;
    memory[regK00K03InputRelation] = 0xF;
    cpuFrequency = kOsc1Frequency;
    inputs.fillRange(0, 2, 0);
    // TamaLIB's buttons idle high (active low)
    for (var p = 0; p < 4; p++) {
      setInputPin(p, true);
    }
  }

  static int _toPc(int bank, int page, int step) => (step & 0xFF) | ((page & 0xF) << 8) | ((bank & 1) << 12);
  static int _toNp(int bank, int page) => (page & 0xF) | ((bank & 1) << 4);

  int get _pcb => (pc >> 12) & 1;
  int get _pcp => (pc >> 8) & 0xF;
  int get _pcsh => (pc >> 4) & 0xF;
  int get _pcsl => pc & 0xF;
  int get _xp => (x >> 8) & 0xF;
  int get _xh => (x >> 4) & 0xF;
  int get _xl => x & 0xF;
  int get _yp => (y >> 8) & 0xF;
  int get _yh => (y >> 4) & 0xF;
  int get _yl => y & 0xF;
  int get _c => flags & _flagC;
  bool get _d => (flags & _flagD) != 0;

  void _setC(bool v) => flags = v ? (flags | _flagC) : (flags & ~_flagC);
  void _setZ(bool v) => flags = v ? (flags | _flagZ) : (flags & ~_flagZ);

  void _generateInterrupt(int slot, int bit) {
    intFactor[slot] |= 1 << bit;
    if ((intMask[slot] & (1 << bit)) != 0) intTriggered[slot] = 1;
  }

  /// pin 0..3 = K00..K03, 4..7 = K10..K13; high = released.
  void setInputPin(int pin, bool high) {
    final port = (pin & 4) >> 2;
    final bit = pin & 3;
    final state = high ? 1 : 0;
    final old = (inputs[port] >> bit) & 1;
    if (state != old) {
      if (port == 0) {
        if (state != ((memory[regK00K03InputRelation] >> bit) & 1)) _generateInterrupt(intK00K03, bit);
      } else if (state == 0) {
        _generateInterrupt(intK10K13, bit);
      }
    }
    inputs[port] = (inputs[port] & ~(1 << bit)) | (state << bit);
  }

  bool _localLow() => (memory[regIoCtrl] & 0x4) != 0 && (memory[regP20P23IoPort] & 0x1) == 0;

  void _driveUpdate() {
    final l = _localLow();
    if (l != _linkLow) {
      _linkLow = l;
      host.linkDriveChanged(l, tickCounter);
    }
  }

  int _getIo(int n) {
    int tmp;
    switch (n) {
      case regClkIntFactorFlags:
        tmp = intFactor[intClockTimer];
        intFactor[intClockTimer] = 0;
        return tmp;
      case regSwIntFactorFlags:
        tmp = intFactor[intStopwatch];
        intFactor[intStopwatch] = 0;
        return tmp;
      case regProgIntFactorFlags:
        tmp = intFactor[intProgTimer];
        intFactor[intProgTimer] = 0;
        return tmp;
      case regSerialIntFactorFlags:
        tmp = intFactor[intSerial];
        intFactor[intSerial] = 0;
        return tmp;
      case regK00K03IntFactorFlags:
        tmp = intFactor[intK00K03];
        intFactor[intK00K03] = 0;
        return tmp;
      case regK10K13IntFactorFlags:
        tmp = intFactor[intK10K13];
        intFactor[intK10K13] = 0;
        return tmp;
      case regClockIntMasks:
        return intMask[intClockTimer];
      case regSwIntMasks:
        return intMask[intStopwatch] & 0x3;
      case regProgIntMasks:
        return intMask[intProgTimer] & 0x1;
      case regSerialIntMasks:
        return intMask[intSerial] & 0x1;
      case regK00K03IntMasks:
        return intMask[intK00K03];
      case regK10K13IntMasks:
        return intMask[intK10K13];
      case regClockTimerData1:
      case regClockTimerData2:
        return memory[n];
      case regProgTimerDataL:
        return progTimerData & 0xF;
      case regProgTimerDataH:
        return (progTimerData >> 4) & 0xF;
      case regProgTimerReloadDataL:
        return progTimerRld & 0xF;
      case regProgTimerReloadDataH:
        return (progTimerRld >> 4) & 0xF;
      case regK00K03InputPort:
        return inputs[0];
      case regK00K03InputRelation:
        return memory[n];
      case regK10K13InputPort:
        return inputs[1];
      case regR40R43BzOutputPort:
      case regCpuOsc3Ctrl:
      case regLcdCtrl:
        return memory[n];
      case regLcdContrast:
        return 0;
      case regSvdCtrl:
        return memory[n] & 0x7; // battery always fine
      case regBuzzerCtrl1:
        return memory[n];
      case regBuzzerCtrl2:
        return memory[n] & 0x3;
      case regProgTimerCtrl:
        return progTimerEnabled ? 1 : 0;
      case regP20P23IoPort:
        // P20: open drain with pull-up; low when this toy or the linked one drives it
        return (memory[n] & 0xE) | ((_localLow() || host.linkLineLowFromPeer()) ? 0 : 1);
      case regIoCtrl:
        return memory[n];
      default:
        return 0;
    }
  }

  void _setIo(int n, int v) {
    switch (n) {
      case regClockIntMasks:
        intMask[intClockTimer] = v;
        break;
      case regSwIntMasks:
        intMask[intStopwatch] = v;
        break;
      case regProgIntMasks:
        intMask[intProgTimer] = v;
        break;
      case regSerialIntMasks:
        if (kmaskFix) {
          intMask[intSerial] = v;
        } else {
          intMask[intK10K13] = v;
        }
        break;
      case regK00K03IntMasks:
        if (kmaskFix) {
          intMask[intK00K03] = v;
        } else {
          intMask[intSerial] = v;
        }
        break;
      case regK10K13IntMasks:
        intMask[intK10K13] = v;
        break;
      case regProgTimerReloadDataL:
        progTimerRld = v | (progTimerRld & 0xF0);
        break;
      case regProgTimerReloadDataH:
        progTimerRld = (progTimerRld & 0xF) | (v << 4);
        break;
      case regR40R43BzOutputPort:
        host.enableBuzzer((v & 0x8) == 0);
        break;
      case regCpuOsc3Ctrl:
        if ((v & 0x8) != 0 && cpuFrequency != kOsc3Frequency) {
          cpuFrequency = kOsc3Frequency;
          scaledCycleAcc = 0;
        }
        if ((v & 0x8) == 0 && cpuFrequency != kOsc1Frequency) {
          cpuFrequency = kOsc1Frequency;
          scaledCycleAcc = 0;
        }
        break;
      case regBuzzerCtrl1:
        host.setBuzzerFreq(v & 0x7);
        break;
      case regBuzzerCtrl2:
        if ((v & 0x8) != 0) {
          bzShot = true;
          bzShotEnd = tickCounter + ((v & 0x4) != 0 ? 4096 : 1024);
          host.buzzerShot(true);
        }
        break;
      case regProgTimerCtrl:
        if ((v & 0x2) != 0) progTimerData = progTimerRld;
        if ((v & 0x1) != 0 && !progTimerEnabled) progTimerTs = tickCounter;
        progTimerEnabled = (v & 0x1) != 0;
        break;
      case regP20P23IoPort:
      case regIoCtrl:
        _driveUpdate();
        break;
      default:
        break;
    }
  }

  void _setLcd(int n, int v) {
    final seg = (n & 0x7F) >> 1;
    final com0 = ((n & 0x80) >> 7) * 8 + (n & 0x1) * 4;
    for (var i = 0; i < 4; i++) {
      host.setLcdPin(seg, com0 + i, ((v >> i) & 1) != 0);
    }
  }

  int getMemory(int n) {
    if (n < memRamSize) return memory[n];
    if (n >= memDisp1Addr && n < memDisp1Addr + memDisp1Size) return memory[n];
    if (n >= memDisp2Addr && n < memDisp2Addr + memDisp2Size) return memory[n];
    if (n >= memIoAddr && n < memIoAddr + memIoSize) return _getIo(n);
    return 0;
  }

  void setMemory(int n, int v) {
    v &= 0xF;
    if (n < memRamSize) {
      memory[n] = v;
    } else if (n >= memDisp1Addr && n < memDisp1Addr + memDisp1Size) {
      memory[n] = v;
      _setLcd(n, v);
    } else if (n >= memDisp2Addr && n < memDisp2Addr + memDisp2Size) {
      memory[n] = v;
      _setLcd(n, v);
    } else if (n >= memIoAddr && n < memIoAddr + memIoSize) {
      memory[n] = v;
      _setIo(n, v);
    }
  }

  /// Push the display memory and buzzer state to the host again (after loading a state).
  void refreshHw() {
    for (var n = memDisp1Addr; n < memDisp1Addr + memDisp1Size; n++) {
      setMemory(n, memory[n]);
    }
    for (var n = memDisp2Addr; n < memDisp2Addr + memDisp2Size; n++) {
      setMemory(n, memory[n]);
    }
    setMemory(regBuzzerCtrl1, memory[regBuzzerCtrl1]);
    setMemory(regR40R43BzOutputPort, memory[regR40R43BzOutputPort]);
  }

  int _rq(int r) {
    switch (r & 3) {
      case 0:
        return a;
      case 1:
        return b;
      case 2:
        return getMemory(x);
      default:
        return getMemory(y);
    }
  }

  void _setRq(int r, int v) {
    switch (r & 3) {
      case 0:
        a = v & 0xF;
        break;
      case 1:
        b = v & 0xF;
        break;
      case 2:
        setMemory(x, v);
        break;
      default:
        setMemory(y, v);
        break;
    }
  }

  void _waitForCycles(int cycles) {
    scaledCycleAcc += cycles * kTickFrequency;
    final ticks = scaledCycleAcc ~/ cpuFrequency;
    if (ticks > 0) {
      tickCounter += ticks;
      scaledCycleAcc -= ticks * cpuFrequency;
    }
  }

  void _pushPc() {
    setMemory((sp - 1) & 0xFF, _pcp);
    setMemory((sp - 2) & 0xFF, _pcsh);
    setMemory((sp - 3) & 0xFF, _pcsl);
    sp = (sp - 3) & 0xFF;
  }

  void _processInterrupts() {
    for (var i = 0; i < 6; i++) {
      if (intTriggered[i] != 0) {
        _pushPc();
        flags &= ~_flagI;
        np = _toNp((np >> 4) & 1, 1);
        pc = _toPc(_pcb, 1, _intVectors[i]);
        callDepth++;
        halted = false;
        _waitForCycles(12);
        intTriggered[i] = 0;
        return;
      }
    }
  }

  void _toggle(int reg, int bit) => memory[reg] ^= 1 << bit;
  bool _bit(int reg, int bit) => ((memory[reg] >> bit) & 1) != 0;

  void _handleTimers() {
    final t = tickCounter;
    if (bzShot && t - bzShotEnd >= 0) {
      bzShot = false;
      host.buzzerShot(false);
    }
    if (t - clk2 >= _t2hz) {
      do {
        clk2 += _t2hz;
      } while (t - clk2 >= _t2hz);
      _toggle(regClockTimerData2, 3);
      if (!_bit(regClockTimerData2, 3)) _generateInterrupt(intClockTimer, 3);
    }
    if (t - clk4 >= _t4hz) {
      do {
        clk4 += _t4hz;
      } while (t - clk4 >= _t4hz);
      _toggle(regClockTimerData2, 2);
      if (!_bit(regClockTimerData2, 2)) _generateInterrupt(intClockTimer, 2);
    }
    if (t - clk8 >= _t8hz) {
      do {
        clk8 += _t8hz;
      } while (t - clk8 >= _t8hz);
      _toggle(regClockTimerData2, 1);
    }
    if (t - clk16 >= _t16hz) {
      do {
        clk16 += _t16hz;
      } while (t - clk16 >= _t16hz);
      _toggle(regClockTimerData2, 0);
      if (!_bit(regClockTimerData2, 0)) _generateInterrupt(intClockTimer, 1);
    }
    if (t - clk32 >= _t32hz) {
      do {
        clk32 += _t32hz;
      } while (t - clk32 >= _t32hz);
      _toggle(regClockTimerData1, 3);
    }
    if (t - clk64 >= _t64hz) {
      do {
        clk64 += _t64hz;
      } while (t - clk64 >= _t64hz);
      _toggle(regClockTimerData1, 2);
      if (!_bit(regClockTimerData1, 2)) _generateInterrupt(intClockTimer, 0);
    }
    if (t - clk128 >= _t128hz) {
      do {
        clk128 += _t128hz;
      } while (t - clk128 >= _t128hz);
      _toggle(regClockTimerData1, 1);
    }
    if (t - clk256 >= _t256hz) {
      do {
        clk256 += _t256hz;
      } while (t - clk256 >= _t256hz);
      _toggle(regClockTimerData1, 0);
    }
    if (progTimerEnabled && t - progTimerTs >= _t256hz) {
      do {
        progTimerTs += _t256hz;
        progTimerData = (progTimerData - 1) & 0xFF;
        if (progTimerData == 0) {
          progTimerData = progTimerRld;
          _generateInterrupt(intProgTimer, 0);
        }
      } while (t - progTimerTs >= _t256hz);
    }
  }

  /// Ticks until the next timer event (for skipping while halted).
  int _ticksToNextEvent() {
    var n = clk256 + _t256hz - tickCounter;
    if (progTimerEnabled) {
      final p = progTimerTs + _t256hz - tickCounter;
      if (p < n) n = p;
    }
    if (bzShot) {
      final s = bzShotEnd - tickCounter;
      if (s < n) n = s;
    }
    return n;
  }

  /// One instruction (or one halt period). Returns false on an unknown op code.
  bool step({int limitTick = 0}) {
    var i = _opNone;
    if (!halted) {
      final op = program[pc] & 0xFFF;
      i = _dec.idx[op];
      if (i == _opNone) {
        fault = 'Unknown op code 0x${op.toRadixString(16)} at 0x${pc.toRadixString(16)}';
        return false;
      }
      nextPc = (pc + 1) & 0x1FFF;
      _waitForCycles(previousCycles);
      _exec(i, _dec.arg0[op], _dec.arg1[op]);
      pc = nextPc;
      previousCycles = _dec.cycles[op];
      if (i != _opPset) np = (pc >> 8) & 0x1F;
    } else {
      if (fastHalt && cpuFrequency == kOsc1Frequency && scaledCycleAcc == 0) {
        // Equivalent to repeated 5-cycle halts, landing on the next timer event.
        var n = _ticksToNextEvent();
        if (limitTick > 0 && tickCounter + n > limitTick) n = limitTick - tickCounter;
        if (n < 5) n = 5;
        tickCounter += n;
      } else {
        _waitForCycles(5);
      }
      previousCycles = 0;
    }
    _handleTimers();
    if ((flags & _flagI) != 0 && i != _opPset && i != _opEi) _processInterrupts();
    return true;
  }

  /// Runs until the tick counter reaches [targetTick] or [maxSteps] steps were done.
  /// Returns the number of steps done.
  int runUntil(int targetTick, {int maxSteps = 1 << 30}) {
    var n = 0;
    while (tickCounter < targetTick && n < maxSteps) {
      if (!step(limitTick: targetTick)) break;
      n++;
    }
    return n;
  }

  void _exec(int i, int arg0, int arg1) {
    int tmp;
    switch (i) {
      case 0: // PSET
        np = arg0;
        break;
      case 1: // JP
        nextPc = arg0 | (np << 8);
        break;
      case 2:
        if ((flags & _flagC) != 0) nextPc = arg0 | (np << 8);
        break;
      case 3:
        if ((flags & _flagC) == 0) nextPc = arg0 | (np << 8);
        break;
      case 4:
        if ((flags & _flagZ) != 0) nextPc = arg0 | (np << 8);
        break;
      case 5:
        if ((flags & _flagZ) == 0) nextPc = arg0 | (np << 8);
        break;
      case 6: // JPBA
        nextPc = a | (b << 4) | (np << 8);
        break;
      case 7: // CALL
        pc = (pc + 1) & 0x1FFF;
        _pushPc();
        nextPc = _toPc(_pcb, np & 0xF, arg0);
        callDepth++;
        break;
      case 8: // CALZ
        pc = (pc + 1) & 0x1FFF;
        _pushPc();
        nextPc = _toPc(_pcb, 0, arg0);
        callDepth++;
        break;
      case 9: // RET
        nextPc = getMemory(sp) | (getMemory((sp + 1) & 0xFF) << 4) | (getMemory((sp + 2) & 0xFF) << 8) | (_pcb << 12);
        sp = (sp + 3) & 0xFF;
        if (callDepth > 0) callDepth--;
        break;
      case 10: // RETS
        nextPc = getMemory(sp) | (getMemory((sp + 1) & 0xFF) << 4) | (getMemory((sp + 2) & 0xFF) << 8) | (_pcb << 12);
        sp = (sp + 3) & 0xFF;
        nextPc = (nextPc + 1) & 0x1FFF;
        if (callDepth > 0) callDepth--;
        break;
      case 11: // RETD
        nextPc = getMemory(sp) | (getMemory((sp + 1) & 0xFF) << 4) | (getMemory((sp + 2) & 0xFF) << 8) | (_pcb << 12);
        sp = (sp + 3) & 0xFF;
        setMemory(x, arg0 & 0xF);
        setMemory(((x + 1) & 0xFF) | (_xp << 8), (arg0 >> 4) & 0xF);
        x = ((x + 2) & 0xFF) | (_xp << 8);
        if (callDepth > 0) callDepth--;
        break;
      case 12: // NOP5
      case 13: // NOP7
        break;
      case 14: // HALT
        halted = true;
        break;
      case 15: // INC X
        x = ((x + 1) & 0xFF) | (_xp << 8);
        break;
      case 16: // INC Y
        y = ((y + 1) & 0xFF) | (_yp << 8);
        break;
      case 17: // LD X
        x = arg0 | (_xp << 8);
        break;
      case 18: // LD Y
        y = arg0 | (_yp << 8);
        break;
      case 19:
        x = (x & 0xFF) | (_rq(arg0) << 8);
        break;
      case 20:
        x = _xl | (_rq(arg0) << 4) | (_xp << 8);
        break;
      case 21:
        x = _rq(arg0) | (_xh << 4) | (_xp << 8);
        break;
      case 22:
        y = (y & 0xFF) | (_rq(arg0) << 8);
        break;
      case 23:
        y = _yl | (_rq(arg0) << 4) | (_yp << 8);
        break;
      case 24:
        y = _rq(arg0) | (_yh << 4) | (_yp << 8);
        break;
      case 25:
        _setRq(arg0, _xp);
        break;
      case 26:
        _setRq(arg0, _xh);
        break;
      case 27:
        _setRq(arg0, _xl);
        break;
      case 28:
        _setRq(arg0, _yp);
        break;
      case 29:
        _setRq(arg0, _yh);
        break;
      case 30:
        _setRq(arg0, _yl);
        break;
      case 31: // ADC XH
        tmp = _xh + arg0 + _c;
        x = _xl | ((tmp & 0xF) << 4) | (_xp << 8);
        _setC((tmp >> 4) != 0);
        _setZ((tmp & 0xF) == 0);
        break;
      case 32: // ADC XL
        tmp = _xl + arg0 + _c;
        x = (tmp & 0xF) | (_xh << 4) | (_xp << 8);
        _setC((tmp >> 4) != 0);
        _setZ((tmp & 0xF) == 0);
        break;
      case 33: // ADC YH
        tmp = _yh + arg0 + _c;
        y = _yl | ((tmp & 0xF) << 4) | (_yp << 8);
        _setC((tmp >> 4) != 0);
        _setZ((tmp & 0xF) == 0);
        break;
      case 34: // ADC YL
        tmp = _yl + arg0 + _c;
        y = (tmp & 0xF) | (_yh << 4) | (_yp << 8);
        _setC((tmp >> 4) != 0);
        _setZ((tmp & 0xF) == 0);
        break;
      case 35:
        _setC(_xh < arg0);
        _setZ(_xh == arg0);
        break;
      case 36:
        _setC(_xl < arg0);
        _setZ(_xl == arg0);
        break;
      case 37:
        _setC(_yh < arg0);
        _setZ(_yh == arg0);
        break;
      case 38:
        _setC(_yl < arg0);
        _setZ(_yl == arg0);
        break;
      case 39: // LD r,i
        _setRq(arg0, arg1);
        break;
      case 40: // LD r,q
        _setRq(arg0, _rq(arg1));
        break;
      case 41:
        a = getMemory(arg0);
        break;
      case 42:
        b = getMemory(arg0);
        break;
      case 43:
        setMemory(arg0, a);
        break;
      case 44:
        setMemory(arg0, b);
        break;
      case 45: // LDPX MX,i
        setMemory(x, arg0);
        x = ((x + 1) & 0xFF) | (_xp << 8);
        break;
      case 46: // LDPX r,q
        _setRq(arg0, _rq(arg1));
        x = ((x + 1) & 0xFF) | (_xp << 8);
        break;
      case 47: // LDPY MY,i
        setMemory(y, arg0);
        y = ((y + 1) & 0xFF) | (_yp << 8);
        break;
      case 48: // LDPY r,q
        _setRq(arg0, _rq(arg1));
        y = ((y + 1) & 0xFF) | (_yp << 8);
        break;
      case 49: // LBPX
        setMemory(x, arg0 & 0xF);
        setMemory(((x + 1) & 0xFF) | (_xp << 8), (arg0 >> 4) & 0xF);
        x = ((x + 2) & 0xFF) | (_xp << 8);
        break;
      case 50: // SET
        flags |= arg0;
        break;
      case 51: // RST
        flags &= arg0;
        break;
      case 52:
        flags |= _flagC;
        break;
      case 53:
        flags &= ~_flagC;
        break;
      case 54:
        flags |= _flagZ;
        break;
      case 55:
        flags &= ~_flagZ;
        break;
      case 56:
        flags |= _flagD;
        break;
      case 57:
        flags &= ~_flagD;
        break;
      case 58:
        flags |= _flagI;
        break;
      case 59:
        flags &= ~_flagI;
        break;
      case 60:
        sp = (sp + 1) & 0xFF;
        break;
      case 61:
        sp = (sp - 1) & 0xFF;
        break;
      case 62: // PUSH r
        sp = (sp - 1) & 0xFF;
        setMemory(sp, _rq(arg0));
        break;
      case 63:
        sp = (sp - 1) & 0xFF;
        setMemory(sp, _xp);
        break;
      case 64:
        sp = (sp - 1) & 0xFF;
        setMemory(sp, _xh);
        break;
      case 65:
        sp = (sp - 1) & 0xFF;
        setMemory(sp, _xl);
        break;
      case 66:
        sp = (sp - 1) & 0xFF;
        setMemory(sp, _yp);
        break;
      case 67:
        sp = (sp - 1) & 0xFF;
        setMemory(sp, _yh);
        break;
      case 68:
        sp = (sp - 1) & 0xFF;
        setMemory(sp, _yl);
        break;
      case 69:
        sp = (sp - 1) & 0xFF;
        setMemory(sp, flags);
        break;
      case 70: // POP r
        _setRq(arg0, getMemory(sp));
        sp = (sp + 1) & 0xFF;
        break;
      case 71:
        x = _xl | (_xh << 4) | (getMemory(sp) << 8);
        sp = (sp + 1) & 0xFF;
        break;
      case 72:
        x = _xl | (getMemory(sp) << 4) | (_xp << 8);
        sp = (sp + 1) & 0xFF;
        break;
      case 73:
        x = getMemory(sp) | (_xh << 4) | (_xp << 8);
        sp = (sp + 1) & 0xFF;
        break;
      case 74:
        y = _yl | (_yh << 4) | (getMemory(sp) << 8);
        sp = (sp + 1) & 0xFF;
        break;
      case 75:
        y = _yl | (getMemory(sp) << 4) | (_yp << 8);
        sp = (sp + 1) & 0xFF;
        break;
      case 76:
        y = getMemory(sp) | (_yh << 4) | (_yp << 8);
        sp = (sp + 1) & 0xFF;
        break;
      case 77:
        flags = getMemory(sp);
        sp = (sp + 1) & 0xFF;
        break;
      case 78:
        sp = (sp & 0xF) | (_rq(arg0) << 4);
        break;
      case 79:
        sp = _rq(arg0) | (sp & 0xF0);
        break;
      case 80:
        _setRq(arg0, (sp >> 4) & 0xF);
        break;
      case 81:
        _setRq(arg0, sp & 0xF);
        break;
      case 82: // ADD r,i
        _addTo(arg0, _rq(arg0) + arg1);
        break;
      case 83: // ADD r,q
        _addTo(arg0, _rq(arg0) + _rq(arg1));
        break;
      case 84: // ADC r,i
        _addTo(arg0, _rq(arg0) + arg1 + _c);
        break;
      case 85: // ADC r,q
        _addTo(arg0, _rq(arg0) + _rq(arg1) + _c);
        break;
      case 86: // SUB
        _subTo(arg0, (_rq(arg0) - _rq(arg1)) & 0xFF);
        break;
      case 87: // SBC r,i
        _subTo(arg0, (_rq(arg0) - arg1 - _c) & 0xFF);
        break;
      case 88: // SBC r,q
        _subTo(arg0, (_rq(arg0) - _rq(arg1) - _c) & 0xFF);
        break;
      case 89:
        _setRq(arg0, _rq(arg0) & arg1);
        _setZ(_rq(arg0) == 0);
        break;
      case 90:
        _setRq(arg0, _rq(arg0) & _rq(arg1));
        _setZ(_rq(arg0) == 0);
        break;
      case 91:
        _setRq(arg0, _rq(arg0) | arg1);
        _setZ(_rq(arg0) == 0);
        break;
      case 92:
        _setRq(arg0, _rq(arg0) | _rq(arg1));
        _setZ(_rq(arg0) == 0);
        break;
      case 93:
        _setRq(arg0, _rq(arg0) ^ arg1);
        _setZ(_rq(arg0) == 0);
        break;
      case 94:
        _setRq(arg0, _rq(arg0) ^ _rq(arg1));
        _setZ(_rq(arg0) == 0);
        break;
      case 95: // CP r,i
        tmp = _rq(arg0);
        _setC(tmp < arg1);
        _setZ(_rq(arg0) == arg1);
        break;
      case 96: // CP r,q
        _setC(_rq(arg0) < _rq(arg1));
        _setZ(_rq(arg0) == _rq(arg1));
        break;
      case 97: // FAN r,i
        _setZ((_rq(arg0) & arg1) == 0);
        break;
      case 98: // FAN r,q
        _setZ((_rq(arg0) & _rq(arg1)) == 0);
        break;
      case 99: // RLC
        tmp = (_rq(arg0) << 1) | _c;
        _setC((_rq(arg0) & 0x8) != 0);
        _setRq(arg0, tmp & 0xF);
        break;
      case 100: // RRC
        tmp = (_rq(arg0) >> 1) | (_c << 3);
        _setC((_rq(arg0) & 0x1) != 0);
        _setRq(arg0, tmp & 0xF);
        break;
      case 101: // INC Mn
        tmp = getMemory(arg0) + 1;
        setMemory(arg0, tmp & 0xF);
        _setC((tmp >> 4) != 0);
        _setZ(getMemory(arg0) == 0);
        break;
      case 102: // DEC Mn
        tmp = (getMemory(arg0) - 1) & 0xFF;
        setMemory(arg0, tmp & 0xF);
        _setC((tmp >> 4) != 0);
        _setZ(getMemory(arg0) == 0);
        break;
      case 103: // ACPX
        tmp = getMemory(x) + _rq(arg0) + _c;
        _addToMem(x, tmp);
        x = ((x + 1) & 0xFF) | (_xp << 8);
        break;
      case 104: // ACPY
        tmp = getMemory(y) + _rq(arg0) + _c;
        _addToMem(y, tmp);
        y = ((y + 1) & 0xFF) | (_yp << 8);
        break;
      case 105: // SCPX
        tmp = (getMemory(x) - _rq(arg0) - _c) & 0xFF;
        _subToMem(x, tmp);
        x = ((x + 1) & 0xFF) | (_xp << 8);
        break;
      case 106: // SCPY
        tmp = (getMemory(y) - _rq(arg0) - _c) & 0xFF;
        _subToMem(y, tmp);
        y = ((y + 1) & 0xFF) | (_yp << 8);
        break;
      case 107: // NOT
        _setRq(arg0, ~_rq(arg0) & 0xF);
        _setZ(_rq(arg0) == 0);
        break;
    }
  }

  void _addTo(int r, int tmp) {
    tmp &= 0xFF;
    if (_d) {
      if (tmp >= 10) {
        _setRq(r, (tmp - 10) & 0xF);
        _setC(true);
      } else {
        _setRq(r, tmp);
        _setC(false);
      }
    } else {
      _setRq(r, tmp & 0xF);
      _setC((tmp >> 4) != 0);
    }
    _setZ(_rq(r) == 0);
  }

  void _subTo(int r, int tmp) {
    if (_d) {
      _setRq(r, (tmp >> 4) != 0 ? (tmp - 6) & 0xF : tmp);
    } else {
      _setRq(r, tmp & 0xF);
    }
    _setC((tmp >> 4) != 0);
    _setZ(_rq(r) == 0);
  }

  void _addToMem(int addr, int tmp) {
    tmp &= 0xFF;
    if (_d) {
      if (tmp >= 10) {
        setMemory(addr, (tmp - 10) & 0xF);
        _setC(true);
      } else {
        setMemory(addr, tmp);
        _setC(false);
      }
    } else {
      setMemory(addr, tmp & 0xF);
      _setC((tmp >> 4) != 0);
    }
    _setZ(getMemory(addr) == 0);
  }

  void _subToMem(int addr, int tmp) {
    if (_d) {
      setMemory(addr, (tmp >> 4) != 0 ? (tmp - 6) & 0xF : tmp);
    } else {
      setMemory(addr, tmp & 0xF);
    }
    _setC((tmp >> 4) != 0);
    _setZ(getMemory(addr) == 0);
  }

  // ---- state ----

  static const int _stateVersion = 1;

  Uint8List saveState() {
    final bd = BytesBuilder();
    final h = ByteData(8 * 24);
    var o = 0;
    void p(int v) {
      h.setInt64(o, v);
      o += 8;
    }

    p(_stateVersion);
    for (final v in [pc, x, y, a, b, np, sp, flags, callDepth, clk2, clk4, clk8, clk16, clk32, clk64, clk128, clk256]) {
      p(v);
    }
    for (final v in [progTimerTs, progTimerEnabled ? 1 : 0, progTimerData, progTimerRld, tickCounter, halted ? 1 : 0]) {
      p(v);
    }
    bd.add(h.buffer.asUint8List(0, o));
    final h2 = ByteData(8 * 5);
    h2.setInt64(0, cpuFrequency);
    h2.setInt64(8, scaledCycleAcc);
    h2.setInt64(16, previousCycles);
    h2.setInt64(24, bzShot ? 1 : 0);
    h2.setInt64(32, bzShotEnd);
    bd.add(h2.buffer.asUint8List());
    bd.add(inputs);
    bd.add(intFactor);
    bd.add(intMask);
    bd.add(intTriggered);
    bd.add(memory);
    return bd.toBytes();
  }

  bool loadState(Uint8List s) {
    if (s.length < 24 * 8 + 40 + 2 + 18 + 4096) return false;
    final h = ByteData.sublistView(s);
    var o = 0;
    int g() {
      final v = h.getInt64(o);
      o += 8;
      return v;
    }

    if (g() != _stateVersion) return false;
    pc = g();
    x = g();
    y = g();
    a = g();
    b = g();
    np = g();
    sp = g();
    flags = g();
    callDepth = g();
    clk2 = g();
    clk4 = g();
    clk8 = g();
    clk16 = g();
    clk32 = g();
    clk64 = g();
    clk128 = g();
    clk256 = g();
    progTimerTs = g();
    progTimerEnabled = g() != 0;
    progTimerData = g();
    progTimerRld = g();
    tickCounter = g();
    halted = g() != 0;
    cpuFrequency = g();
    scaledCycleAcc = g();
    previousCycles = g();
    bzShot = g() != 0;
    bzShotEnd = g();
    inputs.setRange(0, 2, s, o);
    o += 2;
    intFactor.setRange(0, 6, s, o);
    o += 6;
    intMask.setRange(0, 6, s, o);
    o += 6;
    intTriggered.setRange(0, 6, s, o);
    o += 6;
    memory.setRange(0, 4096, s, o);
    nextPc = pc;
    fault = null;
    refreshHw();
    return true;
  }
}
