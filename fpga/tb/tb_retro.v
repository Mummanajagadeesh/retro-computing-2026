// tb_retro.v -- full guest boot on the FPGA memory system.
// SDRAM is preloaded from sdram.hex (see mkimage.py); the bootloader is
// bypassed straight to cache flush + boot. The test stops at TARGET_FRAMES
// (or the C++ cycle cap), dumps the fb page as PGM + raw .bin, and logs
// every UART byte. Any guest _exit before the target frame is a failure.
module tb_retro (
    input  clk,
    input  rst,
    input  uart_rxd,
    output uart_txd,
    output [31:0] frame_cnt_o,
    output booted_o,
    output [31:0] uart_bytes_o,
    output tx_ever_o,
    output [31:0] pc_o,
    output [31:0] ins_o,
    output [31:0] cyc_o,
    output [31:0] fw_o,
    output [31:0] fv_o,
    output [31:0] tb_o,
    output reg done,
    output reg pass
);
    parameter TARGET_FRAMES = 2;
    integer target_frames;
    initial begin
        if (!$value$plusargs("frames=%d", target_frames))
            target_frames = TARGET_FRAMES;
    end

    wire core_clk, core_rst;
    wire [31:0] pc_out;
    wire [31:0] inst_addr0, inst_addr1, inst_data0, inst_data1;
    wire mem_we0, mem_re0, mem_we1, mem_re1;
    wire [31:0] mem_addr0, mem_wdata0, mem_addr1, mem_wdata1;
    wire [2:0] mem_funct3_0, mem_funct3_1;
    wire [31:0] mem_rdata0, mem_rdata1;
    wire reg_write0, reg_write1;
    wire [4:0] reg_wa0, reg_wa1;
    assign inst_addr0 = pc_out;
    assign inst_addr1 = pc_out + 32'd4;

    core_top #(.RESET_PC(32'h00000000)) cpu (
        .clk(core_clk),
        .rst(core_rst),
        .pc_out(pc_out),
        .instr0(inst_data0),
        .instr1(inst_data1),
        .mem_read_data0(mem_rdata0),
        .mem_read_data1(mem_rdata1),
        .mem_read0(mem_re0),
        .mem_write0(mem_we0),
        .mem_addr0(mem_addr0),
        .mem_wdata0(mem_wdata0),
        .mem_funct30(mem_funct3_0),
        .mem_read1(mem_re1),
        .mem_write1(mem_we1),
        .mem_addr1(mem_addr1),
        .mem_wdata1(mem_wdata1),
        .mem_funct31(mem_funct3_1),
        .reg_write0(reg_write0),
        .reg_wa0(reg_wa0),
        .reg_write1(reg_write1),
        .reg_wa1(reg_wa1)
    );

    wire [12:0] DRAM_ADDR;
    wire [1:0] DRAM_BA;
    wire [15:0] DRAM_DQ;
    wire DRAM_CAS_N, DRAM_CKE, DRAM_CLK, DRAM_CS_N;
    wire [1:0] DRAM_DQM;
    wire DRAM_RAS_N, DRAM_WE_N;
    wire booted, exit_req, tx_active, rx_active;
    wire [7:0] exit_code_lo, bl_progress;
    wire [31:0] frame_cnt;
    reg [31:0] uart_bytes;
    initial uart_bytes = 32'd0;
    reg tx_ever;
    initial tx_ever = 1'b0;
    mem_top_fpga mem0 (
        .sys_clk(clk), .sys_rst(rst), .core_rst_req(1'b0),
        .tb_bypass_boot(1'b1),
        .core_clk(core_clk), .core_rst(core_rst),
        .inst_addr0(inst_addr0), .inst_data0(inst_data0),
        .inst_addr1(inst_addr1), .inst_data1(inst_data1),
        .mem_we0(mem_we0), .mem_re0(mem_re0),
        .mem_addr0(mem_addr0), .mem_wdata0(mem_wdata0),
        .mem_funct3_0(mem_funct3_0), .mem_rdata0(mem_rdata0),
        .mem_we1(mem_we1), .mem_re1(mem_re1),
        .mem_addr1(mem_addr1), .mem_wdata1(mem_wdata1),
        .mem_funct3_1(mem_funct3_1), .mem_rdata1(mem_rdata1),
        .reg_write0(reg_write0), .reg_wa0(reg_wa0),
        .reg_write1(reg_write1), .reg_wa1(reg_wa1),
        .uart_rxd(uart_rxd), .uart_txd(uart_txd),
        .DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA), .DRAM_DQ(DRAM_DQ),
        .DRAM_CAS_N(DRAM_CAS_N), .DRAM_CKE(DRAM_CKE), .DRAM_CLK(DRAM_CLK),
        .DRAM_CS_N(DRAM_CS_N), .DRAM_DQM(DRAM_DQM),
        .DRAM_RAS_N(DRAM_RAS_N), .DRAM_WE_N(DRAM_WE_N),
        .booted(booted), .exit_req(exit_req), .exit_code_lo(exit_code_lo),
        .frame_cnt(frame_cnt), .tx_active(tx_active), .rx_active(rx_active),
        .bl_progress(bl_progress)
    );
    assign frame_cnt_o = frame_cnt;
    assign booted_o = booted;
    assign uart_bytes_o = uart_bytes;
    assign tx_ever_o = tx_ever;
    assign pc_o = cpu.pc_out;
    assign ins_o = mem0.instret_q[31:0];
    assign cyc_o = mem0.cycle_q[31:0];
    assign fw_o = fw_c;
    assign fv_o = fv_c;
    assign tb_o = tb_c;

    sdram_model sdram (
        .clk(DRAM_CLK), .cke(DRAM_CKE), .cs_n(DRAM_CS_N),
        .ras_n(DRAM_RAS_N), .cas_n(DRAM_CAS_N), .we_n(DRAM_WE_N),
        .addr(DRAM_ADDR), .ba(DRAM_BA), .dq(DRAM_DQ), .dqm(DRAM_DQM)
    );

    initial $readmemh("sdram.hex", sdram.mem);

    // UART transcript log.
    wire [7:0] log_data;
    wire log_valid, log_ferr;
    uart_rx #(.CLK_FREQ(50_000_000), .BAUD(921_600), .OVR(6)) logger (
        .clk(clk), .rst(rst), .rx(uart_txd),
        .data(log_data), .valid(log_valid), .frame_err(log_ferr)
    );
    always @(posedge clk) begin
        if (tx_active) tx_ever <= 1'b1;
        if (log_valid) begin
            uart_bytes <= uart_bytes + 32'd1;
        end
    end
    reg [31:0] fw_c, fv_c, tb_c;
    reg fw_p, fv_p, tb_p;
    initial begin fw_c = 0; fv_c = 0; tb_c = 0; fw_p = 0; fv_p = 0; tb_p = 0; end
    always @(posedge clk) begin
        fw_p <= mem0.fifo_wr; fv_p <= mem0.feed_tx_valid; tb_p <= mem0.tx_busy;
        if (mem0.fifo_wr && !fw_p) fw_c <= fw_c + 1;
        if (mem0.feed_tx_valid && !fv_p) fv_c <= fv_c + 1;
        if (mem0.tx_busy && !tb_p) tb_c <= tb_c + 1;
    end

    // Framebuffer byte j of the 64 KB window.
    function [7:0] fb_byte(input [31:0] j);
        reg [22:0] w;
        reg [15:0] h0, h1;
        begin
            w  = 23'h7FC000 + j[31:2];
            h0 = sdram.mem[{w, 1'b0}];
            h1 = sdram.mem[{w, 1'b1}];
            case (j[1:0])
                2'd0: fb_byte = h0[7:0];
                2'd1: fb_byte = h0[15:8];
                2'd2: fb_byte = h1[7:0];
                default: fb_byte = h1[15:8];
            endcase
        end
    endfunction

    task dump_bin;
        integer fd, j;
        begin
            fd = $fopen("frame_fpga.bin", "w");
            for (j = 0; j < 64000; j = j + 1)
                $fwrite(fd, "%c", fb_byte(j));
            $fclose(fd);
        end
    endtask

    task dump_pgm;
        integer fd, j;
        begin
            fd = $fopen("frame_fpga.pgm", "w");
            $fwrite(fd, "P2\n320 200\n255\n");
            for (j = 0; j < 64000; j = j + 1) begin
                $fwrite(fd, "%0d%c", fb_byte(j), ((j % 16) == 15) ? 8'h0A : 8'h20);
            end
            $fclose(fd);
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            done <= 1'b0;
            pass <= 1'b0;
        end else if (!done) begin
            if (exit_req) begin
                done <= 1'b1;
                pass <= 1'b0;
            end else if (frame_cnt >= target_frames) begin
                dump_bin;
                dump_pgm;
                done <= 1'b1;
                pass <= 1'b1;
            end
        end
    end
endmodule
