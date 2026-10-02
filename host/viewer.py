#!/usr/bin/env python3
"""doom_viewer.py -- Live DOOM video streaming & interactive controller over UART.

Receives rendered framebuffers from the DE0-Nano FPGA over UART (COM7 @ 921,600 baud),
renders them in real-time in authentic 256-color DOOM palette, and captures laptop
keyboard inputs (with press & release) to play the game interactively.

Controls:
  Arrow Keys / WASD : Move / Turn
  Ctrl              : Fire (+attack)
  Space             : Open Doors / Activate (+use)
  Shift             : Run / Speed (+speed)
  Enter             : Menu select
  Escape            : Game Menu
  Tab               : Automap
  1 - 7             : Select Weapons
  F1                : Switch to Full Resolution (320x200 @ ~1.4 FPS)
  F2                : Switch to Fast Half Resolution (160x100 @ ~5.8 FPS)
  F3                : Toggle Stream Pause / Resume
"""

import argparse
import os
import queue
import struct
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk

import numpy as np
from PIL import Image, ImageTk
import serial

# DOOM engine keycodes (doomkeys.h)
DOOM_KEYS = {
    # Arrows / WASD
    "Up": 0xAD, "w": 0xAD, "W": 0xAD,
    "Down": 0xAF, "s": 0xAF, "S": 0xAF,
    "Left": 0xAC, "a": 0xAC, "A": 0xAC,
    "Right": 0xAE, "d": 0xAE, "D": 0xAE,
    # Actions
    "Control_L": 0xA3, "Control_R": 0xA3,  # Fire (KEY_FIRE, doomkeys.h)
    "space": 0xA2,                            # Use / Open (KEY_USE, doomkeys.h)
    "Shift_L": 0xB6, "Shift_R": 0xB6,      # Run
    "Alt_L": 0xB8, "Alt_R": 0xB8,          # Strafe
    "Return": 13,                           # Enter
    "BackSpace": 8,                         # Backspace / Delete
    "Escape": 27,                           # Menu
    "Tab": 9,                              # Automap
    # Weapons
    "1": 0x31, "2": 0x32, "3": 0x33, "4": 0x34,
    "5": 0x35, "6": 0x36, "7": 0x37,
    # Yes / No for menus
    "y": 0x79, "Y": 0x79,
    "n": 0x6E, "N": 0x6E,
}

# Streamer command codes
CMD_RELEASE_PREFIX = 0xF0
CMD_FULL_RES       = 0xFC  # 320x200
CMD_HALF_RES       = 0xFD  # 160x100
CMD_TOGGLE_DUMP    = 0xFE  # Pause/Resume


def make_rgb332_palette() -> np.ndarray:
    """Standard 256-color RGB332 palette (3 bits R, 3 bits G, 2 bits B)."""
    pal = np.zeros((256, 3), dtype=np.uint8)
    for b in range(256):
        pal[b] = [
            ((b >> 5) & 7) * 255 // 7,
            ((b >> 2) & 7) * 255 // 7,
            (b & 3) * 255 // 3,
        ]
    return pal


def load_wad_palette(wad_path: str) -> np.ndarray:
    """Extract the first 256-color RGB palette (PLAYPAL lump) from WAD or MENUWAD blob."""
    if not os.path.exists(wad_path):
        print(f"[viewer] WAD not found at {wad_path}, using RGB332 palette")
        return make_rgb332_palette()

    with open(wad_path, "rb") as f:
        data = f.read()

    # Search for IWAD magic anywhere in the file (handles standalone WAD and packed menu.blob)
    iwad_pos = data.find(b'IWAD')
    if iwad_pos < 0:
        iwad_pos = data.find(b'PWAD')

    if iwad_pos >= 0:
        magic, numlumps, infotableofs = struct.unpack("<4sII", data[iwad_pos : iwad_pos + 12])
        base = iwad_pos
        for i in range(numlumps):
            entry_ofs = base + infotableofs + i * 16
            if entry_ofs + 16 > len(data):
                break
            filepos, size, name = struct.unpack("<II8s", data[entry_ofs : entry_ofs + 16])
            name_str = name.rstrip(b"\x00").decode("ascii", errors="ignore")
            if name_str == "PLAYPAL":
                raw_pal = data[base + filepos : base + filepos + 768]
                palette = np.frombuffer(raw_pal, dtype=np.uint8).reshape((256, 3))
                print(f"[viewer] Loaded authentic DOOM PLAYPAL from {wad_path}")
                return palette

    print(f"[viewer] PLAYPAL lump not found in {wad_path}, using RGB332 palette")
    return make_rgb332_palette()


