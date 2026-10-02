`include "defines.v"

// CSR file with a REGISTERED read port.
//
// Timing: the old async read mux sat on the worst path in the design
// (id_ex_csr -> ... -> pc, ~35 ns). Only rdata_q exists now: it settles a
// cycle after the address is presented, and the pipeline holds EX for one
// extra cycle on CSR ops (csr_stall in core_top) so the value is always
// correct when consumed.
module csr_reg (
    input         clk,
    input         rst,
    input         we,
    input  [11:0] addr,
    input  [31:0] wdata,
    input  [2:0]  funct3,
    input  [31:0] rs1_data,
    output reg [31:0] rdata_q
);

    reg [31:0] csr [0:15];
    integer i;

    initial begin
        for (i = 0; i < 16; i = i + 1) begin
            csr[i] = 32'h0;
        end
        csr[0] = 32'h0;
        csr[1] = 32'h0;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            csr[0] <= 32'h0;
            csr[1] <= 32'h0;
            csr[2] <= 32'h0;
            csr[3] <= 32'h0;
            csr[4] <= 32'h0;
            csr[5] <= 32'h100;
            csr[6] <= 32'h0;
            csr[7] <= 32'h0;
            csr[8] <= 32'h0;
            csr[9] <= 32'h0;
            csr[10] <= 32'h0;
            csr[11] <= 32'h0;
            rdata_q <= 32'h0;
        end else begin
            if (we) begin
                case (funct3)
                    3'b001: csr[addr[3:0]] <= rs1_data;
                    3'b010: csr[addr[3:0]] <= csr[addr[3:0]] | rs1_data;
                    3'b011: csr[addr[3:0]] <= csr[addr[3:0]] & ~rs1_data;
                    default: csr[addr[3:0]] <= rs1_data;
                endcase
            end
            rdata_q <= csr[addr[3:0]];
        end
    end


endmodule
