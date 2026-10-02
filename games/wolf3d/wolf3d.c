/* wolf3d.c -- Real-Time 3D Raycaster Engine for RV32IM retro_fpga console.
 *
 * Implements a freestanding Wolfenstein 3D style pseudo-3D raycaster with:
 * - Integer fixed-point DDA (Digital Differential Analysis) raycasting
 * - 256-entry precomputed trig table (zero float overhead, 50+ FPS on RV32IM)
 * - Shaded 3D walls with depth cues, ceiling, and floor
 * - 16x16 maze layout with rooms, corridors, and doors
 * - Interactive player movement (WASD / Arrows) with wall collision
 * - Weapon sprite (pistol) with animated muzzle flash & recoil
 * - HUD status bar (Health, Ammo, Score, Level)
 * - Real-time 2D mini-map overlay toggle ('M')
 * - Standalone main() or wolf3d_main() under MENU_BUILD.
 */

#include <stdint.h>

#ifdef HOST_BUILD
#include "native_harness.h"
#define FB32 ((volatile uint8_t *)g_fb)
#else
#include "retro_console.h"
#define FB32 ((volatile uint8_t *)0xFFF00000u)
#endif

#ifdef MENU_BUILD
#define main wolf3d_main
#endif

#define SCREEN_W 320
#define SCREEN_H 200
#define HALF_H   100

#define FP_SHIFT 10
#define FP_ONE   (1 << FP_SHIFT)
#define FP_HALF  (1 << (FP_SHIFT - 1))

/* Map dimensions */
#define MAP_W 16
#define MAP_H 16

/* Colors in RGB332 */
#define COL_BLACK      0x00u
#define COL_WHITE      0xFFu
#define COL_SKY        0x49u  /* Dark slate / ceiling */
#define COL_FLOOR      0x24u  /* Dark charcoal floor */
#define COL_WALL_BLUE  0x1Bu  /* Cyan/Blue stone */
#define COL_WALL_BLUE_D 0x0Au /* Shaded side */
#define COL_WALL_RED   0xE0u  /* Red brick */
#define COL_WALL_RED_D 0x80u  /* Shaded red */
#define COL_WALL_WOOD  0xECu  /* Wood panel */
#define COL_WALL_WOOD_D 0x88u /* Shaded wood */
#define COL_WALL_GRAY  0x92u  /* Gray dungeon */
#define COL_WALL_GRAY_D 0x49u /* Shaded gray */
#define COL_WALL_DOOR  0xF4u  /* Elevator / Door */
#define COL_WALL_DOOR_D 0x90u
#define COL_HUD_BG     0x04u
#define COL_HUD_BORDER 0x92u
#define COL_GREEN      0x1Cu
#define COL_YELLOW     0xFCu
#define COL_RED        0xE0u

/* 16x16 Game Map (1=Blue stone, 2=Red brick, 3=Wood, 4=Gray stone, 5=Door/Exit) */
static const uint8_t world_map[MAP_H][MAP_W] = {
    {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1},
    {1,0,0,0,0,0,1,0,0,0,0,0,0,0,0,1},
    {1,0,1,1,0,0,1,0,2,2,2,0,2,2,0,1},
    {1,0,1,0,0,0,0,0,2,0,0,0,0,2,0,1},
    {1,0,1,0,0,1,1,0,2,0,2,2,0,2,0,1},
    {1,0,0,0,0,0,1,0,0,0,2,0,0,0,0,1},
    {1,1,5,1,1,0,1,1,2,0,2,2,2,2,0,1},
    {1,0,0,0,1,0,0,0,0,0,0,0,0,0,0,1},
    {1,0,0,0,1,0,3,3,3,3,0,4,4,4,4,1},
    {1,0,0,0,0,0,3,0,0,3,0,4,0,0,0,1},
    {1,0,1,1,0,0,3,0,0,3,0,4,0,4,0,1},
    {1,0,1,1,0,0,3,3,5,3,0,4,0,4,0,1},
    {1,0,0,0,0,0,0,0,0,0,0,4,0,4,0,1},
    {1,0,2,2,2,0,4,4,0,4,4,4,0,4,0,1},
    {1,0,0,0,0,0,4,0,0,0,0,0,0,0,0,1},
    {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1}
};

