#!/usr/bin/env python3
"""Render a tb frame dump (frame_fpga.bin) to PNG.
  tiny (default): first 2048 bytes as 64x32 RGB332.
  --doom --wad X: 320x200 indices through the WAD PLAYPAL.
Usage: fb2png.py [frame_fpga.bin] [out.png] [--doom --wad file] [--scale N]
"""
import struct
import sys

from PIL import Image


def rgb332(b):
    return (((b >> 5) & 7) * 255 // 7, ((b >> 2) & 7) * 255 // 7, (b & 3) * 255 // 3)


def main():
    args = sys.argv[1:]
    doom = "--doom" in args
    if doom:
        args.remove("--doom")
    wad = None
    if "--wad" in args:
        i = args.index("--wad")
        wad = args[i + 1]
        del args[i:i + 2]
    scale = 8
    if "--scale" in args:
        i = args.index("--scale")
        scale = int(args[i + 1])
        del args[i:i + 2]
    src = args[0] if len(args) > 0 else "frame_fpga.bin"
    dst = args[1] if len(args) > 1 else "frame.png"
    raw = open(src, "rb").read()
    if doom:
        w, h, px = 320, 200, raw[:64000]
        pal = None
        if wad:
            data = open(wad, "rb").read()
            _, numlumps, infotableofs = struct.unpack("<4sII", data[:12])
            for i in range(numlumps):
                filepos, _, name = struct.unpack("<II8s", data[infotableofs + 16 * i:infotableofs + 16 * i + 16])
                if name.rstrip(b"\x00") == b"PLAYPAL":
                    pal = data[filepos:filepos + 768]
                    break
        img = Image.new("RGB", (w, h))
        out = img.load()
        for y in range(h):
            for x in range(w):
                v = px[y * w + x]
                if pal:
                    out[x, y] = (pal[3 * v], pal[3 * v + 1], pal[3 * v + 2])
                else:
                    out[x, y] = (v, v, v)
    else:
        w, h, px = 64, 32, raw[:2048]
        img = Image.new("RGB", (w, h))
        out = img.load()
        for y in range(h):
            for x in range(w):
                out[x, y] = rgb332(px[y * w + x])
    img = img.resize((w * scale, h * scale), Image.NEAREST)
    img.save(dst)
    print(f"wrote {dst} ({w}x{h} x{scale})")


if __name__ == "__main__":
    main()
