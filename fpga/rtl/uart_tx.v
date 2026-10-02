// uart_tx.v -- 8N1 UART transmitter, parametrized baud divisor.
// Byte in, one start bit, 8 data bits LSB first, one stop bit.
module uart_tx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 115_200,
    parameter DIV      = CLK_FREQ / BAUD   // clocks per bit
) (
    input       clk,
    input       rst,          // sync, active high
    input [7:0] data,
    input       valid,        // pulse: latch data and start
    output reg  busy,         // high while a byte is on the wire
    output reg  tx            // idle high
);
    localparam IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;
    reg [1:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_cnt;
    reg [7:0]  shreg;

    always @(posedge clk) begin
        if (rst) begin
            state   <= IDLE;
            tx      <= 1'b1;
            busy    <= 1'b0;
            clk_cnt <= 16'd0;
            bit_cnt <= 3'd0;
            shreg   <= 8'd0;
        end else begin
            case (state)
                IDLE: begin
                    tx      <= 1'b1;
                    busy    <= 1'b0;
                    clk_cnt <= 16'd0;
                    bit_cnt <= 3'd0;
                    if (valid) begin
                        shreg <= data;
                        busy  <= 1'b1;
                        state <= START;
                    end
                end
                START: begin
                    tx <= 1'b0;
                    if (clk_cnt == DIV-1) begin
                        clk_cnt <= 16'd0;
                        state   <= DATA;
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end
                DATA: begin
                    tx <= shreg[0];
                    if (clk_cnt == DIV-1) begin
                        clk_cnt <= 16'd0;
                        shreg   <= {1'b0, shreg[7:1]};
                        if (bit_cnt == 3'd7) begin
                            bit_cnt <= 3'd0;
                            state   <= STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 3'd1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end
                STOP: begin
                    tx <= 1'b1;
                    if (clk_cnt == DIV-1) begin
                        clk_cnt <= 16'd0;
                        state   <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end
            endcase
        end
    end
endmodule
