/* mon.c -- machine monitor for the retro_fpga console (rv32im, freestanding).
 *
 * The machine boots into this the way a 1977 machine boots into its
 * monitor ROM: a `*' prompt on the serial console, hex everywhere, no
 * decimal, no menus. Commands:
 *
 *   D addr [count]   hex dump (default 128 bytes); empty line continues
 *   M addr [byte]    examine / deposit one byte
 *   F addr len byte  fill memory
 *   G addr           call address as void f(void)
 *   L                load Motorola S-records (S0/S1/S9, upper or lower
 *                    case, checksummed); end with S9, empty line, or ESC
 *   T                show wall-clock ms + frame counter
 *   H                this help
 *   Q                exit (halts the core; press KEY1 for the bootloader)
 *
 * All numbers are hex. Only RAM [0, 0x02000000) and the MMIO window
 * [0xFFF00000, ...] can be touched; the hole between them is refused
 * because unmapped reads can hang the bus.
 */
#include "../common/console.h"

#ifdef MENU_BUILD
#define main mon_main
#define sys_exit(c) return (c)
#endif


static void echoc(char c)
{
    char b[2];
    b[0] = c;
    b[1] = 0;
    print(b);
}

static void newline(void)
{
    print("\n");
}

/* blocking key: press events only, releases ignored */
static uint8_t conget(void)
{
    for (;;) {
        int p;
        uint8_t c;
        if (key_poll(&p, &c) && p && c)
            return c;
    }
}

/* line editor: echo, backspace (BS/DEL), Enter ends, ESC aborts (0 len + esc) */
static int getline(char *buf, int max, int *esc)
{
    int n = 0;
    *esc = 0;
    for (;;) {
        uint8_t c = conget();
        if (c == 27) {              /* ESC */
            *esc = 1;
            return n;
        }
        if (c == 13 || c == 10) {   /* Enter */
            newline();
            buf[n] = 0;
            return n;
        }
        if (c == 8 || c == 127) {   /* backspace */
            if (n > 0) {
                n--;
                print("\010 \010");
            }
            continue;
        }
        if (c < 32 || c > 126)
            continue;
        if (n < max - 1) {
            buf[n++] = (char)c;
            echoc((char)c);
        }
    }
}

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* parse hex number; *pp advanced past it. ok=0 on failure. */
static uint32_t gethex(const char **pp, int *ok)
{
    const char *p = *pp;
    uint32_t v = 0;
    int digits = 0;
    while (*p == ' ' || *p == '\t') p++;
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
    for (;;) {
        int h = hexval(*p);
        if (h < 0) break;
        v = (v << 4) | (uint32_t)h;
        digits++;
        p++;
    }
    *pp = p;
    *ok = digits > 0;
    return v;
}

static int mapped(uint32_t a)
{
    return a < 0x02000000u || a >= 0xFFF00000u;
}

static void dump(uint32_t addr, uint32_t count)
{
    uint32_t end = addr + count;
    if (end < addr) end = 0xFFFFFFFFu;
    for (; addr < end;) {
        uint32_t row = addr & ~0xFu;
        uint32_t i;
        if (!mapped(row) || !mapped(row + 15)) {
            print("unmapped\n");
            return;
        }
        print_hex(row);
        print("  ");
        for (i = 0; i < 16; i++) {
            uint8_t b = *(volatile uint8_t *)(row + i);
            echoc("0123456789abcdef"[b >> 4]);
            echoc("0123456789abcdef"[b & 15]);
            echoc(i == 7 ? '-' : ' ');
        }
        print(" ");
        for (i = 0; i < 16; i++) {
            uint8_t b = *(volatile uint8_t *)(row + i);
            echoc((b >= 32 && b < 127) ? (char)b : '.');
        }
        newline();
        addr = row + 16;
        if (addr == 0) break;   /* wrapped past 0xFFFFFFFF */
    }
}

