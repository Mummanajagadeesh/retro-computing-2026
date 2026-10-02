/* menu.c -- On-Screen 32-Game Console Launcher for RV32IM retro_fpga
 * Uniform 64x32 display @ 45 FPS real-time.
 */
#ifdef HOST_BUILD
#include "native_harness.h"
#define FB32 ((volatile uint8_t *)g_fb)
const char *cpm_auto_cmd = 0;
__attribute__((weak)) int snake_main(void) { return 0; }
__attribute__((weak)) int tetris_main(void) { return 0; }
__attribute__((weak)) int g2048_main(void) { return 0; }
__attribute__((weak)) int minesweeper_main(void) { return 0; }
__attribute__((weak)) int flappy_main(void) { return 0; }
__attribute__((weak)) int chip8_main(void) { return 0; }
__attribute__((weak)) int cpm_entry(void) { return 0; }
__attribute__((weak)) int doom_main(int argc, char **argv) { (void)argc; (void)argv; return 0; }
__attribute__((weak)) int wolf3d_main(void) { return 0; }
#else
#include "console.h"
#endif
#include "menu/menu_blob.h"

/* Native games and engines */
int snake_main(void);
int tetris_main(void);
int g2048_main(void);
int minesweeper_main(void);
int flappy_main(void);
int chip8_main(void);
int cpm_entry(void);
int doom_main(int argc, char **argv);
int wolf3d_main(void);

/* Globals consumed by chip8.c / abstraction_retro.h / w_file_blob.c */
const uint8_t *menu_disk_base;
const uint8_t *menu_doom_base;
const uint8_t *menu_rom_ptr;
uint32_t menu_rom_len;

static const struct menuwad_rom *romtab;
static uint32_t romcount;

/* 32-Game Catalog Entry Structure */
struct game_entry {
    const char *name;
    const char *badge;
    uint8_t type;         /* 0=DOOM, 1=WOLF3D, 2=SNAKE, 3=2048, 4=TETRIS, 5=CPM, 6=CHIP8, 7=MINES, 8=FLAP */
    const char *arg;      /* Chip-8 ROM key OR CP/M startup command */
};

#define TOTAL_GAMES 32

static const struct game_entry games[TOTAL_GAMES] = {
    /* 1 - 7: Native Games & 3D Engines (Uniform 64x32 @ 45 FPS) */
    {"DOOM (EP.1)",      "[3D] ", 0, 0},
    {"WOLFENSTEIN",      "[3D] ", 1, 0},
    {"MINESWEEPER",      "[PUZ]", 7, 0},
    {"FLAPPY BIRD",      "[ARC]", 8, 0},
    {"SNAKE",            "[ARC]", 2, 0},
    {"2048",             "[PUZ]", 3, 0},
    {"TETRIS",           "[PUZ]", 4, 0},

    /* 8 - 13: CP/M 2.2 Retro Games & Systems (RunCPM Z80 on RV32IM) */
    {"STAR TREK",        "[CPM]", 5, "MBASIC STARTRK"},
    {"LADDER",           "[CPM]", 5, "MBASIC LADDER"},
    {"HAMURABI",         "[CPM]", 5, "MBASIC HAMURABI"},
    {"LUNAR LANDER",     "[CPM]", 5, "MBASIC LUNAR"},
    {"HUNT WUMPUS",      "[CPM]", 5, "MBASIC WUMPUS"},
    {"RUNCPM OS",        "[CPM]", 5, "DIR"},

    /* 14 - 32: Chip-8 Virtual Console Games (19 Curated Classics) */
    {"INVADERS",         "[CH8]", 6, "INVADERS"},
    {"PONG AI",          "[CH8]", 6, "PONG"},
    {"BRIX BREAK",       "[CH8]", 6, "BRIX"},
    {"TANK ARENA",       "[CH8]", 6, "TANK"},
    {"BLITZ BOMB",       "[CH8]", 6, "BLITZ"},
    {"MISSILE DEF",      "[CH8]", 6, "MISSILE"},
    {"UFO SHOOTER",      "[CH8]", 6, "UFO"},
    {"CAVE ESCAPE",      "[CH8]", 6, "CAVE"},
    {"LUNAR LAND",       "[CH8]", 6, "LANDING"},
    {"AIRPLANE",         "[CH8]", 6, "AIRPLANE"},
    {"CONNECT 4",        "[CH8]", 6, "CONNECT4"},
    {"TIC-TAC-TOE",      "[CH8]", 6, "TICTAC"},
    {"15 PUZZLE",        "[CH8]", 6, "15PUZZLE"},
    {"LOGIC PUZ",        "[CH8]", 6, "PUZZLE"},
    {"MERLIN MEM",       "[CH8]", 6, "MERLIN"},
    {"HIDDEN PAIR",      "[CH8]", 6, "HIDDEN"},
    {"BLINKY PAC",       "[CH8]", 6, "BLINKY"},
    {"MAZE WALK",        "[CH8]", 6, "MAZE"},
    {"WIPEOFF",          "[CH8]", 6, "WIPEOFF"}
};

#define VISIBLE_ROWS 3

