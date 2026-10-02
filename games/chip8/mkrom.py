#!/usr/bin/env python3
"""Assemble a .c8 source (labels + dw/db/org) and wrap it as an uploadable
.ch8 ROM for the WAD slot ([u16 len LE][bytes]).

  ./games/chip8/mkrom.py games/chip8/roms/pong.c8   # run from project root
"""
import re
import struct
import sys

SRC = sys.argv[1]
DST = SRC.rsplit(".", 1)[0] + ".ch8"


def parse_expr(tok, labels):
    tok = tok.strip()
    if not tok:
        raise ValueError("empty expression")
    parts = tok.split("+")
    if len(parts) > 2:
        raise ValueError(f"bad expression: {tok}")
    val = 0
    for p in parts:
        p = p.strip()
        if re.fullmatch(r"[0-9][0-9a-fA-FxX]*", p):
            val += int(p, 0)
        elif re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", p):
            if p not in labels:
                raise ValueError(f"undefined label: {p}")
            val += labels[p]
        else:
            raise ValueError(f"bad term: {p}")
    return val


def main():
    org = 0x200
    addr = org
    labels = {}
    items = []  # (addr, kind, [exprs], lineno)
    for ln, raw in enumerate(open(SRC), 1):
        line = raw.split(";")[0].strip()
        if not line:
            continue
        while ":" in line:  # one or more labels
            name, line = line.split(":", 1)
            name = name.strip()
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                raise SystemExit(f"{SRC}:{ln}: bad label: {name}")
            if name in labels:
                raise SystemExit(f"{SRC}:{ln}: duplicate label: {name}")
            labels[name] = addr
            line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        op = parts[0].lower()
        arg = parts[1] if len(parts) > 1 else ""
        if op == "org":
            addr = int(arg, 0)
            org = addr
        elif op == "align":
            if addr & 1:
                items.append((addr, "b", ["0"], ln))
                addr += 1
        elif op in ("dw", "db"):
            exprs = [e.strip() for e in arg.split(",") if e.strip()]
            if not exprs:
                raise SystemExit(f"{SRC}:{ln}: {op} needs operands")
            items.append((addr, "w" if op == "dw" else "b", exprs, ln))
            addr += len(exprs) * (2 if op == "dw" else 1)
        else:
            raise SystemExit(f"{SRC}:{ln}: unknown op: {op}")

    out = bytearray()
    for a, kind, exprs, ln in items:
        while org + len(out) < a:
            out.append(0)
        try:
            vals = [parse_expr(e, labels) for e in exprs]
        except ValueError as e:
            raise SystemExit(f"{SRC}:{ln}: {e}")
        for v in vals:
            if kind == "w":
                if not 0 <= v <= 0xFFFF:
                    raise SystemExit(f"{SRC}:{ln}: dw out of range: {v:#x}")
                out += struct.pack(">H", v)
            else:
                if not 0 <= v <= 0xFF:
                    raise SystemExit(f"{SRC}:{ln}: db out of range: {v:#x}")
                out.append(v)
    blob = struct.pack("<H", len(out)) + bytes(out)
    open(DST, "wb").write(blob)
    print(f"[mkrom] {SRC} -> {DST}: {len(out)} ROM bytes")


if __name__ == "__main__":
    main()
