# 0.96" SSD1306 I2C OLED Display Integration Guide

This guide explains how to connect and run a **0.96-inch $128 \times 64$ I2C OLED display (SSD1306)** directly on the DE0-Nano FPGA retro console in [`retro-comp-oled/`](file:///C:/Users/JAGADEESH/Downloads/doom-rv32im/retro-comp-oled).

---

## 1. Hardware Overview & Display Specifications

* **Display Controller**: SSD1306 CMOS OLED Driver
* **Screen Resolution**: $128 \times 64$ pixels (Monochrome blue/white/yellow-blue)
* **Interface**: 2-Wire I2C (SCL, SDA)
* **Bus Speed**: 400 kHz Fast-Mode I2C
* **I2C Address**: `0x3C` (Write byte: `0x78`)
* **Aspect Ratio & Resolution Mapping**:
  * Native Console Framebuffer: **$64 \times 32$**
  * Target OLED Display: **$128 \times 64$**
  * Scaling: **Exact $2\times2$ pixel-perfect integer scale** ($64 \times 2 = 128$, $32 \times 2 = 64$)
  * **0% distortion, zero cropping, and no black letterboxing!**

---

## 2. DE0-Nano JP1 Header Wiring

Connect the 4 pins of your 0.96" I2C OLED display module to the DE0-Nano **JP1** expansion header as follows:

| OLED Module Pin | DE0-Nano JP1 Header Pin | FPGA Pin (Cyclone IV) | Description |
| :--- | :--- | :--- | :--- |
| **VCC** | **Pin 29** (or external 3.3V) | `3.3V Power Rail` | 3.3V DC Power supply |
| **GND** | **Pin 12** | `GND Power Rail` | Ground |
| **SCL** | **Pin 6** | **`PIN_A3`** (`GPIO_0[2]`) | I2C Clock (400 kHz) with internal pull-up |
| **SDA** | **Pin 8** | **`PIN_B4`** (`GPIO_0[4]`) | I2C Data (Bidirectional) with internal pull-up |

> [!TIP]
> Both `OLED_SCL` and `OLED_SDA` are configured in Quartus with **Weak Pull-Up Resistors (`WEAK_PULL_UP_RESISTOR ON`)** and open-drain drive, so external pull-up resistors are optional if your module already has onboard 4.7kΩ resistors.

---

## 3. FPGA Architecture & RTL Modules

The hardware architecture in [`retro-comp-oled/fpga/rtl/`](file:///C:/Users/JAGADEESH/Downloads/doom-rv32im/retro-comp-oled/fpga/rtl) consists of:

1. **[`ssd1306_i2c.v`](file:///C:/Users/JAGADEESH/Downloads/doom-rv32im/retro-comp-oled/fpga/rtl/ssd1306_i2c.v)**:
   * **Power-On Reset State Machine**: Handles the 20ms startup delay and issues the 25-byte SSD1306 initialization sequence (Charge Pump ON, Horizontal Addressing Mode, 64-MUX, Remapped COM/SEG).
   * **Frame Scanner & $2\times2$ Pixel Scaler**: Reads the 64×32 framebuffer and continuously constructs the 8-page $\times$ 128-column ($1024$ byte) GDDRAM payload.
   * **400 kHz I2C Master**: Drives the open-drain SCL and SDA lines to stream live video at ~30–45 FPS.

2. **[`mem_top_fpga.v`](file:///C:/Users/JAGADEESH/Downloads/doom-rv32im/retro-comp-oled/fpga/rtl/mem_top_fpga.v)**:
   * Framebuffer memory tap (`fb_stream_valid`, `fb_stream_addr`, `fb_stream_data`) that forwards updated frame bytes from SDRAM to the OLED controller without stalling the RISC-V CPU.

3. **[`retro_top.v`](file:///C:/Users/JAGADEESH/Downloads/doom-rv32im/retro-comp-oled/fpga/rtl/retro_top.v)**:
   * Top-level module connecting CPU core, SDRAM, UART, and the SSD1306 OLED controller.

---

## 4. How to Compile & Program the FPGA

### Step A: Compile the Bitstream in Quartus Prime Lite
1. Open Quartus Prime Lite.
2. Open the project:
   ```text
   retro-comp-oled/fpga/quartus/de0_nano_retro.qpf
   ```
3. Click **Start Compilation** (`Ctrl+L`).
4. Open the **Programmer**, select the USB-Blaster, and program `de0_nano_retro.sof` to your DE0-Nano.

### Step B: Build and Upload the Game Firmware
Run in WSL / Bash:
```bash
cd retro-comp-oled
python3 games/cpm/mkdisk.py games/cpm/diskfiles games/cpm/disk.blob
bash games/menu/build.sh
```

Launch the game console loader on Windows:
```powershell
py host/play.py
```

The 32-game menu, DOOM, Wolfenstein 3D, Snake, Tetris, Minesweeper, Flappy Bird, and CP/M games will immediately light up on your physical 0.96" OLED screen!
