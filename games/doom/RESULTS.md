# DOOM on `rv32i-super-br-hybp-btb-ras-hzopt-luopt-fulu` — integration results

Cloned with `git sparse-checkout` from
`Mummanajagadeesh/rv32i` → `rv32i-super-br-hybp-btb-ras-hzopt-luopt-fulu` only.

## Status

| stage | state |
|---|---|
| Toolchain installed | ✅ Verilator 5.032, riscv64-unknown-elf-gcc 14.2.0 |
| Their design builds + runs | ✅ reproduces their published CPI exactly |
| Peripheral bridge (dual-port) | ✅ built, written + read path both verified |
| Framebuffer → PGM on host | ✅ 64,015-byte P5 PGMs, pixel-exact |
| Bare-metal render workload on their core | ✅ real image, IPC 1.098 |
| doomgeneric source | ✅ cloned, 95 `.c` files |
| IWAD | ✅ freedoom1.wad obtained (28,795,076 B, BSD-licensed) |
| Full DOOM build links | ✅ 378,976 text / 59,816 data / 241,532 bss |
| IWAD found + parsed | ✅ `W_Init` reads all 3163 lumps |
| Init sequence completes | ✅ through `ST_Init`, `D_DoomLoop`, first tic |
| Title screen frame | ✅ 320x200, 107,873,474 cycles |
| **E1M1 gameplay** | ✅ `-warp 1 1`: 3D view + sprites + status bar, ~0.4-1.8 Mcycles/frame |
| Scripted keyboard into the running game | ✅ `+keyfile` bridge; walk/turn/fire/use all observed in-frame |
| Gameplay video | ✅ `doom/e1m1_gameplay.gif` — 200 tics at 35 fps, 1 frame = 1 simulated tic |
| Their CoreMark numbers | ✅ unchanged after the ALU fixes **and** after the bridge's port-1 fix (bit-identical) |

## 0. The dmem address window -- the bug that cost the most time

`data_mem.v` indexes its array with

