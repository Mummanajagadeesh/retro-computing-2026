// sim_rt.cpp -- untimed C++ testbench for tb_rt (real-time DOOM).
//
// Replaces tb/tb_doom.v's timed constructs (forever-clock, #delays, run loop)
// with a plain eval loop, so the model builds WITHOUT --timing. Same guest-
// visible semantics: same reset, same counters, same 1-cycle key pulses,
// same stop conditions, same console/report formats.
//
// Args (all +plusargs, tb_doom-compatible where it matters):
//   +wad=<path> +wad_base=<hex>   WAD load (consumed by tb_rt.v at t=0)
//   +keyfile=<path>               "<cycle> <key>" schedule, key|0x100 = release
//   +max_cycles=N  +max_frames=N  +progress=N
//   +pgm                          also write frame_<n>.pgm (bit-identical to
//                                 tb_doom's; default off: the fast path keeps
//                                 frames in memory for the live UI)
//   +live=PORT                    TCP live mode: serve frames/console, take keys
//
// Live protocol (localhost TCP, non-blocking, sim never blocks):
//   sim -> bridge: 'F' u32le n u64le cyc u64le instret 65536B (latest frame
//                  grabs; bridge polls with 'G', sim replies with latest)
//                  'F' means full frame; 'C' u16le len bytes = console line
//   bridge -> sim: 'K' u8 key u8 pressed   (inject at next cycle)
//                  'G'                     (send latest frame now)

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Vtb_rt.h"
#include "Vtb_rt__Dpi.h"
#include "svdpi.h"

