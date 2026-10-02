// native_harness.h -- provides console.h ABI for host GCC execution
#ifndef NATIVE_HARNESS_H
#define NATIVE_HARNESS_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FB_W 64
#define FB_H 32
#define FB_STD_W 320
#define FB_STD_H 200

extern uint8_t g_fb[FB_STD_W * FB_STD_H];
#define FB g_fb

#define K_UP        0xADu
#define K_DOWN      0xAFu
#define K_LEFT      0xACu
#define K_RIGHT     0xAEu
#define K_ESC       27u
#define K_ENTER     13u
#define K_SPACE     32u
#define K_TAB       9u

#define RGB332(r, g, b) \
    ((uint8_t)(((uint8_t)(r) & 0xE0u) | (((uint8_t)(g) >> 3) & 0x1Cu) | ((uint8_t)(b) >> 6)))

#define C_BLACK     0x00u
#define C_WHITE     0xFFu
#define C_RED       0xE0u
#define C_GREEN     0x1Cu
#define C_BLUE      0x03u
#define C_YELLOW    0xFCu
#define C_CYAN      0x1Fu
#define C_MAGENTA   0xE3u
#define C_GRAY      0x92u
#define C_DKGRAY    0x49u
#define C_ORANGE    0xECu

void     fb_clear(uint8_t c);
void     fb_px(int x, int y, uint8_t c);
void     fb_rect(int x, int y, int w, int h, uint8_t c);
void     fb_text(int x, int y, const char *s, uint8_t c);
void     fb_num(int x, int y, uint32_t v, int digits, uint8_t c);
int      key_poll(int *pressed, uint8_t *code);
void     key_flush(void);
uint32_t ticks_ms(void);
void     sleep_ms(uint32_t ms);
void     dump_tiny(void);
void     dump_std(void);
uint32_t frames(void);
uint32_t rng32(void);
void     print(const char *s);
void     print_hex(uint32_t v);
void     print_dec(uint32_t v);
void     sys_exit(uint32_t code);

extern uint8_t _wad_start[65536];
extern uint8_t _wad_end[4];

#endif