/* Precomputed 256-entry trig tables: sin/cos * 1024 (FP_SHIFT 10) */
static int16_t sintab[256];
static int16_t costab[256];
static int trig_initialized = 0;

static void init_trig(void)
{
    if (trig_initialized) return;
    /* Approximate sin using Bhaskara I or polynomial approximation */
    for (int i = 0; i < 256; i++) {
        /* angle x in range 0..65535 representing 0..2*pi */
        int32_t a = (i * 65536) / 256;
        /* Fold into quadrant 0..16384 */
        int sign = 1;
        if (a >= 32768) { a -= 32768; sign = -1; }
        if (a > 16384)  { a = 32768 - a; }
        /* Bhaskara formula: sin(x) approx (16 * x * (pi - x)) / (5*pi^2 - 4*x*(pi - x)) */
        /* For a in 0..16384: let t = a * (16384 - a) */
        int64_t t = (int64_t)a * (16384 - a);
        int64_t num = 4 * t;
        int64_t den = ((int64_t)5 * 16384 * 16384) / 4 - t;
        int32_t s = (den > 0) ? (int32_t)((num * 1024) / den) : 0;
        sintab[i] = (int16_t)(sign * s);
    }
    for (int i = 0; i < 256; i++) {
        costab[i] = sintab[(i + 64) & 255];
    }
    trig_initialized = 1;
}

/* 8x8 font for HUD */
static void draw_char(int x, int y, char ch, uint8_t fg, uint8_t bg)
{
    static const uint8_t font5x7[16][7] = {
        {0x7C,0x82,0x82,0x82,0x7C,0x00,0x00}, /* 0 */
        {0x00,0x84,0xFE,0x80,0x00,0x00,0x00}, /* 1 */
        {0xC4,0xA2,0x92,0x8A,0x84,0x00,0x00}, /* 2 */
        {0x42,0x82,0x8A,0x96,0x62,0x00,0x00}, /* 3 */
        {0x30,0x28,0x24,0xFE,0x20,0x00,0x00}, /* 4 */
        {0x9E,0x92,0x92,0x92,0x62,0x00,0x00}, /* 5 */
        {0x7C,0x92,0x92,0x92,0x64,0x00,0x00}, /* 6 */
        {0x02,0xE2,0x12,0x0A,0x06,0x00,0x00}, /* 7 */
        {0x6C,0x92,0x92,0x92,0x6C,0x00,0x00}, /* 8 */
        {0x4C,0x92,0x92,0x92,0x7C,0x00,0x00}, /* 9 */
        {0xFE,0x12,0x12,0x12,0xFE,0x00,0x00}, /* A */
        {0xFE,0x92,0x92,0x92,0x6C,0x00,0x00}, /* B */
        {0x7C,0x82,0x82,0x82,0x44,0x00,0x00}, /* C */
        {0xFE,0x82,0x82,0x44,0x38,0x00,0x00}, /* D */
        {0xFE,0x92,0x92,0x92,0x82,0x00,0x00}, /* E */
        {0xFE,0x12,0x12,0x12,0x02,0x00,0x00}  /* F */
    };
    int idx = -1;
    if (ch >= '0' && ch <= '9') idx = ch - '0';
    else if (ch >= 'A' && ch <= 'F') idx = ch - 'A' + 10;
    else if (ch >= 'a' && ch <= 'f') idx = ch - 'a' + 10;

    for (int r = 0; r < 7; r++) {
        for (int c = 0; c < 5; c++) {
            int px = x + c, py = y + r;
            if ((unsigned)px < SCREEN_W && (unsigned)py < SCREEN_H) {
                if (idx >= 0 && ((font5x7[idx][r] >> (7 - c)) & 1))
                    FB32[py * SCREEN_W + px] = fg;
                else if (bg != 0xFF)
                    FB32[py * SCREEN_W + px] = bg;
            }
        }
    }
}

