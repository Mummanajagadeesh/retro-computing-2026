/* console.c -- shared game support: MMIO, framebuffer, keys, time, text.
 * Freestanding: no libc. Provides the memset/memcpy gcc may emit. */
#include "console.h"

#define MMIO      0xFFFFF000u
#define MM_EXIT   (*(volatile uint32_t *)(MMIO + 0x000))
#define MM_CYC    (*(volatile uint32_t *)(MMIO + 0x004))
#define MM_KEY    (*(volatile uint32_t *)(MMIO + 0x014))
#define MM_FRAMES (*(volatile uint32_t *)(MMIO + 0x018))
#define MM_UART   (*(volatile uint32_t *)(MMIO + 0x024))
#define MM_DUMP   (*(volatile uint32_t *)(MMIO + 0x028))
#define MM_WALL_LO (*(volatile uint32_t *)(MMIO + 0x02C))

/* freestanding essentials (signatures match gcc's builtins on rv32) */
void *memset(void *d, int c, __SIZE_TYPE__ n)
{
    unsigned char *p = (unsigned char *)d;
    while (n--) *p++ = (unsigned char)c;
    return d;
}
void *memcpy(void *d, const void *s, __SIZE_TYPE__ n)
{
    unsigned char *p = (unsigned char *)d;
    const unsigned char *q = (const unsigned char *)s;
    while (n--) *p++ = *q++;
    return d;
}
void *memmove(void *d, const void *s, __SIZE_TYPE__ n)
{
    unsigned char *p = (unsigned char *)d;
    const unsigned char *q = (const unsigned char *)s;
    if (p < q) { while (n--) *p++ = *q++; }
    else if (p > q) { p += n; q += n; while (n--) *--p = *--q; }
    return d;
}

/* ---------------------------------------------------------- framebuffer */
void fb_clear(uint8_t c)
{
    volatile uint8_t *f = FB;
    for (int i = 0; i < FB_W * FB_H; i++) f[i] = c;
}

void fb_px(int x, int y, uint8_t c)
{
    if ((unsigned)x < FB_W && (unsigned)y < FB_H) FB[y * FB_W + x] = c;
}

void fb_rect(int x, int y, int w, int h, uint8_t c)
{
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > FB_W) w = FB_W - x;
    if (y + h > FB_H) h = FB_H - y;
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++)
            FB[(y + j) * FB_W + x + i] = c;
}

/* 3x5 micro font, rows MSB-left in the low 3 bits */
static const uint8_t font_digit[10][5] = {
    {7,5,5,5,7}, {2,6,2,2,7}, {7,1,7,4,7}, {7,1,7,1,7}, {5,5,7,1,1},
    {7,4,7,1,7}, {7,4,7,5,7}, {7,1,1,2,2}, {7,5,7,5,7}, {7,5,7,1,7},
};
static const uint8_t font_alpha[26][5] = {
    {2,5,7,5,5}, {6,5,6,5,6}, {3,4,4,4,3}, {6,5,5,5,6}, {7,4,6,4,7},
    {7,4,6,4,4}, {3,4,5,5,3}, {5,5,7,5,5}, {7,2,2,2,7}, {1,1,1,5,2},
    {5,5,6,5,5}, {4,4,4,4,7}, {5,7,7,5,5}, {6,5,5,5,5}, {2,5,5,5,2},
    {6,5,6,4,4}, {2,5,5,6,3}, {6,5,6,5,5}, {3,4,2,1,6}, {7,2,2,2,2},
    {5,5,5,5,7}, {5,5,5,5,2}, {5,5,7,7,5}, {5,5,2,5,5}, {5,5,2,2,2},
    {7,1,2,4,7},
};
static const uint8_t g_space[5] = {0,0,0,0,0};
static const uint8_t g_minus[5] = {0,0,7,0,0};
static const uint8_t g_dot[5]   = {0,0,0,0,2};
static const uint8_t g_colon[5] = {0,2,0,2,0};
static const uint8_t g_bang[5]  = {2,2,2,0,2};
static const uint8_t g_slash[5] = {1,1,2,4,4};

static const uint8_t g_gt[5]   = {4,2,1,2,4};
static const uint8_t g_lt[5]   = {1,2,4,2,1};
static const uint8_t g_star[5] = {5,2,7,2,5};
static const uint8_t g_lbrk[5] = {6,4,4,4,6};
static const uint8_t g_rbrk[5] = {3,1,1,1,3};

static const uint8_t *glyph_for(char c)
{
    if (c >= '0' && c <= '9') return font_digit[c - '0'];
    if (c >= 'A' && c <= 'Z') return font_alpha[c - 'A'];
    if (c >= 'a' && c <= 'z') return font_alpha[c - 'a'];
    switch (c) {
    case '-': return g_minus;
    case '.': return g_dot;
    case ':': return g_colon;
    case '!': return g_bang;
    case '/': return g_slash;
    case '>': return g_gt;
    case '<': return g_lt;
    case '*': return g_star;
    case '[': return g_lbrk;
    case ']': return g_rbrk;
    default:  return g_space;
    }
}

