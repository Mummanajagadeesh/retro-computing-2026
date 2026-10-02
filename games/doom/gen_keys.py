#!/usr/bin/env python3
"""Write a +keyfile schedule for tb_doom.

tb_doom.v reads its keyboard schedule with $fscanf("%d %d\\n", ...), which on
Verilator 5.032 skips blank lines but permanently wedges on a non-numeric one
(it returns 0 without advancing, so every later line also parses as 0). So the
generated file is strictly "<cycle> <key>" pairs and the friendly syntax --
key names, tics, comments -- lives here instead.

    ./doom/gen_keys.py -o keys.txt --start 120400000 \\
        "hold up 70t" "hold right 12t" "tap ctrl 3t x4 gap 10t" "tap space 2t"

Units: 1 tic = 35714 cycles (28.57 ms at 1.25 MHz); 'c' suffix = raw cycles.
Adding 0x100 to a doomkeys byte turns the injection into a key RELEASE, which
is what makes "hold" and "tap" mean anything to the engine.
"""
import argparse
import sys

# doomgeneric's TranslateKey() is the identity, so these are the engine's own
# codes -- doomkeys.h, verbatim.
KEYS = {
    "up": 0xAD, "down": 0xAF, "left": 0xAC, "right": 0xAE,
    "strafe_l": 0xA0, "strafe_r": 0xA1,
    "use": 0xA2, "fire": 0xA3,
    "ctrl": 0x9D, "shift": 0xB6, "alt": 0xB8,   # KEY_RCTRL/RSHIFT/RALT
    "enter": 13, "esc": 27, "escape": 27, "tab": 9, "space": 32,
    "1": 0x31, "2": 0x32, "3": 0x33, "4": 0x34,
    "5": 0x35, "6": 0x36, "7": 0x37,
}
TIC_CYCLES = 1620000        # measured cycles per game tic on this bench.
                            # -singletics runs exactly ONE tic per
                            # doomgeneric_Tick(), and each Tick renders one
                            # frame whose cost is ~1.62M cycles while the
                            # level is live (0.4M idle, >10M during attacks).
                            # A key press shorter than one Tick is polled
                            # zero or two times and vanishes -- which is why
                            # an earlier 35714-cycles/tic schedule produced a
                            # player that neither walked far nor fired.
RELEASE = 0x100
MIN_GAP = 20000             # min cycles between injections (bridge holds 1 key)


def duration(spec: str) -> int:
    spec = spec.strip().lower()
    if spec.endswith("t"):
        return int(float(spec[:-1]) * TIC_CYCLES)
    if spec.endswith("c"):
        return int(spec[:-1])
    return int(float(spec) * TIC_CYCLES)      # bare number = tics


def key_code(name: str) -> int:
    n = name.strip().lower()
    if n in KEYS:
        return KEYS[n]
    if n.startswith("0x"):
        return int(n, 16)
    raise SystemExit(f"unknown key {name!r} (known: {', '.join(sorted(KEYS))})")


def compile_action(act: str, at: int, out: list) -> int:
    """Return the cycle the next action starts at."""
    tok = act.split()
    verb = tok[0].lower()

    if verb in ("hold", "tap"):
        # hold <key> <dur>          tap <key> <dur> [xN] [gap <dur>]
        code = key_code(tok[1])
        dur = duration(tok[2])
        repeat = 1
        gap = 0
        i = 3
        while i < len(tok):
            if tok[i].lower().startswith("x"):
                repeat = int(tok[i][1:])
            elif tok[i].lower() == "gap":
                gap = duration(tok[i + 1])
                i += 1
            i += 1
        for _ in range(repeat):
            out.append((at, code))
            at += dur
            out.append((at, code | RELEASE))
            at += gap
        return at

    if verb == "gap":
        return at + duration(tok[1])

    if verb == "at":                       # "at <cycle>" -- absolute reposition
        return int(tok[1])

    raise SystemExit(f"unknown action {act!r} (use hold/tap/gap/at)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", default="doom/keys.txt")
    ap.add_argument("--start", type=int, required=True,
                    help="cycle the first event lands on")
    ap.add_argument("actions", nargs="+", help="quoted action strings")
    a = ap.parse_args()

    events: list[tuple[int, int]] = []
    at = a.start
    for act in a.actions:
        at = compile_action(act, at, events)

    # The bridge has room for exactly ONE pending key: mem_top_dg.v latches
    # key_reg/key_valid on inject_valid and only the guest's acknowledge write
    # clears it, so two events on the same cycle means the first is never seen.
    # Sort with releases ahead of presses (a key-up must land before the key-down
    # that replaces it), then space every event at least MIN_GAP cycles apart --
    # comfortably inside one tic, and plenty for the guest's read+ack.
    events.sort(key=lambda e: (e[0], 0 if e[1] & RELEASE else 1))
    spaced: list[tuple[int, int]] = []
    for cyc, val in events:
        if spaced:
            cyc = max(cyc, spaced[-1][0] + MIN_GAP)
        spaced.append((cyc, val))

    with open(a.out, "w") as f:
        for cyc, val in spaced:
            f.write(f"{cyc} {val}\n")

    print(f"[gen_keys] {len(spaced)} events -> {a.out} "
          f"({spaced[0][0]} .. {spaced[-1][0]}, "
          f"span {(spaced[-1][0]-spaced[0][0])/TIC_CYCLES:.1f} tics, "
          f"min gap {MIN_GAP} cyc)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