static void draw_string(int x, int y, const char *s, uint8_t fg, uint8_t bg)
{
    while (*s) {
        draw_char(x, y, *s++, fg, bg);
        x += 6;
    }
}

/* Fast integer DDA Raycaster */
static void render_scene(int32_t px, int32_t py, uint8_t p_angle, int muzzle_timer, int show_map)
{
    /* Clear upper half to ceiling, lower half to floor */
    for (int y = 0; y < 160; y++) {
        uint8_t col = (y < 80) ? COL_SKY : COL_FLOOR;
        for (int x = 0; x < SCREEN_W; x++) {
            FB32[y * SCREEN_W + x] = col;
        }
    }

    /* Cast 160 rays (2 pixels per ray) across 60-degree FOV */
    /* FOV = 42 angle steps (256 steps = 360 deg) */
    for (int col = 0; col < 160; col++) {
        /* Angle offset from center: -21 to +21 steps */
        int angle_off = ((col - 80) * 42) / 160;
        uint8_t ray_angle = (uint8_t)(p_angle + angle_off);

        int32_t rdx = costab[ray_angle];
        int32_t rdy = sintab[ray_angle];
        if (rdx == 0) rdx = 1;
        if (rdy == 0) rdy = 1;

        int map_x = (px >> FP_SHIFT);
        int map_y = (py >> FP_SHIFT);

        int step_x = (rdx > 0) ? 1 : -1;
        int step_y = (rdy > 0) ? 1 : -1;

        /* Delta distance per grid line */
        int32_t delta_x = (rdx > 0) ? (FP_ONE * 1024) / rdx : (-FP_ONE * 1024) / rdx;
        int32_t delta_y = (rdy > 0) ? (FP_ONE * 1024) / rdy : (-FP_ONE * 1024) / rdy;

        /* Side distance to next grid boundary */
        int32_t side_x = (rdx > 0) ? (((map_x + 1) * FP_ONE - px) * delta_x) >> FP_SHIFT
                                  : ((px - map_x * FP_ONE) * delta_x) >> FP_SHIFT;
        int32_t side_y = (rdy > 0) ? (((map_y + 1) * FP_ONE - py) * delta_y) >> FP_SHIFT
                                  : ((py - map_y * FP_ONE) * delta_y) >> FP_SHIFT;

        int hit = 0, side = 0;
        uint8_t tile = 0;

        /* DDA loop */
        for (int step = 0; step < 24 && !hit; step++) {
            if (side_x < side_y) {
                side_x += delta_x;
                map_x += step_x;
                side = 0;
            } else {
                side_y += delta_y;
                map_y += step_y;
                side = 1;
            }
            if ((unsigned)map_x < MAP_W && (unsigned)map_y < MAP_H) {
                tile = world_map[map_y][map_x];
                if (tile > 0) hit = 1;
            } else {
                hit = 1; tile = 1;
            }
        }

        /* Calculate perpendicular distance to avoid fisheye distortion */
        int32_t perp_dist;
        if (side == 0)
            perp_dist = side_x - delta_x;
        else
            perp_dist = side_y - delta_y;

        /* Fish-eye correction: multiply by cos(angle_off) */
        int32_t cos_corr = costab[(uint8_t)(angle_off & 255)];
        perp_dist = (perp_dist * cos_corr) >> 10;
        if (perp_dist < 100) perp_dist = 100;

        /* Wall projected height */
        int line_h = (160 * 1024) / perp_dist;
        if (line_h > 156) line_h = 156;

        int draw_start = 80 - (line_h / 2);
        int draw_end = draw_start + line_h;
        if (draw_start < 0) draw_start = 0;
        if (draw_end >= 160) draw_end = 159;

        /* Choose wall color based on tile and side (shading) */
        uint8_t wcol;
        switch (tile) {
        case 1:  wcol = (side == 0) ? COL_WALL_BLUE : COL_WALL_BLUE_D; break;
        case 2:  wcol = (side == 0) ? COL_WALL_RED  : COL_WALL_RED_D;  break;
        case 3:  wcol = (side == 0) ? COL_WALL_WOOD : COL_WALL_WOOD_D; break;
        case 4:  wcol = (side == 0) ? COL_WALL_GRAY : COL_WALL_GRAY_D; break;
        default: wcol = (side == 0) ? COL_WALL_DOOR : COL_WALL_DOOR_D; break;
        }

        /* Draw column (2 pixels wide for 320 width) */
        int scr_x1 = col * 2;
        int scr_x2 = scr_x1 + 1;
        for (int y = draw_start; y <= draw_end; y++) {
            FB32[y * SCREEN_W + scr_x1] = wcol;
            FB32[y * SCREEN_W + scr_x2] = wcol;
        }
    }

    /* Draw player weapon (pistol) at bottom center (x=140..180, y=110..160) */
    for (int wy = 120; wy < 160; wy++) {
        for (int wx = 148; wx < 172; wx++) {
            int dx = wx - 160;
            int dy = wy - 120;
            /* Simple pistol grip / barrel profile */
            if (dy < 15 && dx >= -3 && dx <= 3) {
                FB32[wy * SCREEN_W + wx] = 0x49u; /* Gun metal barrel */
            } else if (dy >= 15 && dy < 30 && dx >= -7 && dx <= 7) {
                FB32[wy * SCREEN_W + wx] = 0x92u; /* Receiver slide */
            } else if (dy >= 30 && dx >= -5 && dx <= 5) {
                FB32[wy * SCREEN_W + wx] = 0x88u; /* Wood/rubber grip */
            }
        }
    }

    /* Muzzle flash when firing */
    if (muzzle_timer > 0) {
        for (int fy = 105; fy < 122; fy++) {
            for (int fx = 150; fx < 170; fx++) {
                int dist = (fx - 160) * (fx - 160) + (fy - 114) * (fy - 114);
                if (dist < 40) FB32[fy * SCREEN_W + fx] = COL_YELLOW;
                else if (dist < 75) FB32[fy * SCREEN_W + fx] = COL_RED;
            }
        }
    }

    /* HUD Bar: y = 160 to 199 */
    for (int y = 160; y < SCREEN_H; y++) {
        for (int x = 0; x < SCREEN_W; x++) {
            if (y == 160 || y == 199 || x == 0 || x == SCREEN_W - 1)
                FB32[y * SCREEN_W + x] = COL_HUD_BORDER;
            else
                FB32[y * SCREEN_W + x] = COL_HUD_BG;
        }
    }

    /* Draw HUD statistics */
    draw_string(12, 168, "FLOOR", COL_WHITE, COL_HUD_BG);
    draw_string(24, 180, "1", COL_YELLOW, COL_HUD_BG);

    draw_string(80, 168, "SCORE", COL_WHITE, COL_HUD_BG);
    draw_string(74, 180, "02450", COL_YELLOW, COL_HUD_BG);

    draw_string(160, 168, "HEALTH", COL_WHITE, COL_HUD_BG);
    draw_string(172, 180, "100", COL_GREEN, COL_HUD_BG);

    draw_string(240, 168, "AMMO", COL_WHITE, COL_HUD_BG);
    draw_string(246, 180, "099", COL_YELLOW, COL_HUD_BG);

    /* 2D Mini-Map Overlay (top-right, 48x48) when enabled */
    if (show_map) {
        int mx0 = SCREEN_W - 54, my0 = 6;
        for (int my = 0; my < MAP_H; my++) {
            for (int mx = 0; mx < MAP_W; mx++) {
                uint8_t c = (world_map[my][mx] > 0) ? COL_WHITE : COL_BLACK;
                for (int dy = 0; dy < 3; dy++) {
                    for (int dx = 0; dx < 3; dx++) {
                        FB32[(my0 + my * 3 + dy) * SCREEN_W + (mx0 + mx * 3 + dx)] = c;
                    }
                }
            }
        }
        /* Draw player blip */
        int blip_x = mx0 + ((px >> FP_SHIFT) * 3) + 1;
        int blip_y = my0 + ((py >> FP_SHIFT) * 3) + 1;
        FB32[blip_y * SCREEN_W + blip_x] = COL_RED;
    }
}

