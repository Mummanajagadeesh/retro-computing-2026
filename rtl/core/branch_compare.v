`include "defines.v"

module branch_compare (
    input  [31:0] rs1,
    input  [31:0] rs2,
    input  [2:0]  funct3,
    output reg    branch_taken
);
    always @(*) begin
        branch_taken = 1'b0;
        case (funct3)
            3'b000: branch_taken = (rs1 == rs2);
            3'b001: branch_taken = (rs1 != rs2);
            3'b010: branch_taken = 1'b0;
            3'b011: branch_taken = 1'b0;
            3'b100: branch_taken = ($signed(rs1) < $signed(rs2));
            3'b101: branch_taken = ($signed(rs1) >= $signed(rs2));
            3'b110: branch_taken = (rs1 < rs2);
            3'b111: branch_taken = (rs1 >= rs2);
        endcase
    end
endmodule
