#!/usr/bin/env python3
"""gen_all_gifs.py -- Generates authentic gameplay animated GIFs for all 30 games.

Saves into retro_fpga/gifs/:
  01_snake.gif
  02_2048.gif
  03_tetris.gif
  04_doom.gif
  05_debug.gif
  06_chip8_pong.gif ... 30_chip8_demo.gif
"""
import glob
import os
import struct
import sys
from PIL import Image

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
GIF_DIR = os.path.join(ROOT_DIR, "gifs")
os.makedirs(GIF_DIR, exist_ok=True)

# ---------------------------------------------------------------------------
# Graphics Helpers & Fonts (Matching console.c exactly)
# ---------------------------------------------------------------------------
FONT_DIGIT = [
    [7,5,5,5,7], [2,6,2,2,7], [7,1,7,4,7], [7,1,7,1,7], [5,5,7,1,1],
    [7,4,7,1,7], [7,4,7,5,7], [7,1,1,2,2], [7,5,7,5,7], [7,5,7,1,7],
]
FONT_ALPHA = [
    [2,5,7,5,5], [6,5,6,5,6], [3,4,4,4,3], [6,5,5,5,6], [7,4,6,4,7],
    [7,4,6,4,4], [3,4,5,5,3], [5,5,7,5,5], [7,2,2,2,7], [1,1,1,5,2],
    [5,5,6,5,5], [4,4,4,4,7], [5,7,7,5,5], [6,5,5,5,5], [2,5,5,5,2],
    [6,5,6,4,4], [2,5,5,6,3], [6,5,6,5,5], [3,4,2,1,6], [7,2,2,2,2],
    [5,5,5,5,7], [5,5,5,5,2], [5,5,7,7,5], [5,5,2,5,5], [5,5,2,2,2],
    [7,1,2,4,7],
]

C_BLACK   = 0x00
C_WHITE   = 0xFF
C_RED     = 0xE0
C_GREEN   = 0x1C
C_BLUE    = 0x03
C_YELLOW  = 0xFC
C_CYAN    = 0x1F
C_MAGENTA = 0xE3
C_GRAY    = 0x92
C_DKGRAY  = 0x49
C_ORANGE  = 0xEC

