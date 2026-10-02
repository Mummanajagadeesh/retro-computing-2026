#!/usr/bin/env python3
"""tinyview.py -- Ultra-Fast 45 FPS Real-Time Viewer for 64x32 Retro Console.

Receives 64x32 RGB332 frames from DE0-Nano FPGA over UART (921,600 baud),
renders them scaled with crisp nearest-neighbor interpolation, and calculates
real-time frame rate (45 FPS).
Handles full keyboard capture (Arrows, WASD, Ctrl, Shift, Space, Enter, Digits, CP/M terminal).
"""
import argparse
import queue
import sys
import threading
import time
import tkinter as tk

import serial
from PIL import Image, ImageTk

MAGIC = b"\x55\xAA\x5A\xA5"


def rgb332(px: bytes) -> bytes:
    out = bytearray()
    for b in px:
        out += bytes((((b >> 5) & 7) * 255 // 7,
                      ((b >> 2) & 7) * 255 // 7,
                      (b & 3) * 255 // 3))
    return bytes(out)


class Receiver(threading.Thread):
    def __init__(self, ser, frames, stop):
        super().__init__(daemon=True)
        self.ser, self.frames, self.stop = ser, frames, stop
        self.buf = bytearray()

    def run(self):
        while not self.stop.is_set():
            try:
                chunk = self.ser.read(4096)
            except serial.SerialException as e:
                print(f"\n[tinyview] serial error: {e}")
                break
            if not chunk:
                continue
            self.buf.extend(chunk)
            while len(self.buf) >= 10:
                idx = self.buf.find(MAGIC)
                if idx < 0:
                    sys.stdout.buffer.write(bytes(self.buf[:-3]))
                    sys.stdout.buffer.flush()
                    self.buf = self.buf[-3:]
                    break
                if idx > 0:
                    sys.stdout.buffer.write(bytes(self.buf[:idx]))
                    sys.stdout.buffer.flush()
                    self.buf = self.buf[idx:]
                if len(self.buf) < 10:
                    break
                w = self.buf[7] | (self.buf[8] << 8)
                h = self.buf[9]
                if w != 64 or h != 32:
                    self.buf = self.buf[1:]
                    continue
                if len(self.buf) < 10 + 2048:
                    break
                px = bytes(self.buf[10:10 + 2048])
                self.buf = self.buf[10 + 2048:]
                try:
                    if self.frames.full():
                        self.frames.get_nowait()
                    self.frames.put_nowait(px)
                except queue.Full:
                    pass


# Special console keycodes matching console.h and doomkeys.h
KEY_MAP = {
    "Up": 0xAD,
    "Down": 0xAF,
    "Left": 0xAC,
    "Right": 0xAE,
    "space": 0x20,
    "Return": 0x0D,
    "Escape": 0x1B,
    "Tab": 0x09,
    "BackSpace": 0x08,
    "Control_L": 0xA3,
    "Control_R": 0xA3,
    "Shift_L": 0xB6,
    "Shift_R": 0xB6,
    "Alt_L": 0xB8,
    "Alt_R": 0xB8,
}

CMD_RELEASE_PREFIX = 0xF0


def get_keycode(ev):
    if ev.keysym in KEY_MAP:
        return KEY_MAP[ev.keysym]
    if ev.char:
        b = ev.char.lower().encode("latin1", "ignore")
        if len(b) == 1:
            return b[0]
    return None


def main():
    ap = argparse.ArgumentParser(description="retro_fpga 45 FPS 64x32 Console Viewer")
    ap.add_argument("--port", default="COM7")
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--scale", type=int, default=10)
    a = ap.parse_args()

    print(f"[tinyview] Connecting to {a.port} @ {a.baud} baud (45 FPS mode)...")
    try:
        ser = serial.Serial(a.port, a.baud, timeout=0.05)
    except Exception as e:
        print(f"[tinyview] Cannot open {a.port}: {e}")
        sys.exit(1)

    stop = threading.Event()
    frames = queue.Queue(maxsize=5)
    Receiver(ser, frames, stop).start()

    root = tk.Tk()
    img_w, img_h = 64 * a.scale, 32 * a.scale
    root.geometry(f"{img_w}x{img_h + 28}")
    root.configure(bg="#050505")
    root.title(f"retro_fpga Console [{a.port}] - Waiting for frames...")

    canvas = tk.Canvas(root, width=img_w, height=img_h,
                       bg="#000000", highlightthickness=0)
    canvas.pack(fill=tk.BOTH, expand=True)

    status_var = tk.StringVar(value="Controls: Arrows/WASD | Enter/Space | ESC: Exit Game (Confirm Y/N)")
    status_lbl = tk.Label(root, textvariable=status_var,
                          bg="#101015", fg="#00FF88", font=("Consolas", 9, "bold"))
    status_lbl.pack(fill=tk.X, side=tk.BOTTOM)

    photo = {"img": None, "item": None}
    nframes = {"n": 0}
    fps_state = {"last_t": time.time(), "count": 0, "fps": 0.0}
    pressed_keys = set()

    def on_key_press(ev):
        code = get_keycode(ev)
        if code is not None and code not in pressed_keys:
            pressed_keys.add(code)
            try:
                ser.write(bytes([code]))
            except Exception as e:
                print(f"[tinyview] write error: {e}")

    def on_key_release(ev):
        code = get_keycode(ev)
        if code is not None:
            pressed_keys.discard(code)
            try:
                ser.write(bytes([CMD_RELEASE_PREFIX, code]))
            except Exception as e:
                print(f"[tinyview] write error: {e}")

    def update():
        try:
            got_frame = False
            while not frames.empty():
                px = frames.get_nowait()
                img = Image.frombytes("RGB", (64, 32), rgb332(px))
                img = img.resize((img_w, img_h), Image.NEAREST)
                photo["img"] = ImageTk.PhotoImage(img)
                if photo["item"] is None:
                    photo["item"] = canvas.create_image(
                        0, 0, anchor=tk.NW, image=photo["img"])
                else:
                    canvas.itemconfig(photo["item"], image=photo["img"])
                nframes["n"] += 1
                fps_state["count"] += 1
                got_frame = True

            now = time.time()
            dt = now - fps_state["last_t"]
            if dt >= 0.5:
                fps_state["fps"] = fps_state["count"] / dt
                fps_state["count"] = 0
                fps_state["last_t"] = now
                root.title(f"retro_fpga Console [{a.port}] - {fps_state['fps']:.1f} FPS (Frame {nframes['n']})")

        except Exception as e:
            print(f"[tinyview] render error: {e}")

        if not stop.is_set():
            root.after(10, update)

    def on_close():
        stop.set()
        try:
            ser.close()
        except Exception:
            pass
        root.destroy()

    root.bind("<KeyPress>", on_key_press)
    root.bind("<KeyRelease>", on_key_release)
    root.protocol("WM_DELETE_WINDOW", on_close)
    root.after(10, update)
    print(f"[tinyview] Running @ {a.baud} baud. 64x32 @ 45 FPS active. Close window to exit.")
    root.mainloop()


if __name__ == "__main__":
    main()