namespace {

constexpr int FB_W = 320, FB_H = 200, FB_WORDS = FB_W * FB_H / 4;

struct SchedKey {
    uint64_t cyc;
    uint16_t key;  // bit8 = release
};

Vtb_rt *top = nullptr;
uint64_t g_cycle = 0;  // post-reset rising edges evaluated (= tb_rt cycle_q)
uint64_t g_instret = 0;

std::string g_uart;        // full guest console
std::string g_uart_line;   // line buffer for live forwarding
std::vector<uint8_t> g_fb(FB_W * FB_H, 0);
int g_frame_n = -1;
uint64_t g_frame_cyc = 0, g_frame_instret = 0;
bool g_frame_fresh = false;
bool g_want_pgm = false;

std::vector<SchedKey> g_sched;
size_t g_sched_ptr = 0;

int g_listen_fd = -1, g_client_fd = -1;
uint64_t g_last_poll = 0;

// ---- wall clock ----
double now_s() {
    using clk = std::chrono::steady_clock;
    static const auto t0 = clk::now();
    return std::chrono::duration<double>(clk::now() - t0).count();
}

// ---- live TCP ----
void live_listen(int port) {
    g_listen_fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (g_listen_fd < 0) { perror("socket"); return; }
    int one = 1;
    ::setsockopt(g_listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons((uint16_t)port);
    if (::bind(g_listen_fd, (sockaddr *)&a, sizeof a) < 0) { perror("bind"); return; }
    if (::listen(g_listen_fd, 1) < 0) { perror("listen"); return; }
    ::fcntl(g_listen_fd, F_SETFL, O_NONBLOCK);
    printf("[rt] live TCP on 127.0.0.1:%d\n", port);
    fflush(stdout);
}

void live_send_all(const uint8_t *p, size_t n) {
    // best effort: drop on backpressure, sim never blocks
    while (n > 0 && g_client_fd >= 0) {
        ssize_t w = ::send(g_client_fd, p, n, MSG_NOSIGNAL | MSG_DONTWAIT);
        if (w <= 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;  // drop rest
            ::close(g_client_fd);
            g_client_fd = -1;
            return;
        }
        p += (size_t)w;
        n -= (size_t)w;
    }
}

void live_send_frame() {
    uint8_t hdr[1 + 4 + 8 + 8];
    hdr[0] = 'F';
    uint32_t n = (uint32_t)g_frame_n;
    memcpy(hdr + 1, &n, 4);
    memcpy(hdr + 5, &g_frame_cyc, 8);
    memcpy(hdr + 13, &g_frame_instret, 8);
    live_send_all(hdr, sizeof hdr);
    live_send_all(g_fb.data(), g_fb.size());
}

void live_send_console(const char *p, size_t n) {
    while (n > 0) {
        size_t chunk = n > 4096 ? 4096 : n;
        uint8_t hdr[3];
        hdr[0] = 'C';
        uint16_t len = (uint16_t)chunk;
        memcpy(hdr + 1, &len, 2);
        live_send_all(hdr, 3);
        live_send_all((const uint8_t *)p, chunk);
        p += chunk;
        n -= chunk;
    }
}

void live_poll() {
    if (g_listen_fd < 0) return;
    if (g_client_fd < 0) {
        int c = ::accept(g_listen_fd, nullptr, nullptr);
        if (c >= 0) {
            ::fcntl(c, F_SETFL, O_NONBLOCK);
            g_client_fd = c;
            printf("[rt] live client connected\n");
            fflush(stdout);
            // hand it the latest frame + recent console immediately, so a
            // late-joining UI still sees boot text and the current screen
            if (g_frame_n >= 0) live_send_frame();
            if (!g_uart.empty()) {
                size_t back = g_uart.size() > 4096 ? 4096 : g_uart.size();
                live_send_console(g_uart.data() + g_uart.size() - back, back);
            }
        }
    }
    if (g_client_fd < 0) return;
    uint8_t buf[64];
    ssize_t r = ::recv(g_client_fd, buf, sizeof buf, MSG_DONTWAIT);
    if (r == 0) {
        ::close(g_client_fd);
        g_client_fd = -1;
        return;
    }
    if (r < 0) return;  // EAGAIN: nothing
    for (ssize_t i = 0; i < r;) {
        if (buf[i] == 'G') {
            if (g_frame_n >= 0) live_send_frame();
            ++i;
        } else if (buf[i] == 'K' && i + 2 < r) {
            uint8_t key = buf[i + 1], pressed = buf[i + 2];
            uint16_t k = pressed ? key : (uint16_t)(key | 0x100);
            g_sched.push_back(SchedKey{g_cycle + 1, k});
            // keep schedule sorted (live keys append at ~now, schedule is
            // time-ordered, so bubble the tail back into place)
            for (size_t j = g_sched.size() - 1;
                 j > g_sched_ptr && g_sched[j].cyc < g_sched[j - 1].cyc; --j)
                std::swap(g_sched[j], g_sched[j - 1]);
            i += 3;
        } else {
            ++i;  // resync on unknown bytes
        }
    }
}

}  // namespace

// ---- DPI imports (called FROM Verilog) ----
void rt_uart_put(char ch) {
    g_uart.push_back(ch);
    if (g_client_fd >= 0) {
        g_uart_line.push_back(ch);
        if (ch == '\n' || g_uart_line.size() >= 200) {
            live_send_console(g_uart_line.data(), g_uart_line.size());
            g_uart_line.clear();
        }
    }
}

int g_frame_pending = -1;

void rt_frame(int n) {
    // NOTE: called from inside the posedge eval. We must NOT call the
    // rt_fb_word export from here (no DPI scope is active inside an import
    // callback); just latch the request. The main loop grabs fb[] right
    // after the eval returns, when it is still identical (the guest only
    // writes it on clock edges).
    g_frame_pending = n;
    g_frame_cyc = g_cycle;
    g_frame_instret = g_instret;
}

void grab_frame() {
    int n = g_frame_pending;
    g_frame_pending = -1;
    // DPI exports need an active scope when called from C++ (IEEE 35.5.3):
    // point at the bridge instance that owns fb[].
    svScope scope = svGetScopeFromName("TOP.tb_rt.uut.mem");
    if (scope) svSetScope(scope);
    for (int i = 0; i < FB_WORDS; ++i) {
        uint32_t w = rt_fb_word(i);
        g_fb[4 * i + 0] = (uint8_t)(w & 0xFF);
        g_fb[4 * i + 1] = (uint8_t)((w >> 8) & 0xFF);
        g_fb[4 * i + 2] = (uint8_t)((w >> 16) & 0xFF);
        g_fb[4 * i + 3] = (uint8_t)((w >> 24) & 0xFF);
    }
    g_frame_n = n;
    g_frame_cyc = g_cycle;
    g_frame_instret = g_instret;
    g_frame_fresh = true;

    static double last_t = 0;
    static uint64_t last_c = 0;
    double t = now_s();
    double mhz = (last_t > 0 && t > last_t)
                     ? (double)(g_cycle - last_c) / (t - last_t) / 1e6
                     : 0.0;
    last_t = t;
    last_c = g_cycle;
    printf("[rt] frame %d  cyc=%lu instret=%lu  sim=%.2f MHz\n", n,
           (unsigned long)g_cycle, (unsigned long)g_instret, mhz);
    fflush(stdout);

    if (g_want_pgm) {
        char name[64];
        snprintf(name, sizeof name, "frame_%d.pgm", n);
        FILE *f = fopen(name, "wb");
        if (f) {
            fwrite("P5\n320 200\n255\n", 1, 15, f);
            fwrite(g_fb.data(), 1, g_fb.size(), f);
            fclose(f);
        }
    }
    if (g_client_fd >= 0) live_send_frame();
}

// ---- plusarg helpers (Verilator also feeds argv to $value$plusargs) ----
bool get_plusarg(const char *prefix, std::string &out, int argc, char **argv) {
    size_t n = strlen(prefix);
    for (int i = 1; i < argc; ++i)
        if (strncmp(argv[i], prefix, n) == 0) {
            out = argv[i] + n;
            return true;
        }
    return false;
}
long get_plusint(const char *prefix, long dflt, int argc, char **argv) {
    std::string s;
    return get_plusarg(prefix, s, argc, argv) ? strtol(s.c_str(), nullptr, 0)
                                             : dflt;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    long max_cycles = get_plusint("+max_cycles=", 2000000000L, argc, argv);
    long max_frames = get_plusint("+max_frames=", 1L, argc, argv);
    long progress = get_plusint("+progress=", 0L, argc, argv);
    long live_port = get_plusint("+live=", 0L, argc, argv);
    std::string s;
    if (get_plusarg("+pgm", s, argc, argv)) g_want_pgm = true;

    std::string keyfile;
    if (get_plusarg("+keyfile=", keyfile, argc, argv)) {
        FILE *f = fopen(keyfile.c_str(), "r");
        if (!f) {
            fprintf(stderr, "[rt] FATAL: cannot open +keyfile %s\n",
                    keyfile.c_str());
            return 1;
        }
        long cyc;
        int key;
        while (fscanf(f, "%ld %d", &cyc, &key) == 2)
            g_sched.push_back(SchedKey{(uint64_t)cyc, (uint16_t)(key & 0x1FF)});
        fclose(f);
        printf("[rt] keyfile: %zu events from %s\n", g_sched.size(),
               keyfile.c_str());
    }
    printf("[rt] max_cycles=%ld max_frames=%ld%s\n", max_cycles, max_frames,
           g_want_pgm ? " +pgm" : "");

    if (live_port > 0) live_listen((int)live_port);

    top = new Vtb_rt;
    top->clk = 0;
    top->rst = 1;
    top->inject_valid = 0;
    top->inject_key = 0;
    top->eval();  // settle t=0 (runs tb_rt initial: WAD load)

    // reset for 2 full cycles (tb_doom: #20 at 10-unit period)
    for (int i = 0; i < 2; ++i) {
        top->clk = 0;
        top->eval();
        top->clk = 1;
        top->eval();
    }
    top->rst = 0;

    bool done = false;
    const char *stop_why = "pc stable (hang?)";
    uint32_t last_pc = 0xFFFFFFFFu;
    int stable = 0;
    double t_start = now_s();

    while (!done && (long)g_cycle < max_cycles) {
        // falling edge
        top->clk = 0;
        top->eval();

        // rising edge
        top->clk = 1;
        top->eval();
        if (g_frame_pending >= 0) grab_frame();
        ++g_cycle;
        g_instret = top->instret_count;

        // Key schedule, bit-exact vs tb_doom.v: that testbench decides in an
        // always@(posedge) reading the PRE-edge count, so a key due at cycle
        // C goes high after edge C->C+1 and latches on edge C+1->C+2. Here
        // g_cycle is the POST-edge count, hence the +1 below. The value set
        // here persists through the next falling+rise (like a non-blocking
        // update), so the pulse is exactly one cycle wide.
        bool fire = false;
        uint16_t fire_key = 0;
        if (g_sched_ptr < g_sched.size() &&
            g_sched[g_sched_ptr].cyc + 1 == (uint64_t)g_cycle) {
            fire = true;
            fire_key = g_sched[g_sched_ptr].key;
            ++g_sched_ptr;
            printf("[rt] key %s 0x%02x at cyc=%lu\n",
                   (fire_key & 0x100) ? "UP  " : "DOWN", fire_key & 0xFF,
                   (unsigned long)(g_cycle - 1));
            fflush(stdout);
        }
        top->inject_valid = fire ? 1 : 0;
        top->inject_key = fire_key & 0x1FF;

        if (live_port > 0 && g_cycle - g_last_poll >= 512) {
            g_last_poll = g_cycle;
            live_poll();
        }
        if (progress > 0 && (g_cycle % (uint64_t)progress) == 0)
            printf("[PROGRESS] cyc=%lu pc=%08x frames=%u halted=%d\n",
                   (unsigned long)g_cycle, top->pc_debug, top->dg_frames,
                   (int)top->halted);

        if (top->pc_debug == last_pc)
            ++stable;
        else {
            stable = 0;
            last_pc = top->pc_debug;
        }

        if (top->dg_exit) {
            done = true;
            stop_why = "guest EXIT";
        } else if (top->halted) {
            done = true;
            stop_why = "ecall halt";
        } else if ((long)top->dg_frames >= max_frames) {
            done = true;
            stop_why = "max_frames";
        } else if (stable > 64) {
            done = true;
        }
    }
    if (!done && (long)g_cycle >= max_cycles) {
        done = true;
        stop_why = "max_cycles";
    }

    double wall = now_s() - t_start;
    double mhz = wall > 0 ? (double)g_cycle / wall / 1e6 : 0;

    printf("\n---------------- GUEST CONSOLE (%zu chars) ----------------\n",
           g_uart.size());
    fwrite(g_uart.data(), 1, g_uart.size(), stdout);
    printf("\n---------------- END GUEST CONSOLE ----------------\n");
    FILE *uf = fopen("doom_console.txt", "w");
    if (uf) {
        fwrite(g_uart.data(), 1, g_uart.size(), uf);
        fclose(uf);
    }

    printf("\n============================================================\n");
    printf("         RV32IM DOOM / REAL-TIME RESULTS\n");
    printf("============================================================\n");
    printf("Total cycles:         %lu\n", (unsigned long)g_cycle);
    printf("Retired instructions: %lu\n", (unsigned long)g_instret);
    printf("CPI:                  %0.6f\n",
           g_instret ? (double)g_cycle / (double)g_instret : 0);
    printf("IPC:                  %0.6f\n",
           g_cycle ? (double)g_instret / (double)g_cycle : 0);
    printf("Frames dumped:        %u\n", top->dg_frames);
    printf("Final PC:             0x%08x\n", top->pc_debug);
    printf("Stopped by:           %s\n", stop_why);
    if (top->dg_exit) printf("Guest exit code:      %u\n", top->dg_exit_code);
    printf("Wall time:            %.2f s  (%.2f MHz avg)\n", wall, mhz);
    printf("============================================================\n");

    FILE *f = fopen("tb_doom_results.txt", "w");
    if (f) {
        fprintf(f, "Total cycles: %lu\n", (unsigned long)g_cycle);
        fprintf(f, "Retired instructions: %lu\n", (unsigned long)g_instret);
        fprintf(
            f, "CPI: %0.6f\n",
            g_instret ? (double)g_cycle / (double)g_instret : 0);
        fprintf(f, "IPC: %0.6f\n",
                g_cycle ? (double)g_instret / (double)g_cycle : 0);
        fprintf(f, "Frames: %u\n", top->dg_frames);
        fprintf(f, "Final PC: 0x%08x\n", top->pc_debug);
        fprintf(f, "Stopped by: %s\n", stop_why);
        fclose(f);
    }

    top->final();
    delete top;
    return 0;
}
