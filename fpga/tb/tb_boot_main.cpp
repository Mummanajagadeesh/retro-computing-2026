// tb_boot_main.cpp -- bit-bangs the UART bootloader protocol against tb_boot.
// Phase 1 sends a corrupt CRC and expects BAD + no boot; after a reset,
// phase 2 sends the real image and expects OK + boot + tb-verified data.
#include <cstdint>
#include <cstdio>
#include <vector>
#include "Vtb_boot.h"

static Vtb_boot *top;
static long long ticks = 0;
static const long long TICK_CAP = 200000000LL;
// Start-edge monitor: replies to a just-sent byte (dots, OK/BAD) can begin
// while send_byte is still ticking, so every tick records the most recent
// start edge (first fall after 540+ idle ticks) for recv_byte to resync to.
static long long first_fall = -1000000LL;
static int prev_txd = 1;

static void tick(int n = 1) {
    for (int i = 0; i < n; i++) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        ++ticks;
        int t = top->uart_txd;
        if (prev_txd == 1 && t == 0 && ticks - first_fall > 540)
            first_fall = ticks;
        prev_txd = t;
        if (ticks > TICK_CAP) {
            printf("TIMEOUT\n");
            exit(1);
        }
    }
}

// 921600 baud at 50 MHz: 54 clocks per bit, idle high.
static void send_byte(uint8_t b) {
    top->uart_rxd = 0; tick(54);
    for (int i = 0; i < 8; i++) {
        top->uart_rxd = (b >> i) & 1;
        tick(54);
    }
    top->uart_rxd = 1; tick(54);
}

static uint8_t recv_byte() {
    long long age = ticks - first_fall;
    long long t0;
    if (age < 540) {
        t0 = first_fall;   // start edge already seen; resync to it
    } else {
        first_fall = -1000000LL;
        while (top->uart_txd == 1) tick(1);
        t0 = (first_fall > 0) ? first_fall : ticks;
    }
    uint8_t b = 0;
    for (int i = 0; i < 8; i++) {
        long long target = t0 + 27 + 54 + 54 * i;
        while (ticks < target) tick(1);
        b |= (uint8_t)(top->uart_txd << i);
    }
    while (ticks < t0 + 27 + 54 * 9) tick(1);
    first_fall = -1000000LL;
    return b;
}

static void send_u16(uint16_t v) {
    send_byte(v & 0xFF); send_byte(v >> 8);
}

static void send_u32(uint32_t v) {
    for (int i = 0; i < 4; i++) send_byte((v >> (8 * i)) & 0xFF);
}

static uint32_t crc_table[256];
static void crc_init() {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++)
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        crc_table[i] = c;
    }
}
static uint32_t crc32(const std::vector<uint8_t> &d) {
    uint32_t c = 0xFFFFFFFFu;
    for (uint8_t b : d) c = crc_table[(c ^ b) & 0xFF] ^ (c >> 8);
    return ~c;
}

static bool recv_byte_to(uint8_t &out, long long budget) {
    long long age = ticks - first_fall;
    long long t0;
    if (age < 540) {
        t0 = first_fall;
    } else {
        first_fall = -1000000LL;
        long long start = ticks;
        while (top->uart_txd == 1) {
            if (ticks - start > budget) return false;
            tick(1);
        }
        t0 = (first_fall > 0) ? first_fall : ticks;
    }
    uint8_t b = 0;
    for (int i = 0; i < 8; i++) {
        long long target = t0 + 27 + 54 + 54 * i;
        while (ticks < target) tick(1);
        b |= (uint8_t)(top->uart_txd << i);
    }
    while (ticks < t0 + 27 + 54 * 9) tick(1);
    first_fall = -1000000LL;
    out = b;
    return true;
}

static void hello_with_retry() {
    for (int attempt = 0; attempt < 4; attempt++) {
        for (char c : {'H', 'E', 'L', 'L', 'O'}) send_byte(c);
        bool ok = true;
        for (const char *w = "BLRDY1"; *w; w++) {
            uint8_t b;
            if (!recv_byte_to(b, 3000000LL) || b != (uint8_t)*w) {
                ok = false;
                break;
            }
        }
        if (ok) return;
        printf("hello attempt %d: no READY, retrying\n", attempt);
    }
    printf("HELLO FAILED after retries\n");
    exit(1);
}

static void expect_str(const char *s) {
    while (*s) {
        uint8_t got = recv_byte();
        if (got != (uint8_t)*s) {
            printf("PROTOCOL FAIL: want '%c' got 0x%02x\n", *s, got);
            exit(1);
        }
        s++;
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vtb_boot;
    crc_init();

    // test image: seg0 256 B @0x1000, seg1 8 KB @0x100000, wad 1 KB @wad base
    struct Seg { uint32_t addr; std::vector<uint8_t> data; };
    std::vector<Seg> segs;
    Seg s0 = {0x1000, {}};
    for (int i = 0; i < 0x100; i++) s0.data.push_back((uint8_t)(0xA0 + (i & 0x1F)));
    Seg s1 = {0x100000, {}};
    for (int i = 0; i < 0x2000; i++) s1.data.push_back((uint8_t)((i * 7 + 3) & 0xFF));
    Seg wad = {0x00D26270, {}};
    for (int i = 0; i < 0x400; i++) wad.data.push_back((uint8_t)((i * 13 + 1) & 0xFF));
    segs.push_back(s0);
    segs.push_back(s1);
    std::vector<uint8_t> payload;
    for (auto &s : segs)
        payload.insert(payload.end(), s.data.begin(), s.data.end());
    payload.insert(payload.end(), wad.data.begin(), wad.data.end());
    // total 0x2500 bytes -> dots after byte 4096 and 8192
    uint32_t good_crc = crc32(payload);

    for (int phase = 0; phase < 2; phase++) {
        bool corrupt = (phase == 0);
        top->uart_rxd = 1;
        top->expect_bad = corrupt ? 1 : 0;
        top->check_now = 0;
        top->rst = 1;
        tick(50);
        top->rst = 0;
        tick(20);

        hello_with_retry();
        send_u16(2);
        size_t sent = 0;
        auto send_seg = [&](Seg &s) {
            send_u32(s.addr);
            send_u32(s.data.size());
            for (uint8_t b : s.data) {
                send_byte(b);
                if (++sent % 4096 == 0) expect_str(".");
            }
        };
        send_seg(segs[0]);
        send_seg(segs[1]);
        send_seg(wad);
        send_byte('G'); send_byte('O');
        send_u32(corrupt ? (good_crc ^ 0xFFFFFFFFu) : good_crc);
        if (corrupt) {
            expect_str("BAD");
        } else {
            expect_str("OK");
            uint32_t echo = 0;
            for (int i = 0; i < 4; i++) echo |= (uint32_t)recv_byte() << (8 * i);
            if (echo != good_crc) {
                printf("CRC ECHO MISMATCH %08x vs %08x\n", echo, good_crc);
                return 1;
            }
        }
        top->check_now = 1;
        while (!top->done) tick(1);
        if (!top->pass) {
            printf("PHASE %d TB CHECK FAILED\n", phase);
            return 1;
        }
        printf("phase %d (%s) OK after %lld ticks\n",
               phase, corrupt ? "corrupt" : "good", ticks);
        top->check_now = 0;
    }
    printf("tb_boot PASS\n");
    return 0;
}
