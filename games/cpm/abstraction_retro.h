/* abstraction_retro.h -- RunCPM platform layer for the retro_fpga console.
 *
 * Console on the game ABI (key_poll/print via <retro_console.h>), time on
 * ticks_ms(), disk as a RAM disk in SDRAM preloaded from the _wad_start
 * blob by _HardwareInit. Single drive A:, user 0. Semantics mirror
 * abstraction_arduino.h; see PORT.md.
 */
#ifndef ABSTRACT_H
#define ABSTRACT_H

#include <retro_console.h>
#ifdef MENU_BUILD
#include "menu/menu_blob.h"
#endif
/* NOTE: no ctype.h on this freestanding target; the one ctype
   call the core needs is provided by shim.c. */
int toupper(int c);
#include <stdbool.h>
#include <stddef.h> /* size_t: compiler-provided, no libc on target */
/* string bits the core uses; implemented in shim.c / console.c */
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
void *memset(void *d, int c, size_t n);
void *memcpy(void *d, const void *s, size_t n);

/* sprintf is used by cpu_mhz.h + ccp.h (prompt). Declared manually so no
 * hosted stdio.h is needed; defined in shim.c (target) / libc (harness). */
int sprintf(char *s, const char *f, ...);
/* time: cpm.h date calls need struct tm/time/mktime to compile+link.
 * Unreachable under CP/M 2.2 (internal CCP never issues BDOS 104/105).
 * Layout matches glibc so the host harness stays compatible. */
struct tm {
    int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year;
    int tm_wday, tm_yday, tm_isdst;
    long tm_gmtoff;
    const char *tm_zone;
};
typedef long time_t;
time_t time(time_t *t);
time_t mktime(struct tm *tm);
struct tm *localtime(time_t *t);
#define calloc(n, s) (rd_calloc_pool)
static uint8 rd_calloc_pool[256];

/* CP/M directory structures (all backends define these for disk.h) */
typedef struct {
    uint8 dr;
    uint8 fn[8];
    uint8 tp[3];
    uint8 ex, s1, s2, rc;
    uint8 al[16];
    uint8 cr, r0, r1, r2;
} CPM_FCB;

typedef struct {
    uint8 dr;
    uint8 fn[8];
    uint8 tp[3];
    uint8 ex, s1, s2, rc;
    uint8 al[16];
} CPM_DIRENTRY;

#define HostOS 0x50
#define FOLDERCHAR '/'
#define FILEBASE ""

/* time (cpu Delay path uses usleep when ARDUINO is undefined) */
#define millis() (ticks_ms())
#define usleep(us) sleep_ms((us) / 1000)
#define delay(ms) sleep_ms(ms)

/* ------------------------------------------------------------ console */
void _console_init(void)
{
}

void _console_reset(void)
{
}

static char cpm_term_lines[4][17];
static int cpm_term_cx = 0, cpm_term_cy = 0;

static void cpm_term_render(void)
{
    fb_clear(C_BLACK);
    /* Top status header */
    fb_rect(0, 0, 64, 6, C_DKGRAY);
    fb_text(2, 0, "* RUNCPM Z80 *", C_YELLOW);
    for (int r = 0; r < 4; r++) {
        fb_text(1, 7 + r * 6, cpm_term_lines[r], C_GREEN);
    }
    /* Cursor block */
    fb_px(1 + cpm_term_cx * 4, 7 + cpm_term_cy * 6 + 4, C_WHITE);
    dump_tiny();
}

void _putch(uint8 ch)
{
    con_putc((char)ch);
    char c = (char)ch;
    if (c == '\r') {
        cpm_term_cx = 0;
    } else if (c == '\n') {
        cpm_term_cx = 0;
        if (cpm_term_cy < 3) {
            cpm_term_cy++;
        } else {
            for (int r = 0; r < 3; r++) {
                memcpy(cpm_term_lines[r], cpm_term_lines[r + 1], 17);
            }
            memset(cpm_term_lines[3], 0, 17);
        }
    } else if (c == '\b') {
        if (cpm_term_cx > 0) {
            cpm_term_cx--;
            cpm_term_lines[cpm_term_cy][cpm_term_cx] = 0;
        }
    } else if (c >= 32 && c < 127) {
        if (cpm_term_cx < 15) {
            cpm_term_lines[cpm_term_cy][cpm_term_cx++] = c;
            cpm_term_lines[cpm_term_cy][cpm_term_cx] = 0;
        }
    }
    cpm_term_render();
}

