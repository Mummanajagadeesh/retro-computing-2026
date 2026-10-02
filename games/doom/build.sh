#!/usr/bin/env bash
# Rebuild the DOOM ELF for the rv32im superscalar.
#   ./games/doom/build.sh [path/to/iwad]
set -euo pipefail
cd "$(dirname "$0")/../.."

DG=${DG:-/home/user/doomgeneric/doomgeneric}
WAD=${1:-games/doom/freedoom1.wad}
SIZE=$(stat -c%s "$WAD")
echo "[build] WAD=$WAD  size=$SIZE"

CF="-march=rv32im -mabi=ilp32 -O2 -fno-pic -mno-relax --specs=picolibc.specs
    -DNORMALUNIX -DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200
    -DWAD_BLOB_SIZE=$SIZE -I$DG -Idoom"

riscv64-unknown-elf-gcc $CF -c games/doom/w_file_blob.c -o games/doom/build/w_file_blob.o
riscv64-unknown-elf-gcc $CF -c games/doom/port/m_misc.c   -o games/doom/build/m_misc.o
riscv64-unknown-elf-gcc $CF -c games/doom/port/w_wad.c    -o games/doom/build/w_wad.o
riscv64-unknown-elf-gcc $CF -c games/doom/port/i_video.c  -o games/doom/build/i_video.o
riscv64-unknown-elf-gcc $CF -c games/doom/port/d_main.c   -o games/doom/build/d_main.o

riscv64-unknown-elf-gcc $CF -nostartfiles -o games/doom/doom.elf \
    games/doom/crt0_doom.S games/doom/dg_platform.c games/doom/build/*.o \
    -T games/doom/doom.ld -Wl,--gc-sections -lgcc

echo "[build] linked:"
riscv64-unknown-elf-size games/doom/doom.elf | tail -1

# ---------------------------------------------------------------------------
# data_mem.v indexes with offset[$clog2(DATA_MEM_WORDS)+1:2], i.e. $clog2(W)
# bits, so only 2*W BYTES of address space are reachable; above that, addresses
# wrap back to 0 and reads silently return the wrong data.
#
# With `DATA_MEM_WORDS 16777216 the window is 0x00000000..0x03FFFFFF (64 MB).
# An earlier 40 MB heap put the IWAD's lump directory at 0x04490B34, past the
# window, and DOOM died with "W_GetNumForName: PNAMES not found!" even though
# the bytes were present in the array. Catch that here instead.
# ---------------------------------------------------------------------------
python3 - "$WAD" <<'PYCHK'
import subprocess, sys
out = subprocess.run(["riscv64-unknown-elf-nm", "games/doom/doom.elf"],
                     capture_output=True, text=True, check=True).stdout
sym = {}
for line in out.splitlines():
    f = line.split()
    if len(f) == 3:
        sym[f[2]] = int(f[0], 16)

WINDOW_TOP = 0x04000000          # 2 * DATA_MEM_WORDS * 4
wad_end    = sym["_wad_end"]
heap_mb    = (sym["__heap_end"] - sym["__heap_start"]) / 2**20

print(f"[build] heap          {heap_mb:.2f} MiB")
print(f"[build] _wad_start    0x{sym['_wad_start']:08X}")
print(f"[build] _wad_end      0x{wad_end:08X}  ({wad_end/2**20:.2f} MiB)")
print(f"[build] dmem window   0x00000000..0x{WINDOW_TOP-1:08X} (64.00 MiB)")

if wad_end > WINDOW_TOP:
    sys.exit(
        f"\n[build] FATAL: _wad_end 0x{wad_end:08X} is past the 64 MB dmem window.\n"
        f"        data_mem.v would wrap it to 0x{wad_end & 0x00FFFFFF:08X} and DOOM would\n"
        f"        read zeroes for the WAD's lump directory. Shrink the heap in doom.ld.\n"
    )
print(f"[build] headroom      {(WINDOW_TOP-wad_end)/2**20:.2f} MiB  OK")
PYCHK