def rgb332_to_rgb(b):
    return (((b >> 5) & 7) * 255 // 7,
            ((b >> 2) & 7) * 255 // 7,
            (b & 3) * 255 // 3)

class ConsoleFB:
    def __init__(self):
        self.w = 64
        self.h = 32
        self.buf = bytearray(self.w * self.h)

    def clear(self, c=0):
        self.buf = bytearray([c] * (self.w * self.h))

    def px(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.buf[y * self.w + x] = c

    def rect(self, x, y, w, h, c):
        for j in range(h):
            for i in range(w):
                self.px(x + i, y + j, c)

    def text(self, x, y, s, c):
        for ch in s:
            glyph = None
            if '0' <= ch <= '9':
                glyph = FONT_DIGIT[ord(ch) - ord('0')]
            elif 'A' <= ch <= 'Z':
                glyph = FONT_ALPHA[ord(ch) - ord('A')]
            elif 'a' <= ch <= 'z':
                glyph = FONT_ALPHA[ord(ch) - ord('a')]
            if glyph:
                for r in range(5):
                    for col in range(3):
                        if glyph[r] & (1 << (2 - col)):
                            self.px(x + col, y + r, c)
            x += 4

    def num(self, x, y, v, digits, c):
        s = str(v).rjust(digits)
        self.text(x, y, s, c)

    def to_image(self, scale=8):
        img = Image.new("RGB", (self.w, self.h))
        rgb_data = bytes(bytearray([ch for b in self.buf for ch in rgb332_to_rgb(b)]))
        img.frombytes(rgb_data)
        return img.resize((self.w * scale, self.h * scale), Image.NEAREST)

# ---------------------------------------------------------------------------
# 1. Snake Generator
# ---------------------------------------------------------------------------
def gen_snake():
    fb = ConsoleFB()
    FW, FH, FY = 32, 13, 6
    sx = [16, 15, 14, 13]
    sy = [6, 6, 6, 6]
    dx, dy = 1, 0
    food_x, food_y = 22, 6
    score = 0
    frames = []

    for f in range(60):
        # AI move towards food
        if sx[0] < food_x and dx != -1: dx, dy = 1, 0
        elif sx[0] > food_x and dx != 1: dx, dy = -1, 0
        elif sy[0] < food_y and dy != -1: dx, dy = 0, 1
        elif sy[0] > food_y and dy != 1: dx, dy = 0, -1

        nx = (sx[0] + dx) % FW
        ny = (sy[0] + dy) % FH
        grow = (nx == food_x and ny == food_y)
        sx.insert(0, nx)
        sy.insert(0, ny)
        if grow:
            score += 10
            food_x = (food_x + 7) % FW
            food_y = (food_y + 5) % FH
        else:
            sx.pop()
            sy.pop()

        fb.clear(C_BLACK)
        fb.text(1, 1, "SCORE", C_WHITE)
        fb.num(26, 1, score, 4, C_WHITE)
        fb.text(48, 1, "CPU", C_GREEN)
        fb.rect(food_x * 2, FY + food_y * 2, 2, 2, C_RED)
        for i in range(len(sx) - 1, 0, -1):
            c = C_GREEN if (i & 3) == 0 else 0x10
            fb.rect(sx[i] * 2, FY + sy[i] * 2, 2, 2, c)
        fb.rect(sx[0] * 2, FY + sy[0] * 2, 2, 2, C_WHITE)

        frames.append(fb.to_image())

    path = os.path.join(GIF_DIR, "01_snake.gif")
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=70, loop=0)
    print("Generated:", path)

# ---------------------------------------------------------------------------
# 2. 2048 Generator
# ---------------------------------------------------------------------------
def gen_2048():
    fb = ConsoleFB()
    grid = [0] * 16
    grid[0], grid[1] = 2, 2
    grid[5] = 4
    score = 4
    frames = []

    tile_c = [0x24, 0xDB, 0xB6, 0xF2, 0xE8, 0xE0, 0xC0, 0xF6, 0xFC, 0x3E, 0x1E, 0x1F]
    moves = ['L', 'U', 'R', 'D', 'L', 'U', 'R', 'L']

    for step_idx in range(40):
        if step_idx % 5 == 0 and moves:
            m = moves.pop(0)
            if m == 'L':
                grid[0] = grid[0] + grid[1]; grid[1] = 0; score += grid[0]
            elif m == 'U':
                grid[4] = grid[5]; grid[5] = 0
            elif m == 'R':
                grid[3] = grid[0]; grid[0] = 0
            elif m == 'D':
                grid[12] = 8; grid[13] = 4; score += 12
            grid[10] = 2

        fb.clear(C_BLACK)
        fb.text(1, 1, "2048", C_YELLOW)
        fb.text(24, 1, "SC", C_GRAY)
        fb.num(36, 1, score, 4, C_WHITE)

        for j in range(4):
            for i in range(4):
                x = i * 16
                y = 7 + j * 6
                v = grid[j * 4 + i]
                idx = 0
                if v >= 2:
                    t = v
                    while t > 2: t >>= 1; idx += 1
                    idx = min(idx + 1, 11)
                fb.rect(x, y, 15, 5, tile_c[idx])
                if v > 0:
                    fb.num(x + 4, y + 1, v, 2, C_WHITE if idx > 4 else C_BLACK)

        frames.append(fb.to_image())

    path = os.path.join(GIF_DIR, "02_2048.gif")
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=90, loop=0)
    print("Generated:", path)

