`include "defines.v"

module pc_reg #(
    parameter RESET_PC = 32'h00000000
) (
    input         clk,
    input         rst,
    input         stall,
    input  [31:0] pc_next,
    output reg [31:0] pc
);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pc <= RESET_PC;
        end else if (!stall) begin
            pc <= pc_next;
        end
    end
endmodule
