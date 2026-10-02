#include <stdint.h>
#define MMIO 0xFFFFF000u
#define MM_UART (*(volatile uint32_t *)(MMIO+0x024))
#define MM_EXIT (*(volatile uint32_t *)(MMIO+0x000))
int main(void){
    /* 10 distinct chars, no loop-carried dependency, no reads */
    MM_UART='A'; MM_UART='B'; MM_UART='C'; MM_UART='D'; MM_UART='E';
    MM_UART='F'; MM_UART='G'; MM_UART='H'; MM_UART='I'; MM_UART='J';
    MM_EXIT=0u;
    for(;;);
}
