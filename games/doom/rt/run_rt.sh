#!/usr/bin/env bash
# Run an ELF under the real-time sim.
#   ./doom/rt/run_rt.sh doom/doom.elf doom/freedoom1.wad [extra plusargs...]
# Honors MAX_FRAMES / MAX_CYCLES like doom/run_doom.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

ELF="${1:?usage: run_rt.sh <elf> <wad> [plusargs...]}"
WAD="${2:-}"; shift 2 || true

NM=riscv64-unknown-elf-nm
WAD_START=$($NM "$ELF" | awk '$3=="_wad_start"{print $1}')
[ -n "$WAD_START" ] || { echo "no _wad_start in $ELF"; exit 1; }
echo "[run] _wad_start = 0x$WAD_START"

python3 doom/elf2hex_doom.py "$ELF" hex/inst_mem.hex hex/data_mem.hex

ARGS=(+max_frames="${MAX_FRAMES:-1}" +max_cycles="${MAX_CYCLES:-2000000000}"
      "+wad_base=$WAD_START")
[ -n "$WAD" ] && ARGS+=("+wad=$WAD")
ARGS+=("$@")

echo "[run] ./obj_dir_rt/Vtb_rt ${ARGS[*]}"
exec ./obj_dir_rt/Vtb_rt "${ARGS[@]}"
