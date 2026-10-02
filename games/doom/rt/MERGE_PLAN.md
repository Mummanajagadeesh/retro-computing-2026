# Merge plan: best of both real-time flows (+ web UI)

Goal: one harness that is fastest to iterate (snapshots), robust for live
play (key FIFO), provably correct (selftest + byte-compare), and playable
from a browser (web UI). Guest ELF and core/bridge RTL stay untouched.

## 1. What exists today (this tree)

| piece | file(s) | status |
|---|---|---|
| toolchain | apt: Verilator 5.032, riscv gcc 14.2.0, picolibc | working, versions match project |
| complete guest build | `doom/build_full.sh` | working (`-O2`; `-O3` tried, no win) |
| untimed shell | `doom/rt/tb_rt.v` | working (DUT + counters + WAD loader) |
| C++ TB | `doom/rt/sim_rt.cpp` | working: keyfile + live-TCP keys, DPI frames/UART, `+pgm`, stats |
| bridge DPI hooks | `rtl/mem/mem_top_dg.v` (`RT_LIVE`) | working: `rt_uart_put` / `rt_frame` imports, `rt_fb_word` export |
| file list / build / run | `doom/rt/tb_rt.f`, `build_rt.sh`, `run_rt.sh` | working (no `--timing`, `-O3`, `fast`/`fast`, native) |
| web bridge + player | `doom/rt/bridge.py`, `doom/rt/ui.html` | **live now**: frames, keys, console, stats |
| docs | `doom/rt/REALTIME.md` | done |
| proof | 10/10 PGMs + console byte-identical to `tb_doom`; live Tab→automap observed | done |

Measured here: ~4.6 MHz steady, ~2.8 tics/s (~8% realtime).

## 2. Their deltas to adopt (in value order)

1. **Snapshots** — save/restore full sim state; replay from frame 1 in ~2 s
   instead of rebooting 120 M cycles (~24–28 s). Biggest iteration win.
2. **16-deep key FIFO** (shell) posted from C++ with drop counting — fixes
   the real hole in my live path: a human tap faster than one wall-tick can
   vanish against the 1-deep bridge register.
3. **Shell-local DPI exports** — bridge file keeps only the one-line
   `MM_DUMP` commit import (also the lost-frame fix); all exports move to
   the shell with a single `svSetScope` after construction (no per-frame
   scope lookup, no bridge edits beyond the import call).
4. **Host selftest** (`sim/selftest`, plain gcc, mock model): frame
   numbering, keymap, snapshot format, FIFO order/overflow, error paths.
5. **Their ~10% loop edge** (~5.1 vs ~4.6 MHz) — adopt whatever the A/B
   crowns (suspects: `-O2` vs `-O3` on verilated code, leaner per-cycle
   branches, `--x-initial 0` vs `fast`).
6. **Results extras**: guest exit code + dropped-key count in the results
   file; honest MHz (simulated-cycles / wall — already true here).
7. **Documented kill-list**: 2-thread build = 175 kHz (adopt 1-thread
   default as a measured decision, not a guess).

## 3. Target architecture

```
browser <--HTTP--> bridge.py <--TCP v2--> sim_main <--DPI--> tb_live.v <--ports--> rv32i_top_dg (untouched)
                                          |                     |-- key FIFO (16) --> bridge KEY reg
                                          |-- snapshot save/restore (--savable + sidecar)
                                          +-- selftest (host gcc, mock model)
```

### 3a. Shell (`tb_live.v`, evolves `tb_rt.v`)

- Untimed; DUT, 64-bit counters, single-initial-block WAD loader (as now).
- **Key FIFO**: 16×9-bit queue. C++ posts head via DPI import
  `live_post_key(int key) -> int full`; shell shifts the head into the
  bridge inject port whenever `key_valid == 0` (read hierarchically).
  Scheduled keys keep legacy-exact timing: FIFO is empty at post time for
  any sane spacing (≥20 k cyc), so the key lands on the same edge as today
  (proven by byte-compare, step 5).
- **DPI exports** (all 2-state `int`): `live_fb_word(i)`,
  `live_key_valid()`, `live_fifo_depth()`. One `svSetScope` in C++ init.
- Bridge diff stays at exactly one guarded line: the commit import call
  inside the `MM_DUMP` task (both designs already agree on this spot —
  it is also the lost-frame fix; grab-before-stop-check in C++).

### 3b. C++ (`sim_main`, evolves `sim_rt.cpp`)