class SerialReceiver(threading.Thread):
    """Background thread that parses frames and console logs from the FPGA UART."""

    MAGIC = b"\x55\xAA\x5A\xA5"

    def __init__(self, ser: serial.Serial, frame_queue: queue.Queue, stop_event: threading.Event):
        super().__init__(daemon=True)
        self.ser = ser
        self.frame_queue = frame_queue
        self.stop_event = stop_event
        self.rx_buf = bytearray()

    def run(self):
        while not self.stop_event.is_set():
            try:
                chunk = self.ser.read(4096)
                if not chunk:
                    continue
                self.rx_buf.extend(chunk)

                # Process buffer
                while len(self.rx_buf) >= 10:
                    idx = self.rx_buf.find(self.MAGIC)
                    if idx < 0:
                        # No magic in buffer: all is console/terminal text
                        # Keep last 3 bytes in case magic is split across reads
                        text_bytes = bytes(self.rx_buf[:-3])
                        self.rx_buf = self.rx_buf[-3:]
                        if text_bytes:
                            sys.stdout.buffer.write(text_bytes)
                            sys.stdout.buffer.flush()
                        break

                    # If there is text preceding the magic, print it
                    if idx > 0:
                        text_bytes = bytes(self.rx_buf[:idx])
                        sys.stdout.buffer.write(text_bytes)
                        sys.stdout.buffer.flush()
                        self.rx_buf = self.rx_buf[idx:]

                    # Check if full header is available (10 bytes)
                    if len(self.rx_buf) < 10:
                        break

                    # Parse 10-byte header
                    mode = self.rx_buf[4]
                    frame_num = self.rx_buf[5] | (self.rx_buf[6] << 8)
                    width = self.rx_buf[7] | (self.rx_buf[8] << 8)
                    height = self.rx_buf[9]

                    # Sanity check header
                    if width not in (64, 160, 320) or height not in (32, 100, 200):
                        # False sync, skip first magic byte
                        self.rx_buf = self.rx_buf[1:]
                        continue

                    expected_pixels = width * height
                    total_needed = 10 + expected_pixels

                    if len(self.rx_buf) < total_needed:
                        # Wait for complete frame
                        break

                    # Extract pixels
                    pixel_bytes = bytes(self.rx_buf[10:total_needed])
                    self.rx_buf = self.rx_buf[total_needed:]

                    # Push frame to UI
                    frame_data = {
                        "mode": mode,
                        "frame_num": frame_num,
                        "width": width,
                        "height": height,
                        "pixels": pixel_bytes,
                        "timestamp": time.time(),
                    }
                    try:
                        # Drop old frame if UI is lagging behind
                        if self.frame_queue.full():
                            try:
                                self.frame_queue.get_nowait()
                            except queue.Empty:
                                pass
                        self.frame_queue.put_nowait(frame_data)
                    except queue.Full:
                        pass

            except serial.SerialException as e:
                print(f"\n[viewer] Serial error: {e}")
                break
            except Exception as e:
                print(f"\n[viewer] Unexpected error: {e}")
                break


