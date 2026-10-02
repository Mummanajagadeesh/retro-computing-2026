# CP/M 2.2 on the console: RunCPM port

Status: **sim-verified on the RTL**. Boots to `A0>` in the Verilator
model of the actual Verilog, runs DIR / TYPE / INFO / PIP / ERA,
executes `.COM` programs on the emulated Z80, exits cleanly.
Remaining: bench run (instructions below).

Source: RunCPM by Marcelo Dantas (MIT), pinned at
`79396be665d6ec263a2728b20b177f4149647ed8`. Vendored pristine in
`runcpm/` (see `VENDORED.txt`); zero modifications. The port is four
files: `abstraction_retro.h`, `shim.c`, `cpm_main.c`, `mkdisk.py`,
plus one shared addition (`con_putc` in `games/common/`) and the
sim bench (`fpga/tb/tb_cpm.v`, `fpga/tb/tb_cpm_main.cpp`).

## Configuration

- CPU = Z80 (`cpu2.h`, smaller/optimized core) + internal CCP.
- Killed at the top of `cpm_main.c`: `USE_PUN`, `USE_LST`.
- Never enabled: `STREAMIO`, `DEBUG`, `CPM3`, `ABDOS`.
- `Z80estimateClock()` intentionally not called (its 10M-iteration
  loop costs ~40 s at 50 MHz).

## How it fits the machine

- Console: `_putch` -> `con_putc` (new, `MM_UART` direct);
  `_getch`/`_kbhit` -> `key_poll`, press events only. Because the
  key register holds ONE event and `key_poll` consumes it, `_kbhit`
  keeps a 1-deep peek buffer.
- Time: `millis()` -> `ticks_ms()`.
- Disk: RAM disk in SDRAM, drive A: only, 96 files, 2 MB arena.
  `_HardwareInit` unpacks the `_wad_start` blob (see below). Files
  are contiguous with relocation-on-grow; delete unlinks (arena
  leaks until reboot, which restores the shipped image).
- No malloc, no FILE, no stdio, no libc headers at all: the target
  toolchain ships none, so the few used decls (`toupper`, `strlen`,
  `strcmp`, `memset`, `memcpy`, `sprintf`, time bits) are declared
  manually and implemented in `shim.c` / `console.c`. 64-bit
  division comes from libgcc (already linked by build.sh).

## Disk image (fetch, don't vendor)

The shipped image is RunCPM's own `A0.zip` at the pinned commit:

```
curl -L -o A0.zip \
  https://github.com/MockbaTheBorg/RunCPM/raw/79396be665d6ec263a2728b20b177f4149647ed8/DISK/A0.zip
unzip -j A0.zip 'A/0/*' -d diskfiles
printf DIR > diskfiles/AUTOEXEC.TXT
python3 games/cpm/mkdisk.py diskfiles games/cpm/disk.blob
```

79 files (~877 KB): TE, ASM, MAC, DDT, PIP, DUMP, ZSID, XMODEM,
SUBMIT, MBASIC, Z80ASM, ZEXDOC/ZEXALL, and the CCP/BDOS sources.
The bundle (including MBASIC) is fetched at build time so this
repo ships no third-party binaries; that is deliberate. The packed
`disk.blob` is git-ignored for the same reason.

Blob layout: `[u16 total][u16 count][name11, u32 len, bytes]...`.
`mkdisk.py` writes the `u16` wrap itself; the uploader sends the
file raw into the WAD slot (it prints a note, not an error).

## Host patch (already applied in this tree)

`host/tinyview.py` gained one KEY_MAP line: BackSpace -> 0x08 (^H),
for CP/M line editing. Ctrl+letter needs no patch: Tk delivers the
control byte via `ev.char` already (verify on the bench: `^C` must
abort a `TYPE`).

## Verification evidence

Host harness plus full RTL sim (`./games/run.sh cpm`: builds the
ELF, packs the image, runs `tb_cpm` with a prompt-synchronized
`DIR/TYPE/INFO/EXIT` script):

```
tb_cpm PASS after 195937679 sys cycles, booted=1
uart=9053 bytes, 8141689 instructions retired, exit code 0
boot -> banner, A0>               ok (on RTL)
AUTOEXEC (DIR) at every boot      ok (on RTL)
DIR (80 files incl. MBASIC.COM)   ok (on RTL)
TYPE 1STREAD.ME + pagination      ok (on RTL)
INFO.COM executes (Z80 emu)       ok (on RTL)
PIP B.TXT=... (create+write)      ok (host harness)
ERA B.TXT (delete)                ok (host harness)
EXIT -> halt, exit code 0         ok (on RTL)
our files: zero warnings (-Wall)  ok
shim: -Werror -ffreestanding      ok
sprintf unit test (%llu/%u/%c..)  ok
cpm.elf: fully linked, no undefs  ok (90 KB text, 2.1 MB bss)
```

## Known warts

- `sprintf` is minimal (%c %s %d %i %u %x %X, l/ll, %%; no
  width/precision). Covers every ungated caller; extend if needed.
- `time()/mktime()/localtime()` are stubs for the BDOS 104/105
  date code, unreachable under CP/M 2.2.
- Pasting text faster than the poll loop can drop chars (single
  key register, no queue). Human typing is fine.

## Bench run

```
cd games && ./build.sh cpm        # -> games/cpm/cpm.elf
<fetch A0.zip + mkdisk.py, above> # -> games/cpm/disk.blob
py host/uploader.py upload games/cpm/cpm.elf games/cpm/disk.blob
py host/tinyview.py
DIR
TYPE 1STREAD.ME
INFO
MBASIC                            # Microsoft BASIC-5.29 prompt
```

Slower-than-host items to confirm on the bench: `^C` handling,
ZEXDOC self-test, TE/ASM/DDT edit-assemble-debug loop.
