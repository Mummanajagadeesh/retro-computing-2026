#!/usr/bin/env python3
"""play.py -- All-in-one launcher and player for the retro_fpga console.

Usage:
  python host/play.py               # Directly boots on-screen 32-game launcher on FPGA
  python host/play.py --list        # Print complete list of all 32 games
  python host/play.py doom          # Upload and play DOOM directly
  python host/play.py wolf3d        # Upload and play Wolfenstein 3D directly
  python host/play.py invaders      # Upload and play Space Invaders directly
  python host/play.py 7             # Upload and play game #7
"""
import argparse
import os
import subprocess
import sys
import types

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from uploader import cmd_upload

# Complete 32 Games Catalog: Zero Test/Debug boilerplate
GAMES_32 = [
    # 1 - 5: Native Bare-Metal RISC-V Games & 3D Engines
    {
        "id": "doom",
        "num": 1,
        "category": "native",
        "name": "DOOM (Episode 1: Knee-Deep in the Dead)",
        "badge": "3D FPS / BSP",
        "desc": "Authentic id Software 1993 3D BSP engine with monsters, weapons, and E1M1.",
        "ctrl": "Arrows/WASD move, Ctrl fire, Space use, Shift run, 1-7 weapons",
        "elf": os.path.join(ROOT_DIR, "games", "doom", "doom.elf"),
        "wad": os.path.join(ROOT_DIR, "games", "doom", "doom1.wad"),
        "viewer": "tiny",
    },
    {
        "id": "wolf3d",
        "num": 2,
        "category": "native",
        "name": "Wolfenstein 3D",
        "badge": "3D Raycaster",
        "desc": "Real-time 3D raycaster with textured walls, 3D maze corridors, and weapon view.",
        "ctrl": "Arrows/WASD move/turn, Space fire weapon, M toggle mini-map",
        "elf": os.path.join(ROOT_DIR, "games", "wolf3d", "wolf3d.elf"),
        "wad": os.path.join(ROOT_DIR, "games", "doom", "empty.wad"),
        "viewer": "tiny",
    },
    {
        "id": "snake",
        "num": 3,
        "category": "native",
        "name": "Snake",
        "badge": "Arcade",
        "desc": "Classic arcade snake with autonomous attract AI mode and player takeover.",
        "ctrl": "Arrows or W/A/S/D to steer snake; touch any key to take over from AI",
        "elf": os.path.join(ROOT_DIR, "games", "snake", "snake.elf"),
        "wad": os.path.join(ROOT_DIR, "games", "doom", "empty.wad"),
        "viewer": "tiny",
    },
    {
        "id": "2048",
        "num": 4,
        "category": "native",
        "name": "2048",
        "badge": "Puzzle",
        "desc": "Power-of-two number sliding puzzle with real-time color-coded tiles.",
        "ctrl": "Arrows or W/A/S/D to slide tiles across the 4x4 grid",
        "elf": os.path.join(ROOT_DIR, "games", "g2048", "g2048.elf"),
        "wad": os.path.join(ROOT_DIR, "games", "doom", "empty.wad"),
        "viewer": "tiny",
    },
    {
        "id": "tetris",
        "num": 5,
        "category": "native",
        "name": "Tetris",
        "badge": "Puzzle",
        "desc": "Classic falling tetrominoes in 10x20 well with rotations and hard drop.",
        "ctrl": "Left/Right move, Up/W rotate, Down/S soft drop, Space hard drop",
        "elf": os.path.join(ROOT_DIR, "games", "tetris", "tetris.elf"),
        "wad": os.path.join(ROOT_DIR, "games", "doom", "empty.wad"),
        "viewer": "tiny",
    },

    # 6 - 11: CP/M 2.2 Retro Games & Systems (Powered by RunCPM Z80 on RV32IM)
    {
        "id": "startrk", "num": 6, "category": "cpm", "name": "Star Trek (CP/M)", "badge": "CP/M",
        "desc": "1978 Tactical space warfare simulator on CP/M 2.2 via RunCPM.",
        "ctrl": "Commands: 1=SRS, 2=LRS, 3=Phasers, 4=Torpedo, 5=Warp, 6=Shields",
        "elf": os.path.join(ROOT_DIR, "games", "cpm", "cpm.elf"),
        "wad": os.path.join(ROOT_DIR, "games", "cpm", "disk.blob"), "viewer": "tiny"
    },
    {
        "id": "ladder", "num": 7, "category": "cpm", "name": "Ladder (CP/M)", "badge": "CP/M",
        "desc": "1982 ASCII platform climber game climbing ladders and dodging boulders.",
        "ctrl": "4=Left, 6=Right, 8=Climb Up, 2=Climb Down",
        "elf": os.path.join(ROOT_DIR, "games", "cpm", "cpm.elf"),
        "wad": os.path.join(ROOT_DIR, "games", "cpm", "disk.blob"), "viewer": "tiny"
    },
    {
        "id": "hamurabi", "num": 8, "category": "cpm", "name": "Hamurabi (CP/M)", "badge": "CP/M",
        "desc": "1973 Kingdom management economic sim on CP/M 2.2 via RunCPM.",
        "ctrl": "Input grain, bushels, acres to buy/sell, plant crops, feed citizens",
        "elf": os.path.join(ROOT_DIR, "games", "cpm", "cpm.elf"),
        "wad": os.path.join(ROOT_DIR, "games", "cpm", "disk.blob"), "viewer": "tiny"
    },
    {
        "id": "lunar", "num": 9, "category": "cpm", "name": "Lunar Lander (CP/M)", "badge": "CP/M",
        "desc": "1969 Apollo trajectory physics sim on CP/M 2.2 via RunCPM.",
        "ctrl": "Enter retro-rocket fuel burn rate (0-30 lbs/sec) to control descent",
        "elf": os.path.join(ROOT_DIR, "games", "cpm", "cpm.elf"),
        "wad": os.path.join(ROOT_DIR, "games", "cpm", "disk.blob"), "viewer": "tiny"
    },
    {
        "id": "wumpus", "num": 10, "category": "cpm", "name": "Hunt the Wumpus (CP/M)", "badge": "CP/M",
        "desc": "1973 Dodecahedron cave deduction & hazard game on CP/M 2.2.",
        "ctrl": "1=Move, 2=Shoot crooked magic arrows, 3=Quit",
        "elf": os.path.join(ROOT_DIR, "games", "cpm", "cpm.elf"),
        "wad": os.path.join(ROOT_DIR, "games", "cpm", "disk.blob"), "viewer": "tiny"
    },
    {
        "id": "cpm", "num": 11, "category": "cpm", "name": "RunCPM Dev Studio", "badge": "Z80 VM",
        "desc": "CP/M 2.2 OS shell: MBASIC 5.29, ASM, DDT, PIP, ED, Z80ASM with 85 files.",
        "ctrl": "Console commands: DIR, TYPE 1STREAD.ME, MBASIC, ASM, DDT, PIP",
        "elf": os.path.join(ROOT_DIR, "games", "cpm", "cpm.elf"),
        "wad": os.path.join(ROOT_DIR, "games", "cpm", "disk.blob"), "viewer": "tiny"
    },

    # 12 - 32: Chip-8 Virtual Console Games (21 Unique Classics, ZERO Repetitions)
    {"id": "invaders", "num": 12, "category": "chip8", "rom": "invaders", "name": "Space Invaders", "badge": "Chip-8", "desc": "1978 Space defense arcade classic.", "ctrl": "Q/E move cannon, W fire missile"},
    {"id": "pong", "num": 13, "category": "chip8", "rom": "pong", "name": "Pong (1P vs AI)", "badge": "Chip-8", "desc": "Table tennis rally against computer AI opponent.", "ctrl": "W paddle up, S paddle down"},
    {"id": "brix", "num": 14, "category": "chip8", "rom": "brix", "name": "Brix (Breakout)", "badge": "Chip-8", "desc": "Deflect bouncing ball to demolish brick wall.", "ctrl": "Q move left, E move right"},
    {"id": "blinky", "num": 15, "category": "chip8", "rom": "blinky", "name": "Blinky (Pac-Man)", "badge": "Chip-8", "desc": "Navigate maze, eat pellets, and dodge ghosts.", "ctrl": "W up, S down, Q left, E right"},
    {"id": "tank", "num": 16, "category": "chip8", "rom": "tank", "name": "Tank Arena", "badge": "Chip-8", "desc": "Top-down armored vehicle battle combat arena.", "ctrl": "W/S/A/D drive & aim, Space fire shell"},
    {"id": "blitz", "num": 17, "category": "chip8", "rom": "blitz", "name": "Blitz (Bomber)", "badge": "Chip-8", "desc": "Bomb city skyscrapers before your aircraft descends.", "ctrl": "W drop bomb"},
    {"id": "missile", "num": 18, "category": "chip8", "rom": "missile", "name": "Missile Defense", "badge": "Chip-8", "desc": "Intercept incoming rocket attacks over target city.", "ctrl": "Q/E target, W launch missile"},
    {"id": "ufo", "num": 19, "category": "chip8", "rom": "ufo", "name": "UFO Shooter", "badge": "Chip-8", "desc": "High-speed flying saucer target shooting.", "ctrl": "Q/E move cannon, W fire laser"},
    {"id": "cave", "num": 20, "category": "chip8", "rom": "cave", "name": "Cave Explorer", "badge": "Chip-8", "desc": "Navigate treacherous cavern tunnels and walls.", "ctrl": "W thruster up, Q/E steer left/right"},
    {"id": "landing", "num": 21, "category": "chip8", "rom": "landing", "name": "Lunar Descent", "badge": "Chip-8", "desc": "Lunar module descent with gravity and fuel limits.", "ctrl": "W main thrust, Q/E retro-jets"},
    {"id": "airplane", "num": 22, "category": "chip8", "rom": "airplane", "name": "Airplane", "badge": "Chip-8", "desc": "Flight acrobatics and mid-air obstacle dodging.", "ctrl": "W climb, S dive, Q/E roll"},
    {"id": "connect4", "num": 23, "category": "chip8", "rom": "connect4", "name": "Connect 4", "badge": "Chip-8", "desc": "Tactical four-in-a-row checker drop board game.", "ctrl": "Keys 1-7 to select drop column"},
    {"id": "tictac", "num": 24, "category": "chip8", "rom": "tictac", "name": "Tic-Tac-Toe", "badge": "Chip-8", "desc": "Classic 3x3 noughts and crosses grid battle.", "ctrl": "Keys 1-9 for grid position"},
    {"id": "15puzzle", "num": 25, "category": "chip8", "rom": "15puzzle", "name": "15 Puzzle", "badge": "Chip-8", "desc": "Order numbered tiles 1 to 15 in sliding square.", "ctrl": "Q/W/E/A/S/D to slide adjacent tile"},
    {"id": "puzzle", "num": 26, "category": "chip8", "rom": "puzzle", "name": "Logic Puzzle", "badge": "Chip-8", "desc": "Number permutation and deduction challenge.", "ctrl": "Keypad numbers 1-9"},
    {"id": "merlin", "num": 27, "category": "chip8", "rom": "merlin", "name": "Merlin (Simon Says)", "badge": "Chip-8", "desc": "Simon Says electronic sequence memory pattern game.", "ctrl": "Keys 1, 2, 4, 5 for flashing quadrants"},
    {"id": "hidden", "num": 28, "category": "chip8", "rom": "hidden", "name": "Hidden Pairs", "badge": "Chip-8", "desc": "Memory card match and hidden pair discovery.", "ctrl": "Q/W/E/S cursor move, Space flip card"},
    {"id": "guess", "num": 29, "category": "chip8", "rom": "guess", "name": "Guess Number", "badge": "Chip-8", "desc": "Binary search number deduction guessing game.", "ctrl": "1 higher, 2 lower, 3 match"},
    {"id": "maze", "num": 30, "category": "chip8", "rom": "maze", "name": "Maze Explorer", "badge": "Chip-8", "desc": "Real-time algorithmic labyrinth carving and escape.", "ctrl": "W/S/A/D move through maze corridors"},
    {"id": "kaleid", "num": 31, "category": "chip8", "rom": "kaleid", "name": "Kaleidoscope", "badge": "Chip-8", "desc": "Hypnotic 4-way symmetrical pattern generator.", "ctrl": "Keys 1-4 to alter symmetry"},
    {"id": "wipeoff", "num": 32, "category": "chip8", "rom": "wipeoff", "name": "Wipeoff", "badge": "Chip-8", "desc": "Angular ball rebound paddle brick breaker.", "ctrl": "Q paddle left, E paddle right"},
]

