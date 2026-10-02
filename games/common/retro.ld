/* retro.ld -- linker script for console games (tiny images, fixed ROM slot).
 * Layout: code at 0, small bss, 64 KB stack, 64 KB ROM/blob slot that the
 * uploader's WAD segment and mkimage.py fill from _wad_start. */
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

    /* ---- stack: 64 KB (games need a few KB; this is generous) ---- */
    . = ALIGN(16);
    _stack_bottom = .;
    . += 64K;
    _stack_top = .;

    /* ---- ROM/blob slot: filled by the uploader WAD segment / mkimage.
            Kept at a fixed address so the loader and the guest agree. ---- */
    . = ALIGN(4);
    _wad_start = .;
    . += 64K;
    _wad_end = .;

    ASSERT(_wad_end < 0x04000000, "game image exceeds the 64 MB window")

    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame*) }
}
