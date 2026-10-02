#!/usr/bin/env python3
"""elf2hex_doom.py -- sparse hex generator for the DOOM build.

Differs from scripts/elf2hex.py in three ways that matter at this size:

1. Sparse emit. Their version always writes every word (4096 inst / 2048 data).
   With DATA_MEM_WORDS = 16,777,216 that would be 64 MB of hex text, almost all
   zeros. This writes only up to the highest word actually used.

2. The WAD is not part of the image at all. tb_doom.v loads it with $fread
   straight into the data memory array at _wad_start.

IMPORTANT: .rodata is placed into BOTH images, exactly as their elf2hex.py
does. This core is Harvard -- instruction fetches come from inst_mem, loads
and stores come from data_mem, and both are indexed from the same base
address. String literals and const tables therefore have to exist in dmem or
every `lb` from .rodata reads zero. Removing this duplication silently breaks
anything that reads a constant (a string print loop terminates immediately,
since the NUL it reads looks like the end of the string).

Format is the same $readmemh word-per-line their memories already use, so no
RTL change is needed.
"""
import os
import re
import struct
import subprocess
import sys
import tempfile

OBJDUMP = "riscv64-unknown-elf-objdump"
OBJCOPY = "riscv64-unknown-elf-objcopy"

INST_WORDS_MAX = 524288      # 2 MB, matches `INST_MEM_WORDS`
DATA_WORDS_MAX = 16777216    # 64 MB, matches `DATA_MEM_WORDS`


def parse_sections(elf):
    out = subprocess.check_output([OBJDUMP, "-h", elf], text=True)
    secs, pending = [], None
    hdr = re.compile(
        r"^\s*(\d+)\s+(\S+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+"
        r"([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+2\*\*(\d+)")
    for line in out.splitlines():
        m = hdr.match(line)
        if m:
            pending = {"name": m.group(2), "size": int(m.group(3), 16),
                       "vma": int(m.group(4), 16), "flags": ""}
            continue
        if pending is not None:
            f = line.strip()
            if f:
                pending["flags"] = f
                secs.append(pending)
                pending = None
    return secs


def dump(elf, name, td):
    p = os.path.join(td, name.replace("/", "_") + ".bin")
    subprocess.run([OBJCOPY, "--dump-section", f"{name}={p}", elf],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(p, "rb") as fh:
        return fh.read()


def write_sparse(path, mem, words_cap, label):
    """Write only up to the last non-zero word."""
    last = -1
    for i in range(words_cap - 1, -1, -1):
        if mem[i * 4:i * 4 + 4] != b"\x00\x00\x00\x00":
            last = i
            break
    n = last + 1
    with open(path, "w") as f:
        for i in range(n):
            f.write("%08x\n" % struct.unpack("<I", mem[i * 4:i * 4 + 4])[0])
    print(f"  {label}: {n:,} words ({n * 9 / 1024 / 1024:.1f} MB of hex text, "
          f"cap {words_cap:,})")
    return n


def main():
    if len(sys.argv) < 4:
        print("usage: elf2hex_doom.py <elf> <inst.hex> <data.hex>")
        return 1

    elf, inst_hex, data_hex = sys.argv[1], sys.argv[2], sys.argv[3]
    inst = bytearray(INST_WORDS_MAX * 4)
    data = bytearray(DATA_WORDS_MAX * 4)

    placed = []
    with tempfile.TemporaryDirectory() as td:
        for s in parse_sections(elf):
            if s["size"] == 0 or "CONTENTS" not in s["flags"]:
                continue
            if s["name"] == ".wad":
                continue                      # loaded by the testbench
            payload = dump(elf, s["name"], td)
            vma = s["vma"]

            if s["name"].startswith((".text", ".rodata")):
                if vma + len(payload) > len(inst):
                    print(f"ERROR: {s['name']} overflows inst mem", file=sys.stderr)
                    return 1
                inst[vma:vma + len(payload)] = payload
                placed.append((s["name"], "imem", vma, len(payload)))

            if s["name"].startswith((".data", ".sdata", ".rodata")):
                if vma + len(payload) > len(data):
                    print(f"ERROR: {s['name']} overflows data mem", file=sys.stderr)
                    return 1
                data[vma:vma + len(payload)] = payload
                placed.append((s["name"], "dmem", vma, len(payload)))

    print("sections placed:")
    for n, w, v, sz in placed:
        print(f"  {n:10s} -> {w}  @0x{v:08X}  {sz:,} B")

    write_sparse(inst_hex, inst, INST_WORDS_MAX, "inst_mem.hex")
    write_sparse(data_hex, data, DATA_WORDS_MAX, "data_mem.hex")
    return 0


if __name__ == "__main__":
    sys.exit(main())
