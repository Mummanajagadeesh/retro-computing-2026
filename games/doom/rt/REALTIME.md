# Real-time DOOM: untimed sim + live play

Batch mode (`tb_doom`: wait ~12 min, watch a GIF) is now complemented by a
**live mode**: frames stream out of the running RTL simulation and keys
inject back into it, so you play the game *while it simulates*.

## What was built

| file | role |
|---|---|
| `doom/rt/tb_rt.v` | untimed TB top: same DUT, counters, WAD loader; clock/reset/keys from C++ |
| `doom/rt/sim_rt.cpp` | C++ testbench: eval loop, keyfile + live-TCP injection, DPI frame/UART grab, `+pgm` dumps, stats |
| `doom/rt/tb_rt.f` | file list (64 MB mem overrides + `RT_LIVE`) |
| `doom/rt/build_rt.sh` | builds `obj_dir_rt/Vtb_rt` (no `--timing`, `-O3`, `--x-assign/initial fast`, `-march=native`) |
| `doom/rt/run_rt.sh` | `run_doom.sh` equivalent for the rt sim |
| `doom/rt/bridge.py` | sim-TCP ↔ browser-HTTP bridge (stdlib only): `/api/state`, `/api/key`, `/api/palette` |
| `doom/rt/ui.html` | single-file player: canvas, stats, console, keyboard capture |
| `doom/build_full.sh` | **complete** guest build (checked-in `build.sh` only rebuilds the 5 port overrides and expects 90 cached objects) |
| `rtl/mem/mem_top_dg.v` | + `RT_LIVE` DPI hooks (`rt_uart_put`, `rt_frame`, `rt_fb_word`); stock path `#else` untouched, verified clean |

Guest and core RTL are unmodified; timing/ISA behavior is unchanged.

## Use

```bash
# 1. guest (needs doomgeneric sources + picolibc riscv)
DG=/path/to/doomgeneric ./doom/build_full.sh doom/freedoom1.wad [-O2]

# 2. sim
./doom/rt/build_rt.sh

# 3a. batch (deterministic, keyfile-compatible with tb_doom)
MAX_FRAMES=200 ./doom/rt/run_rt.sh doom/doom.elf doom/freedoom1.wad \
    +pgm +keyfile=doom/keys_e1m1.txt

# 3b. live (this is the real-time mode)
MAX_FRAMES=100000 MAX_CYCLES=20000000000 \
    ./doom/rt/run_rt.sh doom/doom.elf doom/freedoom1.wad +live=7777 &
python3 doom/rt/bridge.py --sim-port 7777 --http-port 8080 \
    --wad doom/freedoom1.wad   # -> open :8080 and play
```

Keys in the UI: arrows move/turn, Ctrl fire, Space use, Shift run, `,`/`.`
strafe, 1–7 weapons, Tab map, Enter/Esc menus. One sim frame = one game tic.

## Measured results (2× Xeon 2.6 GHz sandbox, Verilator 5.032)

| | tb_doom (`--timing -O2`) | rt sim (untimed `-O3`) |
|---|---|---|
| boot → frame 0 | 120.31 M cyc / 75.2 s wall | 120.31 M cyc / ~28 s wall |
| steady throughput | **1.70 MHz** | **4.2–4.7 MHz** (**~2.6×**) |
| game rate | ~1.0 tics/s | **~2.8 tics/s (~8% of realtime)** |
| E1M1 934-frame take | ~12 min wall | **~4.5 min wall** (projected) |

Correctness proof (10 frames, `+pgm`): **all 10 PGMs + full guest console
byte-identical** to `tb_doom`; CPI/IPC identical (0.830120/1.204645);
cycle/retired counts differ by exactly 2 (TB stop-latency artifact only).
Live keys proven end-to-end (Tab automap toggle observed in-frame).

Guest `-O3` was also tried: **no win** (−0.24% cycles, worse CPI) — DOOM here
is pointer/table-bound, so `-O2` stays.

## The honest physics

True 35 tics/s needs ~57 M sim-cycles/s (1.62 Mcyc/tic × 35). A Verilator
eval of this design costs ~115 ns on this host, so ~4.5 MHz (≈2.8 tics/s)
is the ceiling here — live play is **slow-motion**, keys/frames/con carrying
on in real interaction but stretched ~13× in time. The RTL itself is not the
bottleneck: at 100 MHz on FPGA the same design does ~60 tics/s. Nothing in
the sim can close a 13× gap on this host; the win delivered is (a) 2.6×
faster sim, (b) zero-wait live video + live input instead of batch-and-GIF.
