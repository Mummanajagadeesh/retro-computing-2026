/* console.h -- game ABI for the retro_fpga console (rv32im, freestanding).
 *
 * Games render into the 64 KB framebuffer window at 0xFFF00000. Tiny games
 * use bytes [0, 2048) as a 64x32 RGB332 image (RRRGGGBB per byte) and hand
 * it to the streamer with dump_tiny() (MM_DUMP = 2). DOOM keeps the full
 * 320x200 window with dump_std() (MM_DUMP = 1).
 *
 * Keys arrive as press/release events through MM_KEY. The host viewer
 * 'console' preset sends letters lowercase, digits as ASCII, and arrows /
 * space / enter / esc with the codes below. The key register holds ONE
 * event (no queue), so games must poll every frame.
 */
#ifndef RETRO_CONSOLE_H
#define RETRO_CONSOLE_H

#include <stdint.h>

#define FB_W        64
#define FB_H        32
#define FB          ((volatile uint8_t *)0xFFF00000u)

/* console keycodes (host viewer 'console' preset) */
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

/* palette shortcuts */
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
int      key_poll_raw(int *pressed, uint8_t *code);
void     key_flush(void);
uint32_t ticks_ms(void);
void     sleep_ms(uint32_t ms);
void     dump_tiny(void);
void     dump_std(void);
uint32_t frames(void);
uint32_t rng32(void);
void     print(const char *s);
void     con_putc(char c);
void     print_hex(uint32_t v);
void     print_dec(uint32_t v);
void     sys_exit(uint32_t code) __attribute__((noreturn));

/* Fast non-local jumps for game exit back to menu */
typedef uint32_t jmp_buf[16];
int      setjmp(jmp_buf env);
void     longjmp(jmp_buf env, int val) __attribute__((noreturn));

extern int g_in_game;
extern jmp_buf menu_jmp_buf;

/* ROM / blob slot (uploader WAD): mkrom.py wraps payloads as [u16 len][bytes] */
extern const uint8_t _wad_start[];
extern const uint8_t _wad_end[];

#endif