/* S-record loader. Returns bytes loaded, or -1 on abort. */
static int32_t sload(void)
{
    char line[160];
    uint32_t total = 0, errors = 0, lineno = 0;
    print("S-records, end with S9 / empty line / ESC\n");
    for (;;) {
        int esc, n, i, ok = 1;
        int type, count, sum, addr;
        n = getline(line, sizeof(line), &esc);
        if (esc) {
            print("aborted\n");
            return -1;
        }
        if (n == 0)
            break;
        lineno++;
        if ((line[0] != 's' && line[0] != 'S') || n < 10) {
            print("L"); print_dec(lineno); print(": bad line\n");
            errors++;
            continue;
        }
        type = line[1] | 32;
        count = hexval(line[2]) * 16 + hexval(line[3]);
        addr = (hexval(line[4]) << 12) | (hexval(line[6]) << 8) |
               (hexval(line[8]) << 4) | hexval(line[9]);
        if (count < 3 || n < 4 + count * 2) ok = 0;
        sum = count + ((addr >> 8) & 0xFF) + (addr & 0xFF);
        for (i = 0; ok && i < count - 2; i++) {
            int h0 = hexval(line[10 + i * 2]);
            int h1 = hexval(line[11 + i * 2]);
            if (h0 < 0 || h1 < 0) { ok = 0; break; }
            sum += h0 * 16 + h1;
        }
        if (ok && ((sum & 0xFF) != 0xFF)) ok = 0;
        if (!ok) {
            print("L"); print_dec(lineno); print(": checksum\n");
            errors++;
            continue;
        }
        if (type == '9' || type == '8' || type == '7')
            break;  /* end record */
        if (type != '1' && type != '0')
            continue;  /* ignore anything else */
        for (i = 0; i < count - 3; i++) {
            uint8_t b = (uint8_t)(hexval(line[10 + i * 2]) * 16 +
                                  hexval(line[11 + i * 2]));
            uint32_t a = (uint32_t)addr + (uint32_t)i;
            if (type == '1') {
                if (!mapped(a)) {
                    print("L"); print_dec(lineno); print(": unmapped\n");
                    errors++;
                    break;
                }
                *(volatile uint8_t *)a = b;
                total++;
            }
        }
    }
    print("loaded "); print_dec(total);
    print(" bytes, "); print_dec(errors); print(" errors\n");
    return (int32_t)total;
}

static void help(void)
{
    print("D addr [n]  dump    M addr [b]  exam/dep  F a n b  fill\n");
    print("G addr      call    L           S-records T        ticks\n");
    print("H           help    Q           exit      (all hex)\n");
}

int main(void)
{
    char line[80];
    uint32_t last_dump = 0;
    int have_last = 0;

    fb_clear(C_BLACK);
    fb_text(2, 2, "RV32IM MONITOR", C_GREEN);
    fb_text(2, 12, "SEE SERIAL", C_GRAY);
    dump_tiny();

    print("\nRV32IM machine monitor\n");
    help();
    for (;;) {
        const char *p;
        int esc, cmd;
        print("*");
        (void)getline(line, sizeof(line), &esc);
        if (esc) {
            newline();
            continue;
        }
        p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) {  /* empty line: continue last dump */
            if (have_last) {
                dump(last_dump, 128);
                last_dump += 128;
            }
            continue;
        }
        cmd = *p | 32;
        p++;
        if (cmd == 'h' || cmd == '?') {
            help();
        } else if (cmd == 'q') {
            print("halt\n");
            sys_exit(0);
        } else if (cmd == 't') {
            print("ms "); print_dec(ticks_ms());
            print(" frames "); print_dec(frames());
            newline();
        } else if (cmd == 'l') {
            (void)sload();
        } else if (cmd == 'd' || cmd == 'm' || cmd == 'f' || cmd == 'g') {
            int ok;
            uint32_t a = gethex(&p, &ok);
            if (!ok) {
                print("?\n");
                continue;
            }
            if (!mapped(a) || (cmd != 'm' && !mapped(a))) {
                print("unmapped\n");
                continue;
            }
            if (cmd == 'd') {
                uint32_t n = gethex(&p, &ok);
                if (!ok) n = 128;
                dump(a, n);
                last_dump = a + n;
                have_last = 1;
            } else if (cmd == 'm') {
                uint32_t b = gethex(&p, &ok);
                if (ok) {
                    if (a >= 0xFFF00000u)
                        print("(mmio!) ");
                    *(volatile uint8_t *)a = (uint8_t)b;
                }
                print_hex(a);
                print(": ");
                echoc("0123456789abcdef"
                      [(*(volatile uint8_t *)a >> 4) & 15]);
                echoc("0123456789abcdef"
                      [*(volatile uint8_t *)a & 15]);
                newline();
            } else if (cmd == 'f') {
                uint32_t n = gethex(&p, &ok);
                uint32_t b;
                if (!ok) { print("?\n"); continue; }
                b = gethex(&p, &ok);
                if (!ok) { print("?\n"); continue; }
                if (a >= 0xFFF00000u)
                    print("(mmio!) ");
                for (uint32_t i = 0; i < n; i++) {
                    if (!mapped(a + i)) {
                        print("unmapped\n");
                        break;
                    }
                    *(volatile uint8_t *)(a + i) = (uint8_t)b;
                }
            } else {  /* g */
                void (*f)(void) = (void (*)(void))a;
                print("calling ");
                print_hex(a);
                newline();
                f();
                print("returned\n");
            }
        } else {
            print("?\n");
        }
    }
}
