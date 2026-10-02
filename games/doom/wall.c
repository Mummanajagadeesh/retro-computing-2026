/* DOOM-style shaded wall column renderer -- exercises the same store stream
 * (4 pixels packed per word store) and the same mul/div per column. */
#include <stdint.h>
#define MMIO 0xFFFFF000u
#define MM_DUMP (*(volatile uint32_t *)(MMIO+0x028))
#define MM_EXIT (*(volatile uint32_t *)(MMIO+0x000))
#define FB 0xFFF00000u
#define W 320
#define H 200
int main(void){
    volatile uint8_t *fb=(volatile uint8_t*)FB;
    for (int frame=0; frame<2; ++frame) {
        for (int x=0; x<W; ++x) {
            uint32_t wallh = 40u + ((uint32_t)x * 120u) / 320u;   /* mul + div */
            int top = (int)((200u - wallh) / 2u);
            uint32_t shade = 255u - ((uint32_t)x * 200u) / 320u;
            for (int y=0; y<H; ++y) {
                uint32_t px;
                if (y < top || y >= top + (int)wallh)
                    px = 20u + (uint32_t)(y / 4);                 /* floor/ceiling */
                else
                    px = (shade * (uint32_t)(y - top)) / wallh;   /* mul + div */
                if (px > 255u) px = 255u;
                px += (uint32_t)(frame * 8);
                if (px > 255u) px = 255u;
                fb[y*W + x] = (uint8_t)px;                        /* byte store */
            }
        }
        MM_DUMP = 1u;
    }
    MM_EXIT = 0u;
    for(;;);
}