- Lean single-threaded eval loop (adopt §2.5 winner).
- Unified key source: keyfile schedule (cycle-stamped) + live TCP keys
  (stamped now+1) → post into shell FIFO; count + report drops.
- **Snapshots** via Verilator `--savable` + sidecar JSON:
  `+snap_save=<prefix> +snap_at_frame=N` writes `<prefix>.vlsnap` (model
  stream: core, mems incl. 64 MB dmem + WAD, bridge incl. fb) and
  `<prefix>.json` `{format:1, cyc, instret, frames, sched_ptr, keyfile_sha}`;
  `+snap_restore=<prefix>` loads both and continues (batch or live).
  Save/load ~1 s at ~70 MB. C++-side state (sched ptr, uart log tail,
  PGM numbering) all comes from the sidecar — nothing implicit.
- Args stay `tb_doom`-compatible (`+wad`, `+wad_base`, `+keyfile`,
  `+max_cycles`, `+max_frames`, `+progress`, `+pgm`) plus
  `+live=PORT`, `+snap_save/at/restore`, `+pause` (start paused for UI).
- Results file adds `exit_code` and `dropped_keys`; MHz stays honest.

### 3c. TCP protocol v2 (sim ↔ bridge; v1 + drops/snap/pause)

- `K key pressed` → sim (unchanged); sim replies nothing (drops visible
  via `D` and state poll).
- `G` → sim sends `F n cyc instret frame` (unchanged, 64 000 B).
- `D` → sim sends `drops fifo_depth` (new, 4 B).
- `P 0/1` → pause/resume eval loop (new; loop sleeps 10 ms while paused).
- `S` → sim takes a snapshot to the configured prefix, replies `s ok/err`
  (new; lets the UI snapshot mid-play).
- `C len bytes` console lines (unchanged).

### 3d. Web UI (keep + extend; stdlib-only bridge, single-file page)

- Keep: canvas + PLAYPAL map, 4 Hz poll, keys, console tail, MHz/tps/CPI.
- Add: FIFO depth + dropped-key indicator; Snapshot / Restore / Pause
  buttons; frame-step while paused (`+1 tic` posts nothing, just runs to
  next commit — implement as `max_frames = n+1` resume-then-pause).
- Reconnect-proof: bridge retries TCP forever; UI shows LIVE / paused /
  ended distinctly.
- Shared keymap doc with any SDL build so both players send identical
  bytes (keymap becomes a selftest fixture, §3e).

### 3e. Tests

- `sim/selftest` (plain gcc, no Verilator): frame-numbering, shared
  keymap table, snapshot sidecar round-trip, FIFO order + overflow +
  drop-count, TCP framing incl. partial reads, plusarg error paths.
- `doom/rt/regress.sh` (needs Verilator): builds legacy `tb_doom` + new
  sim, runs identical keyfile N frames on both, asserts byte-identical
  PGMs/console and cycle equality ±2 with explanation; asserts
  snapshot-restore replay is byte-identical incl. commit cycles.

### 3f. Docs

- Merge `REALTIME.md` + their §12 into one: architecture, protocol,
  snapshot format, keymap, budget table (legacy/new/factor), union bug
  log (both lists agree on DPI-scope, DPI-2-state, 2-cycle-stop-late).
- Legacy `RESULTS.md` §8 flow stays the reference; nothing there changes.

## 4. Execution order (each step gated)

1. **DPI refactor**: exports → shell, one scope call, bridge keeps only
   the commit import. Gate: byte-compare still passes.
2. **Flag A/B** (`-O2`/`-O3`, `x-initial 0`/`fast`, loop trim). Gate:
   measured table, adopt winner.
3. **FIFO** (shell + C++ post + drop stats + results fields). Gate:
   scheduled-keyfile byte-compare + 20 rapid live taps, zero drops.
4. **Snapshots** (save/restore/continue, sidecar, doc). Gate: restore →
   replay byte-identical incl. commit cycles; boot skipped.
5. **`regress.sh`** automation. Gate: one command, all green.
6. **`selftest`** suite. Gate: `gcc` only, all green.
7. **Web UI v2** (drops, snapshot/pause/step buttons). Gate: live demo.
8. **Merged doc**. Gate: a fresh reader can reproduce everything.

## 5. Explicit non-goals

- No threads (measured 175 kHz — slower than legacy).
- No guest `-O3` (measured wash), no render/viewport changes (game stays
  authentic), no "realtime" claims past ~10% on this host (budget math:
  35 × 1.61 Mcyc ≈ 56.7 Mcyc/s needed vs ~5 delivered).
