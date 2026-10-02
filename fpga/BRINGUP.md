# Phase 1 bring-up: DE0-Nano heartbeat + UART echo + SDRAM test

Proves the Quartus flow, the TTL wiring, and the SDRAM controller on real
hardware before the core enters the picture. The RTL in `rtl/` is already
verified here: `run_tb.sh` passes UART loopback at 115200 and 2M
(128 bytes each, zero errors) and a 4-region SDRAM write/readback plus
byte-enable and last-word checks against a behavioral IS42S16160 model.

## Files

```
fpga/
├── rtl/bringup_top.v    top: reset, echo, tester, LEDs
├── rtl/uart_tx.v        8N1 transmitter
├── rtl/uart_rx.v        8N1 receiver, 16x oversample
├── rtl/sdram_ctrl.v     32-bit SDRAM controller (auto-precharge design)
├── rtl/sdram_tester.v   write/readback self test
├── quartus/de0_nano.qpf Quartus project (open this)
├── quartus/de0_nano.qsf device + pins + files
├── quartus/de0_nano.sdc 50 MHz timing
├── tb/                  Verilator testbenches (reference only)
└── run_tb.sh            rebuilds + runs tb_uart, tb_sdram
```

## 1. Wiring (do first, board unpowered)

JP1 is the 40-pin header silkscreened "JP1" on the PCB. Pin 1 has the
square pad; pin 2 sits next to it on the other row, then 4, 6... down
that row. CP2102 module, 3.3 V TTL levels:

| JP1 header | goes to           |
|-----------:|-------------------|
| pin 2      | TTL module TX pin |
| pin 4      | TTL module RX pin |
| pin 12     | TTL module GND    |

Common ground only. Do NOT connect the TTL 5V/3V3 rail; the DE0-Nano is
powered by its own USB cable. If echo fails later, swap pins 2/4 first.

## 2. Compile

1. Copy the whole `fpga/` tree to Windows, path with NO spaces
   (e.g. `C:\retro_fpga`). Quartus dislikes spaces.
2. Open `fpga\quartus\de0_nano.qpf` in Quartus Prime Lite 20.1.
3. Processing > Start Compilation. A few minutes on this device.
4. Expect zero errors. Warnings about unused KEY[1] are fine.

## 3. Program

1. Connect the DE0-Nano by USB. If the USB-Blaster is unknown in Device
   Manager, point it at `<quartus>\drivers\usb-blaster`.
2. Tools > Programmer. Hardware Setup > USB-Blaster. Add File >
   `output_files\de0_nano.sof`. Tick Program, Start.
3. This loads volatile SRAM: reprogram after every power cycle
   (flash programming comes in a later phase).

## 4. Expected result

| LED | meaning       | want |
|-----|---------------|------|
| 0   | 1 Hz heartbeat| blinking |
| 1   | uart-rx       | blinks as you type |
| 2   | uart-tx       | blinks as you type |
| 3   | test active   | off (test takes ~50 ms) |
| 4   | progress      | whatever it froze on |
| 5   | sdram ready   | ON |
| 6   | FAIL (sticky) | OFF |
| 7   | PASS (sticky) | ON |

Press KEY0 any time to re-run everything from reset.

## 5. Serial test

Open the CP2102 COM port at 115200 8N1 (PuTTY / Tera Term / Arduino
monitor). Type: every character echoes back, LED1/LED2 flicker.

## 6. If something is off

| symptom | check |
|---|---|
| No USB-Blaster in Programmer | driver (§3.1); try another USB port/cable |
| LED6 on / LED7 off | SDRAM test failed: report it, do not proceed |
| LED0 dark | bitstream did not load: reprogram, check .sof path |
| no echo, LEDs fine | TX/RX swapped (most common); wrong COM port; 115200 8N1 |
| garbage characters | baud mismatch; GND missing between the two USB sides |

## 7. Next

Report PASS/FAIL plus anything odd. Phase 2 is below: the core on a
gated clock, SDRAM-backed memory, a UART bootloader for the ELF +
shareware WAD, and DOOM to a console transcript.

---
# Phase 2 bring-up: DOOM on the core, transcript over UART

What this proves: the rv32i core running real DOOM binaries out of
SDRAM on the DE0-Nano, with the game console streaming back over the
same TTL serial you wired in phase 1. Verified in simulation first:
`tb_boot` passes a corrupt upload (rejected, `BAD`, no boot) and a
good upload (CRC match, boot, all 9472 SDRAM bytes verified), and
`tb_retro` runs the uploaded image two frames with output bit-identical
to the reference sim. `tb_retro` passes the full boot plus two frames in
807,272,211 sys cycles (50,456,686 gated core clocks against the
reference sim's 50,456,566; the 120 extra clocks are the testbench
draining the last UART frame after the stop). The dumped framebuffer is
byte identical to the reference sim's second frame (64,000 bytes, zero
differences against `frame_1.pgm`), and the 1,953 byte guest console
stream matches the reference guest stream byte for byte. The
`PRED_SMALL` build (16 entry predictor tables, the configuration the
Quartus project synthesizes) passes the same check: 807,845,498 sys
cycles, 50,497,549 gated clocks, zero frame and console differences.
Reference counts moved from 49,502,100 to 50,456,566 cycles with the M
diet (about two percent); the framebuffer and console bytes did not
move at all.