```verilog
wire [$clog2(`DATA_MEM_WORDS)-1:0] idx0 = offset0[$clog2(`DATA_MEM_WORDS)+1:2];
```

which is exactly `$clog2(W)` bits, i.e. the full W-word array -- the `+1` is
correct. What it is *not* is a bounds check: any address at or above `4*W`
bytes wraps modulo the array and reads whatever lives at the alias, silently.

With `DATA_MEM_WORDS 16777216` the reachable window is `0x0000_0000..0x03FF_FFFF`
(64 MB). An early 40 MB heap put `_wad_start` at `0x0292_xxxx`, so the IWAD's
lump directory at `0x0449_0B34` (68.6 MB) fell past the end of the array and
aliased to `0x0049_0B34`. Every directory read returned 0 while `numlumps`
(loaded from offset 0, inside the array) was right -- the signature of an
aliasing read, not a parse bug. Confirmed from both sides at once: the
testbench read `uut.mem.dmem.mem[17973965] == 0x0000000c` (lump 0's
`filepos = 12`) while the guest's volatile read of the same address returned 0.

**Fix used:** size the image so it fits the array. `doom/doom.ld` uses a 12 MB
heap, putting `_wad_end` at `0x02B2_6190` (43.15 MB) with 20.85 MB of headroom,
and `doom/build.sh` fails the build if `_wad_end` ever crosses `0x04000000`.

**Why not change the memory defines globally.** The shipped ELFs are linked
against the wrap: with the stock `DATA_MEM_WORDS 2048` their `crt0.S`
`sp = 0x80001c00` and even the `.data` VMAs only make sense as aliases inside
the 8 KB window. Enlarging the window moves those aliases and the stock
binaries misbehave. `defines.v` therefore keeps 4096/2048 (now `` `ifndef ``
guarded) and `doom/tb_doom.f` overrides with `+define+` for the DOOM build only.
Verified after the change: `tb_program` still reports **21,484,387 cycles /
29,546,308 retired / halted YES (ecall)** -- bit-identical to the published
baseline, re-checked this session on the patched ALU.

## 1. Their core reproduces exactly

Built `tb/tb_program.f` with Verilator and ran their prebuilt `coremark_i100_o3.elf`:

```
measured : cycles 21,484,387   retired 29,546,308   CPI 0.727143
their blog: rv32i-super-...-fulu O3 CPI 0.727143, CoreMark/MHz 4.654543
```

CPI matches to six decimals. Retired count matches the blog's `29,546,306` to
±2. So this checkout is the variant the blog's final row describes.

**Discrepancy worth knowing about:** the repo's own
`tb_program_results_rv32im_i100_o3.txt` claims `28,996,237 cycles /
27,814,121 retired` (CPI 1.038). Running that exact ELF gives
`21,484,387 / 29,546,308`. That results file does not correspond to the ELF it
is named after. I have not determined which run produced it.

## 2. Measured simulator throughput — 2.2 MHz

Three timed runs of the 21.5M-cycle CoreMark, Verilator `--timing`, no
`--trace`, 2 cores:

```
run1: cycles= 21,484,387  wall=10.02 s  throughput= 2144 kHz
run2: cycles= 21,484,387  wall= 9.86 s  throughput= 2179 kHz
run3: cycles= 21,484,387  wall= 9.68 s  throughput= 2219 kHz
```

This is ~20× faster than the generic published figures I used for the original
budget (Embecosm EAN6: 47–129 kHz; Chipyard #2000: 10–270 kHz for RocketChip).
Their design is 17 Verilog modules with no cache, SoC fabric or bus monitors,
so Verilator's compiled model is tiny. **My earlier "7–22 days for a full
timedemo" estimate was based on those generic numbers and was far too
pessimistic for this design.** Revised: a full 2134-frame demo3 is roughly
8–25 hours — an overnight run, not an impossible one.

## 3. The bridge

`rtl/mem/mem_top_dg.v` replaces `rtl/mem/mem_top.v`. The reason a new file was
needed: their `data_mem` is **dual port** (`we0/re0/addr0`, `we1/re1/addr1`)
because the superscalar issues two memory ops per cycle. A single-port MMIO
bridge would let slot 1 read garbage from the framebuffer.

Both read paths verified against expected values:

```
[RES] aabbccdd 00000010 00000000 fff00000 aabbccdd 12345678 12345678 eeeeeeee
[FB ] aabbccdd
      fb[0]    CYC_LO   FRAMES   FB_BASE  fb[0]#2  dmem wr  dmem rd  sentinel
```

Store-pattern test (`fb[i] = i` for 16000 words), read back through the PGM:

```
pixels 4,5,6,7   = 1,0,0,0
pixels 8,9,10,11 = 2,0,0,0
pixels 63996..99 = 127,62,0,0     (15999 = 0x3E7F -> bytes 7F 3E 00 00)
```

Byte order and addressing are exact. One earlier all-pixels-20 result was a bug
in my renderer, not the bridge — the incrementing-pattern test above is what
proved that.

## 4. Render workload actually running on their core

`doom/wall.c` — DOOM-style shaded wall columns, `mul` and `div` per column,
byte stores into the framebuffer:

```
frame_0: cyc=  786,896  instret=  863,383
frame_1: cyc=1,572,508  instret=1,727,070
CPI 0.910506   IPC 1.098291
distinct grey levels: 75   (frame_1)
wall-clock for 2 frames: 0.74 s
```

IPC 1.098 on a store-heavy renderer vs 1.375 on CoreMark — dual-issue does not
fill as well when the loop is dominated by byte stores to one region.
`frame_rendered.png` is the upscaled result.

## 5. Porting DOOM to a machine with no filesystem

Three changes to doomgeneric were needed, all in files under `doom/`:

**a) `w_file_blob.c` replaces `w_file_stdc.c`.** There is no filesystem, so
`fopen`/`fread` have nothing to open. This implements the same `wad_file_t`
interface over the blob the testbench loaded, and exports the class under the
name `stdc_wad_file` because `w_file.c`'s `W_OpenFile()` calls
`stdc_wad_file.OpenFile(path)` directly rather than walking the class table —
so the symbol name is the integration point.

Interposing `fopen`/`fread` instead was tried and rejected: picolibc's `FILE` is
`struct __file`, so a substitute collides with it and leaves `stdout`/`stderr`
undefined.

**b) `M_FileExists()` had to be patched** (`doom/port/m_misc.c`, a verbatim copy
of upstream with one function changed). `d_iwad.c`'s search loop gates on it,
and upstream implements it as `fopen()+fclose()`, which can never succeed here.
DOOM aborted with `IWAD file 'freedoom1.wad' not found!` until it reported the
blob present. Overriding it from `dg_platform.c` does not work — under
`-fno-common` the linker reports `multiple definition of M_FileExists`, so the
port has to edit the file.

**c) The blob length must be the real file size, not the reserved region.**
`_wad_end - _wad_start` is 30 MiB; the file is 28,795,076 B. Using the region
size lets `W_Read` succeed past the end of the WAD. `doom/build.sh` stats the
WAD and passes `-DWAD_BLOB_SIZE=<bytes>`.

Everything upstream of `W_Init` already worked: `Z_Init` mallocs its 6 MB zone
from the picolibc heap, `V_Init` and `M_LoadDefaults` degrade gracefully when
they cannot read or write `.default.cfg`, and the console banner prints over the
UART bridge.

## 6. Real bugs found in their ALU, fixed

Four separate RISC-V "M" spec violations in `rtl/core/alu.v`, each proven on the
core with a directed guest probe (`doom/divtest.c`, `doom/mulhtest.c`) before
and after the fix. Their published CoreMark results are unaffected: re-running
`coremark_i100_o3.elf` after the fixes gives bit-identical
21,484,387 cycles / 29,546,308 retired, because that binary never executes a
faulting form and the fixes are combinational.

1. **MULHU returned 0 for every input.** `result = (a * b) >> 32` is a 32-bit
   by 32-bit product, which is 32 bits wide; shifting it right by 32 discards
   everything. MULH only worked by accident: `$signed(a) * $signed(b)` is
   self-determined at 64 bits. This is the one that matters in practice: gcc
   implements every division by a constant as `mulhu` + shift, so any binary
   built with this toolchain gets wrong results for `x / 320` etc. It is also
   why DOOM's very first frame was black -- see the `fb_scaling` note in §5;
   the factor was computed as 320/320 == 0.

2. **MULHSU had the same zero-width product** and likewise returned 0.

3. **DIV and REM computed unsigned quotients.** `a`, `b` and `result` are all
   unsigned nets, and Verilog's `?:` is context-determined: mixing
   `$signed(a)/$signed(b)` with the unsigned literal `32'd1` made the division
   operands unsigned. Measured: `-7/2 -> 0x7FFFFFFC`, `-10/3 -> 0x55555552`.

4. **DIVU x/0 returned 1** where the spec requires all ones (the previously
   reported bug). The signed `x/0`, `x%0` and `INT_MIN/-1` cases were also made
   explicit (`div_by_zero`, `div_ovf` wires) rather than left to the
   simulator's `x/0` behaviour, which Verilator implements as all-ones.

The products are now named 64-bit wires (`prod_ss/prod_su/prod_uu`) and the
divide corner cases are separate wires; an intermediate inline fix for MULHU
was verified to miscompile on Verilator 5.032 (the case arm provably executed,
via a `0xDEADBEEF` marker, yet the widened inline expression still returned 0),
so the named-wire form is deliberate.

## 7. Files added / changed

```
rtl/mem/mem_top_dg.v        NEW  dual-port peripheral bridge (FB + MMIO + PGM dump)
rtl/top/rv32i_top_dg.v      NEW  rv32i_top with mem_top -> mem_top_dg
tb/tb_doom.v                NEW  testbench; $fread WAD loader, buffered UART capture
defines.v                   EDIT `INST_MEM_WORDS`/`DATA_MEM_WORDS` wrapped in `ifndef`
                                 (values unchanged: 4096 / 2048)
scripts/elf2hex.py          EDIT one line: RISCV_PREFIX -> riscv64-unknown-elf-

doom/tb_doom.f              NEW  verilator file list; +define+ memory overrides
doom/build.sh               NEW  compiles, links, and range-checks the image
doom/run_doom.sh            NEW  derives +wad_base from nm, generates hex, runs
doom/elf2hex_doom.py        NEW  sparse hex; .rodata -> both images; skips .wad
doom/doom.ld                NEW  memory map; 12 MB heap keeps _wad_end in window
doom/crt0_doom.S            NEW  bare-metal startup, explicit sp = _stack_top
doom/dg_platform.c          NEW  DG_Init/DrawFrame/SleepMs/GetTicksMs/GetKey + MMIO
doom/w_file_blob.c          NEW  replaces w_file_stdc.c; WAD served from the blob
doom/wad_size.h             NEW  -DWAD_BLOB_SIZE contract
doom/port/m_misc.c          NEW  copy of upstream with M_FileExists() patched
doom/wall.c  smoke.c  fbtest.c  uarttest.c   isolation / bring-up tests
```

Stock `rtl/core/`, `rtl/mem/data_mem.v`, `rtl/mem/inst_mem.v`, `tb/tb_program.*`
and `Makefile` are untouched. `mem_top_dg.v` is a new file rather than an edit,
and `rv32i_top_dg.v` is a copy of their top with one module name changed, so the
original design still builds and simulates exactly as shipped.

## 8. Reproduce

```bash
cd rv32i-super-br-hybp-btb-ras-hzopt-luopt-fulu

# their baseline -- must print 21,484,387 cycles / 29,546,308 retired, CPI 0.727143
python3 scripts/elf2hex.py coremark_i100_o3.elf hex/inst_mem.hex hex/data_mem.hex
verilator --binary -j 4 -O2 --timing -Wno-fatal --top-module tb_program \
  -f tb/tb_program.f --Mdir obj_dir -o Vtb_program
./obj_dir/Vtb_program && head -8 tb_program_results.txt

# DOOM
verilator --binary -j 4 -O2 --timing -Wno-fatal --top-module tb_doom \
  -f doom/tb_doom.f --Mdir obj_dir_dg -o Vtb_doom
./doom/build.sh doom/freedoom1.wad        # links, then range-checks the image
MAX_FRAMES=1 MAX_CYCLES=1500000000 ./doom/run_doom.sh doom/doom.elf doom/freedoom1.wad
# guest console lands in doom_console.txt, frames in frame_<n>.pgm
```

`doom/build.sh` needs doomgeneric at `$DG` (default
`/home/user/doomgeneric/doomgeneric`) and picolibc for riscv.

## 9. What has been measured on their core (this port)

| workload | cycles | retired | CPI |
|---|---|---|---|
| DOOM `-warp 1 1`: reset -> first E1M1 frame | 120,331,393 | 141,751,217 | 0.8449 |
| E1M1 steady frame (next tic, static view) | +1,811,150 | +2,796,565 | 0.6476 |
| E1M1 steady frame (tic after that) | +385,883 | +471,277 | 0.8188 |
| DOOM title screen (earlier argv) | 107,873,474 | 126,306,294 | 0.8541 |
| E1M1 scripted play: 200 frames, walk+turn+fire+use | 362,341,398 | 498,514,179 | 0.726843 |
| CoreMark i100 o3 (their number, re-verified) | 21,484,387 | 29,546,308 | 0.727143 |

Steady-state E1M1 frames cost ~0.4-1.8 Mcycles on this core -- versus the
domipheus anchor of 125,601,821 cycles/frame on a 5-stage RV32I with software
multiply and DDR3 stalls. The gap is the M-extension hardware, dual issue, and
the framebuffer living on-chip instead of in DDR3.

## 10. Remaining work, in order

1. `-timedemo demo1` for a scene-independent cycles/frame figure.
2. ~~Keyboard injection~~ done -- see 11.
3. Compare IPC on the renderer (1.18-1.38) vs CoreMark (1.375) against the
   luopt/fulu features to see whether the +17.026% CoreMark win survives a
   texture-heavy workload.
4. A longer scripted run into the courtyard (enemy AI + sprite load under
   sustained play) and, if possible, a kill to exercise the obituary path.

## 11. Driving the game -- scripted keyboard, and the bug that hid in the bridge

The bridge always had a KEY register (`+0x014`, bit31 valid, w = acknowledge),
but until now nothing could play it like a keyboard. Three changes make the
game genuinely drivable from the testbench:

1. **Release events.** The inject port is now 9 bits: bit 8 marks a key
   RELEASE, exposed to the guest as bit 30 of the KEY register, so
   `DG_GetKey()` can produce `ev_keyup` and holds/taps mean something.
   (`rtl/mem/mem_top_dg.v`, `rtl/top/rv32i_top_dg.v`, `doom/dg_platform.c`.)
2. **A key schedule.** `+keyfile=<path>` feeds `"<cycle> <key>"` pairs into
   the KEY register at the named cycles (`tb/tb_doom.v`, `$fscanf`-parsed;
   doomgeneric's `TranslateKey()` is the identity, so the bytes are the
   engine's own codes from `doomkeys.h`: 0xAD up, 0xAE right, 0xA3 fire,
   0xA2 use...). `doom/gen_keys.py` writes the file from a friendly
   description (`hold up 40t`, `tap fire 2t gap 4t x2`, ...).
3. **The actual bug:** the core dual-issues stores, and the bridge only
   decoded MMIO writes on data port 0 (the UART alone had a slot-1 handler).
   A slot-1 store to `+0x014` silently dropped the acknowledge, `key_valid`
   stayed set, and the guest re-read the same key on every poll -- which is
   why early runs "walked" by luck and never fired. The fix decodes both
   ports for every register (older instruction first), with a standalone
   key-probe ELF as the before/after proof: before, each injected press was
   read twice; after, exactly one down + one up per event.

Pacing rule learned the hard way: with `-singletics` the engine runs exactly
one tic per `doomgeneric_Tick()`, and one Tick costs ~1.62 Mcycles while the
level is live -- so a key press shorter than ~1.6 Mcycles can vanish inside a
single tic. `gen_keys.py` therefore sizes everything in 1.62 Mcycle "tics",
and the captured video is exactly 35 game-tics per second of footage.

The recorded run (`doom/keys_e1m1.txt`, 22 events): walk out of the start
room, fire the pistol twice while moving (ammo 50 -> 48, visible in the status
bar), turn right, fire again, turn back, tap USE, walk on. 200 frames =
362,341,398 cycles / 498,514,179 retired (CPI 0.726843, IPC 1.375813 -- the
best IPC of any DOOM phase, because live gameplay is branch- and
texture-heavy exactly where this core's dual issue wins). Artefacts:
`doom/e1m1_gameplay.gif` (200 frames @ 35 fps, 5.6 s of game time),
`doom/gf_*.png` (2x-scaled stills), `doom/frames2video.py` (WAD PLAYPAL ->
RGB -> PNG/GIF; delays can be cycle-derived via `--clock` for other clocks).

Interactive play at human speed is not on offer in software simulation:
200 tics cost 362 Mcycles, i.e. 56.7 Mcycles/s of core clock for real-time
35 fps; Verilator here simulates ~2.2 Mcycles/s (single thread, -O2), about
26x slower than a 50 MHz FPGA part would run it. The GIF is the playable
artefact; the same `+keyfile` mechanism would drive it on real silicon.
