# Web UI handoff — live DOOM player for the RTL sim

Share this file + `bridge.py` + `ui.html` with the other agent. It is
self-contained: architecture, exact wire bytes, file-by-file behavior,
runbook, keymap, knobs, limits, and v2 plans.

## 0. What this is (30 s)

A browser page that plays video **out of a live Verilator RTL simulation**
of DOOM on a dual-issue RV32IM core, and injects the player's keys **back
into the RTL**. No recording step: while the sim runs, frames appear and
keys take effect (in slow motion — §8).

```
 DOOM guest (RV32IM ELF) ──runs on──▶ Verilator RTL model (rv32i_top_dg)
        │ MMIO framebuffer commits / UART / KEY register
        ▼ DPI (RT_LIVE build)
 sim_rt (C++ testbench, +live=7777) ◀──TCP v1──▶ bridge.py (:8080) ◀──HTTP──▶ ui.html (browser)
  eval loop, key schedule, fb grab      'F' frames up                poll /api/state (4 Hz)
                                       'C' console up               POST /api/key
                                       'K' keys + 'G' poll down
```

Base paths (repo `doom-rv32im`, variant dir):

```
V = rv32i/rv32i-super-br-hybp-btb-ras-hzopt-luopt-fulu/
```

## 1. File inventory

| file | lines | role — do-not-confuse |
|---|---|---|
| `V/doom/rt/bridge.py` | 243 | stdlib-only Python: TCP client to sim + HTTP server to browser. Owns PLAYPAL extract, frame cache, stats math. |
| `V/doom/rt/ui.html` | 129 | single-file page (inline CSS/JS, zero deps/CDN): canvas, stats, console, keyboard capture. |
| `V/doom/rt/sim_rt.cpp` | 434 | sim side of the contract: `+live` server, frame grab, key injection. Web agent reads §5, does not need to modify. |
| `V/doom/rt/tb_rt.v` | 119 | untimed Verilog shell (DUT + counters + WAD loader). Untouched by web work. |
| `V/doom/freedoom1.wad` | 28 795 076 B | game data; bridge reads PLAYPAL from it at startup. |
| `V/doom/rt/REALTIME.md` | — | speed/determinism report for the fast sim. |
| `V/doom/rt/MERGE_PLAN.md` | — | v2 plan (snapshots, key FIFO, UI extensions). |

Nothing else is needed at runtime. Build outputs (`V/obj_dir_rt/Vtb_rt`,
`V/hex/*`) already exist in the workspace but rebuild cleanly (§6).

## 2. `bridge.py` (243 lines) — behavior contract

`main()` (L223): parses `--sim-port/--http-port/--wad/--ui`, extracts
PLAYPAL once via `playpal()` (L31: reads WAD header → lump dir → first
768 B of `PLAYPAL` lump; aborts if missing), starts `SimLink` reader
thread, serves `ThreadingHTTPServer` on **`0.0.0.0:<http-port>`**
(must stay 0.0.0.0 — the sandbox preview proxies to it).

`SimLink` (L44) — the only TCP owner:

- `run()` (L67): **connect-retry forever** (`create_connection` to
  127.0.0.1, 0.5 s backoff). One connection at a time. If the sim drops,
  sets `ended=True` and keeps serving the last cached state (UI shows
  "sim ended", never crashes).
- `_reader_loop()` (L105): sends `G` (want-latest-frame) every **250 ms**,
  `recv()` into a `bytearray`, parses framed messages (§4), tolerates
  partial reads; unknown tag bytes are skipped (resync). `socket.timeout`
  just continues the loop.
- On each new `F` frame: recomputes `mhz = Δcyc/Δt/1e6`,
  `tps = Δn/Δt` (one frame = one game tic in `-singletics` mode, so this
  is honest game speed), `cpi = Δcyc/Δinstret`. First frame sets baseline,
  stats read 0.0 until the second frame.
- `send_key()` (L102): `K <key:u8> <pressed:u8>` under `send_lock`.
  Request threads never touch the socket directly.
- Console: `C` payloads appended to a `deque(maxlen=4000)` of **chars**
  (not lines); `snapshot()` returns the last 3000 chars.

HTTP (`Handler`, L183; access log silenced):

