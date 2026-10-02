#include <stdint.h>
#define UART (*(volatile uint32_t *)0xFFFFF024u)
#define EXIT (*(volatile uint32_t *)0xFFFFF000u)
static void pc(char c){ UART=(uint32_t)(unsigned char)c; }
static void ps(const char*s){ while(*s) pc(*s++); }
/* hex only -- no division, so this cannot perturb the divide under test */
static void ph(uint32_t v){ ps("0x"); for(int i=28;i>=0;i-=4){unsigned d=(v>>i)&15;
    pc((char)(d<10?'0'+d:'a'+d-10));} }

static volatile int  va, vb;
static volatile unsigned int ua, ub;
static int fails;

static void t_sdiv(const char*tag,int a,int b,int want)
{ int got; va=a; vb=b; got=va/vb;
  ps(tag); ps("  sdiv a="); ph((uint32_t)a); ps(" b="); ph((uint32_t)b);
  ps(" -> "); ph((uint32_t)got);
  if(got!=want){ ps("  *** WRONG want "); ph((uint32_t)want); fails++; }
  ps("\n"); }

static void t_udiv(const char*tag,unsigned a,unsigned b,unsigned want)
{ unsigned got; ua=a; ub=b; got=ua/ub;
  ps(tag); ps("  divu a="); ph(a); ps(" b="); ph(b);
  ps(" -> "); ph(got);
  if(got!=want){ ps("  *** WRONG want "); ph(want); fails++; }
  ps("\n"); }

static void t_rem(const char*tag,int a,int b,int want)
{ int got; va=a; vb=b; got=va%vb;
  ps(tag); ps("  rem  a="); ph((uint32_t)a); ps(" b="); ph((uint32_t)b);
  ps(" -> "); ph((uint32_t)got);
  if(got!=want){ ps("  *** WRONG want "); ph((uint32_t)want); fails++; }
  ps("\n"); }

int main(void)
{
    ps("=== rv32im DIV/DIVU/REM probe (hex, no division in the printer) ===\n");
    t_sdiv("eq  ", 320, 320, 1);
    t_sdiv("eq  ", 200, 200, 1);
    t_sdiv("eq  ",   1,   1, 1);
    t_sdiv("eq  ", 65536, 65536, 1);
    t_sdiv("p2  ", 640, 320, 2);
    t_sdiv("gen ", 100,  10, 10);
    t_sdiv("gen ",   7,   2, 3);
    t_sdiv("gen ",  10,   3, 3);
    t_sdiv("neg ",  -7,   2, -3);
    t_sdiv("neg ", -10,   3, -3);
    t_udiv("eq  ", 320u, 320u, 1u);
    t_udiv("gen ", 100u,  10u, 10u);
    t_udiv("gen ",   9u,   3u, 3u);
    t_rem("gen ",  10,   3, 1);
    t_rem("eq  ", 320, 320, 0);
    ps("--- RISC-V spec corner cases ---\n");
    t_udiv("d/0 ",   5u,  0u, 0xFFFFFFFFu);   /* spec: 2^L - 1 */
    t_sdiv("d/0 ",   5,   0, -1);             /* spec: -1 */
    t_rem ("r/0 ",   5,   0,  5);             /* spec: dividend */
    t_sdiv("ovfl", (int)0x80000000, -1, (int)0x80000000);  /* spec: -2^31 */
    t_rem ("ovfl", (int)0x80000000, -1, 0);
    ps("--- result ---\n");
    ps(fails ? "FAILURES: " : "all divide results correct\n");
    if (fails) { ph((uint32_t)fails); ps("\n"); }
    EXIT = fails ? 1u : 0u;
    return 0;
}
