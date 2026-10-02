#!/usr/bin/env bash
# Build + run the FPGA phase-1 testbenches with Verilator.
set -euo pipefail
cd "$(dirname "$0")"

verilator --cc --exe tb/tb_uart_main.cpp -j 2 -O2 \
  --x-assign fast --x-initial fast \
  -Wno-fatal --top-module tb_uart --Mdir tb/obj_uart \
  --build -o tb_uart tb/tb_uart.v rtl/uart_tx.v rtl/uart_rx.v

verilator --cc --exe tb/tb_sdram_main.cpp -j 2 -O2 \
  --x-assign fast --x-initial fast \
  -Wno-fatal --top-module tb_sdram --Mdir tb/obj_sdram \
  --build -o tb_sdram tb/tb_sdram.v rtl/sdram_ctrl.v \
  rtl/sdram_tester.v tb/sdram_model.v

verilator --cc --exe tb/tb_boot_main.cpp -j 2 -O2 \
  --x-assign fast --x-initial fast \
  -Wno-fatal --top-module tb_boot --Mdir tb/obj_boot \
  --build -o tb_boot tb/tb_boot.v rtl/mem_top_fpga.v rtl/sdram_ctrl.v \
  rtl/uart_tx.v rtl/uart_rx.v rtl/fifo_sync.v tb/sdram_model.v

./tb/obj_uart/tb_uart
./tb/obj_sdram/tb_sdram
./tb/obj_boot/tb_boot
