/* g2048.c -- 2048 for the retro_fpga console.
 * 4x4 grid of 15x6 cells under a title/score row. Arrows/WASD slide;
 * each key press is one move. Tiles are color coded, values printed.
 */
#include "console.h"

#ifdef MENU_BUILD
#define main g2048_main
#endif


#define GX 0
#define GY 7
#define CW 15
#define CHH 5
#define GAP 1

static uint16_t g[16];
static uint32_t score;
static int over, won, dismissed;

static const uint8_t tile_c[12] = {
    0x24u, 0xDBu, 0xB6u, 0xF2u, 0xE8u, 0xE0u,
    0xC0u, 0xF6u, 0xFCu, 0x3Eu, 0x1Eu, 0x1Fu,
};
/* dark text on the light tiles (idx 1,2,3,7,8), white elsewhere */
static const uint8_t text_c[12] = {
    0x00u, 0x00u, 0x00u, 0x00u, 0xFFu, 0xFFu,
    0xFFu, 0x00u, 0x00u, 0xFFu, 0xFFu, 0xFFu,
};

static int log2idx(uint16_t v)
{
    int i = 0;
    while (v > 2) { v >>= 1; i++; }
    return i + 1;   /* 2->1 ... 2048->11 */
}

static void spawn(void)
{
    int empt[16], n = 0;
    for (int i = 0; i < 16; i++)
        if (!g[i]) empt[n++] = i;
    if (!n) return;
    g[empt[rng32() % (uint32_t)n]] = (rng32() % 10 == 0) ? 4 : 2;
}

static void reset(void)
{
    for (int i = 0; i < 16; i++) g[i] = 0;
    score = 0; over = 0; won = 0; dismissed = 0;
    spawn(); spawn();
}

/* slide one line left; returns 1 if anything changed, adds to score */
static int slide_line(uint16_t *a)
{
    uint16_t t[4], w = 0;
    for (int i = 0; i < 4; i++)
        if (a[i]) t[w++] = a[i];
    while (w < 4) t[w++] = 0;
    int gained = 0, o = 0;
    uint16_t r[4];
    for (int i = 0; i < 4; i++) {
        if (i + 1 < 4 && t[i] && t[i] == t[i + 1]) {
            r[o++] = (uint16_t)(t[i] * 2); gained += t[i] * 2; i++;
        } else {
            r[o++] = t[i];
        }
    }
    int changed = 0;
    for (int i = 0; i < 4; i++)
        if (a[i] != r[i]) { changed = 1; a[i] = r[i]; }
    score += (uint32_t)gained;
    return changed;
}

static int cell_idx(int dir, int line, int i)
{
    switch (dir) {
    case 0: return line * 4 + i;          /* left */
    case 1: return line * 4 + (3 - i);    /* right */
    case 2: return i * 4 + line;          /* up */
    default: return (3 - i) * 4 + line;   /* down */
    }
}

static int move_dir(int dir)
{
    int changed = 0;
    for (int l = 0; l < 4; l++) {
        uint16_t a[4];
        for (int i = 0; i < 4; i++) a[i] = g[cell_idx(dir, l, i)];
        if (slide_line(a)) changed = 1;
        for (int i = 0; i < 4; i++) g[cell_idx(dir, l, i)] = a[i];
    }
    return changed;
}

static int can_move(void)
{
    for (int i = 0; i < 16; i++)
        if (!g[i]) return 1;
    for (int y = 0; y < 4; y++)
        for (int x = 0; x < 4; x++) {
            if (x < 3 && g[y * 4 + x] == g[y * 4 + x + 1]) return 1;
            if (y < 3 && g[y * 4 + x] == g[(y + 1) * 4 + x]) return 1;
        }
    return 0;
}

static void render(void)
{
    fb_clear(C_BLACK);
    fb_text(1, 1, "2048", C_YELLOW);
    fb_text(24, 1, "SC", C_GRAY);
    fb_num(36, 1, score > 9999 ? 9999 : score, 4, C_WHITE);
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            int x = GX + i * (CW + GAP), y = GY + j * (CHH + GAP);
            uint16_t v = g[j * 4 + i];
            int idx = v ? log2idx(v) : 0;
            if (idx > 11) idx = 11;
            fb_rect(x, y, CW, CHH, tile_c[idx]);
            if (v) {
                int digits = v < 10 ? 1 : v < 100 ? 2 : v < 1000 ? 3 : 4;
                fb_num(x + (CW - (digits * 4 - 1)) / 2, y + 1, v, digits, text_c[idx]);
            }
        }
    }
    if (over) {
        fb_rect(6, 11, 52, 12, C_BLACK);
        fb_text(11, 13, "GAME OVER", C_RED);
        fb_text(14, 19, "PRESS KEY", C_WHITE);
    } else if (won && !dismissed) {
        fb_rect(8, 11, 48, 12, C_BLACK);
        fb_text(14, 13, "YOU WIN", C_GREEN);
        fb_text(14, 19, "PRESS KEY", C_WHITE);
    }
}

int main(void)
{
    print("\n[2048] retro_fpga 2048\n");
    reset();
    key_flush();
    uint32_t tick = 0;
    for (;;) {
        int pressed;
        uint8_t code;
        while (key_poll(&pressed, &code)) {
            if (!pressed) continue;
            if (over || (won && !dismissed)) {
                if (over) reset();
                else dismissed = 1;
                continue;
            }
            int dir = -1;
            if (code == K_LEFT || code == 'a' || code == 'A') dir = 0;
            else if (code == K_RIGHT || code == 'd' || code == 'D') dir = 1;
            else if (code == K_UP || code == 'w' || code == 'W') dir = 2;
            else if (code == K_DOWN || code == 's' || code == 'S') dir = 3;
            if (dir >= 0 && move_dir(dir)) {
                spawn();
                for (int i = 0; i < 16; i++)
                    if (g[i] == 2048) won = 1;
                if (!can_move()) over = 1;
            }
        }
        render();
        if ((++tick & 1) == 0) dump_tiny();
        sleep_ms(16);
    }
}
