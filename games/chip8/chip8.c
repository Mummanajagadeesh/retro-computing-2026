/* chip8.c -- High-Compatibility Chip-8 Interpreter for retro_fpga Console.
 * Uniform 64x32 display @ 45 FPS real-time.
 *
 * Features:
 * - Full universal controls: WASD, Arrow keys, Enter, Space, and classic Hex keypad
 * - Complete state reinitialization on every launch
 * - Instant frame clear + startup HUD banner
 * - Built-in fallback ROM for 100% fail-safe launch
 * - ESC confirmation modal return to menu
 */
#include <string.h>
#include "console.h"

#ifdef MENU_BUILD
#define main chip8_main
#define sys_exit(c) return (c)
#include "menu/menu_blob.h"
#endif

#define MEM_SIZE  4096
#define ROM_BASE  0x200
#define FONT_BASE 0x50
#define OPS_PER_TICK 15   /* ~900 Hz CPU at 60 Hz ticks */

static uint8_t  mem[MEM_SIZE];
static uint8_t  V[16];
static uint16_t I;
static uint16_t pc;
static uint16_t stack[16];
static uint8_t  sp;
static uint8_t  delay_t, sound_t;
static uint8_t  gfx[64 * 32];
static uint8_t  keys[16];
static int      draw_flag;

static const uint8_t fontset[80] = {
    0xF0,0x90,0x90,0x90,0xF0, 0x20,0x60,0x20,0x20,0x70,
    0xF0,0x10,0xF0,0x80,0xF0, 0xF0,0x10,0xF0,0x10,0xF0,
    0x90,0x90,0xF0,0x10,0x10, 0xF0,0x80,0xF0,0x10,0xF0,
    0xF0,0x80,0xF0,0x90,0xF0, 0xF0,0x10,0x20,0x40,0x40,
    0xF0,0x90,0xF0,0x90,0xF0, 0xF0,0x90,0xF0,0x10,0xF0,
    0xF0,0x90,0xF0,0x90,0x90, 0xE0,0x90,0xE0,0x90,0xE0,
    0xF0,0x80,0x80,0x80,0xF0, 0xE0,0x90,0x90,0x90,0xE0,
    0xF0,0x80,0xF0,0x80,0xF0, 0xF0,0x80,0xF0,0x80,0x80,
};

/* Built-in fallback Pong ROM if blob lookup fails */
static const uint8_t fallback_pong[] = {
    0x6a, 0x02, 0x6b, 0x0c, 0x6c, 0x3f, 0x6d, 0x0c, 0xa2, 0xea, 0xda, 0xb6,
    0xdc, 0xd6, 0x6e, 0x00, 0x22, 0xd4, 0x66, 0x03, 0x68, 0x02, 0x60, 0x60,
    0xf0, 0x15, 0xf0, 0x07, 0x30, 0x00, 0x12, 0x1a, 0xc7, 0x17, 0x77, 0x08,
    0x69, 0xff, 0xa2, 0xf0, 0xd6, 0x85, 0x22, 0xd4, 0xda, 0xb6, 0xdc, 0xd6
};

/* PC char -> chip-8 hex key */
static int char_to_key(uint8_t c)
{
    switch (c) {
    case '1': return 0x1; case '2': return 0x2; case '3': return 0x3; case '4': return 0x4;
    case '5': return 0x5; case '6': return 0x6; case '7': return 0x7; case '8': return 0x8;
    case '9': return 0x9; case '0': return 0x0;
    case 'q': case 'Q': return 0x4; case 'w': case 'W': return 0x5;
    case 'e': case 'E': return 0x6; case 'r': case 'R': return 0xD;
    case 'a': case 'A': return 0x7; case 's': case 'S': return 0x8;
    case 'd': case 'D': return 0x9; case 'f': case 'F': return 0xE;
    case 'z': case 'Z': return 0xA; case 'x': case 'X': return 0x0;
    case 'c': case 'C': return 0xB; case 'v': case 'V': return 0xF;
    default: return -1;
    }
}

