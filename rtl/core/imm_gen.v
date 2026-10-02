`include "defines.v"

module imm_gen (
    input  [31:0] instr,
    input  [2:0]  imm_type,
    output reg [31:0] imm
);
    always @(*) begin
        case (imm_type)
            3'b000: imm = {{20{instr[31]}}, instr[31:20]};
            3'b001: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            3'b010: imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            3'b011: imm = {instr[31:12], 12'b0};
            3'b100: imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            3'b101: imm = {{20{instr[31]}}, instr[31:20]};
            default: imm = `ZERO_WORD;
        endcase
    end
endmodule
