    .section .text.startup
    .globl _start
_start:
    .option push
    .option norelax
    la   gp, __global_pointer$
    .option pop
    la   sp, _stack_top

    /* zero .bss -- data_mem is zero-init in sim, but be explicit so this
       also works on any target that does not zero memory */
    la   t0, __bss_start
    la   t1, __bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:
    call main
3:  j    3b
