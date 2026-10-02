    .section .text.startup
    .globl _start
_start:
    .option push
    .option norelax
    la   gp, __global_pointer$
    .option pop
    la   sp, _stack_top

    /* zero .bss -- SDRAM is not zeroed by the bootloader, so this must
       be explicit (unlike sim-only environments that zero memory) */
    la   t0, __bss_start
    la   t1, __bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:
    call main
3:  j    3b

    .section .text
    .globl setjmp
setjmp:
    sw ra,   0(a0)
    sw sp,   4(a0)
    sw s0,   8(a0)
    sw s1,  12(a0)
    sw s2,  16(a0)
    sw s3,  20(a0)
    sw s4,  24(a0)
    sw s5,  28(a0)
    sw s6,  32(a0)
    sw s7,  36(a0)
    sw s8,  40(a0)
    sw s9,  44(a0)
    sw s10, 48(a0)
    sw s11, 52(a0)
    li a0, 0
    ret

    .globl longjmp
longjmp:
    lw ra,   0(a0)
    lw sp,   4(a0)
    lw s0,   8(a0)
    lw s1,  12(a0)
    lw s2,  16(a0)
    lw s3,  20(a0)
    lw s4,  24(a0)
    lw s5,  28(a0)
    lw s6,  32(a0)
    lw s7,  36(a0)
    lw s8,  40(a0)
    lw s9,  44(a0)
    lw s10, 48(a0)
    lw s11, 52(a0)
    mv a0, a1
    bnez a0, 1f
    li a0, 1
1:
    ret
