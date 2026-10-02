/* snake.c -- Snake for the retro_fpga console.
 * 32x13 field of 2x2 cells, status bar on top. Boots into an attract mode
 * (greedy AI) and hands over to the player on the first key. Arrows/WASD.
 */
#include "console.h"

#ifdef MENU_BUILD
#define main snake_main
#endif


#define FW 32
#define FH 13
#define FY 6
#define MAXLEN (FW * FH)
#define ABS(a) ((a) < 0 ? -(a) : (a))

static uint8_t sx[MAXLEN + 4], sy[MAXLEN + 4];
static int len, dir_x, dir_y, attract, food_x, food_y, score;
static uint32_t last_step;

static void render(void);

static int on_snake(int x, int y)
{
    for (int i = 0; i < len; i++)
        if (sx[i] == x && sy[i] == y) return 1;
    return 0;
}

static void place_food(void)
{
    int tries = 0;
    do {
        food_x = (int)(rng32() % FW);
        food_y = (int)(rng32() % FH);
    } while (on_snake(food_x, food_y) && ++tries < 80);
}

static void reset(int cpu)
{
    len = 4;
    for (int i = 0; i < len; i++) { sx[i] = (uint8_t)(FW / 2 - i); sy[i] = FH / 2; }
    dir_x = 1; dir_y = 0;
    score = 0;
    attract = cpu;
    place_food();
    last_step = ticks_ms();
}

static void die(void)
{
    for (int i = 0; i < 3; i++) {
        fb_rect(0, FY, 64, 26, C_WHITE); dump_tiny(); sleep_ms(120);
        render(); dump_tiny(); sleep_ms(120);
    }
    reset(1);
}

static void step(void)
{
    int nx = sx[0] + dir_x, ny = sy[0] + dir_y;
    int grow = (nx == food_x && ny == food_y);
    if (nx < 0 || nx >= FW || ny < 0 || ny >= FH) { die(); return; }
    int lim = grow ? len : len - 1;
    for (int i = 0; i < lim; i++)
        if (sx[i] == nx && sy[i] == ny) { die(); return; }
    for (int i = len; i > 0; i--) { sx[i] = sx[i - 1]; sy[i] = sy[i - 1]; }
    sx[0] = (uint8_t)nx; sy[0] = (uint8_t)ny;
    if (grow) {
        if (len < MAXLEN) len++;
        score += 10;
        place_food();
    }
}

/* greedy attract AI: closest safe non-reversing move to the food */
static void attract_ai(void)
{
    static const int8_t dx[4] = {1, -1, 0, 0};
    static const int8_t dy[4] = {0, 0, 1, -1};
    int best = 0, bestd = 1000000;
    for (int d = 0; d < 4; d++) {
        if (dx[d] == -dir_x && dy[d] == -dir_y) continue;
        int nx = sx[0] + dx[d], ny = sy[0] + dy[d];
        if (nx < 0 || nx >= FW || ny < 0 || ny >= FH) continue;
        if (on_snake(nx, ny)) continue;
        int dist = ABS(nx - food_x) + ABS(ny - food_y);
        if (dist < bestd) { bestd = dist; best = d; }
    }
    if (bestd < 1000000) { dir_x = dx[best]; dir_y = dy[best]; }
}

static void input(void)
{
    int pressed;
    uint8_t code;
    while (key_poll(&pressed, &code)) {
        if (!pressed) continue;
        int ndx = dir_x, ndy = dir_y;
        if (code == K_UP || code == 'w' || code == 'W') { ndx = 0; ndy = -1; }
        else if (code == K_DOWN || code == 's' || code == 'S') { ndx = 0; ndy = 1; }
        else if (code == K_LEFT || code == 'a' || code == 'A') { ndx = -1; ndy = 0; }
        else if (code == K_RIGHT || code == 'd' || code == 'D') { ndx = 1; ndy = 0; }
        if (!(ndx == -dir_x && ndy == -dir_y)) { dir_x = ndx; dir_y = ndy; }
        attract = 0;
    }
}

static void render(void)
{
    fb_clear(C_BLACK);
    fb_text(1, 1, "SCORE", C_WHITE);
    fb_num(26, 1, (uint32_t)score, 4, C_WHITE);
    fb_text(48, 1, attract ? "CPU" : "YOU", attract ? C_GREEN : C_YELLOW);
    fb_rect(food_x * 2, FY + food_y * 2, 2, 2, C_RED);
    for (int i = len - 1; i >= 1; i--)
        fb_rect(sx[i] * 2, FY + sy[i] * 2, 2, 2, (i & 3) == 0 ? C_GREEN : 0x10u);
    fb_rect(sx[0] * 2, FY + sy[0] * 2, 2, 2, C_WHITE);
}

int main(void)
{
    print("\n[snake] retro_fpga Snake\n");
    reset(1);
    key_flush();
    uint32_t tick = 0;
    for (;;) {
        input();
        if (ticks_ms() - last_step > (attract ? 80u : 110u)) {
            if (attract) attract_ai();
            step();
            last_step = ticks_ms();
        }
        render();
        if ((++tick & 1) == 0) dump_tiny();
        sleep_ms(16);
    }
}
