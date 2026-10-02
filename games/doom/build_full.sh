#!/usr/bin/env bash
# Complete DOOM ELF build for the rv32im superscalar.
#   DG=/path/to/doomgeneric ./games/doom/build_full.sh [path/to/iwad] [OPT]
#
# Unlike games/doom/build.sh (which only rebuilds the 5 port overrides + platform
# and expects the 90 doomgeneric objects to already exist in games/doom/build/),
# this compiles the full upstream file set from $DG, so a fresh clone builds.
#
# File list = upstream Makefile's SRC_DOOM (xlib target), minus:
#   doomgeneric_xlib.c  -> replaced by games/doom/dg_platform.c (our main + hooks)
#   w_file_stdc.c       -> replaced by games/doom/w_file_blob.c (blob-backed WAD)
#   d_main,i_video,m_misc,w_wad -> replaced by games/doom/port/*.c (patched copies)
set -euo pipefail
cd "$(dirname "$0")/../.."

DG=${DG:-/home/user/doomgeneric/doomgeneric}
WAD=${1:-games/doom/freedoom1.wad}
OPT=${2:--O2}
SIZE=$(stat -c%s "$WAD")
echo "[build] WAD=$WAD  size=$SIZE  OPT=$OPT  DG=$DG"

[ -d "$DG" ] || { echo "[build] FATAL: DG dir $DG missing (doomgeneric sources)"; exit 1; }
mkdir -p games/doom/build hex

CF="-march=rv32im -mabi=ilp32 $OPT -fno-pic -mno-relax --specs=picolibc.specs
    -DNORMALUNIX -DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200
    -DWAD_BLOB_SIZE=$SIZE -I$DG -Idoom"

# shellcheck disable=SC2086
compile() { # $1 = src, $2 = obj
  echo "[cc] $1"
  riscv64-unknown-elf-gcc $CF -c "$1" -o "$2"
}

# ---- upstream doomgeneric (parallel where possible) ----
UPSTREAM="dummy am_map doomdef doomstat dstrings d_event d_items d_iwad d_loop d_mode d_net f_finale f_wipe g_game hu_lib hu_stuff info i_cdmus i_endoom i_joystick i_scale i_sound i_system i_timer memio m_argv m_bbox m_cheat m_config m_controls m_fixed m_menu m_random p_ceilng p_doors p_enemy p_floor p_inter p_lights p_map p_maputl p_mobj p_plats p_pspr p_saveg p_setup p_sight p_spec p_switch p_telept p_tick p_user r_bsp r_data r_draw r_main r_plane r_segs r_sky r_things sha1 sounds statdump st_lib st_stuff s_sound tables v_video wi_stuff w_checksum w_file w_main z_zone i_input doomgeneric"

# export for xargs workers
export DG CF
export -f compile 2>/dev/null || true
echo "$UPSTREAM" | tr ' ' '\n' | xargs -P "$(nproc)" -I{} bash -c 'riscv64-unknown-elf-gcc $CF -c "$DG/{}.c" -o "games/doom/build/dg_{}.o"'

# ---- port overrides ----
compile games/doom/w_file_blob.c games/doom/build/w_file_blob.o
compile games/doom/port/m_misc.c games/doom/build/m_misc.o
compile games/doom/port/w_wad.c  games/doom/build/w_wad.o
compile games/doom/port/i_video.c games/doom/build/i_video.o
compile games/doom/port/d_main.c games/doom/build/d_main.o

# ---- link ----
# shellcheck disable=SC2086
riscv64-unknown-elf-gcc $CF -nostartfiles -o games/doom/doom.elf \
    games/doom/crt0_doom.S games/doom/dg_platform.c games/doom/build/*.o \
    -T games/doom/doom.ld -Wl,--gc-sections -lgcc

echo "[build] linked:"
riscv64-unknown-elf-size games/doom/doom.elf | tail -1

# ---- 64 MB dmem window check (see games/doom/doom.ld) ----
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
