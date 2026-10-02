`include "defines.v"

module alu_ctrl (
    input      [1:0]  alu_op,
    input      [2:0]  funct3,
    input      [6:0]  funct7,
    input             funct7_5,
    input             is_rtype,
    input             is_lui,
    output reg [4:0]  alu_ctrl
);
    wire is_m_extension = is_rtype && (funct7 == 7'b0000001);
    
    always @(*) begin
        case (alu_op)
            2'b00:   alu_ctrl = `ALU_ADD;
            2'b01:   alu_ctrl = `ALU_SUB;
            2'b10: begin
                if (is_m_extension) begin
                    case (funct3)
                        3'b000:  alu_ctrl = `ALU_MUL;
                        3'b001:  alu_ctrl = `ALU_MULH;
                        3'b010:  alu_ctrl = `ALU_MULHSU;
                        3'b011:  alu_ctrl = `ALU_MULHU;
                        3'b100:  alu_ctrl = `ALU_DIV;
                        3'b101:  alu_ctrl = `ALU_DIVU;
                        3'b110:  alu_ctrl = `ALU_REM;
                        3'b111:  alu_ctrl = `ALU_REMU;
                        default: alu_ctrl = `ALU_ADD;
                    endcase
                end else begin
                    case ({funct7_5, funct3})
                        4'b0000: alu_ctrl = `ALU_ADD;
                        4'b1000: alu_ctrl = `ALU_SUB;
                        4'b0001: alu_ctrl = `ALU_SLL;
                        4'b0010: alu_ctrl = `ALU_SLT;
                        4'b0011: alu_ctrl = `ALU_SLTU;
                        4'b0100: alu_ctrl = `ALU_XOR;
                        4'b0101: alu_ctrl = `ALU_SRL;
                        4'b1101: alu_ctrl = `ALU_SRA;
                        4'b0110: alu_ctrl = `ALU_OR;
                        4'b0111: alu_ctrl = `ALU_AND;
                        default: alu_ctrl = `ALU_ADD;
                    endcase
                end
            end
            2'b11:   alu_ctrl = is_lui ? `ALU_LUI : `ALU_AUIPC;
            default: alu_ctrl = `ALU_NOP;
        endcase
    end
endmodule
