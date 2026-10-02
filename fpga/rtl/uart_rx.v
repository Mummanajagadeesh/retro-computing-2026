// uart_rx.v -- 8N1 UART receiver with parametrized oversampling.
// OVR=16 is the classic robust choice; OVR=8 allows 2 Mbaud from a
// 50 MHz clock (16x would need a fractional tick there). 2-flop input.
module uart_rx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 115_200,
    parameter OVR      = 16,                    // oversampling ratio
    parameter DIVT     = CLK_FREQ / BAUD / OVR  // clocks per tick
) (
    input            clk,
    input            rst,          // sync, active high
    input            rx,
    output reg [7:0] data,
    output reg       valid,        // 1-cycle strobe when a byte lands
    output reg       frame_err     // stop bit was 0 (cleared on next start)
);
    localparam TW = $clog2(OVR);
    localparam [TW-1:0] HALF_TICK = OVR / 2 - 1;   // middle of start bit
    localparam [TW-1:0] FULL_TICK = OVR - 1;       // middle of data/stop

    reg rx_a, rx_b;
    always @(posedge clk) begin
        if (rst) begin
            rx_a <= 1'b1;
            rx_b <= 1'b1;
        end else begin
            rx_a <= rx;
            rx_b <= rx_a;
        end
    end

    localparam IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;
    reg [1:0]  state;
    reg [15:0] clk_cnt;
    reg [TW-1:0] tick_cnt;   // 0..OVR-1 within a bit
    reg [2:0]  bit_cnt;
    reg [7:0]  shreg;

    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            valid     <= 1'b0;
            frame_err <= 1'b0;
            clk_cnt   <= 16'd0;
            tick_cnt  <= {TW{1'b0}};
            bit_cnt   <= 3'd0;
            shreg     <= 8'd0;
            data      <= 8'd0;
        end else begin
            valid <= 1'b0;
            case (state)
                IDLE: begin
                    clk_cnt  <= 16'd0;
                    tick_cnt <= {TW{1'b0}};
                    bit_cnt  <= 3'd0;
                    if (!rx_b) begin
                        state     <= START;
                        frame_err <= 1'b0;
                    end
                end
                START: begin   // wait half a bit, confirm still low
                    if (clk_cnt == DIVT-1) begin
                        clk_cnt <= 16'd0;
                        if (tick_cnt == HALF_TICK) begin
                            tick_cnt <= {TW{1'b0}};
                            state    <= rx_b ? IDLE : DATA;   // glitch reject
                        end else begin
                            tick_cnt <= tick_cnt + 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end
                DATA: begin   // sample the middle of each bit
                    if (clk_cnt == DIVT-1) begin
                        clk_cnt <= 16'd0;
                        if (tick_cnt == FULL_TICK) begin
                            tick_cnt <= {TW{1'b0}};
                            shreg    <= {rx_b, shreg[7:1]};
                            if (bit_cnt == 3'd7) begin
                                bit_cnt <= 3'd0;
                                state   <= STOP;
                            end else begin
                                bit_cnt <= bit_cnt + 3'd1;
                            end
                        end else begin
                            tick_cnt <= tick_cnt + 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end
                STOP: begin
                    if (clk_cnt == DIVT-1) begin
                        clk_cnt <= 16'd0;
                        if (tick_cnt == FULL_TICK) begin
                            tick_cnt  <= {TW{1'b0}};
                            data      <= shreg;
`ifdef BL_DEBUG
                            $display("[rx] byte 0x%02x", shreg);
`endif
                            valid     <= 1'b1;
                            frame_err <= ~rx_b;
                            state     <= IDLE;
                        end else begin
                            tick_cnt <= tick_cnt + 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end
            endcase
        end
    end
endmodule