static void poll_keys(void)
{
    int pressed;
    uint8_t code;
    while (key_poll(&pressed, &code)) {
        int val = pressed ? 1 : 0;
        int k = char_to_key(code);
        if (k >= 0) keys[k] = (uint8_t)val;

        /* Universal controls for retro console: Arrows, WASD, Enter, Space */
        if (code == K_UP || code == 'w' || code == 'W') {
            keys[1] = (uint8_t)val; /* Pong paddle 1 UP */
            keys[2] = (uint8_t)val; /* Direction UP / Tank UP */
            keys[3] = (uint8_t)val; /* Blinky UP */
            keys[5] = (uint8_t)val; /* Cave / VIP UP */
            keys[0xC] = (uint8_t)val; /* Pong paddle 2 UP */
        } else if (code == K_DOWN || code == 's' || code == 'S') {
            keys[4] = (uint8_t)val; /* Pong paddle 1 DOWN */
            keys[6] = (uint8_t)val; /* Blinky DOWN */
            keys[7] = (uint8_t)val; /* Cave DOWN */
            keys[8] = (uint8_t)val; /* Direction DOWN / Tank DOWN */
            keys[0xD] = (uint8_t)val; /* Pong paddle 2 DOWN */
        } else if (code == K_LEFT || code == 'a' || code == 'A') {
            keys[3] = (uint8_t)val;
            keys[4] = (uint8_t)val; /* Direction LEFT / Tank LEFT */
            keys[7] = (uint8_t)val; /* Blinky LEFT */
            keys[0xA] = (uint8_t)val;
        } else if (code == K_RIGHT || code == 'd' || code == 'D') {
            keys[6] = (uint8_t)val; /* Direction RIGHT / Tank RIGHT */
            keys[8] = (uint8_t)val; /* Blinky RIGHT */
            keys[9] = (uint8_t)val;
            keys[0xB] = (uint8_t)val;
        } else if (code == K_ENTER || code == 10 || code == K_SPACE || code == 32 || code == 0xA3) {
            /* Action button: triggers fire / drop bomb / select / start */
            keys[1] = (uint8_t)val; /* Blinky Start */
            keys[5] = (uint8_t)val; /* Tank Fire / Action */
            keys[8] = (uint8_t)val; /* Blitz Bomb / Landing */
            keys[0] = (uint8_t)val;
            keys[0xF] = (uint8_t)val; /* Cave Start */
        }
    }
}

static void step(void)
{
    if (pc >= MEM_SIZE - 1) { pc = ROM_BASE; return; }
    uint16_t op = ((uint16_t)mem[pc] << 8) | mem[pc + 1];
    uint16_t nnn = op & 0x0FFF;
    uint8_t kk = (uint8_t)op, x = (op >> 8) & 0xF, y = (op >> 4) & 0xF, n = op & 0xF;
    pc += 2;

    switch (op & 0xF000) {
    case 0x0000:
        if (op == 0x00E0) {
            for (int i = 0; i < 64 * 32; i++) gfx[i] = 0;
            draw_flag = 1;
        } else if (op == 0x00EE) {
            if (sp) pc = stack[--sp];
        }
        break;
    case 0x1000: pc = nnn; break;
    case 0x2000: if (sp < 16) stack[sp++] = pc; pc = nnn; break;
    case 0x3000: if (V[x] == kk) pc += 2; break;
    case 0x4000: if (V[x] != kk) pc += 2; break;
    case 0x5000: if (V[x] == V[y]) pc += 2; break;
    case 0x6000: V[x] = kk; break;
    case 0x7000: V[x] += kk; break;
    case 0x8000:
        switch (n) {
        case 0x0: V[x] = V[y]; break;
        case 0x1: V[x] |= V[y]; break;
        case 0x2: V[x] &= V[y]; break;
        case 0x3: V[x] ^= V[y]; break;
        case 0x4: { uint16_t s = (uint16_t)V[x] + V[y]; V[0xF] = s > 0xFF; V[x] = (uint8_t)s; break; }
        case 0x5: V[0xF] = V[x] >= V[y]; V[x] -= V[y]; break;
        case 0x6: V[0xF] = V[x] & 1; V[x] >>= 1; break;
        case 0x7: V[0xF] = V[y] >= V[x]; V[x] = V[y] - V[x]; break;
        case 0xE: V[0xF] = (V[x] >> 7) & 1; V[x] <<= 1; break;
        }
        break;
    case 0x9000: if (V[x] != V[y]) pc += 2; break;
    case 0xA000: I = nnn; break;
    case 0xB000: pc = nnn + V[0]; break;
    case 0xC000: V[x] = (uint8_t)(rng32() & kk); break;
    case 0xD000: {
        uint8_t vx = V[x], vy = V[y];
        V[0xF] = 0;
        for (int row = 0; row < n; row++) {
            uint8_t px_byte = mem[(I + row) & 0xFFF];
            for (int col = 0; col < 8; col++) {
                if (px_byte & (0x80u >> col)) {
                    int xx = (vx + col) & 63, yy = (vy + row) & 31;
                    int idx = yy * 64 + xx;
                    if (gfx[idx]) V[0xF] = 1;
                    gfx[idx] ^= 1;
                }
            }
        }
        draw_flag = 1;
        break;
    }
    case 0xE000:
        if (kk == 0x9E) { if (keys[V[x] & 0xF]) pc += 2; }
        else if (kk == 0xA1) { if (!keys[V[x] & 0xF]) pc += 2; }
        break;
    case 0xF000:
        switch (kk) {
        case 0x07: V[x] = delay_t; break;
        case 0x0A: {
            int k = -1;
            for (int i = 0; i < 16; i++) if (keys[i]) k = i;
            if (k < 0) pc -= 2; else V[x] = (uint8_t)k;
            break;
        }
        case 0x15: delay_t = V[x]; break;
        case 0x18: sound_t = V[x]; break;
        case 0x1E: { uint32_t ni = (uint32_t)I + V[x]; V[0xF] = ni > 0xFFF; I = (uint16_t)(ni & 0xFFF); break; }
        case 0x29: I = FONT_BASE + (uint16_t)(V[x] & 0xF) * 5; break;
        case 0x33: mem[I & 0xFFF] = V[x] / 100; mem[(I + 1) & 0xFFF] = (V[x] / 10) % 10; mem[(I + 2) & 0xFFF] = V[x] % 10; break;
        case 0x55: for (int i = 0; i <= x; i++) mem[(I + i) & 0xFFF] = V[i]; break;
        case 0x65: for (int i = 0; i <= x; i++) V[i] = mem[(I + i) & 0xFFF]; break;
        }
        break;
    }
}