Getting there found three real bugs in the new memory system RTL, all
fixed and covered by the passing runs. The preload image was written as
32 bit words while the SDRAM model holds 16 bit halves, so every word
arrived truncated and the core never booted; the image script now emits
halves. The I-cache sampled its hit lookup a state too early, before
the lookup index had propagated through the registered RAM outputs, so
hits served the previous line and the guest spun without ever calling
into the game; a settle state fixed it. The UART path had a write
enable that stayed high past its state, a feeder that re-triggered
before the transmitter flagged busy, and a data capture with no settle
time on the FIFO output; together those repeated, dropped and shifted
bytes until the feeder was rewritten as a fully registered sequence.
Phase 1 still passes with identical cycle counts after every fix.
Quartus Prime 20.1.1 rejects the `if (rst || flush_ex)` form in the two
ID/EX pipeline blocks of `rtl/core/core_top.v` (error 10200, since
`flush_ex` has no edge in the sensitivity list), so the reset and flush
clears are written as separate branches with identical values. The split
is behavior preserving: `tb_retro` passes with cycle-identical counts
after it, and the instruction and riscv-test benches produce
bit-identical results before and after.

## Files (new since phase 1)

```
fpga/
├── mkimage.py           builds sdram.hex preload (16-bit halves)
├── rtl/retro_top.v       phase-2 top: core + mem_top_fpga + LEDs/KEYs
├── rtl/mem_top_fpga.v   SDRAM-backed memory + UART bootloader + MMIO
├── quartus/de0_nano_retro.qpf/.qsf/.sdc
├── uploader.py          PC side: info / upload / term  (needs pyserial)
├── tb/tb_retro.v    2-frame hardware-equivalence check (reference)
└── run_doom.sh          rebuilds + runs tb_retro (takes a few minutes)
games/doom/doom.elf  game binary (shareware WAD_BLOB_SIZE build)
games/doom/doom1.wad           shareware DOOM 1.9 IWAD (4,196,020 bytes)
```

## 1. Wiring

Same as phase 1 (§1): JP1 pin 2 to TTL TX, pin 4 to TTL RX, pin 12 to
GND. No changes. The port now runs at 2 Mbaud; the CP2102 handles it.

## 2. Copy to Windows

Copy the whole variant directory (the one containing `fpga/`, `rtl/`,
`defines.v`, `doom/`) to a path with NO spaces (e.g. `C:\retro_fpga`).
Quartus needs `../../rtl/core/*.v` next to `fpga/quartus/`, and the
uploader needs `games/doom/doom.elf` + `games/doom/doom1.wad`.

## 3. Compile

1. Open `fpga\quartus\de0_nano_retro.qpf` in Quartus Prime Lite 20.1.
2. Processing > Start Compilation. Several minutes on this device.
3. Expect zero errors. Unused-pin warnings are fine.

## 4. Program

Same as phase 1 (§3) but with `output_files\de0_nano_retro.sof`.
Volatile SRAM again: reprogram after every power cycle. After
programming, LED0 blinks (heartbeat) and LED7:6 count upload progress.

## 5. Upload + transcript (PC side)

```
pip install pyserial
cd C:\retro_fpga
python uploader.py --port COM3 info doom\doom_shareware.elf doom\doom1.wad
python uploader.py --port COM3 upload doom\doom_shareware.elf doom\doom1.wad
```

Use your CP2102 COM port for `COM3`. `info` prints the layout and
checks it against the 32 MB window (expect `layout OK`). `upload`
takes about 25 s at 2 Mbaud, shows a progress bar, then prints
`CRC match (...), ... KB/s: core booting` and the transcript streams:

```
=== doomgeneric on rv32im superscalar ===
wad_start = 0x00d26270
wad_end   = 0x02b26270
wad magic = 'IWAD'  (want IWAD or PWAD)
heap      = 0x000a5984
fb        = 0xFFF00000  320x200x8bpp
                           Doom Generic 0.1
Z_Init: Init zone memory allocation daemon.
...
[tk00002] rw=1 ammo=50 x=1056 y=-3616 ang=64 u=0
```

Typing in the terminal taps keys to the game (arrow keys + wasd work,
Ctrl-C quits the terminal; the game keeps running).

## 6. Expected result

| LED | meaning | want |
|-----|---------|------|
| 0 | 1 Hz heartbeat | blinking |
| 1 | uart-tx activity | flickers during upload + transcript |
| 2 | uart-rx activity | flickers during upload |
| 3 | booted | ON after CRC OK |
| 4 | frame tick | toggles every 4 frames while running |
| 5 | guest exit seen | OFF (ON means the game exited) |
| 7:6 | upload progress / frame nibble / exit code | moving, then frame bits |

KEY0 reboots the game from the intact SDRAM image (about a second, no
re-upload). KEY1 resets to the bootloader (re-upload required).

## 7. If something is off

| symptom | check |
|---|---|
| `no bootloader answer` | bitstream running (LED0 blinking)? right COM port? |
| `lost ack at offset` | flaky USB serial at 2 Mbaud: another cable/port/PC |
| `upload failed` / `BAD` | re-run upload; persistent BAD means serial corruption |
| `rejected an address range` | report it (layout bug, should not happen) |
| transcript garbage | terminal must be 2 Mbaud; `term` subcommand does that |
| LED5 on, game stopped | guest exited; LED7:6 show the code; report the tail |
| LED3 never comes on | upload did not finish; see above rows |

## 8. Report back

PASS/FAIL, the transcript from `=== doomgeneric` through the first
screen draw, and anything odd. Phase 3 (VGA) builds on this image.
