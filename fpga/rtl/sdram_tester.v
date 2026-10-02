// sdram_tester.v -- write/readback check of sdram_ctrl: 4 regions x 16K
// words (one per bank), a byte-enable spot check, and the last word.
// pass/fail are sticky for LEDs; error detail outputs are for SignalTap.
module sdram_tester (
    input           clk,
    input           rst,
    output reg      rd_req,
    output reg      wr_req,
    output reg [22:0] addr,
    output reg [31:0] wr_data,
    output reg [3:0]  wr_be,
    input           rd_ack,
    input  [31:0]   rd_data,
    input           wr_ack,
    input           ready,
    output reg      pass,
    output reg      fail,
    output reg      active,
    output reg [7:0] progress,
    output reg [22:0] err_addr,
    output reg [31:0] err_exp,
    output reg [31:0] err_got
);
    localparam T_WAIT = 4'd0,
               T_W    = 4'd1,
               T_R    = 4'd2,
               T_BW0  = 4'd3,
               T_BW1  = 4'd4,
               T_BR   = 4'd5,
               T_CW   = 4'd6,
               T_CR   = 4'd7,
               T_DONE = 4'd8;

    localparam BYTE_ADDR = 23'h100000;
    localparam TOP_ADDR  = 23'h7FFFFF;

    reg [3:0]  state;
    reg [1:0]  region;
    reg [13:0] off;
    wire [22:0] cur = {region, 21'd0} + {9'd0, off};   // region base + offset
    wire [31:0] wdata = {cur, cur[8:0]};

    always @(posedge clk) begin
        if (rst) begin
            rd_req   <= 1'b0;
            wr_req   <= 1'b0;
            addr     <= 23'd0;
            wr_data  <= 32'd0;
            wr_be    <= 4'b1111;
            pass     <= 1'b0;
            fail     <= 1'b0;
            active   <= 1'b0;
            progress <= 8'd0;
            err_addr <= 23'd0;
            err_exp  <= 32'd0;
            err_got  <= 32'd0;
            state  <= T_WAIT;
            region <= 2'd0;
            off    <= 14'd0;
        end else begin
            progress <= addr[7:0];
            case (state)
                T_WAIT: begin
                    if (ready) begin
                        active <= 1'b1;
                        region <= 2'd0;
                        off    <= 14'd0;
                        state  <= T_W;
                    end
                end
                T_W: begin   // write pass over the region
                    wr_req  <= 1'b1;
                    addr    <= cur;
                    wr_data <= wdata;
                    wr_be   <= 4'b1111;
                    if (wr_ack) begin
                        wr_req <= 1'b0;
                        if (off == 14'd16383) begin
                            off   <= 14'd0;
                            state <= T_R;
                        end else begin
                            off   <= off + 14'd1;
                            state <= T_W;
                        end
                    end
                end
                T_R: begin   // read pass, compare
                    rd_req <= 1'b1;
                    addr   <= cur;
                    if (rd_ack) begin
                        rd_req <= 1'b0;
                        if (rd_data !== wdata) begin
                            fail     <= 1'b1;
                            err_addr <= cur;
                            err_exp  <= wdata;
                            err_got  <= rd_data;
                        end
                        if (off == 14'd16383) begin
                            off <= 14'd0;
                            if (region == 2'd3) begin
                                state <= T_BW0;
                            end else begin
                                region <= region + 2'd1;
                                state  <= T_W;
                            end
                        end else begin
                            off   <= off + 14'd1;
                            state <= T_R;
                        end
                    end
                end
                T_BW0: begin   // byte-enable check: full word, then byte 1
                    wr_req  <= 1'b1;
                    addr    <= BYTE_ADDR;
                    wr_data <= 32'hAABBCCDD;
                    wr_be   <= 4'b1111;
                    if (wr_ack) begin
                        wr_req <= 1'b0;
                        state  <= T_BW1;
                    end
                end
                T_BW1: begin
                    wr_req  <= 1'b1;
                    addr    <= BYTE_ADDR;
                    wr_data <= 32'h00001100;
                    wr_be   <= 4'b0010;
                    if (wr_ack) begin
                        wr_req <= 1'b0;
                        state  <= T_BR;
                    end
                end
                T_BR: begin
                    rd_req <= 1'b1;
                    addr   <= BYTE_ADDR;
                    if (rd_ack) begin
                        rd_req <= 1'b0;
                        if (rd_data !== 32'hAABB11DD) begin
                            fail     <= 1'b1;
                            err_addr <= BYTE_ADDR;
                            err_exp  <= 32'hAABB11DD;
                            err_got  <= rd_data;
                        end
                        state <= T_CW;
                    end
                end
                T_CW: begin   // last word of the SDRAM
                    wr_req  <= 1'b1;
                    addr    <= TOP_ADDR;
                    wr_data <= 32'h55AA55AA;
                    wr_be   <= 4'b1111;
                    if (wr_ack) begin
                        wr_req <= 1'b0;
                        state  <= T_CR;
                    end
                end
                T_CR: begin
                    rd_req <= 1'b1;
                    addr   <= TOP_ADDR;
                    if (rd_ack) begin
                        rd_req <= 1'b0;
                        if (rd_data !== 32'h55AA55AA) begin
                            fail     <= 1'b1;
                            err_addr <= TOP_ADDR;
                            err_exp  <= 32'h55AA55AA;
                            err_got  <= rd_data;
                        end
                        state <= T_DONE;
                    end
                end
                T_DONE: begin
                    active <= 1'b0;
                    pass   <= ~fail;
                end
                default: state <= T_WAIT;
            endcase
        end
    end
endmodule