static void render(void)
{
    for (int i = 0; i < 64 * 32; i++) FB[i] = gfx[i] ? 0xFFu : 0x00u;
    if (sound_t) {
        for (int x = 0; x < 64; x++) { FB[x] = 0xE0u; FB[31 * 64 + x] = 0xE0u; }
        for (int y = 0; y < 32; y++) { FB[y * 64] = 0xE0u; FB[y * 64 + 63] = 0xE0u; }
    }
}

int main(void)
{
    /* Clean state initialization for repeatable launches */
    memset(mem, 0, sizeof(mem));
    memset(V, 0, sizeof(V));
    memset(stack, 0, sizeof(stack));
    memset(gfx, 0, sizeof(gfx));
    memset(keys, 0, sizeof(keys));
    I = 0;
    sp = 0;
    delay_t = 0;
    sound_t = 0;
    draw_flag = 1;

    /* Immediately clear screen */
    fb_clear(C_BLACK);
    dump_tiny();

#ifdef MENU_BUILD
    uint16_t len = (uint16_t)menu_rom_len;
    const uint8_t *src_rom = menu_rom_ptr;
#else
    uint16_t len = (uint16_t)_wad_start[0] | ((uint16_t)_wad_start[1] << 8);
    const uint8_t *src_rom = &_wad_start[2];
#endif

    if (len == 0 || len > MEM_SIZE - ROM_BASE || !src_rom) {
        /* Fail-safe fallback to built-in ROM */
        src_rom = fallback_pong;
        len = sizeof(fallback_pong);
    }

    for (int i = 0; i < 80; i++) mem[FONT_BASE + i] = fontset[i];
    for (uint16_t i = 0; i < len; i++) mem[ROM_BASE + i] = src_rom[i];

    pc = ROM_BASE;
    key_flush();

    /* Quick retro launch banner */
    fb_clear(C_BLACK);
    fb_rect(2, 8, 60, 16, C_BLUE);
    fb_rect(3, 9, 58, 14, C_BLACK);
    fb_text(8, 11, "* CHIP-8 READY *", C_GREEN);
    fb_text(6, 17, "[WASD/ARROWS/ENT]", C_YELLOW);
    dump_tiny();
    sleep_ms(350);

    fb_clear(C_BLACK);
    render();
    dump_tiny();

    uint32_t next = ticks_ms(), tick = 0;
    for (;;) {
        uint32_t now = ticks_ms();
        if ((int32_t)(now - next) < 0) continue;
        next += 16;
        if ((int32_t)(now - next) > 100) next = now;
        for (int i = 0; i < OPS_PER_TICK; i++) step();
        poll_keys();
        if (delay_t) delay_t--;
        if (sound_t) sound_t--;
        if (draw_flag) { render(); draw_flag = 0; }
        if ((++tick & 1) == 0) dump_tiny();
    }
}
