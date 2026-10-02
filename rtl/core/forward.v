`include "defines.v"

// fwd_a0/fwd_b0 encoding:
//   2'b00 = regfile
//   2'b10 = slot 0 EX/MEM (older in pair)
//   2'b11 = slot 1 EX/MEM (younger in pair)
//   2'b01 = MEM/WB (either slot, value muxed in core_top)
//
// fwd_a1/fwd_b1 encoding:
//   3'b000 = regfile
//   3'b100 = s0 same-cycle EX result
//   3'b010 = slot 0 EX/MEM (older in pair)
//   3'b011 = slot 1 EX/MEM (younger in pair)
//   3'b001 = MEM/WB (either slot)

module forward (
    input  [4:0]  s0_id_ex_rs1,
    input  [4:0]  s0_id_ex_rs2,
    input  [4:0]  s1_id_ex_rs1,
    input  [4:0]  s1_id_ex_rs2,
    input  [4:0]  s0_ex_mem_rd,
    input         s0_ex_mem_reg_write,
    input  [4:0]  s1_ex_mem_rd,
    input         s1_ex_mem_reg_write,
    input  [4:0]  s0_mem_wb_rd,
    input         s0_mem_wb_reg_write,
    input  [4:0]  s1_mem_wb_rd,
    input         s1_mem_wb_reg_write,
    input  [4:0]  s0_ex_rd,
    input         s0_ex_reg_write,
    output reg [1:0] fwd_a0,
    output reg [1:0] fwd_b0,
    output reg [2:0] fwd_a1,
    output reg [2:0] fwd_b1
);
    always @(*) begin
        // ── slot 0 rs1 ──
        // slot 1 is younger than slot 0 within an issued pair.
        if (s1_ex_mem_reg_write && s1_ex_mem_rd != 0 && s1_ex_mem_rd == s0_id_ex_rs1)
            fwd_a0 = 2'b11;
        else if (s0_ex_mem_reg_write && s0_ex_mem_rd != 0 && s0_ex_mem_rd == s0_id_ex_rs1)
            fwd_a0 = 2'b10;
        else if (s1_mem_wb_reg_write && s1_mem_wb_rd != 0 && s1_mem_wb_rd == s0_id_ex_rs1)
            fwd_a0 = 2'b01;
        else if (s0_mem_wb_reg_write && s0_mem_wb_rd != 0 && s0_mem_wb_rd == s0_id_ex_rs1)
            fwd_a0 = 2'b01;
        else
            fwd_a0 = 2'b00;

        // ── slot 0 rs2 ──
        if (s1_ex_mem_reg_write && s1_ex_mem_rd != 0 && s1_ex_mem_rd == s0_id_ex_rs2)
            fwd_b0 = 2'b11;
        else if (s0_ex_mem_reg_write && s0_ex_mem_rd != 0 && s0_ex_mem_rd == s0_id_ex_rs2)
            fwd_b0 = 2'b10;
        else if (s1_mem_wb_reg_write && s1_mem_wb_rd != 0 && s1_mem_wb_rd == s0_id_ex_rs2)
            fwd_b0 = 2'b01;
        else if (s0_mem_wb_reg_write && s0_mem_wb_rd != 0 && s0_mem_wb_rd == s0_id_ex_rs2)
            fwd_b0 = 2'b01;
        else
            fwd_b0 = 2'b00;

        // ── slot 1 rs1 ──
        if (s0_ex_reg_write && s0_ex_rd != 0 && s0_ex_rd == s1_id_ex_rs1)
            fwd_a1 = 3'b100;
        else if (s1_ex_mem_reg_write && s1_ex_mem_rd != 0 && s1_ex_mem_rd == s1_id_ex_rs1)
            fwd_a1 = 3'b011;
        else if (s0_ex_mem_reg_write && s0_ex_mem_rd != 0 && s0_ex_mem_rd == s1_id_ex_rs1)
            fwd_a1 = 3'b010;
        else if (s1_mem_wb_reg_write && s1_mem_wb_rd != 0 && s1_mem_wb_rd == s1_id_ex_rs1)
            fwd_a1 = 3'b001;
        else if (s0_mem_wb_reg_write && s0_mem_wb_rd != 0 && s0_mem_wb_rd == s1_id_ex_rs1)
            fwd_a1 = 3'b001;
        else
            fwd_a1 = 3'b000;

        // ── slot 1 rs2 ──
        if (s0_ex_reg_write && s0_ex_rd != 0 && s0_ex_rd == s1_id_ex_rs2)
            fwd_b1 = 3'b100;
        else if (s1_ex_mem_reg_write && s1_ex_mem_rd != 0 && s1_ex_mem_rd == s1_id_ex_rs2)
            fwd_b1 = 3'b011;
        else if (s0_ex_mem_reg_write && s0_ex_mem_rd != 0 && s0_ex_mem_rd == s1_id_ex_rs2)
            fwd_b1 = 3'b010;
        else if (s1_mem_wb_reg_write && s1_mem_wb_rd != 0 && s1_mem_wb_rd == s1_id_ex_rs2)
            fwd_b1 = 3'b001;
        else if (s0_mem_wb_reg_write && s0_mem_wb_rd != 0 && s0_mem_wb_rd == s1_id_ex_rs2)
            fwd_b1 = 3'b001;
        else
            fwd_b1 = 3'b000;
    end
endmodule
