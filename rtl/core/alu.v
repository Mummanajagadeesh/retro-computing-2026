`include "defines.v"

// Single-cycle integer ops plus the iterative M unit (muldiv.v).
//
// ADD/SUB/shifts/compares/logic/LUI and MUL-low stay combinational here.
// MUL (low 32) is one 32x32 multiply and maps to the chip's embedded
// multiplier blocks. The seven wide M ops (MULH/MULHSU/MULHU and
// DIV/DIVU/REM/REMU) run in the muldiv unit over 33 cycles; the core
// freezes the front of the pipe while md_busy is high (see core_top).
// They used to be combinational 64 bit products and 32 bit dividers,
// which priced at several thousand LEs per ALU in synthesis.
module alu (
    input                   clk,
    input                   rst,
    input  [`DATA_WIDTH-1:0] a,
    input  [`DATA_WIDTH-1:0] b,
    input  [4:0]             alu_op,
    output reg [`DATA_WIDTH-1:0] result,
    output                      zero,
    output                      md_busy,
    output                      md_done
);
    wire [31:0] md_result;
    wire        md_busy_w;
    muldiv md (
        .clk(clk), .rst(rst),
        .a(a), .b(b), .alu_op(alu_op),
        .result(md_result), .md_busy(md_busy_w), .md_done(md_done)
    );
    assign md_busy = md_busy_w;

    wire op_is_m = (alu_op == `ALU_MULH)  || (alu_op == `ALU_MULHSU) ||
                   (alu_op == `ALU_MULHU) || (alu_op == `ALU_DIV)   ||
                   (alu_op == `ALU_DIVU)  || (alu_op == `ALU_REM)   ||
                   (alu_op == `ALU_REMU);

    always @(*) begin
        if (op_is_m)
            result = md_result;
        else begin
            case (alu_op)
                `ALU_ADD:   result = a + b;
                `ALU_SUB:   result = a - b;
                `ALU_SLL:   result = a << b[4:0];
                `ALU_SLT:   result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
                `ALU_SLTU:  result = (a < b) ? 32'd1 : 32'd0;
                `ALU_XOR:   result = a ^ b;
                `ALU_SRL:   result = a >> b[4:0];
                `ALU_SRA:   result = $signed(a) >>> b[4:0];
                `ALU_OR:    result = a | b;
                `ALU_AND:   result = a & b;
                `ALU_LUI:   result = b;
                `ALU_AUIPC: result = a + b;
                // BUGFIX (MUL low): kept from the old code. The low word of
                // a 32x32 product is the same for every signedness, so the
                // plain 32 bit multiply is correct here and infers one
                // embedded multiplier.
                `ALU_MUL:   result = a * b;
                `ALU_NOP:   result = `ZERO_WORD;
                default:    result = `ZERO_WORD;
            endcase
        end
    end

    assign zero = (result == `ZERO_WORD);
endmodule
