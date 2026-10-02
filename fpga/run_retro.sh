#!/usr/bin/env bash
# Build + run the full-guest FPGA boot (tb_retro). About 2-3 min of host
# time for a DOOM boot + 2 frames. Builds into fpga/tb/obj_retro, runs in
# fpga/sim_out/ so the repo tree stays clean. Point at another preloaded
# image with HEX= (default: fpga/sdram.hex).
# --x-initial 0 (not fast): random X init makes the very first passes
# emit a phantom NUL on UART before the guest's first byte.
set -euo pipefail
cd "$(dirname "$0")"
HEX="${HEX:-sdram.hex}"
test -f "$HEX" || python3 mkimage.py \
  ../games/doom/doom.elf ../games/doom/doom1.wad "$HEX"
verilator --cc --exe tb/tb_retro_main.cpp -j 2 -O2 \
  --x-assign fast --x-initial 0 \
  -Wno-fatal --top-module tb_retro --Mdir tb/obj_retro \
  -I.. -I../rtl/core \
  --build -o tb_retro tb/tb_retro.v rtl/mem_top_fpga.v rtl/sdram_ctrl.v \
  rtl/uart_tx.v rtl/uart_rx.v rtl/fifo_sync.v tb/sdram_model.v \
  ../rtl/core/*.v
mkdir -p sim_out && cp "$HEX" sim_out/sdram.hex
(cd sim_out && ../tb/obj_retro/tb_retro)
