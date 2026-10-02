# Retro Console Game Vault & Customization Guide

This directory holds the extended library of extra games (CHIP-8 ROMs, CP/M MBASIC adventures, and native engines) ready to be swapped into the **32-Game Console Launcher** at any time.

---

## 1. Game Vault Structure

```text
games/
├── vault/
│   ├── chip8/           # Reserve CHIP-8 ROMs
│   │   ├── guess.ch8     (Number guesser)
│   │   ├── kaleid.ch8    (Kaleidoscope visualizer)
│   │   ├── syzygy.ch8    (Classic arcade syzygy)
│   │   ├── pong2.ch8     (Pong 2-player variant)
│   │   ├── vbrix.ch8     (Vertical Brix)
│   │   ├── demo.c8       (CHIP-8 system demo)
│   │   └── ...
│   └── cpm/             # Extra CP/M BASIC games
│       ├── ELIZA.BAS     (1966 MIT AI Psychoanalyst)
│       ├── OREGON.BAS    (1975 Oregon Trail Pioneer expedition)
│       └── ...
```

---

## 2. How to Swap Any Game in the 32-Game Launcher (30-Second Guide)

All active games are defined in [`games/menu/menu.c`](file:///C:/Users/JAGADEESH/Downloads/doom-rv32im/retro-comp/games/menu/menu.c) inside the `games[TOTAL_GAMES]` array:

```c
static const struct game_entry games[TOTAL_GAMES] = {
    {"DOOM (EP.1)",      "[3D] ", 0, 0},
    {"WOLFENSTEIN",      "[3D] ", 1, 0},
    {"MINESWEEPER",      "[PUZ]", 7, 0},
    {"FLAPPY BIRD",      "[ARC]", 8, 0},
    ...
    {"STAR TREK",        "[CPM]", 5, "MBASIC STARTRK"},
    ...
    {"INVADERS",         "[CH8]", 6, "INVADERS"},
    ...
};
```

### Example A: Swap in Oregon Trail
To replace any slot with **Oregon Trail**, simply change that line to:
```c
    {"OREGON TRAIL",     "[CPM]", 5, "MBASIC OREGON"},
```

### Example B: Swap in ELIZA (MIT AI)
To replace any slot with **ELIZA**, simply change that line to:
```c
    {"ELIZA (AI)",       "[CPM]", 5, "MBASIC ELIZA"},
```

### Example C: Swap in a Reserve CHIP-8 ROM (e.g. Syzygy or Guess)
To replace any slot with a reserve ROM from `games/vault/chip8/`:
1. Copy the `.ch8` file into `games/chip8/roms/` (if not already there).
2. Set the entry in `menu.c`:
```c
    {"SYZYGY ARC",       "[CH8]", 6, "SYZYGY"},
```

---

## 3. Rebuilding the Console Firmware

After editing `menu.c`, rebuild and package with one command:

```bash
bash games/menu/build.sh
```

Then run:
```powershell
py host/play.py
```
