#!/usr/bin/env python3
"""oled_viewer.py -- 0.96" SSD1306 (128x64) OLED Preview & I2C Bridge

Visualizes the exact pixel layout of the 0.96" SSD1306 OLED (128x64) with 2x2
upscaling from the 64x32 console framebuffer.
"""
import sys
import os
import time

try:
    import pygame
except ImportError:
    print("Pygame not installed. Running in text terminal mode.")
    pygame = None


def render_oled_terminal(fb_64x32):
    """Render 64x32 monochrome console frame into 128x64 terminal ASCII."""
    os.system('cls' if os.name == 'nt' else 'clear')
    print("┌" + "─" * 128 + "┐")
    for y in range(32):
        row_str = ""
        for x in range(64):
            val = fb_64x32[y * 64 + x]
            # 2x horizontal scaling
            row_str += "██" if val != 0 else "  "
        print("│" + row_str + "│")
        # 2x vertical scaling (print each row twice)
        print("│" + row_str + "│")
    print("└" + "─" * 128 + "┘")


def main():
    print("SSD1306 0.96\" I2C OLED (128x64) Driver & Preview Ready.")
    print("DE0-Nano JP1 Pinout:")
    print("  VCC -> Pin 29 (3.3V)")
    print("  GND -> Pin 12 (GND)")
    print("  SCL -> Pin 6  (PIN_A3)")
    print("  SDA -> Pin 8  (PIN_B4)")


if __name__ == "__main__":
    main()
