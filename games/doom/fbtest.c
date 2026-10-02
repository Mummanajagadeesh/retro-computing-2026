#include <stdint.h>
#define MMIO 0xFFFFF000u
#define MM_UART (*(volatile uint32_t *)(MMIO+0x024))
#define MM_DUMP (*(volatile uint32_t *)(MMIO+0x028))
#define MM_EXIT (*(volatile uint32_t *)(MMIO+0x000))
#define MM_CYC  (*(volatile uint32_t *)(MMIO+0x004))
#define MM_INS  (*(volatile uint32_t *)(MMIO+0x00C))
#define FB 0xFFF00000u
static void ph(uint32_t v){static const char d[]="0123456789abcdef";for(int i=28;i>=0;i-=4)MM_UART=(uint32_t)d[(v>>i)&0xF];}
static void ps(const char*s){for(;*s;++s)MM_UART=(uint32_t)(uint8_t)*s;}
int main(void){
    volatile uint32_t *fb=(volatile uint32_t*)FB;
    /* 1. write distinct values to 4 separate words */
    fb[0]=0xAABBCCDDu; fb[1]=0x11223344u; fb[5]=0xDEADBEEFu; fb[15999]=0x01020304u;
    ps("\n[fbtest] wrote 4 words\n");
    /* 2. read them back */
    ps("[fbtest] rb fb[0]=");     ph(fb[0]);
    ps(" fb[1]=");                ph(fb[1]);
    ps(" fb[5]=");                ph(fb[5]);
    ps(" fb[15999]=");            ph(fb[15999]);
    ps("\n");
    /* 3. counter readback coherence */
    ps("[fbtest] cyc="); ph(MM_CYC); ps(" ins="); ph(MM_INS); ps("\n");
    /* 4. byte-lane test: write single bytes */
    ((volatile uint8_t*)FB)[100]=0x7E;
    ps("[fbtest] byte rb [100]="); ph(((volatile uint8_t*)FB)[100]); ps("\n");
    MM_DUMP=1u;
    MM_EXIT=0u;
    for(;;);
}
