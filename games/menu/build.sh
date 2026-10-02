#!/usr/bin/env bash
# Build the unified menu firmware: games/menu/menu.elf + games/menu/menu.blob
# RV32IM freestanding console launcher: uniform 64x32 display @ 45 FPS real-time.
set -euo pipefail
cd "$(dirname "$0")/../.."

mkdir -p games/menu/obj

# 1. Compile menu-side objects
MCF="-march=rv32im -mabi=ilp32 -O2 -fno-pic -mno-relax -nostdlib -nostartfiles \
 -ffreestanding -fno-builtin -Wall -isystem /usr/include/newlib -DMENU_BUILD \
 -Igames -Igames/common -Igames/cpm"

mcc() { riscv64-unknown-elf-gcc $MCF -c "$1" -o "$2"; }

echo "[menu] compiling objects..."
mcc games/common/crt0.S           games/menu/obj/crt0.o
mcc games/common/console.c        games/menu/obj/console.o
mcc games/snake/snake.c           games/menu/obj/snake.o
mcc games/tetris/tetris.c         games/menu/obj/tetris.o
mcc games/g2048/g2048.c           games/menu/obj/g2048.o
mcc games/minesweeper/minesweeper.c games/menu/obj/minesweeper.o
mcc games/flappy/flappy.c         games/menu/obj/flappy.o
mcc games/wolf3d/wolf3d.c         games/menu/obj/wolf3d.o
mcc games/doom/doom_native.c       games/menu/obj/doom_native.o
mcc games/chip8/chip8.c           games/menu/obj/chip8.o
mcc games/cpm/shim.c              games/menu/obj/shim.o
mcc games/cpm/cpm_main.c          games/menu/obj/cpm_main.o
mcc games/menu/menu.c             games/menu/obj/menu.o

# 2. Link
echo "[menu] linking games/menu/menu.elf..."
riscv64-unknown-elf-gcc $MCF -o games/menu/menu.elf \
    games/menu/obj/crt0.o \
    games/menu/obj/console.o \
    games/menu/obj/menu.o \
    games/menu/obj/doom_native.o \
    games/menu/obj/wolf3d.o \
    games/menu/obj/snake.o \
    games/menu/obj/tetris.o \
    games/menu/obj/g2048.o \
    games/menu/obj/minesweeper.o \
    games/menu/obj/flappy.o \
    games/menu/obj/chip8.o \
    games/menu/obj/shim.o \
    games/menu/obj/cpm_main.o \
    -T games/menu/menu.ld -Wl,--gc-sections -lgcc

echo "[menu] linked:"
riscv64-unknown-elf-size games/menu/menu.elf | tail -1
riscv64-unknown-elf-nm games/menu/menu.elf | grep -E " _wad_start| _wad_end| main$| _stack_top" || true

# 3. Pack the blob
python3 games/menu/mkmenuwad.py games/cpm/disk.blob games/doom/doom1.wad \
    games/chip8/roms games/menu/menu.blob
BLOB=$(stat -c%s games/menu/menu.blob)
test "$BLOB" -le 8388608 || { echo "menu.blob exceeds 8 MB reservation"; exit 1; }
echo "[menu] OK: menu.elf + menu.blob ($BLOB bytes)"
