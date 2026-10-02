// tb_sdram.v -- sdram_ctrl + sdram_tester against the behavioral model.
module tb_sdram (
    input  clk,
    input  rst,
    output done,
    output pass,
    output fail
);
    wire c_rd_req, c_wr_req, c_rd_ack, c_wr_ack, c_ready;
    wire [22:0] c_addr;
    wire [31:0] c_wr_data, c_rd_data;
    wire [3:0] c_wr_be;
    wire t_pass, t_fail, t_active;
    wire [7:0] t_prog;

    wire dram_cke, dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n;
    wire [12:0] dram_addr;
    wire [1:0] dram_ba, dram_dqm;
    wire [15:0] dram_dq;

    sdram_ctrl ctrl (
        .clk(clk), .rst(rst), .ready(c_ready),
        .rd_req(c_rd_req), .wr_req(c_wr_req), .addr(c_addr),
        .wr_data(c_wr_data), .wr_be(c_wr_be),
        .rd_ack(c_rd_ack), .rd_data(c_rd_data), .wr_ack(c_wr_ack),
        .DRAM_CLK(), .DRAM_CKE(dram_cke),
        .DRAM_CS_N(dram_cs_n), .DRAM_RAS_N(dram_ras_n),
        .DRAM_CAS_N(dram_cas_n), .DRAM_WE_N(dram_we_n),
        .DRAM_ADDR(dram_addr), .DRAM_BA(dram_ba),
        .DRAM_DQ(dram_dq), .DRAM_DQM(dram_dqm)
    );

    sdram_tester tst (
        .clk(clk), .rst(rst),
        .rd_req(c_rd_req), .wr_req(c_wr_req), .addr(c_addr),
        .wr_data(c_wr_data), .wr_be(c_wr_be),
        .rd_ack(c_rd_ack), .rd_data(c_rd_data), .wr_ack(c_wr_ack),
        .ready(c_ready),
        .pass(t_pass), .fail(t_fail), .active(t_active),
        .progress(t_prog),
        .err_addr(), .err_exp(), .err_got()
    );

    sdram_model mem (
        .clk(clk), .cke(dram_cke), .cs_n(dram_cs_n),
        .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n),
        .addr(dram_addr), .ba(dram_ba), .dq(dram_dq), .dqm(dram_dqm)
    );

`ifdef TB_DEBUG
    reg [31:0] dbg_cnt;
    reg fail_d;
    always @(posedge clk) begin
        if (rst) begin
            dbg_cnt <= 32'd0;
            fail_d <= 1'b0;
        end else begin
            dbg_cnt <= dbg_cnt + 32'd1;
            if (tst.fail && !fail_d)
                $display("MISMATCH @%0d addr=%h exp=%h got=%h (tst.st=%0d rgn=%0d off=%0d)",
                    dbg_cnt, tst.err_addr, tst.err_exp, tst.err_got,
                    tst.state, tst.region, tst.off);
            fail_d <= tst.fail;
            if (dbg_cnt < 32'd30 || dbg_cnt[19:0] == 20'd0)
                $display("[%0d] ctrl.st=%0d ready=%0b wc=%0d gt=%0d | tst.st=%0d rgn=%0d off=%0d | rd_r=%0b wr_r=%0b rd_a=%0b wr_a=%0b ref_p=%0b ref_o=%0b",
                    dbg_cnt, ctrl.state, c_ready, ctrl.wait_cnt,
                    ctrl.gap_target, tst.state, tst.region, tst.off,
                    c_rd_req, c_wr_req, c_rd_ack, c_wr_ack,
                    ctrl.ref_pend, ctrl.ref_overdue);
        end
    end
`endif

    assign done = ~t_active & (t_pass | t_fail);
    assign pass = t_pass;
    assign fail = t_fail;
endmodule
