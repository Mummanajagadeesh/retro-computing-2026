// tb_rt.v -- untimed (no --timing) testbench top for real-time DOOM runs.
//
// Same DUT (rv32i_top_dg) and same semantics as tb/tb_doom.v, but all timing
// control (clock, reset, run loop, key schedule) lives in sim_rt.cpp. This
// module is pure clocked logic + one initial block, so Verilator builds it
// WITHOUT --timing, which removes the coroutine scheduler overhead that
// dominates the tb_doom runtime (~2x fewer evals per cycle, no time queue).
//
// The WAD loader runs at t=0 in a single initial block (tb_doom.v splits the
// +wad_base parse and the loader across two initial blocks, which is an
// ordering race that only works by simulator convention).
//
// Frame bytes and UART chars reach C++ via DPI (see RT_LIVE blocks in
// rtl/mem/mem_top_dg.v); everything else is plain top-level I/O.

`include "defines.v"

module tb_rt (
    input         clk,
    input         rst,
    input         inject_valid,
    input  [8:0]  inject_key,
    output [63:0] cycle_count,
    output [63:0] instret_count,
    output [31:0] dg_frames,
    output        dg_exit,
    output [31:0] dg_exit_code,
    output        halted,
    output [31:0] pc_debug
);

    wire [31:0] instr_debug;
    wire [31:0] alu_result_debug;
    wire [31:0] mem_read_debug;

    reg [63:0] cycle_q;
    reg [63:0] instret_q;

    assign cycle_count   = cycle_q;
    assign instret_count = instret_q;

    rv32i_top_dg #(
        .INST_HEX("hex/inst_mem.hex"),
        .DATA_HEX("hex/data_mem.hex")
    ) uut (
        .clk(clk),
        .rst(rst),
        .pc_debug(pc_debug),
        .instr_debug(instr_debug),
        .alu_result_debug(alu_result_debug),
        .mem_read_debug(mem_read_debug),
        .halted(halted),
        .cycle_count(cycle_q),
        .instret_count(instret_q),
        .inject_valid(inject_valid),
        .inject_key(inject_key),
        .dg_enable(1'b1),
        .dg_exit(dg_exit),
        .dg_exit_code(dg_exit_code),
        .dg_frames(dg_frames),
        .dg_uart_len()
    );

    // Same counting rule as tb_doom.v: count from the first non-reset edge.
    always @(posedge clk) begin
        if (rst) begin
            cycle_q   <= 64'd0;
            instret_q <= 64'd0;
        end else begin
            cycle_q <= cycle_q + 64'd1;
            instret_q <= instret_q
                       + (uut.core.mem_wb_valid0 ? 64'd1 : 64'd0)
                       + (uut.core.mem_wb_valid1 ? 64'd1 : 64'd0);
        end
    end

    // ------------------------------------------------------------ WAD loader
    // Raw-byte $fread straight into the data memory array at +wad_base,
    // exactly as tb_doom.v does. No timing controls: legal untimed.
    reg [8*256-1:0] wad_path;
    reg [31:0] wad_base;
    integer wfd, wbytes, wi;
    reg [7:0] wbuf [0:31*1024*1024-1];

    initial begin
        wad_base = 32'h0;
        if (!$value$plusargs("wad_base=%h", wad_base)) begin
            $display("[tb_rt] FATAL: +wad_base=<hex> required (nm doom.elf | grep _wad_start)");
            $fatal(1);
        end
        wbytes = 0;
        if ($value$plusargs("wad=%s", wad_path)) begin
            wfd = $fopen(wad_path, "rb");
            if (wfd == 0) begin
                $display("[tb_rt] FATAL: cannot open WAD '%0s'", wad_path);
                $fatal(1);
            end
            wbytes = $fread(wbuf, wfd);
            $fclose(wfd);
            $display("[tb_rt] loaded %0d WAD bytes from %0s", wbytes, wad_path);
            if (wbytes > 30*1024*1024) begin
                $display("[tb_rt] FATAL: WAD %0d exceeds the 30 MB region", wbytes);
                $fatal(1);
            end
            for (wi = 0; wi < (wbytes + 3) / 4; wi = wi + 1) begin
                uut.mem.dmem.mem[(wad_base/4) + wi] =
                      { (wi*4+3 < wbytes) ? wbuf[wi*4+3] : 8'd0,
                        (wi*4+2 < wbytes) ? wbuf[wi*4+2] : 8'd0,
                        (wi*4+1 < wbytes) ? wbuf[wi*4+1] : 8'd0,
                                          wbuf[wi*4+0] };
            end
            $display("[tb_rt] WAD packed into dmem at 0x%08x (%0d words)",
                     wad_base, (wbytes + 3) / 4);
        end else begin
            $display("[tb_rt] no +wad= given; DOOM will fail to find its IWAD");
        end
    end

endmodule