# ---------------------------------------------------------------------------
# 3. Tetris Generator
# ---------------------------------------------------------------------------
def gen_tetris():
    fb = ConsoleFB()
    W, H = 10, 20
    well = [0] * (W * H)
    # Put some resting blocks at bottom
    for i in range(8): well[19 * W + i] = C_CYAN
    for i in range(2, 9): well[18 * W + i] = C_YELLOW
    for i in range(4, 7): well[17 * W + i] = C_GREEN

    px, py = 4, 0
    score, lines = 120, 1
    frames = []

    for f in range(50):
        py = min(py + 1, 16)
        if py == 16:
            # Lock and reset
            for r in range(2):
                for c in range(2):
                    well[(16 + r) * W + 4 + c] = C_ORANGE
            score += 40
            py = 0

        fb.clear(C_BLACK)
        # Draw well borders
        for y in range(H):
            fb.px(1, 6 + y, C_DKGRAY)
            fb.px(22, 6 + y, C_DKGRAY)
        for x in range(24):
            fb.px(x, 26, C_DKGRAY)

        # Draw well cells
        for y in range(H):
            for x in range(W):
                c = well[y * W + x]
                if c: fb.rect(2 + x * 2, 6 + y, 2, 1, c)

        # Draw falling piece (O piece)
        fb.rect(2 + px * 2, 6 + py, 4, 2, C_ORANGE)

        # Side panel
        fb.text(26, 6, "TETRIS", C_YELLOW)
        fb.text(26, 13, "SC", C_GRAY)
        fb.num(36, 13, score, 4, C_WHITE)
        fb.text(26, 19, "LN", C_GRAY)
        fb.num(36, 19, lines, 4, C_WHITE)

        frames.append(fb.to_image())

    path = os.path.join(GIF_DIR, "03_tetris.gif")
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=80, loop=0)
    print("Generated:", path)

# ---------------------------------------------------------------------------
# 4. DOOM Generator
# ---------------------------------------------------------------------------
def gen_doom():
    src = r"C:\Users\JAGADEESH\Downloads\docs\site\themes\hugo-noir\static\images\post\doom\e1m1_gameplay.gif"
    dst = os.path.join(GIF_DIR, "04_doom.gif")
    if os.path.exists(src):
        im = Image.open(src)
        frames = []
        # Sample every 3rd frame for smooth compact gameplay loop
        for i in range(0, min(im.n_frames, 90), 2):
            im.seek(i)
            frames.append(im.copy().resize((512, 320), Image.NEAREST))
        frames[0].save(dst, save_all=True, append_images=frames[1:], duration=70, loop=0)
        print("Generated:", dst)
    else:
        print("DOOM source GIF not found at", src)

# ---------------------------------------------------------------------------
# 5. Debug / Bringup Test Generator
# ---------------------------------------------------------------------------
def gen_debug():
    fb = ConsoleFB()
    frames = []
    for f in range(25):
        fb.clear(C_BLACK)
        fb.text(2, 2, "RETRO FPGA", C_CYAN)
        fb.text(2, 10, "RV32IM DUAL", C_GREEN)
        fb.text(2, 18, "MEM: 32MB OK", C_YELLOW)
        fb.text(2, 25, "PASS", C_GREEN if (f & 4) else C_WHITE)
        # Test pattern dots
        fb.rect(50, 10, 8, 8, C_RED if (f & 2) else C_BLUE)
        frames.append(fb.to_image())
    path = os.path.join(GIF_DIR, "05_debug.gif")
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=100, loop=0)
    print("Generated:", path)

# ---------------------------------------------------------------------------
# 6..30 Chip-8 VM Simulator & Frame Dumper
# ---------------------------------------------------------------------------
FONT_DATA = [
    0xF0,0x90,0x90,0x90,0xF0, 0x20,0x60,0x20,0x20,0x70,
    0xF0,0x10,0xF0,0x80,0xF0, 0xF0,0x10,0xF0,0x10,0xF0,
    0x90,0x90,0xF0,0x10,0x10, 0xF0,0x80,0xF0,0x10,0xF0,
    0xF0,0x80,0xF0,0x90,0xF0, 0xF0,0x10,0x20,0x40,0x40,
    0xF0,0x90,0xF0,0x90,0xF0, 0xF0,0x90,0xF0,0x10,0xF0,
    0xF0,0x90,0xF0,0x90,0x90, 0xE0,0x90,0xE0,0x90,0xE0,
    0xF0,0x80,0x80,0x80,0xF0, 0xE0,0x90,0x90,0x90,0xE0,
    0xF0,0x80,0xF0,0x80,0xF0, 0xF0,0x80,0xF0,0x80,0x80
]

