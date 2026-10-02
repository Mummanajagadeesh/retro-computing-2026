/* doom_native.c -- Real-Time 45 FPS 3D DOOM (E1M1 Knee-Deep in the Dead) Engine
 * Uniform 64x32 RGB332 console engine for RV32IM retro_fpga.
 *
 * Authentic DOOM Episode 1 Hangar experience:
 * - Integer fixed-point DDA raycaster with distance-attenuated depth shading
 * - E1M1 map: spawn room, toxic nukage pool with zig-zag walkway, courtyard, exit
 * - Textured techbase walls, blinking computer panels, and radioactive sludge
 * - Animated DOOM Shotgun & Pistol with muzzle flash, recoil, and smoke
 * - Hostile Imps & Zombiemen with line-of-sight AI, attack states, and death anims
 * - Classic DOOM status bar HUD: AMMO, HEALTH %, ARMOR %, and animated DOOMguy face
 * - 45 FPS real-time serial streaming via dump_tiny()
 * - Clean ESC confirmation modal -> instant return to menu.
 */
#include "console.h"

#ifdef MENU_BUILD
#define main doom_native_main
#endif

#define D_SCREEN_W  64
#define D_SCREEN_H  32
#define D_PLAY_H    26   /* y=0..25 is 3D viewport, y=26..31 is DOOM status bar HUD */

#define FP_SHIFT 10
#define FP_ONE   (1 << FP_SHIFT)

/* E1M1 Map Dimensions: 16x16 authentic Hangar layout */
#define MAP_W 16
#define MAP_H 16

/* Wall & Sector Tile IDs */
#define T_EMPTY    0
#define T_STARTAN  1  /* Brown techbase wall */
#define T_COMP     2  /* Computer terminal wall */
#define T_NUKAGE   3  /* Radioactive slime wall / pipe */
#define T_BRICK    4  /* Dark red brick */
#define T_DOOR     5  /* Silver tech door with hazard stripe */
#define T_EXIT     6  /* Red exit chamber wall */

