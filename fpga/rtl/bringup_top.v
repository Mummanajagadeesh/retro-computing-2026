// bringup_top.v -- DE0-Nano phase-1 bring-up: clock heartbeat, UART echo
// (CP2102 on JP1 header), SDRAM write/readback test. Proves the Quartus
// flow, the TTL wiring, and the SDRAM controller before the core arrives.
//
// Wiring (JP1 40-pin header, board powered by its own USB):
//   JP1 pin 2  (FPGA D3) = UART_RX <- TTL module TX
//   JP1 pin 4  (FPGA C3) = UART_TX -> TTL module RX
//   JP1 pin 12           = GND     -- TTL module GND (common ground only;
//                                     do NOT connect the TTL 5V/3V3 rail)
// UART is 3.3 V, 115200 8N1 for this phase.
//
// LED map: 0 heartbeat 1 Hz, 1 uart-rx activity, 2 uart-tx activity,
//          3 test active, 4 test progress bit, 5 sdram ready,
//          6 FAIL (sticky), 7 PASS (sticky).
module bringup_top (
    input             CLOCK_50,
    input      [1:0]  KEY,          // KEY0 = reset (active low)
    output reg [7:0]  LED,
    input             UART_RX,
    output            UART_TX,
    output     [12:0] DRAM_ADDR,
    output     [1:0]  DRAM_BA,
    inout      [15:0] DRAM_DQ,
    output            DRAM_CAS_N,
    output            DRAM_CKE,
    output            DRAM_CLK,
    output            DRAM_CS_N,
    output     [1:0]  DRAM_DQM,
    output            DRAM_RAS_N,
    output            DRAM_WE_N
);
    wire clk = CLOCK_50;

    // reset: power-on hold + KEY0, synchronized
    reg [15:0] por_cnt;
    reg key0_a, key0_s;
    reg rst;
    initial begin
        por_cnt = 16'd0;
        key0_a  = 1'b1;
        key0_s  = 1'b1;
        rst     = 1'b1;
    end
    always @(posedge clk) begin
        key0_a <= KEY[0];
        key0_s <= key0_a;
        if (por_cnt != 16'hFFFF)
            por_cnt <= por_cnt + 16'd1;
        rst <= (por_cnt != 16'hFFFF) | ~key0_s;
    end

    // UART echo at 115200. One deep: an overrun drops the older byte,
    // impossible at human typing rates.
    wire uart_rxd = UART_RX;
    wire uart_txd;
    assign UART_TX = uart_txd;

    wire [7:0] rx_data;
    wire rx_valid, rx_ferr;
    uart_rx #(.CLK_FREQ(50_000_000), .BAUD(115_200)) urx (
        .clk(clk), .rst(rst), .rx(uart_rxd),
        .data(rx_data), .valid(rx_valid), .frame_err(rx_ferr)
    );

    wire tx_busy;
    reg tx_valid;
    reg [7:0] tx_data;
    uart_tx #(.CLK_FREQ(50_000_000), .BAUD(115_200)) utx (
        .clk(clk), .rst(rst), .data(tx_data), .valid(tx_valid),
        .busy(tx_busy), .tx(uart_txd)
    );

    reg [7:0] echo_data;
    reg echo_pend;
    always @(posedge clk) begin
        if (rst) begin
            echo_pend <= 1'b0;
            tx_valid  <= 1'b0;
            tx_data   <= 8'd0;
            echo_data <= 8'd0;
        end else begin
            tx_valid <= 1'b0;
            if (rx_valid) begin
                echo_data <= rx_data;
                echo_pend <= 1'b1;
            end
            if (echo_pend && !tx_busy) begin
                tx_data   <= echo_data;
                tx_valid  <= 1'b1;
                echo_pend <= 1'b0;
            end
        end
    end

    // SDRAM controller + self test
    wire c_rd_req, c_wr_req, c_rd_ack, c_wr_ack, c_ready;
    wire [22:0] c_addr;
    wire [31:0] c_wr_data, c_rd_data;
    wire [3:0] c_wr_be;
    wire t_pass, t_fail, t_active;
    wire [7:0] t_progress;

    sdram_ctrl #(.CLK_FREQ(50_000_000)) ctrl (
        .clk(clk), .rst(rst), .ready(c_ready),
        .rd_req(c_rd_req), .wr_req(c_wr_req), .addr(c_addr),
        .wr_data(c_wr_data), .wr_be(c_wr_be),
        .rd_ack(c_rd_ack), .rd_data(c_rd_data), .wr_ack(c_wr_ack),
        .DRAM_CLK(DRAM_CLK), .DRAM_CKE(DRAM_CKE),
        .DRAM_CS_N(DRAM_CS_N), .DRAM_RAS_N(DRAM_RAS_N),
        .DRAM_CAS_N(DRAM_CAS_N), .DRAM_WE_N(DRAM_WE_N),
        .DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA),
        .DRAM_DQ(DRAM_DQ), .DRAM_DQM(DRAM_DQM)
    );

    sdram_tester tst (
        .clk(clk), .rst(rst),
        .rd_req(c_rd_req), .wr_req(c_wr_req), .addr(c_addr),
        .wr_data(c_wr_data), .wr_be(c_wr_be),
        .rd_ack(c_rd_ack), .rd_data(c_rd_data), .wr_ack(c_wr_ack),
        .ready(c_ready),
        .pass(t_pass), .fail(t_fail), .active(t_active),
        .progress(t_progress),
        .err_addr(), .err_exp(), .err_got()
    );

    // LEDs: heartbeat + stretchered activity + sticky test result
    reg [24:0] hb_cnt;
    reg hb;
    reg [22:0] rx_stretch, tx_stretch;
    always @(posedge clk) begin
        if (rst) begin
            hb_cnt     <= 25'd0;
            hb         <= 1'b0;
            rx_stretch <= 23'd0;
            tx_stretch <= 23'd0;
            LED        <= 8'd0;
        end else begin
            if (hb_cnt == 25'd25000000-1) begin
                hb_cnt <= 25'd0;
                hb     <= ~hb;
            end else begin
                hb_cnt <= hb_cnt + 25'd1;
            end
            rx_stretch <= rx_valid ? 23'd5000000 :
                          (|rx_stretch ? rx_stretch - 23'd1 : 23'd0);
            tx_stretch <= tx_valid ? 23'd5000000 :
                          (|tx_stretch ? tx_stretch - 23'd1 : 23'd0);
            LED[0] <= hb;
            LED[1] <= |rx_stretch;
            LED[2] <= |tx_stretch;
            LED[3] <= t_active;
            LED[4] <= t_progress[7];
            LED[5] <= c_ready;
            LED[6] <= t_fail;
            LED[7] <= t_pass;
        end
    end
endmodule
