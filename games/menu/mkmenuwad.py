#!/usr/bin/env python3
"""Pack games/menu/menu.blob: the MENUWAD image for the menu firmware.

Layout (see games/menu/menu_blob.h):
    struct menuwad_hdr
    struct menuwad_rom[rom_count]
    ... disk.blob bytes (CP/M) ...
    ... doom1.wad bytes (DOOM) ...
    ... raw chip-8 ROM bytes ...

Usage:  mkmenuwad.py <disk.blob> <doom1.wad> <roms dir> <out.blob>
"""
import glob
import os
import struct
import sys

MAGIC = int.from_bytes(b'MENUWAD1', 'little')
HDR_FMT = '<QHHIIIII'     # magic, version, rom_count, disk_off/len, doom_off/len, reserved
HDR_LEN = struct.calcsize(HDR_FMT)
ROM_FMT = '<12sII'        # name[12], off, len
ROM_LEN = struct.calcsize(ROM_FMT)

assert HDR_LEN == 32 and ROM_LEN == 20


def align4(n):
    return (n + 3) & ~3


def main():
    disk_path, doom_path, roms_dir, out_path = sys.argv[1:5]
    with open(disk_path, 'rb') as f:
        disk = f.read()
    with open(doom_path, 'rb') as f:
        doom = f.read()
    roms = []
    for p in sorted(glob.glob(os.path.join(roms_dir, '*.ch8'))):
        with open(p, 'rb') as f:
            raw = f.read()
        ln = raw[0] | (raw[1] << 8)   # mkrom.py [u16 len][bytes] wrap
        assert 2 + ln <= len(raw), p
        name = os.path.splitext(os.path.basename(p))[0].upper()
        name = ''.join(c if ('A' <= c <= 'Z' or '0' <= c <= '9'
                             or c in '_-./') else '-' for c in name)[:11]
        roms.append((name, raw[2:2 + ln]))

    off = HDR_LEN + ROM_LEN * len(roms)
    disk_off = align4(off)
    off = disk_off + len(disk)
    doom_off = align4(off)
    off = doom_off + len(doom)
    entries = []
    for name, data in roms:
        a = align4(off)
        entries.append((name, a, len(data)))
        off = a + len(data)
    total = align4(off)

    blob = bytearray(total)
    struct.pack_into(HDR_FMT, blob, 0, MAGIC, 1, len(roms),
                     disk_off, len(disk), doom_off, len(doom), 0)
    for i, (name, a, ln) in enumerate(entries):
        nm = name.encode('ascii') + b'\0' * (12 - len(name))
        struct.pack_into(ROM_FMT, blob, HDR_LEN + ROM_LEN * i, nm, a, ln)
    blob[disk_off:disk_off + len(disk)] = disk
    blob[doom_off:doom_off + len(doom)] = doom
    for (_, a, _), (_, data) in zip(entries, roms):
        blob[a:a + len(data)] = data
    with open(out_path, 'wb') as f:
        f.write(blob)
    print('menuwad: %d roms, disk@0x%x %dB, doom@0x%x %dB, total %dB' %
          (len(roms), disk_off, len(disk), doom_off, len(doom), total))


main()
