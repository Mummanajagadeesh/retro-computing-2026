/* shim.c -- tiny libc shims for the RunCPM port (freestanding, no libc).
 * console.c already provides memset/memcpy/memmove; this file adds the
 * string/ctype bits RunCPM's core uses. No malloc anywhere (USE_PUN and
 * USE_LST are undefined, killing the one calloc).
 */
#ifndef USE_PICOLIBC
#include <stdarg.h>
#include <stdint.h>
#include "../common/console.h"

/* time stubs for cpm.h's BDOS 104/105 date code (unreachable under
 * CP/M 2.2). time() is uptime seconds (not epoch); mktime() is a
 * fixed constant. Both only need to compile+link, never run. */
typedef long time_t;
time_t time(time_t *t)
{
    time_t now = (time_t)(ticks_ms() / 1000);
    if (t)
        *t = now;
    return now;
}
time_t mktime(void *tm)
{
    (void)tm;
    return 252504000L; /* 1978-01-01 noon UTC */
}
struct tm {
    int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year;
    int tm_wday, tm_yday, tm_isdst;
    long tm_gmtoff;
    const char *tm_zone;
};
struct tm *localtime(time_t *t)
{
    static struct tm s;
    (void)t;
    return &s;
}

typedef __SIZE_TYPE__ size_t;

size_t strlen(const char *s)
{
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

/* RunCPM uses size_t-less prototypes via its own headers; keep standard. */

char *strcpy(char *d, const char *s)
{
    char *r = d;
    while ((*d++ = *s++)) {}
    return r;
}

char *strncpy(char *d, const char *s, size_t n)
{
    char *r = d;
    while (n--) {
        if (!(*d++ = *s++)) break;
    }
    return r;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
    while (n--) {
        if (*a != *b || !*a)
            return (int)(unsigned char)*a - (int)(unsigned char)*b;
        a++; b++;
    }
    return 0;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *p = a, *q = b;
    while (n--) {
        if (*p != *q) return (int)*p - (int)*q;
        p++; q++;
    }
    return 0;
}

int toupper(int c)
{
    if (c >= 'a' && c <= 'z') return c - 32;
    return c;
}

int tolower(int c)
{
    if (c >= 'A' && c <= 'Z') return c + 32;
    return c;
}

int isdigit(int c) { return c >= '0' && c <= '9'; }
int isxdigit(int c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
           (c >= 'A' && c <= 'F');
}
int isspace(int c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' ||
           c == '\f' || c == '\v';
}

/* Minimal sprintf: %c %s %d %i %u %x %X, l/ll length, %%.
 * No width/precision/padding (no ungated RunCPM caller uses any:
 * cpu_mhz.h wants %llu/%u, ccp.h wants %c/%u). 64-bit division
 * resolves via libgcc (build.sh links -lgcc). */
static char *put_u64(char *p, unsigned long long v, int base, int upper)
{
    char tmp[24];
    int n = 0;
    const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (!v)
        tmp[n++] = '0';
    while (v) {
        tmp[n++] = dig[v % (unsigned)base];
        v /= (unsigned)base;
    }
    while (n--)
        *p++ = tmp[n];
    return p;
}

int sprintf(char *s, const char *f, ...)
{
    va_list ap;
    char *p = s;
    va_start(ap, f);
    while (*f) {
        if (*f != '%') {
            *p++ = *f++;
            continue;
        }
        f++;
        {
            int lng = 0;
            if (*f == 'l') {
                lng = 1;
                f++;
                if (*f == 'l') {
                    lng = 2;
                    f++;
                }
            }
            switch (*f++) {
            case '%':
                *p++ = '%';
                break;
            case 'c':
                *p++ = (char)va_arg(ap, int);
                break;
            case 's': {
                const char *q = va_arg(ap, const char *);
                while (*q)
                    *p++ = *q++;
                break;
            }
            case 'd':
            case 'i': {
                long long v = lng ? va_arg(ap, long long) :
                                    (long long)va_arg(ap, int);
                if (v < 0) {
                    *p++ = '-';
                    v = -v;
                }
                p = put_u64(p, (unsigned long long)v, 10, 0);
                break;
            }
            case 'u': {
                unsigned long long v = lng ? va_arg(ap, unsigned long long) :
                    (unsigned long long)va_arg(ap, unsigned);
                p = put_u64(p, v, 10, 0);
                break;
            }
            case 'x': {
                unsigned long long v = lng ? va_arg(ap, unsigned long long) :
                    (unsigned long long)va_arg(ap, unsigned);
                p = put_u64(p, v, 16, 0);
                break;
            }
            case 'X': {
                unsigned long long v = lng ? va_arg(ap, unsigned long long) :
                    (unsigned long long)va_arg(ap, unsigned);
                p = put_u64(p, v, 16, 1);
                break;
            }
            default:
                *p++ = '?';
                break;
            }
        }
    }
    va_end(ap);
    *p = 0;
    return (int)(p - s);
}

#endif