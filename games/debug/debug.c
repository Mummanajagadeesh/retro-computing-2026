/* R5: minimal repro of the wild-slot-1-store + memset hang.
 * Mimics chip8 init sequence: big BSS, prints+div, memcpy load,
 * key_flush loads, CLS memset, then dump_tiny. Expect mode 3. */
#include "console.h"
static uint8_t mem[4096];
static uint8_t gfx[2048];
static uint8_t V[16];
int main(void)
{
    print("\n[r5] hello\n[r5] len: ");
    print_dec(423);
    print("\n");
    for (uint16_t i = 0; i < 423; i++) mem[0x200 + i] = _wad_start[2 + i];
    for (int i = 0; i < 80; i++) mem[0x50 + i] = (uint8_t)i;
    key_flush();
    for (int i = 0; i < 2048; i++) gfx[i] = 0;   /* CLS memset */
    gfx[100] = 1; gfx[200] = 1;
    for (int i = 0; i < 2048; i++) FB[i] = gfx[i] ? 0xFFu : 0x00u;
    print("[r5] dumping\n");
    dump_tiny();
    sleep_ms(100);
    dump_tiny();
    sleep_ms(100);
    print("[r5] done\n");
    sys_exit(0);
}
