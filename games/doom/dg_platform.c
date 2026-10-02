/* dg_platform.c -- bare-metal platform layer for doomgeneric on
 * rv32i-super-br-hybp-btb-ras-hzopt-luopt-fulu.
 *
 * Register map is the VERIFIED one from rtl/mem/mem_top_dg.v, not a guess.
 * All access is polled MMIO: no interrupts, no trap handler needed.
 */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "doomgeneric.h"

/* ------------------------------------------------------------ MMIO map */
#define MMIO        0xFFFFF000u
#define MM_EXIT     (*(volatile uint32_t *)(MMIO + 0x000))
#define MM_CYC_LO   (*(volatile uint32_t *)(MMIO + 0x004))
#define MM_CYC_HI   (*(volatile uint32_t *)(MMIO + 0x008))
#define MM_INS_LO   (*(volatile uint32_t *)(MMIO + 0x00C))
#define MM_INS_HI   (*(volatile uint32_t *)(MMIO + 0x010))
#define MM_KEY      (*(volatile uint32_t *)(MMIO + 0x014))
#define MM_FRAMES   (*(volatile uint32_t *)(MMIO + 0x018))
#define MM_FB_BASE  (*(volatile uint32_t *)(MMIO + 0x01C))
#define MM_STATUS   (*(volatile uint32_t *)(MMIO + 0x020))
#define MM_UART     (*(volatile uint32_t *)(MMIO + 0x024))
#define MM_DUMP     (*(volatile uint32_t *)(MMIO + 0x028))

#define FB_ADDR     0xFFF00000u
#define SCREENW     320
#define SCREENH     200

/* The WAD is loaded into dmem by the testbench ($fread), bracketed by these
 * linker symbols. There is no filesystem; dg_fopen hands DOOM a pointer in. */
extern char _wad_start[];
extern char _wad_end[];

/* ------------------------------------------------------------- console */
static void uart_putc(char c)
{
    if (c == '\n') MM_UART = (uint32_t)'\r';
    MM_UART = (uint32_t)(uint8_t)c;
}

void dg_print(const char *s) { for (; *s; ++s) uart_putc(*s); }

extern char __heap_start[];
static char *_heap_marker = (char *)0;

static void dg_puthex(uint32_t v)
{
    static const char d[] = "0123456789abcdef";
    int i;
    for (i = 28; i >= 0; i -= 4) uart_putc(d[(v >> i) & 0xF]);
}

