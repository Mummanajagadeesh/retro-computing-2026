/* cpm_main.c -- CP/M 2.2 on the retro_fpga console (RunCPM port).
 *
 * Config: Z80 (cpu2, smaller/optimized core) + internal CCP. PUN/LST
 * off (no files outside the RAM disk), STREAMIO/DEBUG off. Entry is
 * main() via the shared crt0; leaving CP/M halts with sys_exit and
 * KEY1 reboots the board back to the bootloader.
 */
#define CPU "runcpm/cpu2.h"
#define CCP_INTERNAL

#include "runcpm/globals.h"

#undef USE_PUN
#undef USE_LST

#include "abstraction_retro.h"
#include "runcpm/ram.h"
#include "runcpm/console.h"
#include CPU
#include "runcpm/disk.h"
#include "runcpm/host.h"
#include "runcpm/cpm.h"
#include "runcpm/ccp.h"

#ifdef MENU_BUILD
#define main cpm_entry
#define sys_exit(c) return (c)
#endif


const char *cpm_auto_cmd = 0;

int main(void)
{
    _HardwareInit();
    _console_init();
    _clrscr();
    _puts("  CP/M 2.2 on RV32IM retro_fpga (RunCPM v" VERSION " port)\r\n");
    _puts("  by Marcelo Dantas, ported to a custom dual-issue CPU\r\n");
    _puts("----------------------------------------\r\n");
    _puts("CPU is ");
    _puts(CPU_IS);
    _puts("\r\n");
    /* Z80estimateClock() intentionally not called: its 10M-iteration loop
     * costs ~40 s at 50 MHz. Bench timing happens with real programs. */
    _puts("BIOS at 0x");
    _puthex16(BIOSjmppage);
    _puts(" - BDOS at 0x");
    _puthex16(BDOSjmppage);
    _puts("\r\n");
#ifdef INT_HANDOFF
    _puts("BIOS/BDOS using interrupt handoff method\r\n");
#else
    _puts("BIOS/BDOS using legacy IN/OUT call method\r\n");
#endif
    _puts("CCP " CCPname " at 0x");
    _puthex16(CCPaddr);
    _puts("\r\n");
#if BANKS > 1
    _puts("Banked Memory: ");
    _putdec(BANKS);
    _puts(" banks\r\n");
#endif
    while (TRUE) {
        _puts(CCPHEAD);
        _PatchCPM();
        Status = 0;
        _ccp();
        if (Status == 1)
            break;
    }
    _puts("\r\n");
    _console_reset();
    sys_exit(0);
    return 0;
}