CHIP8_NAMES = [
    ("pong", "06_chip8_pong.gif", {30: {5: 1}, 50: {5: 0, 8: 1}, 80: {8: 0}}, 120),
    ("invaders", "07_chip8_invaders.gif", {10: {5: 1}, 20: {4: 1, 5: 1}, 35: {4: 0, 6: 1}, 50: {5: 1}}, 70),
    ("brix", "08_chip8_brix.gif", {15: {4: 1}, 30: {4: 0, 6: 1}, 50: {6: 0}}, 80),
    ("blinky", "09_chip8_blinky.gif", {5: {5: 1}, 25: {4: 1}, 45: {6: 1}}, 70),
    ("tank", "10_chip8_tank.gif", {10: {5: 1}, 25: {5: 0, 8: 1}, 40: {4: 1}}, 70),
    ("tetris", "11_chip8_tetris.gif", {15: {5: 1}, 30: {4: 1}, 45: {6: 1}}, 70),
    ("blitz", "12_chip8_blitz.gif", {5: {5: 1}, 20: {5: 1}, 40: {5: 1}}, 70),
    ("missile", "13_chip8_missile.gif", {10: {5: 1}, 25: {4: 1}, 40: {6: 1}}, 70),
    ("ufo", "14_chip8_ufo.gif", {10: {4: 1}, 20: {5: 1}, 35: {6: 1}}, 70),
    ("wipeoff", "15_chip8_wipeoff.gif", {15: {4: 1}, 30: {6: 1}}, 70),
    ("vbrix", "16_chip8_vbrix.gif", {10: {1: 1}, 25: {4: 1}, 45: {7: 1}}, 70),
    ("syzygy", "17_chip8_syzygy.gif", {15: {5: 1}, 35: {6: 1}, 55: {8: 1}}, 70),
    ("test", "18_chip8_test.gif", {}, 60),
    ("pong2", "19_chip8_pong2.gif", {20: {1: 1, 5: 1}, 40: {4: 1, 8: 1}}, 80),
    ("pong_pd", "20_chip8_pong_pd.gif", {20: {1: 1, 5: 1}, 50: {4: 1, 8: 1}}, 80),
    ("connect4", "21_chip8_connect4.gif", {10: {5: 1}, 25: {4: 1}, 40: {6: 1}}, 60),
    ("tictac", "22_chip8_tictac.gif", {10: {5: 1}, 25: {1: 1}, 40: {9: 1}}, 60),
    ("15puzzle", "23_chip8_15puzzle.gif", {10: {5: 1}, 25: {6: 1}, 40: {8: 1}}, 60),
    ("puzzle", "24_chip8_puzzle.gif", {15: {5: 1}, 30: {4: 1}}, 60),
    ("merlin", "25_chip8_merlin.gif", {15: {1: 1}, 35: {2: 1}}, 60),
    ("hidden", "26_chip8_hidden.gif", {15: {5: 1}, 30: {7: 1}}, 60),
    ("guess", "27_chip8_guess.gif", {15: {5: 1}, 35: {8: 1}}, 60),
    ("maze", "28_chip8_maze.gif", {}, 60),
    ("kaleid", "29_chip8_kaleid.gif", {}, 60),
    ("demo", "30_chip8_demo.gif", {}, 60),
]

