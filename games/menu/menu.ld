/* menu.ld -- linker script for the unified menu firmware (MENU_BUILD).
 * Same shape as doom.ld: the menu links the whole DOOM engine plus all
 * tiny games, so it needs DOOM's 12 MB picolibc heap reservation and the
 * 512 KB stack, with room for the ~5 MB MENUWAD blob behind them. The
 * testbench / uploader loads the blob at _wad_start. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64M
}

SECTIONS
{
    . = 0x00000000;

    .text : {
        KEEP(*(.text.startup))
        KEEP(*(.text.init))
        *(.text .text.*)
    } > RAM

    . = ALIGN(4);
    .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) } > RAM

    . = ALIGN(4);
    .data : { *(.data .data.*) *(.sdata .sdata.*) } > RAM

    . = ALIGN(4);
    __global_pointer$ = . + 0x800;

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    /* ---- picolibc malloc heap (sbrk grows from `end`, as in doom.ld) ---- */
    . = ALIGN(16);
    __heap_start = .;
    . += 12M;
    __heap_end   = .;

    /* ---- stack: 512 KB (DOOM-proven) ---- */
    . = ALIGN(16);
    _stack_bottom = .;
    . += 512K;
    _stack_top = .;

    /* ---- MENUWAD blob: disk image + DOOM WAD + chip-8 ROMs, packed by
            games/menu/mkmenuwad.py and loaded by the testbench/uploader.
            8 MB covers the ~5 MB of payload with room for disk growth. ---- */
    . = ALIGN(4);
    _wad_start = .;
    . += 8M;
    _wad_end = .;

    ASSERT(_wad_end < 0x04000000, "menu image exceeds the 64 MB window")

    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame*) }
}
