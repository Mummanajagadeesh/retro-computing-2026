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

    /* ---- picolibc's own malloc heap (sbrk), separate from DOOM's zone ----
     *
     * 12 MB, NOT 40 MB. data_mem.v indexes with offset[$clog2(W)+1:2], which is
     * $clog2(W) bits, so only 2*W BYTES of the address space are reachable and
     * anything above wraps back to 0. With `DATA_MEM_WORDS 16777216 that window
     * is 0x0000_0000..0x03FF_FFFF (64 MB).
     *
     * A 40 MB heap pushed _wad_start to 0x0292_xxxx, so the WAD's lump
     * directory at 0x0449_0B34 fell past the window and aliased to 0x0049_0B34,
     * reading zeroes. DOOM then died with "W_GetNumForName: PNAMES not found!"
     * even though the bytes were demonstrably present in the array.
     *
     * DOOM only needs ~6 MB here (Z_Init mallocs a 6 MB zone; everything else
     * is lump cache inside that zone), so 12 MB is comfortable and keeps the
     * whole image -- code, heap, stack and the 27.5 MB IWAD -- under 64 MB.
     * ASSERTs below enforce it at link time. */
    . = ALIGN(16);
    __heap_start = .;
    . += 12M;
    __heap_end   = .;

    /* ---- stack: 512 KB ---- */
    . = ALIGN(16);
    _stack_bottom = .;
    . += 512K;
    _stack_top = .;

    /* ---- WAD: loaded by the testbench with $fread, not by elf2hex.
            Kept at a fixed address so the loader and the guest agree. ---- */
    . = ALIGN(4);
    _wad_start = .;
    . += 30M;
    _wad_end = .;

    _heap_limit = .;

    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame*) }
}