/* The key register holds ONE event and key_poll consumes it, so _kbhit
 * needs a 1-deep peek buffer or the char it sees would be lost. */
static int rd_have_peek = 0;
static uint8 rd_peek_ch = 0;

int _kbhit(void)
{
    int p;
    uint8_t c;
    if (rd_have_peek)
        return 1;
    if (key_poll(&p, &c) && p && c) {
        rd_have_peek = 1;
        rd_peek_ch = (uint8)c;
        return 1;
    }
    return 0;
}

uint8 _getch(void)
{
    int p;
    uint8_t c;
    if (rd_have_peek) {
        rd_have_peek = 0;
        return rd_peek_ch;
    }
    for (;;) {
        if (key_poll(&p, &c) && p && c)
            return (uint8)c;
        cpm_term_render();
        sleep_ms(22);
    }
}

uint8 _getche(void)
{
    uint8 c = _getch();
    _putch(c);
    return c;
}

void _clrscr(void)
{
    memset(cpm_term_lines, 0, sizeof(cpm_term_lines));
    cpm_term_cx = 0; cpm_term_cy = 0;
    cpm_term_render();
}

/* ----------------------------------------------------------- RAM disk */
#define RD_MAXFILES 96
#define RD_ARENA_SZ (2u * 1024u * 1024u)

typedef struct {
    uint8 name[11]; /* 8+3, upper case, space padded */
    uint8 used;
    uint32 len;
    uint32 cap;
    uint32 off;
} rd_file_t;

static rd_file_t rd_tab[RD_MAXFILES];
static uint8 rd_arena[RD_ARENA_SZ];
static uint32 rd_brk = 0;

/* "D/U/NAME.EXT" or "NAME.EXT" -> 8+3 upper padded */
static int rd_parse(const uint8 *path, uint8 *out11)
{
    const uint8 *p = path;
    int i;
    if (p[0] && p[1] == (uint8)FOLDERCHAR)
        p += 4; /* skip D/U/ */
    for (i = 0; i < 11; i++)
        out11[i] = ' ';
    i = 0;
    while (*p && *p != '.' && i < 8) {
        uint8 c = *p++;
        if (c >= 'a' && c <= 'z')
            c -= 32;
        out11[i++] = c;
    }
    if (*p == '.')
        p++;
    i = 8;
    while (*p && i < 11) {
        uint8 c = *p++;
        if (c >= 'a' && c <= 'z')
            c -= 32;
        out11[i++] = c;
    }
    return 1;
}

static int rd_cmp11(const uint8 *a, const uint8 *b)
{
    int i;
    for (i = 0; i < 11; i++)
        if (a[i] != b[i])
            return 0;
    return 1;
}

static int rd_find(const uint8 *path)
{
    uint8 n[11];
    int i;
    rd_parse(path, n);
    for (i = 0; i < RD_MAXFILES; i++)
        if (rd_tab[i].used && rd_cmp11(rd_tab[i].name, n))
            return i;
    return -1;
}

static int rd_alloc(uint32 cap)
{
    uint32 o;
    if (cap == 0)
        cap = 4096;
    if (rd_brk + cap > RD_ARENA_SZ)
        return -1;
    o = rd_brk;
    rd_brk += cap;
    return (int)o;
}

