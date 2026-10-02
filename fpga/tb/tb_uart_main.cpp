// tb_uart_main.cpp -- clock driver for tb_uart (done/pass protocol).
#include <cstdint>
#include <cstdio>
#include "Vtb_uart.h"
#include "verilated.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_uart* tb = new Vtb_uart;
    tb->clk = 0;
    tb->rst = 1;
    uint64_t t = 0;
    const uint64_t TMAX = 50000000;
    while (!Verilated::gotFinish() && t < TMAX) {
        tb->clk = 0; tb->eval();
        tb->clk = 1; tb->eval();
        if (t == 20) tb->rst = 0;
        if (tb->done) break;
        ++t;
    }
    bool ok = tb->done && tb->pass;
    printf("tb_uart: %s (cycles=%lu)\n", ok ? "PASS" : "FAIL",
           (unsigned long)t);
    tb->final();
    delete tb;
    return ok ? 0 : 1;
}
