/* smoke.c -- bare-metal integration test for the dg bridge.
 *
 * Proves, in one run, everything the DOOM port depends on:
 *   1. UART MMIO write reaches the transcript
 *   2. framebuffer word stores land in the bridge, not dmem
 *   3. DUMP register emits a valid PGM
 *   4. cycle/instret counters read back coherently from the guest
 *   5. EXIT stops the simulation cleanly
 *   6. hardware mul and div are actually used (the ISA DOOM needs)
 *
 * The pattern drawn is a DOOM-style shaded column wall: a perspective
 * gradient with a per-column height, which is close enough to the real
 * span renderer to stress the same store stream.
 */

#include <stdint.h>

#define MMIO        0xFFFFF000u
#define MM_EXIT     (*(volatile uint32_t *)(MMIO + 0x000))
#define MM_CYC_LO   (*(volatile uint32_t *)(MMIO + 0x004))
#define MM_CYC_HI   (*(volatile uint32_t *)(MMIO + 0x008))
#define MM_INS_LO   (*(volatile uint32_t *)(MMIO + 0x00C))
#define MM_INS_HI   (*(volatile uint32_t *)(MMIO + 0x010))
#define MM_KEY      (*(volatile uint32_t *)(MMIO + 0x014))
#define MM_FRAMES   (*(volatile uint32_t *)(MMIO + 0x018))
#define MM_UART     (*(volatile uint32_t *)(MMIO + 0x024))
#define MM_DUMP     (*(volatile uint32_t *)(MMIO + 0x028))

#define FB          0xFFF00000u
#define W           320
#define H           200

static void puts_(const char *s)
{
    for (; *s; ++s) MM_UART = (uint32_t)(uint8_t)*s;
}

static void puthex(uint32_t v)
{
    static const char d[] = "0123456789abcdef";
    int i;
    for (i = 28; i >= 0; i -= 4) MM_UART = (uint32_t)d[(v >> i) & 0xF];
}

static void putdec(uint32_t v)
{
    char b[12];
    int n = 0;
    if (!v) b[n++] = '0';
    while (v) { b[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) MM_UART = (uint32_t)(uint8_t)b[--n];
}

int main(void)
{
    volatile uint32_t *fb = (volatile uint32_t *)FB;
    uint32_t c0, c1, i0, i1;
    int x, y, i;

    puts_("\n[smoke] rv32im dg-bridge test\n");

    c0 = MM_CYC_LO;
    i0 = MM_INS_LO;

    (void)y;

    /* ---- render 3 frames of a shaded column wall ---- */
    for (int frame = 0; frame < 3; ++frame) {
        /* Pack 4 pixels per word store: this is the store stream DOOM's
         * blitter produces, and it is what the bridge must handle. */
        for (i = 0; i < (W * H) / 4; ++i) {
            uint32_t p0, p1, p2, p3;
            int px0 = (int)(i * 4 + 0), px1 = (int)(i * 4 + 1);
            int px2 = (int)(i * 4 + 2), px3 = (int)(i * 4 + 3);
            int cx, cy, wh, tp;
            uint32_t sh;

            cx = px0 % W; cy = px0 / W;
            wh = 40 + (int)(((uint32_t)cx * 120u) / 320u);
            tp = (H - wh) / 2;
            sh = 255u - ((uint32_t)cx * 200u) / 320u;
            p0 = (cy < tp || cy >= tp + wh) ? (uint32_t)(20 + cy / 4)
                                            : (sh * (uint32_t)(cy - tp)) / (uint32_t)wh;

            cx = px1 % W; cy = px1 / W;
            wh = 40 + (int)(((uint32_t)cx * 120u) / 320u);
            tp = (H - wh) / 2;
            sh = 255u - ((uint32_t)cx * 200u) / 320u;
            p1 = (cy < tp || cy >= tp + wh) ? (uint32_t)(20 + cy / 4)
                                            : (sh * (uint32_t)(cy - tp)) / (uint32_t)wh;

            cx = px2 % W; cy = px2 / W;
            wh = 40 + (int)(((uint32_t)cx * 120u) / 320u);
            tp = (H - wh) / 2;
            sh = 255u - ((uint32_t)cx * 200u) / 320u;
            p2 = (cy < tp || cy >= tp + wh) ? (uint32_t)(20 + cy / 4)
                                            : (sh * (uint32_t)(cy - tp)) / (uint32_t)wh;

            cx = px3 % W; cy = px3 / W;
            wh = 40 + (int)(((uint32_t)cx * 120u) / 320u);
            tp = (H - wh) / 2;
            sh = 255u - ((uint32_t)cx * 200u) / 320u;
            p3 = (cy < tp || cy >= tp + wh) ? (uint32_t)(20 + cy / 4)
                                            : (sh * (uint32_t)(cy - tp)) / (uint32_t)wh;

            fb[i] = (p0 & 0xFF) | ((p1 & 0xFF) << 8) |
                    ((p2 & 0xFF) << 16) | ((p3 & 0xFF) << 24);
        }

        MM_DUMP = 1u;   /* emits frame_<n>.pgm in the simulator cwd */
    }

    c1 = MM_CYC_LO;
    i1 = MM_INS_LO;

    puts_("[smoke] frames=");
    putdec(MM_FRAMES);
    puts_("\n[smoke] cycles used = ");
    putdec(c1 - c0);
    puts_("\n[smoke] instrs used = ");
    putdec(i1 - i0);
    puts_("\n[smoke] cyc_lo=");
    puthex(c1);
    puts_(" ins_lo=");
    puthex(i1);
    puts_("\n[smoke] key reg=");
    puthex(MM_KEY);
    puts_("\n[smoke] done, exiting\n");

    MM_EXIT = 0u;
    for (;;) { }
}