| method + path | returns |
|---|---|
| `GET /` | `ui.html` bytes as `text/html` |
| `GET /api/palette` | 768 raw bytes (`Cache-Control: no-store` on everything) |
| `GET /api/state` | JSON (§3), includes `frame_b64` = base64 of **64 000 raw palette indices** (~85 336 chars) |
| `POST /api/key` `{"key":int,"pressed":bool}` | `{"ok":true}` (or 400 on bad body); forwards one `K` packet |

## 3. `/api/state` JSON — exact keys

```json
{
  "n": 242, "cyc": 513004109, "instret": 700112003, "mframes": 243,
  "mhz": 4.65, "tps": 2.86, "cpi": 0.7012, "ipc": 1.4261,
  "connected": true, "ended": false,
  "frame_b64": "<base64, 64000 indices>",
  "console": "<last ~3000 chars of guest UART>"
}
```

- `n = -1` + zeroed stats means "sim hasn't committed a frame yet"
  (boot takes ~28 s; UI shows "booting…").
- `frame_b64` decodes to exactly 64 000 bytes, row-major, 320×200,
  one byte = PLAYPAL index. Same bytes the legacy flow writes into
  `frame_<n>.pgm` bodies (proven byte-identical, `REALTIME.md`).

## 4. TCP wire protocol v1 (sim:port ↔ bridge) — exact bytes

Little-endian, no checksums, localhost only. Sim is server, bridge is the
single client. Sends are best-effort non-blocking sim-side: **the sim
never blocks on a slow consumer** (frames drop, sim continues).

Bridge → sim:

| bytes | meaning |
|---|---|
| `G` (0x47) | "send latest frame now" (bridge polls every 250 ms) |
| `K` (0x4B) `key:u8` `pressed:u8` | inject: key byte per §7; `pressed` 1 = down, 0 = up. Sim stamps it at `current_cycle + 1` and merges it into the time-ordered schedule. Unknown bytes are skipped (both sides resync). |

Sim → bridge:

| bytes | meaning |
|---|---|
| `F` (0x46) `n:u32` `cyc:u64` `instret:u64` `pixels:64000B` | full frame. Sent on every guest commit **and** on every `G` (repeat-n replies are idempotent; bridge dedupes by `n`). |
| `C` (0x43) `len:u16` `bytes[len]` | guest console chunk (line-buffered, ≤200 chars or ≤4096 B per message). |

Total per frame on the wire: 21 + 64 000 = 64 021 B (~320 KB/s at full
poll rate — trivial on localhost).

## 5. Sim-side contract (`sim_rt.cpp` — read, don't change, unless v2)

Relevant anchors: `live_listen` L77, `live_poll` L133, `live_send_frame`
L108, `live_send_console` L119, `rt_uart_put` L183, `rt_frame`/`grab_frame`
L196/L207, main loop L328/L355.

- Enabled only with `+live=PORT`. Listens on **127.0.0.1** (not public).
- `live_poll()` runs every **512 sim cycles** (~0.1 ms — this sets input
  responsiveness). Single client; on connect the sim immediately pushes
  the latest frame + last 4 KB of console (late-joining UI still sees
  boot text and current screen).
- Frame path: guest `MM_DUMP` → DPI import `rt_frame(n)` (latches request
  only — calling the `rt_fb_word` export from inside an import aborts, no
  DPI scope) → main loop `grab_frame()` after the eval returns (fb still
  identical — guest writes it only on clock edges) → `F` send + optional
  `+pgm` file + `[rt] frame…` log line. Grab runs **before** the stop
  checks, so no committed frame is ever lost, even if `EXIT` dual-issues
  in the same cycle.
- Key path: `K` reception appends `{cycle+1, key|0x100-if-release}` and
  bubble-sorts the tail into the time-ordered schedule (schedule is
  near-sorted, so this is ~free). Injection pulses `inject_valid` for
  exactly one cycle with **bit-exact legacy timing** (`tb_doom.v`
  semantics: key due at C latches on edge C+1→C+2).
- Console: every UART char appended to the full transcript (written to
  `doom_console.txt` at exit); live lines forwarded only while a client
  is connected.
- Run it with `V/doom/rt/run_rt.sh` (regenerates hex, derives `+wad_base`
  via `nm`, execs the binary). **CWD must be `V/`** (relative `hex/`).

