#include <stdint.h>
#define UART (*(volatile uint32_t *)0xFFFFF024u)
#define EXIT (*(volatile uint32_t *)0xFFFFF000u)
static void pc(char c){ UART=(uint32_t)(unsigned char)c; }
static void ps(const char*s){ while(*s) pc(*s++); }
static void ph(uint32_t v){ ps("0x"); for(int i=28;i>=0;i-=4){unsigned d=(v>>i)&15;
    pc((char)(d<10?'0'+d:'a'+d-10));} }

static volatile uint32_t A, B;
static uint32_t do_mulhu(void){ uint32_t r; __asm__("mulhu %0,%1,%2":"=r"(r):"r"(A),"r"(B)); return r; }
static uint32_t do_mul(void)  { uint32_t r; __asm__("mul   %0,%1,%2":"=r"(r):"r"(A),"r"(B)); return r; }

int main(void)
{
    A = 320u; B = 0x88888889u;
    ps("A="); ph(A); ps(" B="); ph(B); ps("\n");
    ps("mul   -> "); ph(do_mul());   ps("   (want 0x11111_1120 truncated = 0x11111120)\n");
    ps("mulhu -> "); ph(do_mulhu()); ps("   (want 0x000000aa)\n");
    A = 0xFFFFFFFFu; B = 0xFFFFFFFFu;
    ps("A="); ph(A); ps(" B="); ph(B); ps("\n");
    ps("mulhu -> "); ph(do_mulhu()); ps("   (want 0xfffffffe)\n");
    A = 0x12345678u; B = 0x9ABCDEF0u;
    ps("mulhu -> "); ph(do_mulhu()); ps("   (want 0x0b66f6a4)\n");
    EXIT=0; return 0;
}
