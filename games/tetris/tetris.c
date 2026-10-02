/* tetris.c -- Tetris for the retro_fpga console.
 * 10x20 well of 2x1 cells beside a next/level/lines panel. Left/right move,
 * up/X rotate, down soft drop (one cell per tap), space hard drop. No key
 * auto-repeat on this console: every action is one key tap.
 */
#include "console.h"

#ifdef MENU_BUILD
#define main tetris_main
#endif


#define W 10
#define H 20
#define CW 2
#define CHH 1
#define OX 2
#define OY 6

/* 7 pieces x 4 facings, 4x4 box, bit15 = row0col0 */
static const uint16_t shapes[7][4] = {
    {0x0F00, 0x2222, 0x0F00, 0x2222},   /* I */
    {0x6600, 0x6600, 0x6600, 0x6600},   /* O */
    {0x4E00, 0x4640, 0x0E40, 0x4C40},   /* T */
    {0x6C00, 0x4620, 0x6C00, 0x4620},   /* S */
    {0xC600, 0x2640, 0xC600, 0x2640},   /* Z */
    {0x8E00, 0x6440, 0x0E20, 0x44C0},   /* J */
    {0x2E00, 0x4460, 0x0E80, 0xC440},   /* L */
};
static const uint8_t colors[7] = {
    C_CYAN, C_YELLOW, C_MAGENTA, C_GREEN, C_RED, C_BLUE, C_ORANGE,
};

static uint8_t well[W * H];
static int cur, next, rot, px, py;
static uint32_t score, lines, level;
static int mode;   /* 0 title, 1 play, 2 over */
static uint32_t last_fall;
static int prev1 = -1, prev2 = -1;

static int collides(int tx, int ty, int tr)
{
    uint16_t m = shapes[cur][tr & 3];
    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
            if (!(m & (0x8000u >> (r * 4 + c)))) continue;
            int wx = tx + c, wy = ty + r;
            if (wx < 0 || wx >= W || wy >= H) return 1;
            if (wy >= 0 && well[wy * W + wx]) return 1;
        }
    }
    return 0;
}

static int rng7(void)
{
    int v = (int)(rng32() % 7);
    if (v == prev1 && v == prev2) v = (int)(rng32() % 7);
    prev2 = prev1; prev1 = v;
    return v;
}

static void new_game(void)
{
    for (int i = 0; i < W * H; i++) well[i] = 0;
    score = 0; lines = 0; level = 1;
    next = rng7();
    cur = rng7(); rot = 0; px = 3; py = 0;
    mode = 1;
    last_fall = ticks_ms();
}

static void spawn(void)
{
    cur = next; next = rng7(); rot = 0; px = 3; py = 0;
    if (collides(px, py, rot)) mode = 2;
}

static void lock(void)
{
    uint16_t m = shapes[cur][rot & 3];
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 4; c++)
            if (m & (0x8000u >> (r * 4 + c))) {
                int wx = px + c, wy = py + r;
                if (wy >= 0 && wx >= 0 && wx < W && wy < H)
                    well[wy * W + wx] = (uint8_t)(cur + 1);
            }
    int cleared = 0;
    for (int y = H - 1; y >= 0; y--) {
        int full = 1;
        for (int x = 0; x < W; x++)
            if (!well[y * W + x]) { full = 0; break; }
        if (full) {
            cleared++;
            for (int yy = y; yy > 0; yy--)
                for (int x = 0; x < W; x++)
                    well[yy * W + x] = well[(yy - 1) * W + x];
            for (int x = 0; x < W; x++) well[x] = 0;
            y++;
        }
    }
    if (cleared) {
        static const uint16_t pts[5] = {0, 40, 100, 300, 1200};
        score += (uint32_t)pts[cleared] * level;
        lines += (uint32_t)cleared;
        level = lines / 10 + 1;
    }
    spawn();
}

static uint32_t fall_ms(void)
{
    int ms = 450 - (int)(level - 1) * 35;
    return (uint32_t)(ms < 60 ? 60 : ms);
}

