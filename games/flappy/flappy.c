/* flappy.c -- Native 45 FPS Flappy Bird for 64x32 Retro Console
 * Controls: SPACE / UP / W / ENTER to flap
 *           R to restart
 *           ESC to exit to menu
 */
#ifdef HOST_BUILD
#include "native_harness.h"
#define FB32 ((volatile uint8_t *)g_fb)
#else
#include "console.h"
#endif

#define GRAVITY 18
#define FLAP_VEL -120
#define MAX_VEL 180

#define PIPE_GAP 10
#define PIPE_WIDTH 5
#define NUM_PIPES 2

struct pipe {
    int x;
    int gap_y; /* top of the gap */
    int passed;
};

static int bird_y;      /* 8.8 fixed point */
static int bird_vy;
static struct pipe pipes[NUM_PIPES];
static int score = 0;
static int best_score = 0;
static int flappy_state = 0; /* 0=title/ready, 1=playing, 2=gameover */
static uint32_t rng_seed = 12345;

static int get_rand(int min, int max)
{
    rng_seed = rng_seed * 1103515245 + 12345;
    int r = (int)((rng_seed >> 16) & 0x7FFF);
    return min + (r % (max - min + 1));
}

static void reset_flappy(void)
{
    bird_y = 14 * 256;
    bird_vy = 0;
    score = 0;
    flappy_state = 0; /* Ready state */

    for (int i = 0; i < NUM_PIPES; i++) {
        pipes[i].x = 64 + i * 36;
        pipes[i].gap_y = get_rand(4, 17);
        pipes[i].passed = 0;
    }
}

static void draw_flappy(void)
{
    fb_clear(C_BLACK);

    /* Background clouds/stars */
    fb_px(8, 6, C_WHITE); fb_px(9, 6, C_WHITE);
    fb_px(42, 8, C_WHITE); fb_px(43, 8, C_WHITE);

    /* Ground (y=30..31) */
    fb_rect(0, 30, 64, 2, C_YELLOW);
    fb_rect(0, 31, 64, 1, C_GREEN);

    /* Draw Pipes */
    for (int i = 0; i < NUM_PIPES; i++) {
        int px = pipes[i].x;
        if (px >= -PIPE_WIDTH && px < 64) {
            int gy = pipes[i].gap_y;

            /* Top pipe (from y=0 to gy) */
            if (gy > 0) {
                fb_rect(px, 0, PIPE_WIDTH, gy, C_GREEN);
                /* Pipe rim */
                fb_rect(px - 1, gy - 2, PIPE_WIDTH + 2, 2, C_WHITE);
            }

            /* Bottom pipe (from gy + PIPE_GAP to y=30) */
            int by = gy + PIPE_GAP;
            if (by < 30) {
                fb_rect(px, by, PIPE_WIDTH, 30 - by, C_GREEN);
                /* Pipe rim */
                fb_rect(px - 1, by, PIPE_WIDTH + 2, 2, C_WHITE);
            }
        }
    }

    /* Draw Bird (at x=14, y=bird_y>>8, size 4x3) */
    int by = bird_y >> 8;
    if (by < 0) by = 0;
    if (by > 27) by = 27;

    /* Bird body */
    fb_rect(14, by, 4, 3, C_YELLOW);
    /* Eye */
    fb_px(16, by, C_WHITE);
    fb_px(17, by, C_BLACK);
    /* Beak */
    fb_px(17, by + 1, C_RED);
    /* Wing */
    if (bird_vy < 0) {
        fb_px(13, by + 1, C_WHITE); /* wing up */
    } else {
        fb_px(14, by + 2, C_WHITE); /* wing down */
    }

    /* Draw Score */
    char s_score[8];
    if (score < 10) {
        s_score[0] = (char)('0' + score);
        s_score[1] = '\0';
        fb_text(54, 2, s_score, C_WHITE);
    } else {
        s_score[0] = (char)('0' + (score / 10));
        s_score[1] = (char)('0' + (score % 10));
        s_score[2] = '\0';
        fb_text(48, 2, s_score, C_WHITE);
    }

    /* Title / Ready Overlay */
    if (flappy_state == 0) {
        fb_rect(10, 4, 44, 11, C_BLUE);
        fb_text(12, 6, "FLAP BIRD", C_YELLOW);
        fb_text(6, 18, "PRESS SPACE", C_WHITE);
    } else if (flappy_state == 2) {
        /* Game Over Overlay */
        fb_rect(8, 6, 48, 18, C_RED);
        fb_text(12, 8, "GAME OVER", C_YELLOW);
        char s_best[12];
        s_best[0] = 'S'; s_best[1] = 'C'; s_best[2] = ':';
        s_best[3] = (char)('0' + (score / 10)); s_best[4] = (char)('0' + (score % 10));
        s_best[5] = ' '; s_best[6] = 'H'; s_best[7] = 'I'; s_best[8] = ':';
        s_best[9] = (char)('0' + (best_score / 10)); s_best[10] = (char)('0' + (best_score % 10));
        s_best[11] = '\0';
        fb_text(10, 16, s_best, C_WHITE);
    }
}

int flappy_main(void)
{
    reset_flappy();
    draw_flappy();
    dump_tiny();

    while (1) {
        int pressed;
        uint8_t code;
        while (key_poll(&pressed, &code)) {
            if (!pressed) continue;

            if (code == 'r' || code == 'R') {
                reset_flappy();
                continue;
            }

            if (code == K_SPACE || code == K_UP || code == 'w' || code == 'W' || code == K_ENTER || code == ' ' || code == 10 || code == 0xA3) {
                if (flappy_state == 0) {
                    flappy_state = 1;
                    bird_vy = FLAP_VEL;
                } else if (flappy_state == 1) {
                    bird_vy = FLAP_VEL;
                } else if (flappy_state == 2) {
                    reset_flappy();
                }
            }
        }

        /* Update physics if playing */
        if (flappy_state == 1) {
            bird_vy += GRAVITY;
            if (bird_vy > MAX_VEL) bird_vy = MAX_VEL;
            bird_y += bird_vy;

            int by = bird_y >> 8;

            /* Ground collision */
            if (by >= 27) {
                bird_y = 27 * 256;
                flappy_state = 2;
                if (score > best_score) best_score = score;
            }
            if (by < 0) {
                bird_y = 0;
                bird_vy = 0;
            }

            /* Move pipes */
            for (int i = 0; i < NUM_PIPES; i++) {
                pipes[i].x--;
                if (pipes[i].x < -PIPE_WIDTH) {
                    pipes[i].x = 64 + (36 - PIPE_WIDTH);
                    pipes[i].gap_y = get_rand(4, 17);
                    pipes[i].passed = 0;
                }

                /* Check score */
                if (!pipes[i].passed && pipes[i].x < 14) {
                    pipes[i].passed = 1;
                    score++;
                    if (score > best_score) best_score = score;
                }

                /* Pipe collision check (bird bounding box: x=14..17, y=by..by+2) */
                int px = pipes[i].x;
                if (px <= 17 && px + PIPE_WIDTH >= 14) {
                    int gy = pipes[i].gap_y;
                    if (by < gy || by + 2 >= gy + PIPE_GAP) {
                        flappy_state = 2;
                        if (score > best_score) best_score = score;
                    }
                }
            }
        }

        draw_flappy();
        dump_tiny();
        sleep_ms(22); /* 45 FPS */
    }
    return 0;
}
