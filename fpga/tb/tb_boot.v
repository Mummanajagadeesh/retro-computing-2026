// tb_boot.v -- bootloader protocol + data check.
// The C++ side bit-bangs the whole uploader protocol (HELLO/segments/WAD/
// GO/CRC); this side checks refusal (corrupt run: booted stays 0) or
// acceptance (good run: booted + every uploaded word in SDRAM).
module tb_boot (
    input  clk,
    input  rst,
    input  uart_rxd,
    output uart_txd,
    input  expect_bad,   // 1 = corrupt run, 0 = good run
    input  check_now,    // C++ raises when the protocol finished
    output reg done,
    output reg pass
);
    // DUT: core side tied off (the arbiter free-runs harmlessly post-boot).
    wire core_clk, core_rst;
    wire [31:0] inst_data0, inst_data1, mem_rdata0, mem_rdata1;
    wire [12:0] DRAM_ADDR;
    wire [1:0] DRAM_BA;
    wire [15:0] DRAM_DQ;
    wire DRAM_CAS_N, DRAM_CKE, DRAM_CLK, DRAM_CS_N;
    wire [1:0] DRAM_DQM;
    wire DRAM_RAS_N, DRAM_WE_N;
    wire booted, exit_req, tx_active, rx_active;
    wire [7:0] exit_code_lo, bl_progress;
    wire [31:0] frame_cnt;
    mem_top_fpga dut (
        .sys_clk(clk), .sys_rst(rst), .core_rst_req(1'b0),
        .tb_bypass_boot(1'b0),
        .core_clk(core_clk), .core_rst(core_rst),
        .inst_addr0(32'd0), .inst_data0(inst_data0),
        .inst_addr1(32'd0), .inst_data1(inst_data1),
        .mem_we0(1'b0), .mem_re0(1'b0),
        .mem_addr0(32'd0), .mem_wdata0(32'd0), .mem_funct3_0(3'd0),
        .mem_rdata0(mem_rdata0),
        .mem_we1(1'b0), .mem_re1(1'b0),
        .mem_addr1(32'd0), .mem_wdata1(32'd0), .mem_funct3_1(3'd0),
        .mem_rdata1(mem_rdata1),
        .reg_write0(1'b0), .reg_wa0(5'd0),
        .reg_write1(1'b0), .reg_wa1(5'd0),
        .uart_rxd(uart_rxd), .uart_txd(uart_txd),
        .DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA), .DRAM_DQ(DRAM_DQ),
        .DRAM_CAS_N(DRAM_CAS_N), .DRAM_CKE(DRAM_CKE), .DRAM_CLK(DRAM_CLK),
        .DRAM_CS_N(DRAM_CS_N), .DRAM_DQM(DRAM_DQM),
        .DRAM_RAS_N(DRAM_RAS_N), .DRAM_WE_N(DRAM_WE_N),
        .booted(booted), .exit_req(exit_req), .exit_code_lo(exit_code_lo),
        .frame_cnt(frame_cnt), .tx_active(tx_active), .rx_active(rx_active),
        .bl_progress(bl_progress)
    );
    sdram_model mem (
        .clk(DRAM_CLK), .cke(DRAM_CKE), .cs_n(DRAM_CS_N),
        .ras_n(DRAM_RAS_N), .cas_n(DRAM_CAS_N), .we_n(DRAM_WE_N),
        .addr(DRAM_ADDR), .ba(DRAM_BA), .dq(DRAM_DQ), .dqm(DRAM_DQM)
    );

    // Expected bytes: must match tb_boot_main.cpp exactly.
    function [7:0] pbyte(input [1:0] ph, input [31:0] i);
        case (ph)
            2'd0: pbyte = 8'hA0 + i[4:0];   // 0xA0 + (i & 0x1F)
            2'd1: pbyte = i * 7 + 3;        // truncated to 8 bits
            default: pbyte = i * 13 + 1;
        endcase
    endfunction
    function [31:0] exp_word(input [1:0] ph, input [31:0] j);
        exp_word = {pbyte(ph, 4 * j + 3), pbyte(ph, 4 * j + 2),
                    pbyte(ph, 4 * j + 1), pbyte(ph, 4 * j)};
    endfunction
    // Model map is linear: word W = halfwords 2W+1:2W.
    function [31:0] got_word(input [22:0] w);
        got_word = {mem.mem[{w, 1'b1}], mem.mem[{w, 1'b0}]};
    endfunction

    localparam C_IDLE = 2'd0, C_RUN = 2'd1, C_DONE = 2'd2;
    reg [1:0] st;
    reg [1:0] phase;
    reg [22:0] base;
    reg [31:0] off, nwords;
    reg err;
    reg [3:0] err_cnt;
    reg [31:0] wait_cnt;

    always @(posedge clk) begin
        if (rst) begin
            st <= C_IDLE; phase <= 2'd0;
            base <= 23'd0; off <= 32'd0; nwords <= 32'd0;
            err <= 1'b0; err_cnt <= 4'd0; done <= 1'b0; pass <= 1'b0;
            wait_cnt <= 32'd0;
        end else begin
            case (st)
                C_IDLE: begin
                    if (check_now) begin
                        if (expect_bad) begin
                            pass <= ~booted;
                            done <= 1'b1;
                            st   <= C_DONE;
                        end else if (!booted) begin
                            // post-OK cache flush still running: wait it out
                            if (wait_cnt == 32'd100000) begin
                                pass <= 1'b0;
                                done <= 1'b1;
                                st   <= C_DONE;
                            end else begin
                                wait_cnt <= wait_cnt + 32'd1;
                            end
                        end else begin
                            phase  <= 2'd0;
                            base   <= 23'h000400;   // seg0 @0x1000
                            off    <= 32'd0;
                            nwords <= 32'h40;
                            err    <= 1'b0;
                            err_cnt <= 4'd0;
                            st     <= C_RUN;
                        end
                    end
                end
                C_RUN: begin
                    if (got_word(base + off[22:0]) !== exp_word(phase, off)) begin
                        err <= 1'b1;
                        if (err_cnt < 4'd8) begin
                            err_cnt <= err_cnt + 4'd1;
                            $display("[tb] MISMATCH ph=%0d off=%0d w=%05x exp=%08x got=%08x",
                                     phase, off, base + off[22:0], exp_word(phase, off),
                                     got_word(base + off[22:0]));
                        end
                    end
                    if (off + 1 == nwords) begin
                        if (phase == 2'd2) begin
                            pass <= ~err & booted;
                            done <= 1'b1;
                            st   <= C_DONE;
                        end else begin
                            phase <= phase + 2'd1;
                            off   <= 32'd0;
                            if (phase == 2'd0) begin
                                base   <= 23'h40000;   // seg1 @0x100000
                                nwords <= 32'h800;
                            end else begin
                                base   <= 23'h34989C;  // wad @0xD26270
                                nwords <= 32'h100;
                            end
                        end
                    end else begin
                        off <= off + 32'd1;
                    end
                end
                C_DONE: begin
                    if (!check_now) begin
                        done <= 1'b0;
                        pass <= 1'b0;
                        st   <= C_IDLE;
                        wait_cnt <= 32'd0;
                    end
                end
                default: st <= C_IDLE;
            endcase
        end
    end
endmodule