void fb_text(int x, int y, const char *s, uint8_t c)
{
    for (; *s; s++, x += 4) {
        const uint8_t *g = glyph_for(*s);
        for (int r = 0; r < 5; r++)
            for (int col = 0; col < 3; col++)
                if (g[r] & (1 << (2 - col))) fb_px(x + col, y + r, c);
    }
}

/* fixed-width decimal, leading spaces, exactly `digits` chars */
void fb_num(int x, int y, uint32_t v, int digits, uint8_t c)
{
    char buf[12];
    if (digits > 10) digits = 10;
    for (int i = digits - 1; i >= 0; i--) { buf[i] = (char)('0' + v % 10); v /= 10; }
    buf[digits] = 0;
    for (int i = 0; i < digits - 1; i++) {
        if (buf[i] == '0') buf[i] = ' ';
        else break;
    }
    fb_text(x, y, buf, c);
}

/* ---------------------------------------------------------------- keys */
int g_in_game = 0;
jmp_buf menu_jmp_buf;

static void prompt_exit_modal(void)
{
    uint8_t fb_save[64 * 32];
    volatile uint8_t *fb = FB;

    /* 1. Backup current frame buffer */
    for (int i = 0; i < 64 * 32; i++)
        fb_save[i] = fb[i];

    /* 2. Draw retro confirmation dialog box */
    fb_rect(3, 7, 58, 18, C_BLUE);
    fb_rect(4, 8, 56, 16, C_BLACK);
    fb_text(6, 10, "EXIT TO MENU?", C_YELLOW);
    fb_text(8, 18, "[Y]YES", C_GREEN);
    fb_text(36, 18, "[N]NO", C_RED);
    dump_tiny();

    /* 3. Modal confirmation loop */
    key_flush();
    for (;;) {
        int pressed;
        uint8_t code;
        while (key_poll_raw(&pressed, &code)) {
            if (!pressed) continue;
            if (code == 'y' || code == 'Y' || code == K_ENTER || code == 10 || code == K_SPACE || code == 32) {
                /* User confirmed exit: force jump back to menu */
                key_flush();
                g_in_game = 0;
                longjmp(menu_jmp_buf, 1);
            }
            if (code == 'n' || code == 'N' || code == K_ESC || code == 27) {
                /* User cancelled exit: restore game screen and resume */
                for (int i = 0; i < 64 * 32; i++)
                    fb[i] = fb_save[i];
                dump_tiny();
                key_flush();
                return;
            }
        }
        sleep_ms(10);
    }
}

int key_poll_raw(int *pressed, uint8_t *code)
{
    uint32_t k = MM_KEY;
    if (!(k & 0x80000000u)) return 0;
    *pressed = (k & 0x40000000u) ? 0 : 1;
    *code = (uint8_t)(k & 0xFFu);
    MM_KEY = 0u;
    return 1;
}

int key_poll(int *pressed, uint8_t *code)
{
    int has_key = key_poll_raw(pressed, code);
    if (!has_key) return 0;

    /* If player is currently inside a game and presses ESC, show confirmation modal */
    if (g_in_game && *pressed && *code == K_ESC) {
        prompt_exit_modal();
        return 0; /* ESC was consumed by the confirmation modal */
    }

    return 1;
}

void key_flush(void)
{
    int p;
    uint8_t c;
    while (key_poll_raw(&p, &c)) {}
}

/* ---------------------------------------------------------------- time */
uint32_t ticks_ms(void)
{
    return MM_WALL_LO / 50000u;   /* 50 MHz wall clock */
}

void sleep_ms(uint32_t ms)
{
    uint32_t t = ticks_ms();
    while ((ticks_ms() - t) < ms) {}
}

/* --------------------------------------------------------------- misc */
void dump_tiny(void) { MM_DUMP = 2u; }
void dump_std(void)  { MM_DUMP = 1u; }
uint32_t frames(void) { return MM_FRAMES; }

static uint32_t rng_state = 0;
uint32_t rng32(void)
{
    if (!rng_state) {
        rng_state = MM_CYC ^ 0x9E3779B9u;
        if (!rng_state) rng_state = 0x85EBCA6Bu;
    }
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}

void con_putc(char c)
{
    if (c == '\n') MM_UART = (uint32_t)'\r';
    MM_UART = (uint32_t)(uint8_t)c;
}

void print(const char *s)
{
    for (; *s; ++s) {
        if (*s == '\n') MM_UART = (uint32_t)'\r';
        MM_UART = (uint32_t)(uint8_t)*s;
    }
}

void print_hex(uint32_t v)
{
    static const char d[] = "0123456789abcdef";
    for (int i = 28; i >= 0; i -= 4) {
        char ch = d[(v >> (unsigned)i) & 0xF];
        if (ch == '\n') MM_UART = (uint32_t)'\r';
        MM_UART = (uint32_t)(uint8_t)ch;
    }
}

void print_dec(uint32_t v)
{
    char b[12];
    int n = 0;
    if (!v) b[n++] = '0';
    while (v) { b[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) {
        char ch = b[--n];
        if (ch == '\n') MM_UART = (uint32_t)'\r';
        MM_UART = (uint32_t)(uint8_t)ch;
    }
}

void sys_exit(uint32_t code)
{
    MM_EXIT = code;
    for (;;) {}
}