static int rd_create(const uint8 *n11, uint32 cap)
{
    int i, o;
    for (i = 0; i < RD_MAXFILES; i++)
        if (!rd_tab[i].used)
            break;
    if (i == RD_MAXFILES)
        return -1;
    o = rd_alloc(cap);
    if (o < 0)
        return -1;
    for (cap = 0; cap < 11; cap++)
        rd_tab[i].name[cap] = n11[cap];
    rd_tab[i].used = 1;
    rd_tab[i].len = 0;
    rd_tab[i].cap = (o >= 0) ? (rd_brk - (uint32)o) : 0;
    rd_tab[i].off = (uint32)o;
    return i;
}

/* ensure capacity, relocating the file within the arena if needed */
static int rd_grow(int idx, uint32 need)
{
    uint32 ncap, k;
    int o;
    if (need <= rd_tab[idx].cap)
        return 0;
    ncap = (need + 4095u) & ~4095u;
    o = rd_alloc(ncap);
    if (o < 0)
        return -1;
    for (k = 0; k < rd_tab[idx].len; k++)
        rd_arena[o + k] = rd_arena[rd_tab[idx].off + k];
    rd_tab[idx].off = (uint32)o;
    rd_tab[idx].cap = ncap;
    return 0;
}

uint16 _RamLoad(uint8 *filename, uint16 address, uint16 maxsize)
{
    int idx = rd_find(filename);
    uint32 len, k;
    if (idx < 0)
        return 0;
    len = rd_tab[idx].len;
    if (maxsize && len > (uint32)maxsize)
        len = maxsize;
    for (k = 0; k < len; k++)
        _RamWrite((uint16)(address + k), rd_arena[rd_tab[idx].off + k]);
    return (uint16)len;
}

bool _sys_exists(uint8 *filename)
{
    return rd_find(filename) >= 0;
}

long _sys_filesize(uint8 *filename)
{
    int idx = rd_find(filename);
    if (idx < 0)
        return -1;
    return (long)rd_tab[idx].len;
}

int _sys_openfile(uint8 *filename)
{
    return rd_find(filename) >= 0 ? 1 : 0;
}

int _sys_makefile(uint8 *filename)
{
    uint8 n[11];
    if (rd_find(filename) >= 0)
        return 1; /* like SD O_WRITE: keep existing content */
    rd_parse(filename, n);
    return rd_create(n, 4096) >= 0 ? 1 : 0;
}

int _sys_deletefile(uint8 *filename)
{
    int idx = rd_find(filename);
    if (idx < 0)
        return 0;
    rd_tab[idx].used = 0; /* arena space leaks; reboot restores */
    return 1;
}

int _sys_renamefile(uint8 *filename, uint8 *newname)
{
    int idx = rd_find(filename);
    uint8 n[11];
    int k;
    if (idx < 0)
        return 0;
    rd_parse(newname, n);
    for (k = 0; k < 11; k++)
        rd_tab[idx].name[k] = n[k];
    return 1;
}

uint8 _Truncate(char *filename, uint8 rc)
{
    int idx = rd_find((uint8 *)filename);
    uint32 nl;
    if (idx < 0)
        return 0;
    nl = (uint32)rc * BlkSZ;
    if (nl < rd_tab[idx].len)
        rd_tab[idx].len = nl;
    return 1;
}

bool _sys_extendfile(char *fn, unsigned long fpos)
{
    int idx = rd_find((uint8 *)fn);
    uint8 n[11];
    uint32 k;
    if (idx < 0) {
        rd_parse((uint8 *)fn, n);
        idx = rd_create(n, 4096);
        if (idx < 0)
            return false;
    }
    if ((unsigned long)rd_tab[idx].len < fpos) {
        if (rd_grow(idx, (uint32)fpos))
            return false;
        for (k = rd_tab[idx].len; k < (uint32)fpos; k++)
            rd_arena[rd_tab[idx].off + k] = 0;
        rd_tab[idx].len = (uint32)fpos;
    }
    return true;
}