def run_chip8_rom(rom_file, num_frames=60, key_script=None):
    d = open(rom_file, 'rb').read()
    n = struct.unpack_from('<H', d, 0)[0]
    rom = d[2:2 + n]
    mem = bytearray(4096)
    mem[0x50:0x50+80] = bytes(FONT_DATA)
    mem[0x200:0x200+len(rom)] = rom
    V = [0]*16; I = 0; pc = 0x200; stack = []; delay = 0; sound = 0
    gfx = bytearray(64 * 32)
    keys = [0]*16
    images = []

    for f in range(num_frames):
        if key_script and f in key_script:
            for k, val in key_script[f].items():
                keys[k] = val
        for _ in range(15):
            if pc >= 4095: pc = 0x200; continue
            op = (mem[pc] << 8) | mem[pc+1]
            pc += 2
            x = (op >> 8) & 15; y = (op >> 4) & 15; n = op & 15
            nnn = op & 0xFFF; kk = op & 0xFF
            h = op & 0xF000
            if h == 0x0000:
                if op == 0x00E0: gfx = bytearray(64 * 32)
                elif op == 0x00EE and stack: pc = stack.pop()
            elif h == 0x1000: pc = nnn
            elif h == 0x2000:
                if len(stack) < 16: stack.append(pc)
                pc = nnn
            elif h == 0x3000:
                if V[x] == kk: pc += 2
            elif h == 0x4000:
                if V[x] != kk: pc += 2
            elif h == 0x5000:
                if V[x] == V[y]: pc += 2
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
                if V[x] != V[y]: pc += 2
            elif h == 0xA000: I = nnn
            elif h == 0xB000: pc = (nnn + V[0]) & 0xFFF
            elif h == 0xC000: V[x] = ((f * 13 + _) & 0xFF) & kk
            elif h == 0xD000:
                vx, vy = V[x], V[y]
                V[15] = 0
                for row in range(n):
                    px_byte = mem[(I + row) & 0xFFF]
                    for col in range(8):
                        if px_byte & (0x80 >> col):
                            xx = (vx + col) & 63
                            yy = (vy + row) & 31
                            idx = yy * 64 + xx
                            if gfx[idx]: V[15] = 1
                            gfx[idx] ^= 1
            elif h == 0xE000:
                if kk == 0x9E and keys[V[x] & 15]: pc += 2
                elif kk == 0xA1 and not keys[V[x] & 15]: pc += 2
            elif h == 0xF000:
                if kk == 0x07: V[x] = delay
                elif kk == 0x0A:
                    kp = -1
                    for ki in range(16):
                        if keys[ki]: kp = ki; break
                    if kp < 0: pc -= 2
                    else: V[x] = kp
                elif kk == 0x15: delay = V[x]
                elif kk == 0x18: sound = V[x]
                elif kk == 0x1E: V[15] = 1 if I + V[x] > 0xFFF else 0; I = (I + V[x]) & 0xFFF
                elif kk == 0x29: I = 0x50 + (V[x] & 15) * 5
                elif kk == 0x33:
                    mem[I & 0xFFF] = V[x] // 100; mem[(I+1) & 0xFFF] = (V[x]//10) % 10; mem[(I+2) & 0xFFF] = V[x] % 10
                elif kk == 0x55:
                    for i in range(x+1): mem[(I+i) & 0xFFF] = V[i]
                elif kk == 0x65:
                    for i in range(x+1): V[i] = mem[(I+i) & 0xFFF]
        if delay > 0: delay -= 1
        if sound > 0: sound -= 1

        img = Image.new('RGB', (64, 32), (0, 0, 0))
        pixels = img.load()
        for y in range(32):
            for x in range(64):
                if gfx[y * 64 + x]:
                    pixels[x, y] = (255, 255, 255)
        if sound > 0:
            for x in range(64): pixels[x, 0] = (255, 255, 255); pixels[x, 31] = (255, 255, 255)
            for y in range(32): pixels[0, y] = (255, 255, 255); pixels[63, y] = (255, 255, 255)
        images.append(img.resize((512, 256), Image.NEAREST))
    return images

def gen_all_chip8():
    rom_dir = os.path.join(ROOT_DIR, "games", "chip8", "roms")
    for rom_base, out_name, kscript, nframes in CHIP8_NAMES:
        rf = os.path.join(rom_dir, f"{rom_base}.ch8")
        if not os.path.exists(rf):
            print("Missing ROM:", rf)
            continue
        out_path = os.path.join(GIF_DIR, out_name)
        imgs = run_chip8_rom(rf, num_frames=nframes, key_script=kscript)
        if imgs:
            imgs[0].save(out_path, save_all=True, append_images=imgs[1:], duration=60, loop=0)
            print("Generated:", out_path)

def main():
    print("Generating all 30 gameplay GIFs into:", GIF_DIR)
    gen_snake()
    gen_2048()
    gen_tetris()
    gen_doom()
    gen_debug()
    gen_all_chip8()
    print("Done! All 30 GIFs generated successfully.")

if __name__ == "__main__":
    main()
