`include "defines.v"

module control (
    input      [6:0] opcode,
    input      [2:0] funct3,
    input      [6:0] funct7,
    output reg       mem_read,
    output reg       mem_write,
    output reg       reg_write,
    output reg       mem_to_reg,
    output reg       alu_src,
    output reg [1:0] alu_op,
    output reg       auipc,
    output reg       is_lui,
    output reg [2:0] imm_type,
    output reg       branch,
    output reg       jal,
    output reg       jalr,
    output reg       ecall,
    output reg       halt,
    output reg       csr_read,
    output reg       csr_write
);
    always @(*) begin
        mem_read    = 1'b0;
        mem_write   = 1'b0;
        reg_write   = 1'b0;
        mem_to_reg  = 1'b0;
        alu_src     = 1'b0;
        alu_op      = 2'b00;
        auipc       = 1'b0;
        is_lui      = 1'b0;
        imm_type    = 3'b000;
        branch      = 1'b0;
        jal         = 1'b0;
        jalr        = 1'b0;
        ecall       = 1'b0;
        halt        = 1'b0;
        csr_read    = 1'b0;
        csr_write   = 1'b0;

        case (opcode)
            `OPCODE_LOAD: begin
                mem_read   = 1'b1;
                reg_write  = 1'b1;
                mem_to_reg = 1'b1;
                alu_src    = 1'b1;
                alu_op     = 2'b00;
                imm_type   = 3'b000;
            end
            `OPCODE_STORE: begin
                mem_write  = 1'b1;
                alu_src    = 1'b1;
                alu_op     = 2'b00;
                imm_type   = 3'b001;
            end
            `OPCODE_BRANCH: begin
                branch    = 1'b1;
                alu_op    = 2'b01;
                imm_type  = 3'b010;
            end
            `OPCODE_JALR: begin
                reg_write  = 1'b1;
                jalr       = 1'b1;
                alu_op     = 2'b00;
                imm_type   = 3'b000;
            end
            `OPCODE_JAL: begin
                reg_write  = 1'b1;
                jal        = 1'b1;
                alu_op     = 2'b00;
                imm_type   = 3'b100;
            end
            `OPCODE_AUIPC: begin
                reg_write  = 1'b1;
                auipc      = 1'b1;
                alu_src    = 1'b1;
                alu_op     = 2'b11;
                imm_type   = 3'b011;
            end
            `OPCODE_LUI: begin
                reg_write  = 1'b1;
                is_lui     = 1'b1;
                alu_src    = 1'b1;
                alu_op     = 2'b11;
                imm_type   = 3'b011;
            end
            `OPCODE_OP_IMM: begin
                reg_write  = 1'b1;
                alu_src    = 1'b1;
                alu_op     = 2'b10;
                imm_type   = 3'b000;
            end
            `OPCODE_OP: begin
                reg_write  = 1'b1;
                alu_op     = 2'b10;
            end
            `OPCODE_CSR: begin
                if (funct3 == 3'b000) begin
                    ecall  = 1'b1;
                    halt   = 1'b1;
                end else begin
                    reg_write = 1'b1;
                    csr_read  = 1'b1;
                    csr_write = 1'b1;
                end
            end
            default: begin end
        endcase
    end
endmodule