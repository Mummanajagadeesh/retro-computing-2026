#!/usr/bin/env bash
# Build a game, preload it, run it under tb_retro, keep outputs.
#   ./games/run.sh <chip8|snake|g2048|tetris> [rom.ch8]   (rom only for chip8)
# Honors FRAMES= (default 2): tb stops after that many DUMP writes.
set -euo pipefail
cd "$(dirname "$0")/.."
GAME="${1:?usage: run.sh <game> [rom]}"
ROM="${2:-}"
FRAMES="${FRAMES:-2}"
if [ "$GAME" = doom ]; then
  ELF="games/doom/doom.elf"
  WAD="games/doom/doom1.wad"
else
  ./games/build.sh "$GAME"
  ELF="games/$GAME/$GAME.elf"
  if [ "$GAME" = chip8 ]; then
    WAD="${ROM:-games/chip8/roms/pong.ch8}"
  else
    WAD="games/doom/empty.wad"
  fi
fi
test -f "$WAD" || { echo "missing: $WAD"; exit 1; }
OUT="fpga/sim_out_$GAME"
if [ "$GAME" = chip8 ]; then OUT="${OUT}_$(basename "$WAD" .ch8)"; fi
mkdir -p "$OUT"
python3 fpga/mkimage.py "$ELF" "$WAD" "$OUT/sdram.hex"
test -x fpga/tb/obj_retro/tb_retro || ./fpga/build_tb.sh
(cd "$OUT" && ../tb/obj_retro/tb_retro "+frames=$FRAMES")