static void input(void)
{
    int pressed;
    uint8_t code;
    while (key_poll(&pressed, &code)) {
        if (!pressed) continue;
        if (mode == 0 || mode == 2) { new_game(); continue; }
        if (code == K_LEFT || code == 'a' || code == 'A') { if (!collides(px - 1, py, rot)) px--; }
        else if (code == K_RIGHT || code == 'd' || code == 'D') { if (!collides(px + 1, py, rot)) px++; }
        else if (code == K_UP || code == 'x' || code == 'X' || code == 'w' || code == 'W' || code == K_ENTER || code == 10) {
            int nr = (rot + 1) & 3;
            if (!collides(px, py, nr)) rot = nr;
        } else if (code == K_DOWN || code == 's' || code == 'S') {
            if (!collides(px, py + 1, rot)) { py++; score++; }
            else lock();
        } else if (code == K_SPACE || code == 32) {
            while (!collides(px, py + 1, rot)) { py++; score++; }
            lock();
        }
    }
}

static void draw_cells(int ox, int oy, int cw, int chh, uint16_t m, uint8_t c)
{
    for (int r = 0; r < 4; r++)
        for (int col = 0; col < 4; col++)
            if (m & (0x8000u >> (r * 4 + col)))
                fb_rect(ox + col * cw, oy + r * chh, cw, chh, c);
}

static void render(void)
{
    fb_clear(C_BLACK);
    if (mode == 0) {
        fb_rect(8, 6, 48, 22, C_BLACK);
        fb_rect(8, 6, 48, 1, C_GRAY); fb_rect(8, 27, 48, 1, C_GRAY);
        fb_rect(8, 6, 1, 22, C_GRAY); fb_rect(55, 6, 1, 22, C_GRAY);
        fb_text(20, 10, "TETRIS", C_CYAN);
        fb_text(14, 18, "PRESS KEY", C_WHITE);
        return;
    }
    fb_text(1, 1, "SCORE", C_WHITE);
    fb_num(26, 1, score, 5, C_WHITE);
    fb_rect(OX - 1, OY - 1, W * CW + 2, 1, C_GRAY);
    fb_rect(OX - 1, OY + H * CHH, W * CW + 2, 1, C_GRAY);
    fb_rect(OX - 1, OY, 1, H * CHH, C_GRAY);
    fb_rect(OX + W * CW, OY, 1, H * CHH, C_GRAY);
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++)
            if (well[y * W + x])
                fb_rect(OX + x * CW, OY + y * CHH, CW, CHH, colors[well[y * W + x] - 1]);
    if (mode == 1)
        draw_cells(OX + px * CW, OY + py * CHH, CW, CHH,
                   shapes[cur][rot & 3], colors[cur]);
    fb_text(26, 7, "NEXT", C_GRAY);
    draw_cells(28, 13, 2, 2, shapes[next][0], colors[next]);
    fb_text(26, 22, "LV", C_GRAY);
    fb_num(38, 22, level, 1, C_WHITE);
    fb_text(26, 27, "LN", C_GRAY);
    fb_num(38, 27, lines, 2, C_WHITE);
    if (mode == 2) {
        fb_rect(10, 10, 44, 14, C_BLACK);
        fb_text(14, 12, "GAME OVER", C_RED);
        fb_text(26, 18, "SC", C_GRAY);
        fb_num(38, 18, score, 5, C_WHITE);
    }
}

int main(void)
{
    print("\n[tetris] retro_fpga Tetris\n");
    next = rng7();
    mode = 0;
    key_flush();
    uint32_t tick = 0;
    for (;;) {
        input();
        if (mode == 1 && ticks_ms() - last_fall > fall_ms()) {
            if (!collides(px, py + 1, rot)) py++;
            else lock();
            last_fall = ticks_ms();
        }
        render();
        if ((++tick & 1) == 0) dump_tiny();
        sleep_ms(16);
    }
}
