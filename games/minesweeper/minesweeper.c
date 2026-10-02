/* minesweeper.c -- Native 45 FPS Minesweeper for 64x32 Retro Console
 * Controls: Arrow keys / WASD to move cursor
 *           SPACE / ENTER to reveal cell (First click is always safe!)
 *           F / X / Z to toggle flag
 *           R to restart
 *           ESC to exit to menu
 */
#ifdef HOST_BUILD
#include "native_harness.h"
#define FB32 ((volatile uint8_t *)g_fb)
#else
#include "console.h"
#endif

#define COLS 12
#define ROWS 6
#define NUM_MINES 10

#define CELL_W 4
#define CELL_H 4
#define GRID_X 8
#define GRID_Y 8

static uint8_t board[ROWS][COLS];    /* 0..8 mine count, or 9=mine */
static uint8_t revealed[ROWS][COLS]; /* 0=hidden, 1=revealed, 2=flagged */
static int cursor_x = 0;
static int cursor_y = 0;
static int game_state = 0;           /* 0=ready/playing, 1=won, 2=lost */
static int mines_initialized = 0;
static int flags_placed = 0;
static uint32_t start_tick = 0;
static uint32_t elapsed_sec = 0;

static void place_mines(int safe_x, int safe_y)
{
    for (int r = 0; r < ROWS; r++)
        for (int c = 0; c < COLS; c++)
            board[r][c] = 0;

    int placed = 0;
    uint32_t seed = (uint32_t)ticks_ms() + (uint32_t)safe_x * 7 + (uint32_t)safe_y * 13;
    while (placed < NUM_MINES) {
        seed = seed * 1103515245 + 12345;
        int rx = (int)((seed >> 16) % COLS);
        seed = seed * 1103515245 + 12345;
        int ry = (int)((seed >> 16) % ROWS);

        /* Don't place on or immediately adjacent to safe_x, safe_y on first click */
        if (rx >= safe_x - 1 && rx <= safe_x + 1 && ry >= safe_y - 1 && ry <= safe_y + 1)
            continue;
        if (board[ry][rx] == 9)
            continue;

        board[ry][rx] = 9;
        placed++;
    }

    /* Calculate adjacent mine counts */
    for (int r = 0; r < ROWS; r++) {
        for (int c = 0; c < COLS; c++) {
            if (board[r][c] == 9) continue;
            int count = 0;
            for (int dr = -1; dr <= 1; dr++) {
                for (int dc = -1; dc <= 1; dc++) {
                    int nr = r + dr, nc = c + dc;
                    if (nr >= 0 && nr < ROWS && nc >= 0 && nc < COLS) {
                        if (board[nr][nc] == 9) count++;
                    }
                }
            }
            board[r][c] = (uint8_t)count;
        }
    }
    mines_initialized = 1;
}

static void flood_reveal(int r, int c)
{
    if (r < 0 || r >= ROWS || c < 0 || c >= COLS) return;
    if (revealed[r][c] != 0) return;

    revealed[r][c] = 1;
    if (board[r][c] == 0) {
        for (int dr = -1; dr <= 1; dr++) {
            for (int dc = -1; dc <= 1; dc++) {
                flood_reveal(r + dr, c + dc);
            }
        }
    }
}

static void check_win(void)
{
    int hidden_non_mines = 0;
    for (int r = 0; r < ROWS; r++) {
        for (int c = 0; c < COLS; c++) {
            if (board[r][c] != 9 && revealed[r][c] != 1) {
                hidden_non_mines++;
            }
        }
    }
    if (hidden_non_mines == 0) {
        game_state = 1; /* WIN! */
        /* Flag all remaining mines */
        for (int r = 0; r < ROWS; r++) {
            for (int c = 0; c < COLS; c++) {
                if (board[r][c] == 9) revealed[r][c] = 2;
            }
        }
    }
}

static void reset_minesweeper(void)
{
    for (int r = 0; r < ROWS; r++) {
        for (int c = 0; c < COLS; c++) {
            board[r][c] = 0;
            revealed[r][c] = 0;
        }
    }
    cursor_x = COLS / 2;
    cursor_y = ROWS / 2;
    game_state = 0;
    mines_initialized = 0;
    flags_placed = 0;
    start_tick = (uint32_t)ticks_ms();
    elapsed_sec = 0;
}

