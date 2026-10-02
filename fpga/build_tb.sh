#!/usr/bin/env bash
# Build the tb_retro simulation binary (used by run_retro.sh, games/run.sh).
set -euo pipefail
cd "$(dirname "$0")"
verilator --cc --exe tb/tb_retro_main.cpp -j 2 -O2 \
  --x-assign fast --x-initial 0 \
  -Wno-fatal --top-module tb_retro --Mdir tb/obj_retro \
  -I.. -I../rtl/core \
  --build -o tb_retro tb/tb_retro.v rtl/mem_top_fpga.v rtl/sdram_ctrl.v \
  rtl/uart_tx.v rtl/uart_rx.v rtl/fifo_sync.v tb/sdram_model.v \
  ../rtl/core/*.v
