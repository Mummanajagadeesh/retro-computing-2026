#!/usr/bin/env python3
"""Turn tb_doom's frame_<n>.pgm dumps into something watchable.

The bridge writes the framebuffer as raw 8bpp indices (mem_top_dg.v emits a
P5 320x200 PGM per MM_DUMP write), so the only thing missing is PLAYPAL. This
reads it out of the IWAD's lump directory rather than hardcoding an offset,
applies it, and writes PNGs and/or an animated GIF.

    ./games/doom/frames2video.py --wad games/doom/freedoom1.wad --frames 'frame_*.pgm' \
        --out-gif games/doom/e1m1_walk.gif --scale 2 --fps 25

Frame delays come from --log (the testbench's "[dg] wrote frame_N.pgm cyc=..."
lines) so the animation is paced by simulated cycles, not guessed: at a chosen
clock the gaps between dumps are real game time. Pass --fps instead for a fixed
rate.
"""
import argparse
import glob
import os
import re
import struct
import sys

import numpy as np
from PIL import Image

W, H = 320, 200
PGM_HEADER = b"P5\n320 200\n255\n"
CYCLE_RE = re.compile(r"wrote frame_(\d+)\.pgm\s+cyc=(\d+)")


def playpal(wad_path: str) -> bytes:
    """First 768 bytes of the PLAYPAL lump (palette 0, 256 RGB triplets)."""
    with open(wad_path, "rb") as f:
        magic, nlumps, dirofs = struct.unpack("<4sII", f.read(12))
        if magic not in (b"IWAD", b"PWAD"):
            raise SystemExit(f"{wad_path}: not a WAD (magic {magic!r})")
        f.seek(dirofs)
        for _ in range(nlumps):
            ofs, size, name = struct.unpack("<II8s", f.read(16))
            if name.rstrip(b"\0") == b"PLAYPAL":
                f.seek(ofs)
                pal = f.read(768)
                if len(pal) != 768:
                    raise SystemExit(f"{wad_path}: PLAYPAL lump is {size} bytes")
                return pal
    raise SystemExit(f"{wad_path}: no PLAYPAL lump")


def load_frame(path: str) -> np.ndarray:
    raw = open(path, "rb").read()
    if not raw.startswith(PGM_HEADER):
        raise SystemExit(f"{path}: unexpected PGM header {raw[:16]!r}")
    body = raw[len(PGM_HEADER):]
    idx = np.frombuffer(body, dtype=np.uint8)
    if idx.size != W * H:
        raise SystemExit(f"{path}: {idx.size} pixels, expected {W*H}")
    return idx.reshape(H, W)


def frame_delays(log_path: str, min_ms: int, max_ms: int) -> dict[int, int]:
    """frame index -> display delay in ms, from simulated cycle deltas."""
    cycles: dict[int, int] = {}
    for line in open(log_path, errors="replace"):
        m = CYCLE_RE.search(line)
        if m:
            cycles[int(m.group(1))] = int(m.group(2))
    return cycles


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wad", required=True)
    ap.add_argument("--frames", default="frame_*.pgm")
    ap.add_argument("--out-prefix", default=None, help="write frame_%03d.png")
    ap.add_argument("--out-gif", default=None)
    ap.add_argument("--scale", type=int, default=2)
    ap.add_argument("--fps", type=float, default=0.0,
                    help="fixed frame rate; default 25 if no --clock")
    ap.add_argument("--clock", type=float, default=0.0,
                    help="assumed core clock in Hz; with --log, paces the GIF "
                         "by the real cycle gaps between frame dumps")
    ap.add_argument("--log", default=None, help="testbench stdout with cyc= lines")
    ap.add_argument("--max-frames", type=int, default=0)
    a = ap.parse_args()

    paths = sorted(glob.glob(a.frames),
                   key=lambda p: int(re.search(r"(\d+)", os.path.basename(p)).group(1)))
    if not paths:
        raise SystemExit(f"no frames match {a.frames}")
    if a.max_frames:
        paths = paths[:a.max_frames]

    pal = playpal(a.wad)
    lut = np.frombuffer(pal, dtype=np.uint8).reshape(256, 3)

    # per-frame delay in ms
    delay_ms = {}
    if a.log and a.clock:
        cyc = frame_delays(a.log, 0, 0)
        order = sorted(cyc)
        for i, n in enumerate(order):
            if i + 1 < len(order):
                dt = (cyc[order[i + 1]] - cyc[n]) / a.clock * 1000.0
            else:
                dt = 1000.0 / (a.fps or 25.0)
            delay_ms[n] = int(min(4000, max(20, round(dt))))
        print(f"[frames2video] paced from {a.log}: "
              f"delays {min(delay_ms.values())}..{max(delay_ms.values())} ms "
              f"(median {sorted(delay_ms.values())[len(delay_ms)//2]} ms)")
    fixed = int(1000.0 / (a.fps or 25.0))

    imgs = []
    for i, p in enumerate(paths):
        idx = load_frame(p)
        rgb = Image.fromarray(lut[idx], mode="RGB")
        if a.scale != 1:
            rgb = rgb.resize((W * a.scale, H * a.scale), Image.NEAREST)
        if a.out_prefix:
            rgb.save(f"{a.out_prefix}_{i:03d}.png")
        imgs.append((rgb, delay_ms.get(i, fixed)))

    if a.out_prefix:
        print(f"[frames2video] wrote {len(imgs)} PNGs as {a.out_prefix}_NNN.png")

    if a.out_gif:
        pal_imgs = [im.convert("P", palette=Image.ADAPTIVE, colors=256)
                    for im, _ in imgs]
        pal_imgs[0].save(
            a.out_gif, save_all=True, append_images=pal_imgs[1:],
            duration=[d for _, d in imgs], loop=0, optimize=True,
            disposal=2)
        size = os.path.getsize(a.out_gif)
        total = sum(d for _, d in imgs) / 1000.0
        print(f"[frames2video] wrote {a.out_gif}: {len(imgs)} frames, "
              f"{total:.1f} s, {size/1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