# Set default paths for Chip-8 items
for item in GAMES_32:
    if item["category"] == "chip8":
        item["elf"] = os.path.join(ROOT_DIR, "games", "chip8", "chip8.elf")
        item["wad"] = os.path.join(ROOT_DIR, "games", "chip8", "roms", f"{item['rom']}.ch8")
        item["viewer"] = "tiny"


def print_roster():
    print("\n" + "=" * 80)
    print("         retro_fpga Console -- All 32 Playable Games (Zero Repetitions)")
    print("=" * 80)
    print("-- NATIVE & 3D CONSOLE GAMES (Bare-Metal RISC-V RV32IM @ 45 FPS) --------------")
    for i in range(5):
        g = GAMES_32[i]
        print(f"  {g['num']:2d}. {g['name']:<38s} [{g['badge']}]")

    print("\n-- CP/M 2.2 RETRO GAMES & SYSTEMS (Powered by RunCPM Z80 on RV32IM) -----------")
    for i in range(5, 11):
        g = GAMES_32[i]
        print(f"  {g['num']:2d}. {g['name']:<38s} [{g['badge']}]")

    print("\n-- CHIP-8 VIRTUAL CONSOLE GAMES (21 Unique Classics) --------------------------")
    c8_items = GAMES_32[11:32]
    half = (len(c8_items) + 1) // 2
    for r in range(half):
        g1 = c8_items[r]
        g2 = c8_items[r + half] if r + half < len(c8_items) else None
        s1 = f"{g1['num']:2d}. {g1['name']:<28s}"
        s2 = f"{g2['num']:2d}. {g2['name']:<28s}" if g2 else ""
        print(f"  {s1}  {s2}")
    print("=" * 80 + "\n")


