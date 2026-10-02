#!/usr/bin/env python3
"""trace.py -- host-side Chip-8 ROM tracer (validates ROM logic, no console needed).
Mirrors games/chip8/chip8.c semantics (clip, shift-in-place, Fx55/65 keep I).
Usage: trace.py rom.ch8 [steps]"""
import struct, sys
from collections import Counter
def load(p):
    d = open(p, 'rb').read()
    n = struct.unpack_from('<H', d, 0)[0]
    assert 2 + n <= len(d), "bad wrap"
    return d[2:2 + n]
def main():
    rom = load(sys.argv[1])
    N = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
    mem = bytearray(4096)
    mem[0x200:0x200 + len(rom)] = rom
    V = [0]*16; I = 0; pc = 0x200; stack = []; delay = 0; sound = 0
    keys = [0]*16; ops = Counter(); draws = 0; f0a = 0
    lastpcs = []
    for s in range(N):
        if pc >= 4095: print(f"[{s}] RUNAWAY pc={pc:#x}, reset to 0x200"); pc = 0x200; continue
        op = (mem[pc] << 8) | mem[pc+1]
        ops[op & 0xF000] += 1
        npc = pc + 2
        x = (op >> 8) & 15; y = (op >> 4) & 15; n = op & 15
        nnn = op & 0xFFF; kk = op & 0xFF
        h = op & 0xF000
        if h == 0x0000:
            if op == 0x00EE and stack: npc = stack.pop()
        elif h == 0x1000: npc = nnn
        elif h == 0x2000:
            if len(stack) < 16: stack.append(pc + 2)
            else: print(f"[{s}] STACK OVERFLOW at pc={pc:#x}")
            npc = nnn
        elif h == 0x3000:
            if V[x] == kk: npc += 2
        elif h == 0x4000:
            if V[x] != kk: npc += 2
        elif h == 0x5000:
            if V[x] == V[y]: npc += 2
        elif h == 0x6000: V[x] = kk
        elif h == 0x7000: V[x] = (V[x] + kk) & 0xFF
        elif h == 0x8000:
            a, b = V[x], V[y]
            if n == 0: V[x] = b
            elif n == 1: V[x] = a | b
            elif n == 2: V[x] = a & b
            elif n == 3: V[x] = a ^ b
            elif n == 4: V[x] = (a + b) & 0xFF; V[15] = 1 if a + b > 255 else 0
            elif n == 5: V[x] = (a - b) & 0xFF; V[15] = 1 if a >= b else 0
            elif n == 6: V[15] = a & 1; V[x] = (a >> 1) & 0xFF
            elif n == 7: V[x] = (b - a) & 0xFF; V[15] = 1 if b >= a else 0
            elif n == 0xE: V[15] = (a >> 7) & 1; V[x] = (a << 1) & 0xFF
        elif h == 0x9000:
            if V[x] != V[y]: npc += 2
        elif h == 0xA000: I = nnn
        elif h == 0xB000: npc = (nnn + V[0]) & 0xFFF
        elif h == 0xC000: V[x] = 0x5A & kk  # deterministic "random"
        elif h == 0xD000: draws += 1
        elif h == 0xE000:
            if kk == 0x9E:
                if keys[V[x] & 15]: npc += 2
            elif kk == 0xA1:
                if not keys[V[x] & 15]: npc += 2
        elif h == 0xF000:
            k = kk
            if k == 0x07: V[x] = delay
            elif k == 0x0A:
                f0a += 1
                if f0a <= 3: print(f"[{s}] Fx0A at pc={pc:#x} (no keys -> would spin)")
                npc = pc  # spin like hw retry
            elif k == 0x15: delay = V[x]
            elif k == 0x18: sound = V[x]
            elif k == 0x1E: V[15] = 1 if I + V[x] > 0xFFF else 0; I = (I + V[x]) & 0xFFF
            elif k == 0x29: I = 0x50 + (V[x] & 15) * 5
            elif k == 0x33:
                mem[I & 0xFFF] = V[x] // 100; mem[(I+1) & 0xFFF] = (V[x]//10) % 10; mem[(I+2) & 0xFFF] = V[x] % 10
            elif k == 0x55:
                for i in range(x+1): mem[(I+i) & 0xFFF] = V[i]
            elif k == 0x65:
                for i in range(x+1): V[i] = mem[(I+i) & 0xFFF]
        if s < 12 or op in (0x00EE,) or h in (0x1000, 0x2000, 0xB000):
            print(f"[{s}] pc={pc:#5x} op={op:04X} I={I:#5x} sp={len(stack)} V0..3={[f'{v:02X}' for v in V[:4]]}")
        lastpcs.append(pc)
        if len(lastpcs) > 6: lastpcs.pop(0)
        if len(lastpcs) == 6 and len(set(lastpcs)) <= 2 and s > 100:
            print(f"[{s}] STEADY-STATE LOOP pcs={[hex(p) for p in lastpcs]} V0..7={[f'{v:02X}' for v in V[:8]]} I={I:#x} delay={delay}")
            break
        pc = npc & 0xFFF
        if s % 15 == 14:
            if delay: delay -= 1
            if sound: sound -= 1
    print(f"steps={s+1} draws={draws} Fx0A_hits={f0a} op_histogram={dict(sorted(ops.items()))}")
main()
