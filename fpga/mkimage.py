#!/usr/bin/env python3
"""Build a Verilog $readmemh preload for tb_retro from the guest ELF + WAD.

The file holds 32-bit words addressed by SDRAM word number, with @-gaps:

    @000000
    00100093
    ...

Self-contained (no uploader import): minimal ELF32 parser for PT_LOAD
segments plus the _wad_start symbol.

Usage:  python3 fpga/mkimage.py games/doom/doom.elf games/doom/doom1.wad sdram.hex
"""
import struct
import sys


def parse_elf(elf):
    assert elf[:4] == b"\x7fELF" and elf[4] == 1 and elf[5] == 1, "not LE ELF32"
    e_phoff, e_shoff = struct.unpack_from("<II", elf, 0x1C)
    e_phnum, e_shnum = struct.unpack_from("<HH", elf, 0x2C)[0], struct.unpack_from("<H", elf, 0x30)[0]
    e_shstrndx = struct.unpack_from("<H", elf, 0x32)[0]
    entry = struct.unpack_from("<I", elf, 0x18)[0]
    segments = []
    for i in range(e_phnum):
        ph = struct.unpack_from("<IIIII", elf, e_phoff + 32 * i)
        if ph[0] == 1:  # PT_LOAD
            seg = elf[ph[1]:ph[1] + ph[4]]
            seg += b"\0" * (-len(seg) & 3)  # pad to 4 like uploader.py
            segments.append((ph[3], seg))
    # section names -> find .symtab and .strtab
    shstr_off = struct.unpack_from("<I", elf, e_shoff + 40 * e_shstrndx + 16)[0]
    symtab = strtab = None
    for i in range(e_shnum):
        base = e_shoff + 40 * i
        sh_name = struct.unpack_from("<I", elf, base)[0]
        sh_offset = struct.unpack_from("<I", elf, base + 16)[0]
        sh_size = struct.unpack_from("<I", elf, base + 20)[0]
        end = elf.index(b"\0", shstr_off + sh_name)
        nm = elf[shstr_off + sh_name:end].decode()
        if nm == ".symtab":
            symtab = (sh_offset, sh_size)
        elif nm == ".strtab":
            strtab = (sh_offset, sh_size)
    wad_start = None
    if symtab and strtab:
        for i in range(symtab[1] // 16):
            st_name, st_value = struct.unpack_from("<II", elf, symtab[0] + 16 * i)
            end = elf.index(b"\0", strtab[0] + st_name)
            if elf[strtab[0] + st_name:end] == b"_wad_start":
                wad_start = st_value
    assert wad_start is not None, "no _wad_start symbol"
    return segments, wad_start, entry


def main():
    elf_path, wad_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(elf_path, "rb") as f:
        elf = f.read()
    with open(wad_path, "rb") as f:
        wad = f.read()
    if len(wad) & 3:
        wad += b"\0" * (-len(wad) & 3)

    segments, wad_start, entry = parse_elf(elf)
    image = [(addr, data) for addr, data in segments]
    image.append((wad_start, wad))

    words = {}
    for addr, data in image:
        assert addr & 3 == 0, f"unaligned segment @{addr:#x}"
        base = addr >> 2
        for i in range(0, len(data), 4):
            words[base + i // 4] = struct.unpack_from("<I", data, i)[0]

    addrs = sorted(words)
    with open(out_path, "w") as f:
        prev = None
        for a in addrs:
            # sdram_model mem is 16-bit: word a -> mem[2a]=low, mem[2a+1]=high
            if 2 * a != prev:
                f.write(f"@{2 * a:06x}\n")
            f.write(f"{words[a] & 0xFFFF:04x}\n")
            f.write(f"{words[a] >> 16:04x}\n")
            prev = 2 * a + 2
    nbytes = sum(len(d) for _, d in image)
    print(f"wrote {out_path}: {len(words)} words "
          f"({2 * len(words)} half-lines, {nbytes / 1048576:.2f} MB), "
          f"entry {entry:#010x}")


if __name__ == "__main__":
    main()