uint8 _sys_readseq(uint8 *filename, long fpos)
{
    int idx = rd_find(filename);
    uint32 avail = 0, k;
    if (idx < 0)
        return 0x10;
    if (fpos < 0)
        fpos = 0;
    if ((uint32)fpos < rd_tab[idx].len) {
        avail = rd_tab[idx].len - (uint32)fpos;
        if (avail > BlkSZ)
            avail = BlkSZ;
    }
    for (k = 0; k < BlkSZ; k++)
        _RamWrite(dmaAddr + k, k < avail ?
                  rd_arena[rd_tab[idx].off + (uint32)fpos + k] : 0x1a);
    return avail ? 0x00 : 0x01;
}

uint8 _sys_readrand(uint8 *filename, long fpos)
{
    int idx = rd_find(filename);
    long extSize;
    uint32 avail = 0, k;
    if (idx < 0)
        return 0x10;
    if (fpos >= 65536L * BlkSZ)
        return 0x06;
    if (fpos < 0)
        fpos = 0;
    if ((uint32)fpos > rd_tab[idx].len) {
        extSize = ExtSZ * ((rd_tab[idx].len / ExtSZ) +
                           ((rd_tab[idx].len % ExtSZ) ? 1 : 0));
        return (fpos < extSize) ? 0x01 : 0x04;
    }
    avail = rd_tab[idx].len - (uint32)fpos;
    if (avail > BlkSZ)
        avail = BlkSZ;
    for (k = 0; k < BlkSZ; k++)
        _RamWrite(dmaAddr + k, k < avail ?
                  rd_arena[rd_tab[idx].off + (uint32)fpos + k] : 0x1a);
    return avail ? 0x00 : 0x01;
}

uint8 _sys_writeseq(uint8 *filename, long fpos)
{
    int idx;
    uint32 k;
    uint8 *src;
    if (!_sys_extendfile((char *)filename, (unsigned long)fpos))
        return 0x10;
    idx = rd_find(filename);
    if (idx < 0)
        return 0x10;
    if (fpos < 0)
        fpos = 0;
    if (rd_grow(idx, (uint32)fpos + BlkSZ))
        return 0x01;
    src = _RamSysAddr(dmaAddr);
    for (k = 0; k < BlkSZ; k++)
        rd_arena[rd_tab[idx].off + (uint32)fpos + k] = src[k];
    if ((uint32)fpos + BlkSZ > rd_tab[idx].len)
        rd_tab[idx].len = (uint32)fpos + BlkSZ;
    return 0x00;
}

uint8 _sys_writerand(uint8 *filename, long fpos)
{
    return _sys_writeseq(filename, fpos);
}

static uint8 findNextDirName[13];
static uint16 fileRecords = 0;
static uint16 fileExtents = 0;
static uint16 fileExtentsUsed = 0;
static uint16 firstFreeAllocBlock = 0;
static int rd_findcursor = 0;

static void rd_hostname(int idx, uint8 *out)
{
    int k, p = 0, e = 0;
    for (k = 0; k < 8; k++)
        if (rd_tab[idx].name[k] != ' ')
            out[p++] = rd_tab[idx].name[k];
    for (k = 8; k < 11; k++)
        if (rd_tab[idx].name[k] != ' ')
            e = 1;
    if (e) {
        out[p++] = '.';
        for (k = 8; k < 11; k++)
            if (rd_tab[idx].name[k] != ' ')
                out[p++] = rd_tab[idx].name[k];
    }
    out[p] = 0;
}

uint8 _findnext(uint8 isdir)
{
    uint32 bytes;
    if (allExtents && fileRecords) {
        _mockupDirEntry(0);
        return 0;
    }
    while (rd_findcursor < RD_MAXFILES) {
        int i = rd_findcursor++;
        if (!rd_tab[i].used)
            continue;
        rd_hostname(i, findNextDirName);
        bytes = rd_tab[i].len;
        _HostnameToFCBname(findNextDirName, fcbname);
        if (match(fcbname, pattern)) {
            if (isdir) {
                if (bytes & (BlkSZ - 1))
                    bytes = (bytes & ~(BlkSZ - 1)) + BlkSZ;
                fileRecords = bytes / BlkSZ;
                fileExtents = fileRecords / BlkEX +
                              ((fileRecords & (BlkEX - 1)) ? 1 : 0);
                fileExtentsUsed = 0;
                firstFreeAllocBlock = firstBlockAfterDir;
                _mockupDirEntry(0);
            } else {
                fileRecords = 0;
                fileExtents = 0;
                fileExtentsUsed = 0;
                firstFreeAllocBlock = firstBlockAfterDir;
            }
            _RamWrite(tmpFCB, filename[0] - '@');
            _HostnameToFCB(tmpFCB, findNextDirName);
            return 0x00;
        }
    }
    return 0xff;
}

