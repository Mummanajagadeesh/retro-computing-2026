#!/usr/bin/env bash
# Build one console game:  ./games/build.sh <chip8|snake|g2048|tetris>
# rv32im, freestanding (no libc): crt0.S + console.c + game.c, retro.ld.
set -euo pipefail
cd "$(dirname "$0")/.."
GAME="${1:?usage: build.sh <chip8|snake|g2048|tetris>}"
SRC="games/$GAME/$GAME.c"
ELF="games/$GAME/$GAME.elf"
test -f "$SRC" || { echo "no game: $GAME"; exit 1; }
if [ "$GAME" = chip8 ]; then
    for rom in games/chip8/roms/*.c8; do
        python3 games/chip8/mkrom.py "$rom"
    done
fi
riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 -fno-pic -mno-relax \
  -nostdlib -nostartfiles -fno-stack-protector -ffreestanding -fno-builtin -Wall -Igames/common \
  -o "$ELF" games/common/crt0.S games/common/console.c "$SRC" \
  -T games/common/retro.ld -lgcc
riscv64-unknown-elf-size "$ELF"
riscv64-unknown-elf-nm "$ELF" | grep -E " _wad_start| _wad_end| main$" || true