static void draw_menu(int sel, int top)
{
    /* Clear 64x32 framebuffer to solid black */
    fb_clear(C_BLACK);

    /* Header Bar (y=0..6) */
    fb_rect(0, 0, 64, 7, C_BLUE);
    fb_text(2, 1, "* RETRO 32 OS *", C_YELLOW);

    /* Top Divider Line (y=7) */
    fb_rect(0, 7, 64, 1, C_CYAN);

    /* 3 Scrollable Visible Rows */
    for (int r = 0; r < VISIBLE_ROWS && (top + r) < TOTAL_GAMES; r++) {
        int idx = top + r;
        int y = 9 + r * 6;

        char num_str[4];
        num_str[0] = '0' + ((idx + 1) / 10);
        num_str[1] = '0' + ((idx + 1) % 10);
        num_str[2] = '.';
        num_str[3] = 0;

        if (idx == sel) {
            /* Active selection: inverted highlight cursor bar */
            fb_rect(0, y - 1, 62, 6, C_WHITE);
            fb_text(1, y, ">", C_BLACK);
            fb_text(6, y, num_str, C_BLACK);
            fb_text(19, y, games[idx].name, C_BLACK);
        } else {
            /* Inactive item */
            fb_text(6, y, num_str, C_GRAY);
            fb_text(19, y, games[idx].name, C_WHITE);
        }
    }

    /* Right-edge Scrollbar Indicator (y=8..25, 18 px) */
    fb_rect(63, 8, 1, 18, C_DKGRAY);
    int thumb_y = 8 + (sel * (18 - 4)) / (TOTAL_GAMES - 1);
    fb_rect(63, thumb_y, 1, 4, C_YELLOW);

    /* Bottom Divider (y=26) */
    fb_rect(0, 26, 64, 1, C_GRAY);

    /* Footer Info Bar (y=27..31) */
    fb_rect(0, 27, 64, 5, C_DKGRAY);
    fb_text(2, 27, games[sel].badge, C_YELLOW);
    fb_text(42, 27, "[RUN]", C_GREEN);

    /* Immediately stream 64x32 frame over UART at 45 FPS */
    dump_tiny();
}

extern const char *cpm_auto_cmd;

static void launch_game(int sel)
{
    static char *dargv[] = { (char *)"doom", 0 };
    const struct game_entry *g = &games[sel];

    key_flush();

    switch (g->type) {
    case 0: /* DOOM */
        doom_main(1, dargv);
        break;
    case 1: /* Wolfenstein 3D */
        wolf3d_main();
        break;
    case 2: /* Snake */
        snake_main();
        break;
    case 3: /* 2048 */
        g2048_main();
        break;
    case 4: /* Tetris */
        tetris_main();
        break;
    case 5: /* RunCPM Retro Game or Dev Studio */
        cpm_auto_cmd = g->arg;
        cpm_entry();
        break;
    case 6: /* Chip-8 ROM */
        menu_rom_ptr = 0;
        menu_rom_len = 0;
        if (g->arg && romtab && romcount > 0) {
            for (uint32_t i = 0; i < romcount; i++) {
                int match = 1;
                for (int k = 0; g->arg[k]; k++) {
                    if (romtab[i].name[k] != g->arg[k]) {
                        match = 0; break;
                    }
                }
                if (match) {
                    menu_rom_ptr = (const uint8_t *)_wad_start + romtab[i].off;
                    menu_rom_len = romtab[i].len;
                    break;
                }
            }
        }
        chip8_main();
        break;
    case 7: /* Minesweeper */
        minesweeper_main();
        break;
    case 8: /* Flappy Bird */
        flappy_main();
        break;
    default:
        break;
    }

    key_flush();
}

int main(void)
{
    const struct menuwad_hdr *h = (const struct menuwad_hdr *)_wad_start;
    int sel = 0;
    int top = 0;

    if (h->magic == MENUWAD_MAGIC && h->version == MENUWAD_VERSION) {
        menu_disk_base = (const uint8_t *)_wad_start + h->disk_off;
        menu_doom_base = (const uint8_t *)_wad_start + h->doom_off;
        romtab = (const struct menuwad_rom *)
            ((const uint8_t *)_wad_start + sizeof(*h));
        romcount = h->rom_count;
    }

    key_flush();
    draw_menu(sel, top);

    uint32_t tick = 0;

    for (;;) {
        int pressed, moved = 0;
        uint8_t code;

        while (key_poll(&pressed, &code)) {
            if (!pressed)
                continue;

            if (code == K_UP || code == 'w' || code == 'W') {
                sel = (sel + TOTAL_GAMES - 1) % TOTAL_GAMES;
                moved = 1;
            } else if (code == K_DOWN || code == 's' || code == 'S') {
                sel = (sel + 1) % TOTAL_GAMES;
                moved = 1;
            } else if (code == K_ENTER || code == 10 || code == K_SPACE || code == 0xA2 || code == 0x20) {
                g_in_game = 1;
                if (setjmp(menu_jmp_buf) == 0) {
                    launch_game(sel);
                }
                g_in_game = 0;
                key_flush();
                draw_menu(sel, top);
                moved = 1;
            }
        }

        if (moved) {
            /* Keep sel visible within top..top + VISIBLE_ROWS - 1 */
            if (sel < top)
                top = sel;
            if (sel >= top + VISIBLE_ROWS)
                top = sel - VISIBLE_ROWS + 1;
            draw_menu(sel, top);
        } else if ((++tick & 1) == 0) {
            dump_tiny();
        }

        sleep_ms(22); /* 45 FPS smooth real-time streaming */
    }
}