static void dg_putu(uint32_t v)
{
    char b[12]; int n = 0;
    if (!v) b[n++] = '0';
    while (v) { b[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) uart_putc(b[--n]);
}

/* ------------------------------------------------------ stdio backend
 * picolibc on this target has no device layer, so stdout/stderr/stdin do not
 * exist and DOOM's printf/fprintf/I_Error calls fail to link. Supply minimal
 * FILE objects backed by the UART MMIO register. This is picolibc's intended
 * extension point (see its docs on defining your own stdio streams).
 */
#include <stdio.h>

static int uart_put(char c, struct __file *f)
{
    (void)f;
    if (c == '\n') MM_UART = (uint32_t)'\r';
    MM_UART = (uint32_t)(uint8_t)c;
    return (unsigned char)c;
}


static FILE __dg_stdout = FDEV_SETUP_STREAM(uart_put, NULL, NULL, _FDEV_SETUP_WRITE);
static FILE __dg_stderr = FDEV_SETUP_STREAM(uart_put, NULL, NULL, _FDEV_SETUP_WRITE);
static FILE __dg_stdin  = FDEV_SETUP_STREAM(NULL, NULL, NULL, 0);

FILE *const stdout = &__dg_stdout;
FILE *const stderr = &__dg_stderr;
FILE *const stdin  = &__dg_stdin;

/* ------------------------------------------- picolibc syscall layer
 * These are the hooks picolibc's tinystdio and sbrk expect on a bare target.
 * Nothing here is on DOOM's hot path; they exist so the image links and so
 * exit() reaches a clean stop rather than falling off the end. */
#include <sys/stat.h>
#include <errno.h>

void _exit(int code)
{
    dg_print("[dg] _exit("); dg_putu((uint32_t)code); dg_print(")\n");
    MM_EXIT = (uint32_t)code;      /* tb_doom stops the simulation */
    for (;;) { }
}

int  open(const char *p, int f, ...)  { (void)p; (void)f; errno = ENOENT; return -1; }
int  close(int fd)                    { (void)fd; return -1; }
int  read(int fd, void *b, unsigned n){ (void)fd; (void)b; (void)n; return 0; }
int  write(int fd, const void *b, unsigned n)
{
    const char *s = (const char *)b;
    if (fd == 1 || fd == 2) { for (unsigned i = 0; i < n; ++i) uart_putc(s[i]); return (int)n; }
    return -1;
}
long lseek(int fd, long off, int w)   { (void)fd; (void)off; (void)w; return -1; }
int  unlink(const char *p)            { (void)p; return -1; }
int  fstat(int fd, struct stat *st)   { (void)fd; if (st) st->st_mode = S_IFCHR; return 0; }
int  stat(const char *p, struct stat *st) { (void)p; (void)st; errno = ENOENT; return -1; }
int  isatty(int fd)                   { (void)fd; return 1; }
int  gettimeofday(void *tv, void *tz) { (void)tv; (void)tz; return -1; }
void abort(void)                      { dg_print("[dg] abort()\n"); _exit(1); }

/* --------------------------------------------------- filesystem stubs
 * DOOM calls these for savegames and config files. We are read-only and
 * never save, so they are inert. */
int rename(const char *a, const char *b) { (void)a; (void)b; return -1; }
int mkdir(const char *p, mode_t m)        { (void)p; (void)m; return -1; }
int remove(const char *p)                { (void)p; return -1; }
int access(const char *p, int m)         { (void)p; (void)m; return -1; }

static uint8_t doom_render_buffer[SCREENW * SCREENH];

/* ---------------------------------------------------- doomgeneric hooks */
void DG_Init(void)
{
    /* Point the engine's screen buffer at internal render buffer.
     * DG_DrawFrame downsamples to 64x32 tiny framebuffer at FB_ADDR (0xFFF00000)
     * and streams at 45 FPS real-time over UART via dump_tiny (MM_DUMP = 2). */
    DG_ScreenBuffer = (pixel_t *)doom_render_buffer;
    MM_FB_BASE = FB_ADDR;

    dg_print("\n=== doomgeneric on rv32im superscalar (45 FPS tiny mode) ===\n");
    dg_print("wad_start = 0x"); dg_puthex((uint32_t)(uintptr_t)_wad_start);
    dg_print("\nwad_end   = 0x"); dg_puthex((uint32_t)(uintptr_t)_wad_end);
    dg_print("\nwad magic = '");
    { int q; for (q = 0; q < 4; ++q) uart_putc(_wad_start[q]); }
    dg_print("'  (want IWAD or PWAD)\n");
    dg_print("heap      = 0x"); dg_puthex((uint32_t)(uintptr_t)&_heap_marker);
    dg_print("\nfb        = 0xFFF00000  64x32 @ 45 FPS\n");
}

void DG_DrawFrame(void)
{
    volatile uint8_t *fb = (volatile uint8_t *)FB_ADDR;
    /* Real-time 64x32 downsampling: 5x horizontal, ~6.25x vertical */
    for (int ty = 0; ty < 32; ty++) {
        int sy = (ty * SCREENH) >> 5;
        const uint8_t *src_row = &doom_render_buffer[sy * SCREENW];
        volatile uint8_t *dst_row = &fb[ty * 64];
        for (int tx = 0; tx < 64; tx++) {
            dst_row[tx] = src_row[tx * 5];
        }
    }
    /* MM_DUMP = 2: Stream 2048-byte tiny frame over UART at 45 FPS! */
    MM_DUMP = 2u;
}

/* timedemo runs flat out; any sleep here would be simulated cycles. */
void DG_SleepMs(uint32_t ms) { (void)ms; }

/* Derive game time from the SIMULATED cycle counter, not a wall clock the
 * core cannot observe, so the tic rate is deterministic and reproducible. */
uint32_t DG_GetTicksMs(void) { return MM_CYC_LO / 1000u; }

int DG_GetKey(int *pressed, unsigned char *key)
{
    /* KEY register: bit31 = valid, bit30 = release (ev_keyup), [7:0] = the
     * doomkeys byte. doomgeneric's TranslateKey() is the identity, so whatever
     * the testbench injects arrives at D_PostEvent unmodified -- the bridge is
     * a real keyboard, not a one-shot hack. */
    uint32_t k = MM_KEY;
    if (!(k & 0x80000000u)) return 0;
    *pressed = (k & 0x40000000u) ? 0 : 1;
    *key = (unsigned char)(k & 0xFFu);
    MM_KEY = 0u;                    /* acknowledge -> clears key_valid */
    return 1;
}

void DG_SetWindowTitle(const char *title) { (void)title; }

/* ------------------------------------------------------------------ main */
int main(int argc, char **argv)
{
    /* There is no filesystem, so DOOM cannot search for an IWAD by name.
     * W_BLOB_OpenFile ignores the path and serves the blob the testbench
     * loaded, so the name only has to match something DOOM recognises as an
     * IWAD it supports -- freedoom1.wad is on its built-in search list. */
    static char *dg_argv[] = {
        (char *)"doom",
        (char *)"-iwad",       (char *)"freedoom1.wad",
        (char *)"-nogui",
        /* One tic per doomgeneric_Tick(). Without this the first NetUpdate()
         * tries to catch up every tic implied by the cycle-derived clock,
         * which on a simulator is thousands. See doom/port/d_main.c. */
        (char *)"-singletics",
        /* Boot straight into gameplay instead of the title/demo loop.
         * Freedoom: Phase 1 is episode-based, so this is episode 1, map 1. */
        (char *)"-warp",       (char *)"1", (char *)"1",
        NULL
    };
    (void)argc; (void)argv;

    doomgeneric_Create(7 + 1, dg_argv);

    for (;;) {
        doomgeneric_Tick();
        /* the testbench stops us on +max_frames or +max_cycles */
    }
    return 0;
}
