#!/usr/bin/env python3
"""Pack a directory of CP/M files into the RAM-disk blob.

Layout: [u16 total len][u16 file count][per file: 11 name bytes (8+3, upper, space padded),
u32 length LE, raw bytes]. The blob rides the existing uploader WAD slot
(mkrom-style [u16 total len][blob]) and _HardwareInit unpacks it into the
RAM-disk arena at boot.

Usage:  python3 mkdisk.py <dir> <out.blob>
"""
import os
import struct
import sys


def pack_name(fn):
    base, _, ext = fn.upper().partition(".")
    return (base[:8].ljust(8) + ext[:3].ljust(3)).encode("ascii")


TEXT_EXTS = {".BAS", ".TXT", ".SUB", ".ASM", ".Z80", ".LIB", ".DOC", ".ME", ".INC"}


def sanitize_content(fn, data):
    _, ext = os.path.splitext(fn.upper())
    if ext in TEXT_EXTS:
        try:
            # Decode text, normalize to CRLF
            text = data.decode("ascii", errors="replace")
            # Replace CRLF / LF with \r\n
            lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
            # Remove trailing empty lines
            while lines and not lines[-1].strip():
                lines.pop()
            crlf_text = "\r\n".join(lines) + "\r\n\x1A"
            return crlf_text.encode("ascii")
        except Exception:
            return data
    return data


def main():
    src, dst = sys.argv[1], sys.argv[2]
    names = sorted(f for f in os.listdir(src)
                   if os.path.isfile(os.path.join(src, f)))
    blob = struct.pack("<H", len(names))
    for fn in names:
        with open(os.path.join(src, fn), "rb") as f:
            raw_data = f.read()
        data = sanitize_content(fn, raw_data)
        blob += pack_name(fn) + struct.pack("<I", len(data)) + data
    wrapped = struct.pack("<H", len(blob) & 0xFFFF) + blob
    with open(dst, "wb") as f:
        f.write(wrapped)
    print(f"mkdisk: {len(names)} files, {len(blob)} blob bytes -> {dst}")


if __name__ == "__main__":
    main()
