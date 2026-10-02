#!/usr/bin/env bash
# Build the untimed real-time sim (no --timing: clock/reset/loop in C++).
# Flags chosen for raw eval speed; correctness is proven by the determinism
# check (PGMs + console + counters bit-identical to tb_doom).
set -euo pipefail
cd "$(dirname "$0")/../.."

verilator --cc --exe doom/rt/sim_rt.cpp \
  -j 2 \
  -O3 \
  --x-assign fast --x-initial fast \
  -CFLAGS "-O3 -march=native" \
  -Wno-fatal \
  -f doom/rt/tb_rt.f \
  --top-module tb_rt \
  --Mdir obj_dir_rt \
  --build -o Vtb_rt 2>&1 | tail -4