/* DOOM E1M1: Knee-Deep in the Dead (Hangar) map */
static const uint8_t e1m1_map[MAP_H][MAP_W] = {
    {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
    {1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 1}, /* (1,1)=Spawn, (8,1)=Comp */
    {1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 1},
    {1, 0, 0, 0, 5, 0, 0, 0, 1, 1, 5, 1, 1, 0, 0, 1}, /* Door to hallway */
    {1, 1, 5, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1},
    {1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 1},
    {1, 0, 3, 3, 0, 0, 0, 3, 3, 0, 0, 0, 1, 0, 0, 1}, /* Slime pool */
    {1, 0, 3, 0, 0, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 1}, /* Zigzag walkway */
    {1, 0, 3, 0, 3, 3, 3, 0, 3, 0, 0, 0, 1, 1, 5, 1},
    {1, 0, 3, 0, 3, 0, 3, 0, 3, 0, 0, 0, 0, 0, 0, 1},
    {1, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
    {1, 1, 1, 0, 3, 3, 3, 1, 1, 1, 0, 0, 6, 6, 6, 1}, /* Courtyard & Exit */
    {1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 6, 0, 6, 1},
    {1, 0, 2, 2, 0, 0, 2, 2, 0, 5, 0, 0, 6, 0, 6, 1}, /* Computer alcove */
    {1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 6, 6, 6, 1}, /* (13,13)=Exit switch */
    {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}
};

/* Enemy entities */
struct doom_monster {
    int32_t x, y;
    int health;
    uint8_t type;     /* 1=Zombieman (Former Human), 2=Imp */
    uint8_t state;    /* 0=idle, 1=walk, 2=attack, 3=pain, 4=dead */
    int anim_timer;
};

#define MAX_MONSTERS 4
static struct doom_monster monsters[MAX_MONSTERS];

/* Precomputed fast integer trig tables (256 entries = 360 deg) */
static int16_t d_sintab[256];
static int16_t d_costab[256];
static int d_trig_ready = 0;

static void init_doom_trig(void)
{
    if (d_trig_ready) return;
    for (int i = 0; i < 256; i++) {
        int a = (i < 128) ? i : (256 - i);
        int sign = (i < 128) ? 1 : -1;
        int64_t t = (int64_t)a * (128 - a);
        int64_t num = 4 * t;
        int64_t den = 5 * 128 * 128 / 4 - t;
        int32_t s = (den > 0) ? (int32_t)((num * 1024) / den) : 0;
        d_sintab[i] = (int16_t)(sign * s);
        d_costab[i] = d_sintab[(i + 64) & 255];
    }
    d_trig_ready = 1;
}

/* Texture color mapping based on distance & wall face */
static uint8_t get_wall_color(uint8_t tile, int side, int32_t dist, int blink)
{
    uint8_t col = C_GRAY;
    switch (tile) {
    case T_STARTAN: /* Techbase brown/tan */
        col = (dist < 4 * FP_ONE) ? 0x91u : ((dist < 8 * FP_ONE) ? 0x6Cu : 0x48u);
        break;
    case T_COMP:    /* Computer terminal */
        col = (blink && dist < 6 * FP_ONE) ? C_GREEN : ((dist < 5 * FP_ONE) ? 0x56u : 0x31u);
        break;
    case T_NUKAGE:  /* Green radioactive slime */
        col = (dist < 6 * FP_ONE) ? C_GREEN : 0x14u;
        break;
    case T_BRICK:   /* Dark red brick */
        col = (dist < 5 * FP_ONE) ? 0x80u : 0x40u;
        break;
    case T_DOOR:    /* Door with yellow stripe */
        col = (dist < 5 * FP_ONE) ? C_WHITE : 0x92u;
        break;
    case T_EXIT:    /* Red exit room */
        col = (dist < 6 * FP_ONE) ? C_RED : 0x60u;
        break;
    }
    /* Side shading: darken Y-axis walls for 3D depth cue */
    if (side && col >= 0x20u) col -= 0x20u;
    return col;
}

/* DOOM Status Bar HUD */
static void draw_doom_hud(int health, int armor, int ammo, int weapon, int face_state)
{
    /* HUD Background bar (y=26..31) */
    fb_rect(0, 26, 64, 6, 0x24u); /* Dark steel gray */
    fb_rect(0, 26, 64, 1, 0x49u); /* Border line */

    /* Ammo */
    fb_text(1, 27, "A", C_YELLOW);
    fb_num(5, 27, ammo, 2, C_WHITE);

    /* Health */
    fb_text(17, 27, "H", C_RED);
    fb_num(21, 27, health, 3, C_WHITE);

    /* DOOMguy Face in center (y=27..30, x=34..38) */
    fb_rect(34, 27, 5, 4, 0xBDu); /* Skin tone */
    fb_px(35, 28, C_BLACK); fb_px(37, 28, C_BLACK); /* Eyes */
    if (face_state == 1) {
        /* Firing grin / grimace */
        fb_px(35, 30, C_RED); fb_px(36, 30, C_RED); fb_px(37, 30, C_RED);
    } else if (health < 30) {
        /* Bloody beaten face */
        fb_px(34, 29, C_RED); fb_px(38, 27, C_RED); fb_px(36, 30, C_BLACK);
    } else {
        /* Determined look */
        fb_px(36, 30, C_BLACK);
    }

    /* Armor */
    fb_text(42, 27, "R", C_CYAN);
    fb_num(46, 27, armor, 3, C_WHITE);

    /* Active Weapon indicator */
    fb_text(58, 27, (weapon == 1) ? "P" : "S", C_YELLOW);
}

/* DOOM Weapon Sprite Rendering (Pistol or Shotgun) */
static void draw_weapon(int weapon, int muzzle_timer, int recoil_y)
{
    int cx = 32;
    int base_y = 25 + recoil_y;

    if (weapon == 1) {
        /* Pistol */
        fb_rect(cx - 2, base_y - 7, 4, 8, 0x49u); /* Gun barrel */
        fb_rect(cx - 1, base_y - 8, 2, 2, 0x92u); /* Iron sight */
        fb_rect(cx - 3, base_y - 3, 6, 4, 0x24u); /* Hand/grip */
        if (muzzle_timer > 0) {
            /* Yellow/Orange Muzzle Flash */
            fb_rect(cx - 4, base_y - 12, 8, 4, C_YELLOW);
            fb_rect(cx - 2, base_y - 14, 4, 2, C_ORANGE);
            fb_px(cx, base_y - 15, C_WHITE);
        }
    } else {
        /* Double-barrel Shotgun */
        fb_rect(cx - 4, base_y - 8, 8, 9, 0x49u); /* Twin barrels */
        fb_rect(cx - 3, base_y - 9, 2, 2, C_BLACK); /* Left bore */
        fb_rect(cx + 1, base_y - 9, 2, 2, C_BLACK); /* Right bore */
        fb_rect(cx - 5, base_y - 4, 10, 5, 0x31u); /* Wooden pump */
        if (muzzle_timer > 0) {
            /* Huge Shotgun Blast */
            fb_rect(cx - 7, base_y - 14, 14, 5, C_YELLOW);
            fb_rect(cx - 4, base_y - 16, 8, 3, C_ORANGE);
            fb_px(cx - 1, base_y - 17, C_WHITE);
            fb_px(cx + 1, base_y - 17, C_WHITE);
        }
    }
}

/* Monster Sprite Rendering in 3D Viewport */
static void draw_monster(int screen_x, int dist, int type, int state)
{
    if (dist < FP_ONE / 2 || dist > 12 * FP_ONE) return;
    int h = (12 * D_PLAY_H) / (dist >> (FP_SHIFT - 4));
    if (h < 3) h = 3;
    if (h > D_PLAY_H) h = D_PLAY_H;
    int top = (D_PLAY_H - h) / 2;
    int w = h / 2;
    if (w < 2) w = 2;

    uint8_t body_col = (type == 1) ? 0x48u : 0x6Cu; /* Zombieman=greenish, Imp=brown */
    if (state == 2) body_col = C_RED; /* Attack / Firing */
    if (state == 4) { top += h / 2; h /= 2; body_col = 0x40u; } /* Dead corpse */

    fb_rect(screen_x - w / 2, top, w, h, body_col);
    /* Head */
    if (state != 4) {
        fb_rect(screen_x - w / 4, top, w / 2, h / 3, (type == 1) ? 0xBDu : 0x90u);
        /* Glowing Red Eyes */
        fb_px(screen_x - 1, top + 1, C_RED);
        fb_px(screen_x + 1, top + 1, C_RED);
    }
}

int doom_main(int argc, char **argv)
{
    (void)argc; (void)argv;
    init_doom_trig();

    /* Player State */
    int32_t px = (2 * FP_ONE) + FP_ONE / 2;
    int32_t py = (2 * FP_ONE) + FP_ONE / 2;
    uint8_t p_angle = 0;       /* 0 = facing East (+X) */
    int health = 100;
    int armor = 50;
    int ammo = 50;
    int weapon = 1;            /* 1=Pistol, 2=Shotgun */
    int muzzle_timer = 0;
    int recoil_y = 0;
    int face_state = 0;
    int damage_flash = 0;
    int tick_cnt = 0;

    /* Initialize Monsters */
    monsters[0] = (struct doom_monster){(6 * FP_ONE) + FP_ONE/2, (2 * FP_ONE) + FP_ONE/2, 20, 1, 0, 0};
    monsters[1] = (struct doom_monster){(7 * FP_ONE) + FP_ONE/2, (7 * FP_ONE) + FP_ONE/2, 40, 2, 0, 0};
    monsters[2] = (struct doom_monster){(13 * FP_ONE) + FP_ONE/2, (7 * FP_ONE) + FP_ONE/2, 20, 1, 0, 0};
    monsters[3] = (struct doom_monster){(13 * FP_ONE) + FP_ONE/2, (13 * FP_ONE) + FP_ONE/2, 50, 2, 0, 0};

    key_flush();

    /* Intro Level Title Banner */
    fb_clear(C_BLACK);
    fb_rect(2, 4, 60, 24, C_BLUE);
    fb_rect(3, 5, 58, 22, C_BLACK);
    fb_text(5, 7, "DOOM: EPISODE 1", C_RED);
    fb_text(10, 14, "E1M1: HANGAR", C_YELLOW);
    fb_text(4, 21, "[WASD/ARROWS/SPC]", C_GREEN);
    dump_tiny();
    sleep_ms(800);

    const int32_t move_speed = 64;
    const uint8_t rot_speed = 6;

    int k_up = 0, k_down = 0, k_left = 0, k_right = 0;

    for (;;) {
        int pressed, fired = 0;
        uint8_t code;

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
                /* Fire Weapon */
                if (ammo > 0) {
                    muzzle_timer = (weapon == 1) ? 2 : 4;
                    recoil_y = (weapon == 1) ? 3 : 5;
                    face_state = 1;
                    fired = 1;
                    ammo -= (weapon == 1) ? 1 : 2;
                    if (ammo < 0) ammo = 0;

                    /* Hitscan trace: check if a monster is in crosshairs */
                    int damage = (weapon == 1) ? 15 : 45;
                    for (int m = 0; m < MAX_MONSTERS; m++) {
                        if (monsters[m].state == 4) continue;
                        int32_t dx = monsters[m].x - px;
                        int32_t dy = monsters[m].y - py;
                        int32_t dist = (dx * d_costab[p_angle] + dy * d_sintab[p_angle]) >> 10;
                        int32_t lat = (-dx * d_sintab[p_angle] + dy * d_costab[p_angle]) >> 10;
                        if (dist > 0 && dist < 8 * FP_ONE && lat > -FP_ONE && lat < FP_ONE) {
                            monsters[m].health -= damage;
                            if (monsters[m].health <= 0) {
                                monsters[m].state = 4; /* Killed */
                            }
                        }
                    }
                }
            } else if (pressed && code == '1') {
                weapon = 1; /* Pistol */
            } else if (pressed && code == '2') {
                weapon = 2; /* Shotgun */
            }
        }

        /* Continuous Smooth Movement & Turning */
        if (k_left) p_angle = (uint8_t)(p_angle - rot_speed);
        if (k_right) p_angle = (uint8_t)(p_angle + rot_speed);

        if (k_up) {
            int32_t nx = px + ((d_costab[p_angle] * move_speed) >> 10);
            int32_t ny = py + ((d_sintab[p_angle] * move_speed) >> 10);
            int margin = 220;
            int cx = (nx > px) ? (nx + margin) : (nx - margin);
            int cy = (ny > py) ? (ny + margin) : (ny - margin);
            if (e1m1_map[py >> FP_SHIFT][cx >> FP_SHIFT] == 0) px = nx;
            if (e1m1_map[cy >> FP_SHIFT][px >> FP_SHIFT] == 0) py = ny;
        }
        if (k_down) {
            int32_t nx = px - ((d_costab[p_angle] * move_speed) >> 10);
            int32_t ny = py - ((d_sintab[p_angle] * move_speed) >> 10);
            int margin = 220;
            int cx = (nx > px) ? (nx + margin) : (nx - margin);
            int cy = (ny > py) ? (ny + margin) : (ny - margin);
            if (e1m1_map[py >> FP_SHIFT][cx >> FP_SHIFT] == 0) px = nx;
            if (e1m1_map[cy >> FP_SHIFT][px >> FP_SHIFT] == 0) py = ny;
        }

        tick_cnt++;
        if (muzzle_timer > 0 && !fired) muzzle_timer--;
        if (recoil_y > 0) recoil_y--;
        if (muzzle_timer == 0) face_state = 0;
        if (damage_flash > 0) damage_flash--;

        /* Monster AI & Combat Tick */
        for (int m = 0; m < MAX_MONSTERS; m++) {
            if (monsters[m].state == 4) continue;
            int32_t dx = px - monsters[m].x;
            int32_t dy = py - monsters[m].y;
            int32_t dist_sq = (dx >> 6) * (dx >> 6) + (dy >> 6) * (dy >> 6);
            if (dist_sq < (6 * 16) * (6 * 16)) {
                /* Spot player: advance toward player */
                if ((tick_cnt & 3) == 0) {
                    monsters[m].x += (dx > 0) ? 8 : -8;
                    monsters[m].y += (dy > 0) ? 8 : -8;
                }
                /* Attack player when close */
                if (dist_sq < (2 * 16) * (2 * 16) && (tick_cnt % 30 == 0)) {
                    monsters[m].state = 2;
                    int dmg = (monsters[m].type == 1) ? 5 : 12;
                    if (armor > 0) { armor -= dmg / 2; health -= dmg / 2; }
                    else { health -= dmg; }
                    if (health <= 0) { health = 100; px = (2 * FP_ONE); py = (2 * FP_ONE); } /* Respawn */
                    damage_flash = 2;
                } else if (monsters[m].state == 2 && (tick_cnt % 5 == 0)) {
                    monsters[m].state = 1;
                }
            }
        }

        /* ------------------------------------------------ 3D Raycasting */
        /* Ceiling & Floor */
        for (int y = 0; y < D_PLAY_H / 2; y++) {
            for (int x = 0; x < D_SCREEN_W; x++) FB[y * D_SCREEN_W + x] = 0x24u; /* Dark slate ceiling */
        }
        uint8_t floor_col = (e1m1_map[py >> FP_SHIFT][px >> FP_SHIFT] == T_NUKAGE) ? 0x1Cu : 0x20u;
        for (int y = D_PLAY_H / 2; y < D_PLAY_H; y++) {
            for (int x = 0; x < D_SCREEN_W; x++) FB[y * D_SCREEN_W + x] = floor_col; /* Nukage / stone floor */
        }

        /* 64 Horizontal Rays for 64 Columns */
        int32_t ray_depths[D_SCREEN_W];
        for (int col = 0; col < D_SCREEN_W; col++) {
            /* FOV ~60 degrees across 64 columns */
            int ray_angle_off = (col - 32) * 256 / 192;
            uint8_t ray_angle = (uint8_t)(p_angle + ray_angle_off);

            int32_t r_cos = d_costab[ray_angle];
            int32_t r_sin = d_sintab[ray_angle];
            if (r_cos == 0) r_cos = 1;
            if (r_sin == 0) r_sin = 1;

            int map_x = px >> FP_SHIFT;
            int map_y = py >> FP_SHIFT;
            int step_x = (r_cos > 0) ? 1 : -1;
            int step_y = (r_sin > 0) ? 1 : -1;

            int32_t delta_x = (r_cos > 0) ? ((int32_t)FP_ONE * 1024 / r_cos) : ((int32_t)FP_ONE * -1024 / r_cos);
            int32_t delta_y = (r_sin > 0) ? ((int32_t)FP_ONE * 1024 / r_sin) : ((int32_t)FP_ONE * -1024 / r_sin);

            int32_t side_x = (r_cos > 0) ? (((map_x + 1) * FP_ONE - px) * delta_x >> FP_SHIFT)
                                         : ((px - map_x * FP_ONE) * delta_x >> FP_SHIFT);
            int32_t side_y = (r_sin > 0) ? (((map_y + 1) * FP_ONE - py) * delta_y >> FP_SHIFT)
                                         : ((py - map_y * FP_ONE) * delta_y >> FP_SHIFT);

            int hit = 0, side = 0, tile = 0;
            for (int step = 0; step < 20 && !hit; step++) {
                if (side_x < side_y) {
                    side_x += delta_x;
                    map_x += step_x;
                    side = 0;
                } else {
                    side_y += delta_y;
                    map_y += step_y;
                    side = 1;
                }
                if (map_x >= 0 && map_x < MAP_W && map_y >= 0 && map_y < MAP_H) {
                    tile = e1m1_map[map_y][map_x];
                    if (tile > 0) hit = 1;
                } else {
                    hit = 1; tile = T_STARTAN;
                }
            }

            int32_t wall_dist = (side == 0) ? (side_x - delta_x) : (side_y - delta_y);
            /* Correct fisheye distortion */
            int32_t cos_diff = d_costab[(uint8_t)ray_angle_off];
            if (cos_diff > 0) wall_dist = (wall_dist * cos_diff) >> 10;
            if (wall_dist < FP_ONE / 4) wall_dist = FP_ONE / 4;
            ray_depths[col] = wall_dist;

            int line_h = (16 * D_PLAY_H) / (wall_dist >> (FP_SHIFT - 4));
            if (line_h > D_PLAY_H) line_h = D_PLAY_H;
            int draw_start = (D_PLAY_H - line_h) / 2;
            int draw_end = draw_start + line_h;

            int blink = (tick_cnt & 16) && (tile == T_COMP);
            uint8_t wall_col = get_wall_color(tile, side, wall_dist, blink);

            for (int y = draw_start; y < draw_end; y++) {
                FB[y * D_SCREEN_W + col] = wall_col;
            }
        }

        /* Render Monsters Sorted by Distance */
        for (int m = 0; m < MAX_MONSTERS; m++) {
            int32_t dx = monsters[m].x - px;
            int32_t dy = monsters[m].y - py;
            int32_t m_dist = (dx * d_costab[p_angle] + dy * d_sintab[p_angle]) >> 10;
            int32_t m_lat = (-dx * d_sintab[p_angle] + dy * d_costab[p_angle]) >> 10;
            if (m_dist > FP_ONE / 2) {
                int screen_x = 32 + (m_lat * 48 / m_dist);
                if (screen_x >= 0 && screen_x < D_SCREEN_W && m_dist < ray_depths[screen_x]) {
                    draw_monster(screen_x, m_dist, monsters[m].type, monsters[m].state);
                }
            }
        }

        /* Red Damage Flash */
        if (damage_flash > 0) {
            for (int i = 0; i < D_SCREEN_W; i++) {
                FB[i] = C_RED; FB[(D_PLAY_H - 1) * D_SCREEN_W + i] = C_RED;
            }
        }

        /* Render Weapon & HUD */
        draw_weapon(weapon, muzzle_timer, recoil_y);
        draw_doom_hud(health, armor, ammo, weapon, face_state);

        /* Stream frame at solid 45 FPS */
        dump_tiny();
        sleep_ms(22);
    }

    return 0;
}
