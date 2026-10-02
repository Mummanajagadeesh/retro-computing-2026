// tb_uart.v -- tx->rx loopback, three pairs:
//   A: 115200 @100M 16x, B: 2M @100M 16x, C: 2M @50M 8x (the DOOM link).
// Lockstep: each byte is sent only after the previous one checks out.
module tb_uart (
    input  clk,
    input  rst,
    output reg done,
    output reg pass
);
    reg [7:0] a_txd;
    reg a_txv;
    wire a_busy, a_line, a_rxv, a_ferr;
    wire [7:0] a_rxd;
    uart_tx #(.CLK_FREQ(100_000_000), .BAUD(115_200)) txa (
        .clk(clk), .rst(rst), .data(a_txd), .valid(a_txv),
        .busy(a_busy), .tx(a_line)
    );
    uart_rx #(.CLK_FREQ(100_000_000), .BAUD(115_200), .OVR(16)) rxa (
        .clk(clk), .rst(rst), .rx(a_line),
        .data(a_rxd), .valid(a_rxv), .frame_err(a_ferr)
    );

    reg [7:0] b_txd;
    reg b_txv;
    wire b_busy, b_line, b_rxv, b_ferr;
    wire [7:0] b_rxd;
    uart_tx #(.CLK_FREQ(100_000_000), .BAUD(2_000_000)) txb (
        .clk(clk), .rst(rst), .data(b_txd), .valid(b_txv),
        .busy(b_busy), .tx(b_line)
    );
    uart_rx #(.CLK_FREQ(100_000_000), .BAUD(2_000_000), .OVR(16)) rxb (
        .clk(clk), .rst(rst), .rx(b_line),
        .data(b_rxd), .valid(b_rxv), .frame_err(b_ferr)
    );

    reg [7:0] c_txd;
    reg c_txv;
    wire c_busy, c_line, c_rxv, c_ferr;
    wire [7:0] c_rxd;
    uart_tx #(.CLK_FREQ(50_000_000), .BAUD(2_000_000)) txc (
        .clk(clk), .rst(rst), .data(c_txd), .valid(c_txv),
        .busy(c_busy), .tx(c_line)
    );
    uart_rx #(.CLK_FREQ(50_000_000), .BAUD(2_000_000), .OVR(8)) rxc (
        .clk(clk), .rst(rst), .rx(c_line),
        .data(c_rxd), .valid(c_rxv), .frame_err(c_ferr)
    );

    // corners + ramp + text + LFSR
    reg [7:0] vec [0:127];
    integer i;
    reg [7:0] lfsr;
    initial begin
        vec[0] = 8'h00; vec[1] = 8'hFF; vec[2] = 8'h55; vec[3] = 8'hAA;
        vec[4] = 8'h01; vec[5] = 8'h80; vec[6] = 8'h7F; vec[7] = 8'hFE;
        for (i = 0; i < 32; i = i + 1) vec[8+i] = i[7:0];
        vec[40] = "D"; vec[41] = "O"; vec[42] = "O"; vec[43] = "M";
        vec[44] = "-"; vec[45] = "F"; vec[46] = "P"; vec[47] = "G";
        vec[48] = "A";
        lfsr = 8'h3D;
        for (i = 49; i < 128; i = i + 1) begin
            lfsr   = {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
            vec[i] = lfsr;
        end
    end

    localparam S_SEND = 2'd0, S_WAIT = 2'd1, S_NEXT = 2'd2;
    reg [1:0] sel;
    reg [7:0] idx;
    reg [1:0] st;
    reg [7:0] exp_byte;
    reg [23:0] timeout;
    reg err;

    reg busy, rxv, ferr;
    reg [7:0] rxd;
    always @(*) begin
        case (sel)
            2'd0: begin busy = a_busy; rxv = a_rxv; rxd = a_rxd; ferr = a_ferr; end
            2'd1: begin busy = b_busy; rxv = b_rxv; rxd = b_rxd; ferr = b_ferr; end
            default: begin busy = c_busy; rxv = c_rxv; rxd = c_rxd; ferr = c_ferr; end
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            a_txv <= 1'b0; b_txv <= 1'b0; c_txv <= 1'b0;
            a_txd <= 8'd0; b_txd <= 8'd0; c_txd <= 8'd0;
            sel <= 2'd0; idx <= 8'd0; st <= S_SEND;
            exp_byte <= 8'd0; timeout <= 24'd0;
            err <= 1'b0; done <= 1'b0; pass <= 1'b0;
        end else if (!done) begin
            a_txv <= 1'b0;
            b_txv <= 1'b0;
            c_txv <= 1'b0;
            case (st)
                S_SEND: begin
                    if (!busy) begin
                        case (sel)
                            2'd0: begin a_txd <= vec[idx]; a_txv <= 1'b1; end
                            2'd1: begin b_txd <= vec[idx]; b_txv <= 1'b1; end
                            default: begin c_txd <= vec[idx]; c_txv <= 1'b1; end
                        endcase
                        exp_byte <= vec[idx];
                        timeout  <= 24'd0;
                        st       <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    timeout <= timeout + 24'd1;
                    if (rxv) begin
                        if ((rxd !== exp_byte) || ferr) err <= 1'b1;
                        st <= S_NEXT;
                    end else if (timeout == 24'hFFFFFF) begin
                        err <= 1'b1;
                        st  <= S_NEXT;
                    end
                end
                S_NEXT: begin
                    if (idx == 8'd127) begin
                        if (sel == 2'd2) begin
                            done <= 1'b1;
                            pass <= ~err;
                        end else begin
                            sel <= sel + 2'd1;
                            idx <= 8'd0;
                            st  <= S_SEND;
                        end
                    end else begin
                        idx <= idx + 8'd1;
                        st  <= S_SEND;
                    end
                end
                default: st <= S_SEND;
            endcase
        end
    end
endmodule
