    .section .text.startup
    .globl _start
_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    /* data_mem is 2048 words = 8 KB and its index wraps on bits [12:2],
       so any sp whose low 13 bits land inside 8 KB works. Put the stack at
       the top of the window, clear of .data/.bss. */
    li sp, 0x00001FC0
    call main
1:  j 1b
