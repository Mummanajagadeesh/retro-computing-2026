// native_harness.c -- runs freestanding console games on host PC
#include "native_harness.h"

uint8_t g_fb[FB_STD_W * FB_STD_H];
uint8_t _wad_start[65536];
uint8_t _wad_end[4];

static FILE *g_out_fp = NULL;
static int g_frame_count = 0;
static int g_max_frames = 60;
static uint32_t g_ticks = 0;
static uint32_t g_rng = 0x85EBCA6Bu;

void fb_clear(uint8_t c) {
    memset(g_fb, c, sizeof(g_fb));
}

void fb_px(int x, int y, uint8_t c) {
    if ((unsigned)x < FB_W && (unsigned)y < FB_H)
        g_fb[y * FB_W + x] = c;
}

void fb_rect(int x, int y, int w, int h, uint8_t c) {
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > FB_W) w = FB_W - x;
    if (y + h > FB_H) h = FB_H - y;
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++)
            g_fb[(y + j) * FB_W + x + i] = c;
}

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

static const uint8_t *glyph_for(char c) {
    if (c >= '0' && c <= '9') return font_digit[c - '0'];
    if (c >= 'A' && c <= 'Z') return font_alpha[c - 'A'];
    if (c >= 'a' && c <= 'z') return font_alpha[c - 'a'];
    switch (c) {
    case '-': return g_minus;
    case '.': return g_dot;
    case ':': return g_colon;
    case '!': return g_bang;
    case '/': return g_slash;
    default:  return g_space;
    }
}

void fb_text(int x, int y, const char *s, uint8_t c) {
    for (; *s; s++, x += 4) {
        const uint8_t *g = glyph_for(*s);
        for (int r = 0; r < 5; r++)
            for (int col = 0; col < 3; col++)
                if (g[r] & (1 << (2 - col))) fb_px(x + col, y + r, c);
    }
}

void fb_num(int x, int y, uint32_t v, int digits, uint8_t c) {
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

uint32_t ticks_ms(void) { g_ticks += 4; return g_ticks; }
void sleep_ms(uint32_t ms) { g_ticks += ms; }
uint32_t frames(void) { return g_frame_count; }

uint32_t rng32(void) {
    g_rng = g_rng * 1664525u + 1013904223u;
    return g_rng;
}

// Automated key inject sequence for interactive games (2048, Tetris, etc.)
static uint8_t g_keys[2048];
static int g_khead = 0, g_ktail = 0;
static int g_frame_since_key = 0;
static int g_key_interval = 4;
static int g_active_key = -1;
static int g_key_held_frames = 0;

void harness_queue_key(uint8_t k) {
    if (g_ktail < 2048) g_keys[g_ktail++] = k;
}

int key_poll(int *pressed, uint8_t *code) {
    if (g_active_key >= 0 && g_key_held_frames >= 2) {
        *pressed = 0;
        *code = (uint8_t)g_active_key;
        g_active_key = -1;
        return 1;
    }
    if (g_active_key < 0 && g_khead < g_ktail && g_frame_since_key >= g_key_interval) {
        *pressed = 1;
        *code = g_keys[g_khead++];
        g_active_key = *code;
        g_key_held_frames = 0;
        g_frame_since_key = 0;
        return 1;
    }
    return 0;
}

void key_flush(void) {
    // Keep queued keys
}

void print(const char *s) {}
void print_hex(uint32_t v) {}
void print_dec(uint32_t v) {}
void sys_exit(uint32_t code) {
    if (g_out_fp) fclose(g_out_fp);
    exit(0);
}

int doom_main(int argc, char **argv) { (void)argc; (void)argv; return 0; }
int cpm_entry(void) { return 0; }

void harness_set_out(const char *path, int max_f) {
    g_out_fp = fopen(path, "wb");
    g_max_frames = max_f;
    g_frame_count = 0;
    g_frame_since_key = g_key_interval; // allow immediate first key
    g_active_key = -1;
    g_key_held_frames = 0;
}

void dump_tiny(void) {
    if (g_out_fp) {
        fwrite(g_fb, 1, FB_W * FB_H, g_out_fp);
        fflush(g_out_fp);
    }
    g_frame_count++;
    g_frame_since_key++;
    if (g_active_key >= 0) g_key_held_frames++;
    g_ticks += 33; // ~30 FPS
    if (g_frame_count >= g_max_frames) {
        if (g_out_fp) fclose(g_out_fp);
        exit(0);
    }
}

void dump_std(void) {
    if (g_out_fp) {
        fwrite(g_fb, 1, FB_STD_W * FB_STD_H, g_out_fp);
        fflush(g_out_fp);
    }
    g_frame_count++;
    g_frame_since_key++;
    if (g_active_key >= 0) g_key_held_frames++;
    g_ticks += 33;
    if (g_frame_count >= g_max_frames) {
        if (g_out_fp) fclose(g_out_fp);
        exit(0);
    }
}

__attribute__((constructor)) static void auto_init(void) {
    const char *out_name = getenv("FRAME_OUT");
    if (!out_name) out_name = "frames_out.bin";
    const char *cnt_str = getenv("FRAME_MAX");
    int max_f = cnt_str ? atoi(cnt_str) : 60;
    harness_set_out(out_name, max_f);

    const char *kint_str = getenv("KEY_INTERVAL");
    if (kint_str) g_key_interval = atoi(kint_str);

    // Load ROM if ROM_FILE is specified
    const char *rfile = getenv("ROM_FILE");
    if (rfile) {
        FILE *rf = fopen(rfile, "rb");
        if (rf) {
            fread(_wad_start, 1, sizeof(_wad_start), rf);
            fclose(rf);
        }
    }

    // Queue keys from KEY_STRING if provided
    const char *kstr = getenv("KEY_STRING");
    if (kstr) {
        for (size_t i = 0; kstr[i]; i++) {
            harness_queue_key((uint8_t)kstr[i]);
        }
    }

    // Preset modes
    const char *kmode = getenv("KEY_MODE");
    if (kmode && strcmp(kmode, "2048") == 0) {
        g_key_interval = 3;
        // Slide patterns that merge tiles in 2048
        const char *moves = "asdsawsasdsasdsawsasdsasdsawasdsasdsawsasdsasdsaws";
        for (size_t i = 0; moves[i]; i++) harness_queue_key((uint8_t)moves[i]);
    } else if (kmode && strcmp(kmode, "tetris") == 0) {
        g_key_interval = 2;
        // Tetris moves: space to start, then rotate, move, hard drop
        const char *tmoves = " aa d ww ax dd w a dx   aa d ww ax dd ";
        for (size_t i = 0; tmoves[i]; i++) harness_queue_key((uint8_t)tmoves[i]);
    }
}