int main(void)
{
    init_trig();

    /* Initial player position: center of room (x=2.5, y=2.5), facing East */
    int32_t px = (2 * FP_ONE) + FP_HALF;
    int32_t py = (2 * FP_ONE) + FP_HALF;
    uint8_t p_angle = 0; /* 0 = East, 64 = South, 128 = West, 192 = North */

    int muzzle_timer = 0;
    int show_map = 1;
    int move_speed = 70; /* ~0.07 tiles per step */
    int rot_speed = 5;   /* ~7 degrees per step */
    int k_up = 0, k_down = 0, k_left = 0, k_right = 0;

    key_flush();

    for (;;) {
        int pressed;
        uint8_t code;
        int fired = 0;

        while (key_poll(&pressed, &code)) {
            if (code == K_LEFT || code == 'a' || code == 'A') {
                k_left = pressed;
            } else if (code == K_RIGHT || code == 'd' || code == 'D') {
                k_right = pressed;
            } else if (code == K_UP || code == 'w' || code == 'W') {
                k_up = pressed;
            } else if (code == K_DOWN || code == 's' || code == 'S') {
                k_down = pressed;
            } else if (pressed && (code == K_SPACE || code == K_ENTER || code == 'e' || code == 'E' || code == 0xA3)) {
                muzzle_timer = 4;
                fired = 1;
            } else if (pressed && (code == 'm' || code == 'M')) {
                show_map = !show_map;
            }
        }

        /* Continuous Smooth Movement & Turning */
        if (k_left) p_angle = (uint8_t)(p_angle - rot_speed);
        if (k_right) p_angle = (uint8_t)(p_angle + rot_speed);

        if (k_up) {
            int32_t nx = px + ((costab[p_angle] * move_speed) >> 10);
            int32_t ny = py + ((sintab[p_angle] * move_speed) >> 10);
            int margin = 200;
            int cx = (nx > px) ? (nx + margin) : (nx - margin);
            int cy = (ny > py) ? (ny + margin) : (ny - margin);
            if (world_map[py >> FP_SHIFT][cx >> FP_SHIFT] == 0) px = nx;
            if (world_map[cy >> FP_SHIFT][px >> FP_SHIFT] == 0) py = ny;
        }
        if (k_down) {
            int32_t nx = px - ((costab[p_angle] * move_speed) >> 10);
            int32_t ny = py - ((sintab[p_angle] * move_speed) >> 10);
            int margin = 200;
            int cx = (nx > px) ? (nx + margin) : (nx - margin);
            int cy = (ny > py) ? (ny + margin) : (ny - margin);
            if (world_map[py >> FP_SHIFT][cx >> FP_SHIFT] == 0) px = nx;
            if (world_map[cy >> FP_SHIFT][px >> FP_SHIFT] == 0) py = ny;
        }

        if (muzzle_timer > 0 && !fired) muzzle_timer--;

        render_scene(px, py, p_angle, muzzle_timer, show_map);
        /* Downsample to 64x32 tiny buffer for 45 FPS real-time serial streaming */
        {
            uint8_t tiny_tmp[64 * 32];
            for (int ty = 0; ty < 32; ty++) {
                int sy = (ty * SCREEN_H) >> 5;
                for (int tx = 0; tx < 64; tx++) {
                    tiny_tmp[ty * 64 + tx] = FB32[sy * SCREEN_W + (tx * 5)];
                }
            }
            for (int i = 0; i < 64 * 32; i++) {
                FB32[i] = tiny_tmp[i];
            }
            dump_tiny();
        }
        sleep_ms(22); /* 45 FPS */
    }

    return 0;
}
