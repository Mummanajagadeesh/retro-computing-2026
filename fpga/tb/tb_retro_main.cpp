// tb_doom_main.cpp -- runs the full DOOM boot to TARGET_FRAMES.
#include <cstdint>
#include <cstdio>
#include "Vtb_retro.h"

// Non-blocking 921600-baud @ 50 MHz sampler (54 clocks/bit, mid-bit).
// Independent cross-check of the tb-side uart_rx logger.
static FILE *ufile;
static int prev_txd = 1, rx_state = 0, rx_cnt = 0, rx_bits = 0;
static uint8_t rx_byte = 0;
static unsigned crx = 0;

static void rx_sample(int txd) {
    if (rx_state == 0) {
        if (prev_txd == 1 && txd == 0) { rx_state = 1; rx_cnt = 0; }
    } else if (++rx_cnt >= (rx_state == 1 ? 27 : 54)) {
        rx_cnt = 0;
        if (rx_state == 1) {
            if (txd == 0) { rx_state = 2; rx_bits = 0; rx_byte = 0; }
            else rx_state = 0;
        } else if (rx_state == 2) {
            rx_byte |= (uint8_t)(txd << rx_bits);
            if (++rx_bits >= 8) rx_state = 3;
        } else {
            fputc(rx_byte, ufile); ++crx;
            rx_state = 0;
        }
    }
    prev_txd = txd;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_retro *top = new Vtb_retro;
    const long long CAP = 6000000000LL;
    const long long PROG = 100000000LL;
    long long ticks = 0, next_prog = PROG;
    ufile = fopen("uart_fpga.log", "w");

    top->clk = 0;
    top->rst = 1;
    top->uart_rxd = 1;
    for (int i = 0; i < 50; i++) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    }
    top->rst = 0;
    while (!top->done) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        rx_sample(top->uart_txd);
        if (++ticks > CAP) {
            printf("TIMEOUT at %lld sys cycles, frames=%u booted=%d uart=%u crx=%u txever=%d pc=%08x ins=%u cyc=%u\n",
                   ticks, top->frame_cnt_o, (int)top->booted_o, top->uart_bytes_o, crx, (int)top->tx_ever_o, top->pc_o, top->ins_o, top->cyc_o);
            fclose(ufile);
            return 1;
        }
        if (ticks == next_prog) {
            printf("... %lld sys cycles, frames=%u booted=%d uart=%u crx=%u txever=%d pc=%08x ins=%u cyc=%u fw=%u fv=%u tb=%u\n", ticks, top->frame_cnt_o, (int)top->booted_o, top->uart_bytes_o, crx, (int)top->tx_ever_o, top->pc_o, top->ins_o, top->cyc_o, top->fw_o, top->fv_o, top->tb_o);
            fflush(stdout);
            fflush(ufile);
            next_prog += PROG;
        }
    }
    for (int i = 0; i < 2000; i++) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        rx_sample(top->uart_txd);
        ++ticks;
    }
    printf("tb_retro %s after %lld sys cycles, frames=%u booted=%d uart=%u crx=%u txever=%d pc=%08x ins=%u cyc=%u\n",
           top->pass ? "PASS" : "FAIL", ticks, top->frame_cnt_o, (int)top->booted_o, top->uart_bytes_o, crx, (int)top->tx_ever_o, top->pc_o, top->ins_o, top->cyc_o);
    fclose(ufile);
    return top->pass ? 0 : 1;
}