static void draw_minesweeper(void)
{
    fb_clear(C_BLACK);

    /* Top Bar: (y=0..6) [M:08] [ :) ] [T:024] */
    fb_rect(0, 0, 64, 7, C_BLUE);
    
    /* Mine count left */
    int mines_left = NUM_MINES - flags_placed;
    if (mines_left < 0) mines_left = 0;
    char s_mines[8];
    s_mines[0] = 'M'; s_mines[1] = ':';
    s_mines[2] = (char)('0' + (mines_left / 10));
    s_mines[3] = (char)('0' + (mines_left % 10));
    s_mines[4] = '\0';
    fb_text(1, 1, s_mines, C_YELLOW);

    /* Face status */
    if (game_state == 0)      fb_text(26, 1, ":-)", C_WHITE);
    else if (game_state == 1) fb_text(26, 1, "WIN", C_GREEN);
    else                      fb_text(26, 1, "X-(", C_RED);

    /* Timer */
    if (game_state == 0 && mines_initialized) {
        elapsed_sec = ((uint32_t)ticks_ms() - start_tick) / 1000;
        if (elapsed_sec > 999) elapsed_sec = 999;
    }
    char s_time[8];
    s_time[0] = (char)('0' + (elapsed_sec / 100) % 10);
    s_time[1] = (char)('0' + (elapsed_sec / 10) % 10);
    s_time[2] = (char)('0' + (elapsed_sec % 10));
    s_time[3] = '\0';
    fb_text(48, 1, s_time, C_YELLOW);

    /* Top border line */
    fb_rect(0, 7, 64, 1, C_CYAN);

    /* Grid Area */
    for (int r = 0; r < ROWS; r++) {
        for (int c = 0; c < COLS; c++) {
            int px = GRID_X + c * CELL_W;
            int py = GRID_Y + r * CELL_H;
            uint8_t rev = revealed[r][c];

            if (rev == 0) {
                /* Hidden tile */
                fb_rect(px, py, CELL_W - 1, CELL_H - 1, C_WHITE);
                fb_px(px + 1, py + 1, C_BLACK);
            } else if (rev == 2) {
                /* Flagged tile */
                fb_rect(px, py, CELL_W - 1, CELL_H - 1, C_RED);
                fb_px(px + 1, py + 1, C_YELLOW);
            } else {
                /* Revealed tile */
                uint8_t val = board[r][c];
                if (val == 9) {
                    /* Mine */
                    fb_rect(px, py, CELL_W - 1, CELL_H - 1, C_RED);
                    fb_px(px + 1, py + 1, C_BLACK);
                } else if (val == 0) {
                    /* Empty open floor */
                    fb_rect(px, py, CELL_W - 1, CELL_H - 1, C_BLACK);
                    fb_px(px + 1, py + 1, C_BLUE);
                } else {
                    /* Number (1..8) */
                    fb_rect(px, py, CELL_W - 1, CELL_H - 1, C_BLACK);
                    uint8_t color = C_CYAN;
                    if (val == 2) color = C_GREEN;
                    else if (val == 3) color = C_RED;
                    else if (val >= 4) color = C_MAGENTA;
                    char num_str[2];
                    num_str[0] = (char)('0' + val);
                    num_str[1] = '\0';
                    fb_text(px, py - 1, num_str, color);
                }
            }
        }
    }

    /* Cursor highlight */
    static int blink = 0;
    blink++;
    if ((blink & 8) == 0 || game_state != 0) {
        int cx = GRID_X + cursor_x * CELL_W;
        int cy = GRID_Y + cursor_y * CELL_H;
        /* Draw 4 corner pixels to highlight cursor */
        fb_px(cx, cy, C_YELLOW);
        fb_px(cx + CELL_W - 2, cy, C_YELLOW);
        fb_px(cx, cy + CELL_H - 2, C_YELLOW);
        fb_px(cx + CELL_W - 2, cy + CELL_H - 2, C_YELLOW);
    }

    /* Bottom Status Banner if Game Over */
    if (game_state == 1) {
        fb_rect(4, 12, 56, 10, C_GREEN);
        fb_text(8, 14, "* VICTORY! *", C_BLACK);
    } else if (game_state == 2) {
        fb_rect(6, 12, 52, 10, C_RED);
        fb_text(10, 14, "BOOM! LOST", C_YELLOW);
    }
}

int minesweeper_main(void)
{
    reset_minesweeper();
    draw_minesweeper();
    dump_tiny();

    while (1) {
        int pressed;
        uint8_t code;
        while (key_poll(&pressed, &code)) {
            if (!pressed) continue;

            if (code == 'r' || code == 'R') {
                reset_minesweeper();
                continue;
            }

            if (game_state != 0) {
                if (code == K_SPACE || code == K_ENTER || code == ' ' || code == 10 || code == 0xA3) {
                    reset_minesweeper();
                    continue;
                }
            }

            /* Cursor navigation */
            if ((code == K_UP || code == 'w' || code == 'W') && cursor_y > 0) {
                cursor_y--;
            } else if ((code == K_DOWN || code == 's' || code == 'S') && cursor_y < ROWS - 1) {
                cursor_y++;
            } else if ((code == K_LEFT || code == 'a' || code == 'A') && cursor_x > 0) {
                cursor_x--;
            } else if ((code == K_RIGHT || code == 'd' || code == 'D') && cursor_x < COLS - 1) {
                cursor_x++;
            }

            /* Reveal cell */
            if (code == K_SPACE || code == K_ENTER || code == ' ' || code == 10 || code == 0xA3) {
                if (game_state == 0 && revealed[cursor_y][cursor_x] != 2) {
                    if (!mines_initialized) {
                        place_mines(cursor_x, cursor_y);
                        start_tick = (uint32_t)ticks_ms();
                    }
                    if (board[cursor_y][cursor_x] == 9) {
                        /* BOOM! */
                        game_state = 2;
                        /* Reveal all mines */
                        for (int r = 0; r < ROWS; r++) {
                            for (int c = 0; c < COLS; c++) {
                                if (board[r][c] == 9) revealed[r][c] = 1;
                            }
                        }
                    } else {
                        flood_reveal(cursor_y, cursor_x);
                        check_win();
                    }
                }
            }

            /* Toggle Flag */
            if (code == 'f' || code == 'F' || code == 'x' || code == 'X' || code == 'z' || code == 'Z') {
                if (game_state == 0) {
                    if (revealed[cursor_y][cursor_x] == 0) {
                        revealed[cursor_y][cursor_x] = 2;
                        flags_placed++;
                    } else if (revealed[cursor_y][cursor_x] == 2) {
                        revealed[cursor_y][cursor_x] = 0;
                        flags_placed--;
                    }
                }
            }
        }

        draw_minesweeper();
        dump_tiny();
        sleep_ms(22); /* 45 FPS */
    }
    return 0;
}