## 6. Runbook (copy-paste)

Prereqs (already installed in this workspace; re-run if fresh machine):

```bash
sudo apt-get install -y verilator gcc-riscv64-unknown-elf \
  picolibc-riscv64-unknown-elf python3-pil python3-numpy
```

Build once:

```bash
cd V
DG=/path/to/doomgeneric ./doom/build_full.sh doom/freedoom1.wad  # guest ELF
./doom/rt/build_rt.sh                                             # obj_dir_rt/Vtb_rt
```

Launch (two processes; order-independent — bridge retries):

```bash
cd V
MAX_FRAMES=100000 MAX_CYCLES=20000000000 \
  ./doom/rt/run_rt.sh doom/doom.elf doom/freedoom1.wad +live=7777 \
  > /tmp/sim.log 2>&1 &
python3 doom/rt/bridge.py --sim-port 7777 --http-port 8080 \
  --wad doom/freedoom1.wad --ui doom/rt/ui.html
# → open http://<host>:8080  (in the agent sandbox: the live-preview URL)
```

Verify (expected outputs):

```bash
curl -s localhost:8080/api/palette | wc -c            # → 768
curl -s localhost:8080/api/state | python3 -m json.tool | head -12
# → after ~30 s boot: "n": 0.., "connected": true
curl -s -X POST localhost:8080/api/key \
  -H 'Content-Type: application/json' -d '{"key":9,"pressed":true}'
# → {"ok":true}   (Tab down; automap toggles a tic or two later)
```

Kill: `pkill -f Vtb_rt; pkill -f bridge.py`. NOTE: sandbox background
processes do **not** survive across turns/restarts — relaunch per above
(the doc author verified this the hard way).

## 7. Keymap (browser `e.code` → doomkeys byte → engine meaning)

Single source of truth: `MAP` in `ui.html` (L93–101). `TranslateKey()` in
doomgeneric is the identity, so these bytes reach `D_PostEvent` unmodified.
(`0x9D`/`0xB6`/`0xB8` style raw codes also work, but the table below is what
the UI sends; keep any SDL build byte-identical — keymap is a v2 selftest
fixture.)

| browser `e.code` | byte (dec / hex) | engine meaning |
|---|---|---|
| ArrowUp / Down / Left / Right | 173 / 175 / 172 / 174 (0xAD/AF/AC/AE) | forward / back / turn left / turn right |
| ControlLeft / ControlRight | 163 (0xA3) | FIRE |
| Space | 162 (0xA2) | USE (open doors, triggers) |
| ShiftLeft / ShiftRight | 182 (0xB6) | RUN modifier (hold with arrows) |
| AltLeft / AltRight | 184 (0xB8) | strafe modifier |
| Comma / Period | 160 / 161 (0xA0/A1) | strafe left / right |
| Digit1–Digit7 | 49–55 (0x31–0x37) | weapon select (fists→plasma; 2 = pistol) |
| Enter / Escape | 13 / 27 | menus confirm / cancel |
| Tab | 9 | automap toggle |
| Minus / Equal | 45 / 61 | shrink / enlarge view window |
| KeyY / KeyN | 121 / 110 | yes / no prompts |
| KeyP | 112 | pause-ish / menu key |

UI input rules (`ui.html` L111–127): ignore `e.repeat` and duplicate
keydowns (tracked in `down` set); `preventDefault()` on mapped keys only
(arrows/space/tab would scroll/focus the page); `keyup` always releases;
`window.blur` releases everything (stuck-key safety).

## 8. Tuning knobs (all constants, where they live)

| knob | location | value | effect |
|---|---|---|---|
| bridge `G` poll | `bridge.py` L112 (`now - last_g > 0.25`) | 250 ms | frame freshness vs localhost traffic (~64 KB × rate) |
| browser poll | `ui.html` L90 (`setInterval`) | 250 ms | UI refresh; sim only makes ~2.8 fps, so faster is pointless |
| sim socket poll | `sim_rt.cpp` L355 (`g_cycle - g_last_poll >= 512`) | 512 cycles (~0.1 ms) | input responsiveness; cheaper than it looks |
| console ring | `bridge.py` L64 (`maxlen=4000`), L176 (`[-3000:]`) | 4000/3000 chars | memory cap + payload size per poll |
| frame cache | `bridge.py` L159–181 | latest only | no history — v2 may add ring for rewind |
| canvas scale | `ui.html` CSS (`width:640px;height:400px`) | 2× | display only; `image-rendering:pixelated` keeps it crisp |