class DoomViewerApp:
    """Tkinter Application for interactive DOOM display and controls."""

    def __init__(self, root: tk.Tk, ser: serial.Serial, palette: np.ndarray, init_mode: str):
        self.root = root
        self.ser = ser
        self.palette_doom = palette
        self.palette_rgb332 = make_rgb332_palette()
        self.palette = palette if init_mode == "doom" else self.palette_rgb332
        self.stop_event = threading.Event()
        self.frame_queue = queue.Queue(maxsize=3)

        # Target display dimensions (640x400 default)
        self.display_w = 640
        self.display_h = 400

        self.root.title("DOOM FPGA Live [COM7] - Connecting...")
        self.root.geometry(f"{self.display_w}x{self.display_h + 30}")
        self.root.configure(bg="black")

        # Canvas for game display
        self.canvas = tk.Canvas(
            root, width=self.display_w, height=self.display_h, bg="black", highlightthickness=0
        )
        self.canvas.pack(fill=tk.BOTH, expand=True)

        # Status / Controls bar
        self.status_var = tk.StringVar(
            value="Controls: Arrows/WASD: Move | Ctrl: Fire | Space: Use | ESC: Exit Game (Confirm Y/N)"
        )
        self.status_label = tk.Label(
            root, textvariable=self.status_var, bg="#111111", fg="#00FF00", font=("Consolas", 9)
        )
        self.status_label.pack(fill=tk.X, side=tk.BOTTOM)

        # PhotoImage holder to prevent garbage collection
        self.current_photo = None
        self.image_item = None

        # FPS calculation
        self.fps_frames = 0
        self.fps_start = time.time()
        self.current_fps = 0.0

        # Currently pressed keys (to handle press/release)
        self.pressed_keys = set()

        # Bind keyboard events
        self.root.bind("<KeyPress>", self.on_key_press)
        self.root.bind("<KeyRelease>", self.on_key_release)
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

        # Start receiver thread
        self.receiver = SerialReceiver(self.ser, self.frame_queue, self.stop_event)
        self.receiver.start()

        # Send initial mode command
        if init_mode == "full":
            print("[viewer] Requesting 320x200 full resolution mode")
            self.send_byte(CMD_FULL_RES)
        else:
            print("[viewer] Requesting 160x100 fast half resolution mode (~5.8 FPS)")
            self.send_byte(CMD_HALF_RES)

        # Poll for frames
        self.root.after(10, self.update_frame)

    def send_byte(self, b: int):
        try:
            self.ser.write(bytes([b]))
        except Exception as e:
            print(f"[viewer] Error writing serial byte: {e}")

    def on_key_press(self, event: tk.Event):
        key = event.keysym
        # Handle streamer hotkeys
        if key == "F1":
            print("[viewer] Switch to 320x200 full resolution")
            self.send_byte(CMD_FULL_RES)
            return
        elif key == "F2":
            print("[viewer] Switch to 160x100 fast resolution")
            self.send_byte(CMD_HALF_RES)
            return
        elif key == "F3":
            print("[viewer] Toggle stream pause/resume")
            self.send_byte(CMD_TOGGLE_DUMP)
            return

        # Check hotkey P for palette toggle (RGB332 <-> DOOM)
        if key in ("p", "P") and (event.state & 4) == 0:
            if np.array_equal(self.palette, self.palette_rgb332):
                self.palette = self.palette_doom
                print("[viewer] Switched palette: Authentic DOOM PLAYPAL")
            else:
                self.palette = self.palette_rgb332
                print("[viewer] Switched palette: RGB332 Retro Console")
            return

        # Check key mappings or fall back to ASCII char
        keycode = DOOM_KEYS.get(key)
        if keycode is None and event.char:
            b = event.char.encode("latin1", "ignore")
            if len(b) == 1:
                keycode = b[0]

        if keycode is not None:
            if keycode not in self.pressed_keys:
                self.pressed_keys.add(keycode)
                self.send_byte(keycode)

    def on_key_release(self, event: tk.Event):
        key = event.keysym
        keycode = DOOM_KEYS.get(key)
        if keycode is None and event.char:
            b = event.char.encode("latin1", "ignore")
            if len(b) == 1:
                keycode = b[0]

        if keycode is not None and keycode in self.pressed_keys:
            self.pressed_keys.remove(keycode)
            # Send 0xF0 release prefix followed by keycode
            try:
                self.ser.write(bytes([CMD_RELEASE_PREFIX, keycode]))
            except Exception as e:
                print(f"[viewer] Error sending key release: {e}")

    def update_frame(self):
        try:
            while not self.frame_queue.empty():
                frame = self.frame_queue.get_nowait()
                width = frame["width"]
                height = frame["height"]
                pixels = frame["pixels"]
                frame_num = frame["frame_num"]

                # Map pixels through DOOM palette
                indexed = np.frombuffer(pixels, dtype=np.uint8).reshape((height, width))
                rgb = self.palette[indexed]

                # Convert to PIL Image & upscale to window size with nearest-neighbor
                img = Image.fromarray(rgb)
                img = img.resize((self.display_w, self.display_h), Image.NEAREST)

                self.current_photo = ImageTk.PhotoImage(img)
                if self.image_item is None:
                    self.image_item = self.canvas.create_image(
                        0, 0, anchor=tk.NW, image=self.current_photo
                    )
                else:
                    self.canvas.itemconfig(self.image_item, image=self.current_photo)

                # Update FPS
                self.fps_frames += 1
                now = time.time()
                elapsed = now - self.fps_start
                if elapsed >= 1.0:
                    self.current_fps = self.fps_frames / elapsed
                    self.fps_frames = 0
                    self.fps_start = now
                    mode_str = "160x100 @ 5.8 FPS" if width == 160 else "320x200 @ 1.4 FPS"
                    self.root.title(
                        f"DOOM FPGA Live [COM7] - {self.current_fps:.1f} FPS | Frame {frame_num} | {mode_str}"
                    )

        except Exception as e:
            print(f"[viewer] Frame render error: {e}")

        # Schedule next update
        if not self.stop_event.is_set():
            self.root.after(15, self.update_frame)

    def on_close(self):
        print("[viewer] Closing...")
        self.stop_event.set()
        try:
            self.ser.close()
        except Exception:
            pass
        self.root.destroy()


def main():
    parser = argparse.ArgumentParser(description="DOOM FPGA Live UART Viewer & Controller")
    parser.add_argument("--port", default="COM7", help="Serial port (default: COM7)")
    parser.add_argument("--baud", type=int, default=921600, help="Baud rate (default: 921600)")
    parser.add_argument(
        "--wad", default=r"C:\doom_fpga\doom\doom1.wad", help="Path to DOOM WAD for palette"
    )
    parser.add_argument(
        "--mode", choices=["half", "full"], default="half", help="Initial resolution mode"
    )
    args = parser.parse_args()

    palette = load_wad_palette(args.wad)

    print(f"[viewer] Opening serial port {args.port} at {args.baud} baud...")
    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.05)
    except Exception as e:
        print(f"[viewer] Error opening port {args.port}: {e}")
        sys.exit(1)

    root = tk.Tk()
    app = DoomViewerApp(root, ser, palette, args.mode)
    print("[viewer] DOOM Viewer started. Press Ctrl+C in terminal or close window to exit.")
    root.mainloop()


if __name__ == "__main__":
    main()