def resolve_game(query: str):
    s = query.strip().lower()
    try:
        n = int(s)
        if 1 <= n <= len(GAMES_32):
            return GAMES_32[n - 1]
    except ValueError:
        pass

    for g in GAMES_32:
        if s == g["id"].lower() or s == g["name"].lower():
            return g
        if "rom" in g and s == g["rom"].lower():
            return g

    for g in GAMES_32:
        if s in g["id"].lower() or s in g["name"].lower():
            return g
    return None


def main():
    parser = argparse.ArgumentParser(description="retro_fpga Console Launcher")
    parser.add_argument("game", nargs="?", help="Optional game name or number (1-32). If omitted, launches on-screen graphical menu.")
    parser.add_argument("--port", default="COM7", help="Serial port (default: COM7)")
    parser.add_argument("--baud", type=int, default=921600, help="Baud rate (default: 921600)")
    parser.add_argument("--list", action="store_true", help="Print complete 32-game list and exit")
    parser.add_argument("--res", choices=["fast", "full"], default="full", help="Initial resolution (default: full)")
    args = parser.parse_args()

    if args.list:
        print_roster()
        sys.exit(0)

    # If no game specified: boot unified on-screen menu firmware!
    if not args.game:
        print("\n" + "=" * 80)
        print("          retro_fpga Console -- On-Screen Graphical Launcher")
        print("================================================================================")
        print("Starting unified on-screen console BIOS with all 32 games...")
        print("Upload targets: games/menu/menu.elf + games/menu/menu.blob")
        print(f"Serial port:    {args.port} @ {args.baud} baud")
        print("Controls:       Use UP/DOWN (or W/S) on the graphical screen to move cursor")
        print("                Press ENTER or SPACE to launch the highlighted game")
        print("================================================================================\n")

        elf_path = os.path.join(ROOT_DIR, "games", "menu", "menu.elf")
        blob_path = os.path.join(ROOT_DIR, "games", "menu", "menu.blob")

        if not os.path.exists(elf_path) or not os.path.exists(blob_path):
            print(f"Error: Unified firmware missing: {elf_path} or {blob_path}")
            sys.exit(1)

        upload_args = types.SimpleNamespace(
            elf=elf_path,
            wad=blob_path,
            wad_base=None,
            port=args.port,
            baud=args.baud,
            no_term=True,
        )

        try:
            cmd_upload(upload_args)
        except Exception as e:
            print(f"[play] Upload error: {e}")
            sys.exit(1)

        print("\n[play] Unified firmware uploaded successfully! Opening live 45 FPS graphical viewer...")
        viewer_script = os.path.join(SCRIPT_DIR, "tinyview.py")
        cmd = [sys.executable, viewer_script, "--port", args.port, "--baud", str(args.baud)]
        subprocess.run(cmd)
        return

    # Direct launch requested for a specific game
    target = resolve_game(args.game)
    if not target:
        print(f"Unknown game: '{args.game}'")
        print_roster()
        sys.exit(1)

    print("\n" + "-" * 60)
    print(f"Launching Direct Game: #{target['num']} {target['name']}")
    print(f"Platform/Badge:       {target['badge']}")
    print(f"ELF:                  {os.path.basename(target['elf'])}")
    print(f"WAD/ROM:              {os.path.basename(target['wad'])}")
    print(f"Controls:             {target['ctrl']}")
    print("-" * 60 + "\n")

    if not os.path.exists(target["elf"]) or not os.path.exists(target["wad"]):
        print(f"Error: Target files missing for {target['name']}")
        sys.exit(1)

    upload_args = types.SimpleNamespace(
        elf=target["elf"],
        wad=target["wad"],
        wad_base=None,
        port=args.port,
        baud=args.baud,
        no_term=True,
    )

    try:
        cmd_upload(upload_args)
    except Exception as e:
        print(f"[play] Upload error: {e}")
        sys.exit(1)

    print(f"\n[play] Upload complete. Starting 45 FPS 64x32 viewer...")
    viewer_script = os.path.join(SCRIPT_DIR, "tinyview.py")
    cmd = [sys.executable, viewer_script, "--port", args.port, "--baud", str(args.baud)]
    subprocess.run(cmd)


if __name__ == "__main__":
    main()