## 9. Known limitations (root causes, not mysteries)

1. **Slow-motion live (~2.8 tics/s, ~8% realtime).** Physics: 35 tics/s
   needs ~57 M sim-cycles/s; this host delivers ~4.6 M. Whole world runs
   at ~1/13 speed, including your reaction window — feels like DOOM on a
   slow 386, not lag. FPGA at 100 MHz does ~60 tics/s (§REALTIME.md).
2. **Sub-tick taps can vanish.** The bridge holds ONE key until the guest
   ACKs; press+release inside one wall-tick (~350 ms) may deliver nothing.
   Fix is the v2 shell FIFO (MERGE_PLAN §3a), NOT UI-side repeats/holds.
3. **Input latency 1–2 tics** (engine samples keys once per tic; affected
   frame commits at a tic end). In wall time ~350–700 ms in levels; in
   game time 28–57 ms — exactly as on hardware.
4. **No history/rewind** — bridge keeps only the latest frame; no PGM
   recording in live mode unless sim runs with `+pgm`.
5. **Single client** — one bridge per sim; second TCP client is ignored
   until the first drops. Multiple browsers may poll one bridge freely.
6. **Boot is blind for ~28 s** (`n = -1` until frame 0 commits) — then
   frames + console backlog arrive together. v2 snapshots fix iteration;
   first boot stays.

## 10. Planned v2 (from MERGE_PLAN.md — likely the other agent's task)

- TCP v2 additions: `D` (drop/fifo-depth query) · `P 0/1` (pause/resume
  eval loop) · `S` (snapshot now, reply `s ok/err`).
- UI: FIFO-depth + dropped-key indicator; Snapshot / Restore / Pause /
  +1-tic-step buttons; distinct LIVE / paused / ended states; reconnect
  across sim restarts (bridge already retries — keep it).
- Keep bridge stdlib-only and UI single-file; keymap stays shared with
  any SDL build via the selftest fixture.
- Do NOT: add UI-side key repeats/holds (masks the FIFO fix), switch the
  bridge to websockets unless polling proves insufficient, or claim more
  than ~10% realtime on this host.

## 11. Troubleshooting

| symptom | cause → fix |
|---|---|
| `/api/state` empty / connection refused | bridge/sim not running (sandbox kills bg procs across turns) → §6 relaunch |
| `connected:false`, `n:-1` for >60 s | sim still booting or WAD load failed → check `/tmp/sim.log` for `[tb_rt] loaded … WAD bytes` |
| frames frozen, `ended:true` | sim hit `+max_cycles`/`+max_frames` or guest EXIT → relaunch with bigger caps |
| keys do nothing | page never clicked (browser focus) / sim not at a tic boundary yet (wait ~1 s) / bridge→sim TCP down (`connected:false`) |
| automap stuck on | a Tab `keyup` was lost → press+release Tab again; `blur` handler covers tab-switch cases |
| `frame_b64` decodes to ≠64 000 B | version skew between sim and bridge → rebuild both from this tree |
| palette looks wrong (green static) | normal for frame 0 (wipe buffer — the author's own stills show it); gameplay frames start ≈ frame 9 |
| bridge `No PLAYPAL` abort | wrong `--wad` path → point at `V/doom/freedoom1.wad` |

## 12. Glossary (one line each)

- **tic**: DOOM's 35 Hz game tick; with `-singletics`, one tic = one
  `doomgeneric_Tick()` = one committed frame. **frame `n`** in the API is
  the tic count.
- **doomkeys byte**: engine key code (`doomkeys.h`); identity-mapped here.
- **PLAYPAL**: 768-byte WAD palette (256×RGB); index → color.
- **PGM**: legacy per-frame dump (`P5` + 64 000 index bytes); live mode
  ships the same bytes over TCP instead of disk.
- **wall-tick**: one wall-clock frame period (~350 ms at 2.8 tics/s).