uint8 _findfirst(uint8 isdir)
{
    rd_findcursor = 0;
    _HostnameToFCBname(filename, pattern);
    fileRecords = 0;
    fileExtents = 0;
    fileExtentsUsed = 0;
    return _findnext(isdir);
}

uint8 _findnextallusers(uint8 isdir)
{
    currFindUser = 0;
    return _findnext(isdir);
}

uint8 _findfirstallusers(uint8 isdir)
{
    static const char q[12] = "???????????";
    int i;
    for (i = 0; i < 12; i++)
        pattern[i] = (uint8)q[i];
    rd_findcursor = 0;
    fileRecords = 0;
    fileExtents = 0;
    fileExtentsUsed = 0;
    currFindUser = 0;
    return _findnext(isdir);
}

void _MakeUserDir(void)
{
}

uint8 _sys_makedisk(uint8 drive)
{
    return (drive >= 1 && drive <= 16) ? 0 : 0xff;
}

int _sys_select(uint8 *disk)
{
    return (disk[0] == 'A' || disk[0] == 'a') ? TRUE : FALSE;
}

/* ----------------------------------------------------------- hardware */
void _HardwareInit(void)
{
    /* blob: [u16 total][u16 count][name11, u32 len, bytes]... (mkdisk.py) */
#ifdef MENU_BUILD
    const uint8_t *p = menu_disk_base;
#else
    const uint8_t *p = _wad_start;
#endif
    if (!p) return;
    uint16_t total = p[0] | ((uint16_t)p[1] << 8);
    uint16_t count, f;
    (void)total;
    p += 2;
    count = p[0] | ((uint16_t)p[1] << 8);
    p += 2;
    if (count > 512)
        return; /* no blob uploaded: boot with an empty disk */
    if (count > RD_MAXFILES)
        count = RD_MAXFILES; /* load what fits */
    for (f = 0; f < count; f++) {
        uint8 n[11];
        uint32 len;
        int idx, k;
        for (k = 0; k < 11; k++)
            n[k] = p[k];
        p += 11;
        len = (uint32)p[0] | ((uint32)p[1] << 8) |
              ((uint32)p[2] << 16) | ((uint32)p[3] << 24);
        p += 4;
        idx = rd_create(n, (len + 4095u) & ~4095u);
        if (idx >= 0) {
            for (k = 0; (uint32)k < len; k++)
                rd_arena[rd_tab[idx].off + k] = p[k];
            rd_tab[idx].len = len;
        }
        p += len;
    }
    extern const char *cpm_auto_cmd;
    if (cpm_auto_cmd != 0) {
        int aidx = rd_find((const uint8 *)"AUTOEXEC.TXT");
        if (aidx < 0) {
            uint8 aname[11] = {'A','U','T','O','E','X','E','C','T','X','T'};
            aidx = rd_create(aname, 4096);
        }
        if (aidx >= 0) {
            size_t clen = strlen(cpm_auto_cmd);
            for (size_t c = 0; c < clen; c++)
                rd_arena[rd_tab[aidx].off + c] = (uint8)cpm_auto_cmd[c];
            rd_arena[rd_tab[aidx].off + clen] = '\r';
            rd_arena[rd_tab[aidx].off + clen + 1] = '\n';
            rd_tab[aidx].len = clen + 2;
        }
    }
}

void _HardwareOut(const uint32 Port, const uint32 Value)
{
    (void)Port;
    (void)Value;
}

uint32 _HardwareIn(const uint32 Port)
{
    (void)Port;
    return 0;
}

#endif
