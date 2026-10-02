#include <stdint.h>
#define UART (*(volatile uint32_t *)0xFFFFF024u)
#define EXIT (*(volatile uint32_t *)0xFFFFF000u)
static void pc(char c){ UART=(uint32_t)(unsigned char)c; }
static void ps(const char*s){ while(*s) pc(*s++); }
static void ph(uint32_t v){ ps("0x"); for(int i=28;i>=0;i-=4){unsigned d=(v>>i)&15;
    pc((char)(d<10?'0'+d:'a'+d-10));} }

static volatile uint32_t ua, ub;
static int fails;

static uint32_t mulhu(uint32_t a,uint32_t b){ ua=a; ub=b;
    __asm__ volatile("mulhu %0,%1,%2":"=r"(a):"r"(ua),"r"(ub)); return a; }
static uint32_t mul(uint32_t a,uint32_t b){ ua=a; ub=b;
    __asm__ volatile("mul %0,%1,%2":"=r"(a):"r"(ua),"r"(ub)); return a; }
static int32_t mulh(int32_t a,int32_t b){ ua=(uint32_t)a; ub=(uint32_t)b;
    __asm__ volatile("mulh %0,%1,%2":"=r"(a):"r"(ua),"r"(ub)); return a; }
static uint32_t divu(uint32_t a,uint32_t b){ ua=a; ub=b;
    __asm__ volatile("divu %0,%1,%2":"=r"(a):"r"(ua),"r"(ub)); return a; }

static void chk(const char*tag,uint32_t a,uint32_t b,uint32_t got,uint32_t want)
{ ps(tag); ps(" a="); ph(a); ps(" b="); ph(b); ps(" -> "); ph(got);
  if(got!=want){ ps("  *** WRONG want "); ph(want); fails++; } ps("\n"); }

int main(void)
{
    ps("=== M-extension probe ===\n");
    /* what the compiler emits for x/320:  mulhu x, C;  srl x, k  */
    /* NOTE: 0xCCCCCCCCD does not fit in 32 bits, so it cannot be a mulhu
     * operand. gcc's constant-division sequence for /320 is
     * `mulhu r, x, 0xCCCCCCCCD' on rv64 but on rv32 it emits a different
     * sequence; what matters here is that mulhu itself is exact. */
    chk("mulhu", 320u, 0x88888889u, mulhu(320u,0x88888889u),
        (uint32_t)((320ULL * 0x88888889ULL) >> 32));
    chk("mulhu", 12345u, 67890u, mulhu(12345u,67890u),
        (uint32_t)((12345ULL * 67890ULL) >> 32));
    chk("mulhu",   1u, 0x80000000u, mulhu(1u,0x80000000u),
        (uint32_t)((1ULL*0x80000000ULL)>>32));
    chk("mulhu",   2u, 0x80000000u, mulhu(2u,0x80000000u),
        (uint32_t)((2ULL*0x80000000ULL)>>32));
    chk("mulhu", 0xFFFFFFFFu,0xFFFFFFFFu, mulhu(0xFFFFFFFFu,0xFFFFFFFFu),
        (uint32_t)((0xFFFFFFFFULL*0xFFFFFFFFULL)>>32));
    chk("mulhu", 65536u, 65536u, mulhu(65536u,65536u),
        (uint32_t)((65536ULL*65536ULL)>>32));
    chk("mul  ", 320u, 320u, mul(320u,320u), 102400u);
    chk("mul  ", 0x12345u, 0x6789Au, mul(0x12345u,0x6789Au), 0x12345u*0x6789Au);
    chk("mulh ", (uint32_t)-7, 3u, (uint32_t)mulh(-7,3), 0xFFFFFFFFu);  /* hi(-21) */
    chk("mulh ", 0x40000000u, 4u, (uint32_t)mulh(0x40000000,4), 0x00000001u);
    ps("--- the failing divide, both ways ---\n");
    chk("divu ", 320u, 320u, divu(320u,320u), 1u);
    { volatile uint32_t v = 320u;
      chk("v/320", v, 320u, v/320u, 1u);          /* compiler: mulhu+srl */
      chk("v/256", v, 256u, v/256u, 1u);          /* compiler: srl only   */
      chk("v/3  ", v, 3u,   v/3u,   106u);        /* compiler: mulhu+srl  */
    }
    ps("--- result ---\n");
    if (fails) { ps("FAILURES: "); ph((uint32_t)fails); ps("\n"); }
    else ps("all M-extension results correct\n");
    EXIT = fails?1u:0u; return 0;
}
