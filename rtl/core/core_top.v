`include "defines.v"

module core_top #(
    parameter RESET_PC = 32'h00000000
) (
    input         clk,
    input         rst,
    input  [31:0] instr0,
    input  [31:0] instr1,
    input  [31:0] mem_read_data0,
    output        mem_read0,
    output        mem_write0,
    output [31:0] mem_addr0,
    output [31:0] mem_wdata0,
    output [2:0]  mem_funct30,
    input  [31:0] mem_read_data1,
    output        mem_read1,
    output        mem_write1,
    output [31:0] mem_addr1,
    output [31:0] mem_wdata1,
    output [2:0]  mem_funct31,
    output [31:0] pc_out,
    output        reg_write0,
    output [4:0]  reg_wa0,
    output [31:0] reg_wd0,
    output        reg_write1,
    output [4:0]  reg_wa1,
    output [31:0] reg_wd1,
    output        ecall,
    output        halt
);

    wire stall_if, stall_id, flush_id, flush_ex, squash_s1;
    wire hz_flush_id, hz_flush_ex;
    wire md_busy0, md_busy1;
    wire md_stall = md_busy0 || md_busy1;
    wire md_done0, md_done1;
    wire md_release = md_done0 || md_done1;
    wire [1:0] fwd_a0, fwd_b0;
    wire [2:0] fwd_a1, fwd_b1;

    // Registered EX redirect (timing): both slots resolve control in EX and
    // the redirect takes effect one cycle later through these flops, so the
    // deep forward+ALU+compare cone ends at a register instead of at the PC.
    reg exr_valid;
    reg [31:0] exr_pc;

    // CSR settle stall (timing): the CSR file read is registered, so an EX
    // stage holding a CSR op takes one extra cycle for the data to arrive.
    reg csr_stall_q;
    wire ex_csr_active;
    wire csr_stall;
    wire csr_hold;
    wire csr_we0, csr_we1;

    // Freeze only IF/ID/EX once halt reaches EX/MEM.
    // Keep EX/MEM->MEM/WB advancing so halt can retire in WB.
    wire pipe_halt = ex_mem_halt0 || ex_mem_halt1;

    // =========================================================
    // IF
    // =========================================================
    wire [31:0] pc_current;
    wire [31:0] pc_plus4 = pc_current + 32'd4;
    wire [31:0] pc_plus8 = pc_current + 32'd8;
    wire [31:0] pc_next;

    // Hybrid branch predictor on slot 0 fetch stream.
`ifdef PRED_SMALL
    localparam integer HYBP_IDX_BITS = 4;
`else
    localparam integer HYBP_IDX_BITS = 8;
`endif
    localparam integer HYBP_ENTRIES = (1 << HYBP_IDX_BITS);
    localparam integer HYBP_GHR_BITS = 8;

`ifdef PRED_SMALL
    localparam integer BTB_IDX_BITS = 4;
`else
    localparam integer BTB_IDX_BITS = 8;
`endif
    localparam integer BTB_ENTRIES = (1 << BTB_IDX_BITS);
    localparam integer RAS_DEPTH = 16;
    localparam integer RAS_PTR_BITS = 4;

    reg [1:0] hybp_local_pht  [0:HYBP_ENTRIES-1];
    reg [1:0] hybp_global_pht [0:HYBP_ENTRIES-1];
    reg [1:0] hybp_choice_pht [0:HYBP_ENTRIES-1];
    reg [HYBP_GHR_BITS-1:0] hybp_ghr;
    reg       btb_valid [0:BTB_ENTRIES-1];
    reg [31:0] btb_tag [0:BTB_ENTRIES-1];
    reg [31:0] btb_target [0:BTB_ENTRIES-1];
    reg [31:0] ras_stack [0:RAS_DEPTH-1];
    reg [RAS_PTR_BITS-1:0] ras_top_ptr;
    reg [RAS_PTR_BITS:0] ras_count;
    integer hybp_i;
    integer ras_i;

    wire [HYBP_IDX_BITS-1:0] if_pred_pc_idx = pc_current[HYBP_IDX_BITS+1:2] ^ pc_current[HYBP_IDX_BITS+7:HYBP_IDX_BITS];
    wire if_is_branch0 = (instr0[6:0] == `OPCODE_BRANCH);
    wire if_is_jal0 = (instr0[6:0] == `OPCODE_JAL);
    wire if_is_jalr0 = (instr0[6:0] == `OPCODE_JALR);
    wire [4:0] if_rd0 = instr0[11:7];
    wire [4:0] if_rs1_0 = instr0[19:15];
    wire [31:0] if_branch_imm0 = {{19{instr0[31]}}, instr0[31], instr0[7], instr0[30:25], instr0[11:8], 1'b0};
    wire [31:0] if_jal_imm0 = {{11{instr0[31]}}, instr0[31], instr0[19:12], instr0[20], instr0[30:21], 1'b0};
    wire [31:0] if_jalr_imm0 = {{20{instr0[31]}}, instr0[31:20]};
    wire if_is_ret0 = if_is_jalr0 && (if_rd0 == 5'd0) &&
                      ((if_rs1_0 == 5'd1) || (if_rs1_0 == 5'd5)) && (if_jalr_imm0 == 32'd0);
    wire ras_has_entry0 = (ras_count != 0);
    wire [31:0] if_ras_target0 = ras_has_entry0 ? ras_stack[ras_top_ptr] : 32'b0;
    wire [BTB_IDX_BITS-1:0] if_btb_idx0 = pc_current[BTB_IDX_BITS+1:2];
    wire if_btb_hit0 = btb_valid[if_btb_idx0] && (btb_tag[if_btb_idx0] == pc_current);
    wire [HYBP_IDX_BITS-1:0] if_local_idx0 = if_pred_pc_idx;
    wire [HYBP_IDX_BITS-1:0] if_global_idx0 = if_pred_pc_idx ^ hybp_ghr[HYBP_IDX_BITS-1:0];
    wire if_local_pred_taken0 = hybp_local_pht[if_local_idx0][1];
    wire if_global_pred_taken0 = hybp_global_pht[if_global_idx0][1];
    wire if_choose_global0 = hybp_choice_pht[if_global_idx0][1];
    wire if_pred_branch_taken0 = if_choose_global0 ? if_global_pred_taken0 : if_local_pred_taken0;
    wire if_pred_jal_taken0 = if_is_jal0;
    wire if_pred_jalr_taken0 = if_is_jalr0 && (if_is_ret0 ? ras_has_entry0 : if_btb_hit0);
    wire if_pred_taken0 = (if_is_branch0 && if_pred_branch_taken0) || if_pred_jal_taken0 || if_pred_jalr_taken0;
    wire [31:0] if_pred_target0 = if_is_branch0 ? (if_btb_hit0 ? btb_target[if_btb_idx0] : (pc_current + if_branch_imm0)) :
                               if_is_jal0    ? (pc_current + if_jal_imm0) :
                               if_is_ret0    ? if_ras_target0 :
                                               btb_target[if_btb_idx0];

    pc_reg #(.RESET_PC(RESET_PC)) pc_counter (
        .clk    (clk),
        .rst    (rst),
        .stall  (stall_if || pipe_halt || md_stall || (md_release && !flush_id)),
        .pc_next(pc_next),
        .pc     (pc_current)
    );

    assign pc_out = pc_current;

    // =========================================================
    // IF/ID
    // =========================================================
    reg [31:0] if_id_pc0, if_id_pc1;
    reg [31:0] if_id_instr0, if_id_instr1;
    reg        if_id_valid0, if_id_valid1;
    reg        if_id_pred_taken0;
    reg [31:0] if_id_pred_target0;
    reg [HYBP_IDX_BITS-1:0] if_id_local_idx0;
    reg [HYBP_IDX_BITS-1:0] if_id_global_idx0;
    reg        if_id_local_pred_taken0;
    reg        if_id_global_pred_taken0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            if_id_pc0    <= 32'b0; if_id_pc1    <= 32'b0;
            if_id_instr0 <= 32'h0000_0013; if_id_instr1 <= 32'h0000_0013;
            if_id_valid0 <= 1'b0; if_id_valid1 <= 1'b0;
            if_id_pred_taken0 <= 1'b0;
            if_id_pred_target0 <= 32'b0;
            if_id_local_idx0 <= {HYBP_IDX_BITS{1'b0}};
            if_id_global_idx0 <= {HYBP_IDX_BITS{1'b0}};
            if_id_local_pred_taken0 <= 1'b0;
            if_id_global_pred_taken0 <= 1'b0;
        end else if (flush_id) begin
            if_id_pc0    <= 32'b0; if_id_pc1    <= 32'b0;
            if_id_instr0 <= 32'h0000_0013; if_id_instr1 <= 32'h0000_0013;
            if_id_valid0 <= 1'b0; if_id_valid1 <= 1'b0;
            if_id_pred_taken0 <= 1'b0;
            if_id_pred_target0 <= 32'b0;
            if_id_local_idx0 <= {HYBP_IDX_BITS{1'b0}};
            if_id_global_idx0 <= {HYBP_IDX_BITS{1'b0}};
            if_id_local_pred_taken0 <= 1'b0;
            if_id_global_pred_taken0 <= 1'b0;
        end else if (!stall_id && !pipe_halt && !md_stall && !md_release) begin
            if_id_pc0    <= pc_current;
            if_id_pc1    <= pc_current + 32'd4;
            if_id_instr0 <= instr0;
            if_id_instr1 <= instr1;
            if_id_valid0 <= 1'b1;
            if_id_valid1 <= 1'b1;
            if_id_pred_taken0 <= if_pred_taken0;
            if_id_pred_target0 <= if_pred_target0;
            if_id_local_idx0 <= if_local_idx0;
            if_id_global_idx0 <= if_global_idx0;
            if_id_local_pred_taken0 <= if_local_pred_taken0;
            if_id_global_pred_taken0 <= if_global_pred_taken0;
        end
    end

    // =========================================================
    // ID — decode both slots
    // =========================================================
    wire [6:0] id_opcode0 = if_id_instr0[6:0];
    wire [2:0] id_funct30 = if_id_instr0[14:12];
    wire [6:0] id_funct70 = if_id_instr0[31:25];
    wire [4:0] id_rd0     = if_id_instr0[11:7];
    wire [4:0] id_rs1_0   = if_id_instr0[19:15];
    wire [4:0] id_rs2_0   = if_id_instr0[24:20];
    wire [11:0] id_csr0   = if_id_instr0[31:20];
    wire        id_use_rs1_0 = (id_opcode0 == `OPCODE_LOAD)   ||
                               (id_opcode0 == `OPCODE_STORE)  ||
                               (id_opcode0 == `OPCODE_BRANCH) ||
                               (id_opcode0 == `OPCODE_JALR)   ||
                               (id_opcode0 == `OPCODE_OP_IMM) ||
                               (id_opcode0 == `OPCODE_OP)     ||
                               ((id_opcode0 == `OPCODE_CSR) && (id_funct30 != 3'b000) && !id_funct30[2]);
    wire        id_use_rs2_0 = (id_opcode0 == `OPCODE_STORE)  ||
                               (id_opcode0 == `OPCODE_BRANCH) ||
                               (id_opcode0 == `OPCODE_OP);

    wire id_mem_read0, id_mem_write0, id_reg_write0, id_mem_to_reg0;
    wire id_alu_src0, id_auipc0, id_is_lui0;
    wire [1:0] id_alu_op0;
    wire [2:0] id_imm_type0;
    wire id_branch0, id_jal0, id_jalr0, id_ecall0, id_halt0;
    wire id_csr_read0, id_csr_write0;

    control ctrl0 (
        .opcode(id_opcode0), .funct3(id_funct30), .funct7(id_funct70),
        .mem_read(id_mem_read0), .mem_write(id_mem_write0),
        .reg_write(id_reg_write0), .mem_to_reg(id_mem_to_reg0),
        .alu_src(id_alu_src0), .alu_op(id_alu_op0),
        .auipc(id_auipc0), .is_lui(id_is_lui0), .imm_type(id_imm_type0),
        .branch(id_branch0), .jal(id_jal0), .jalr(id_jalr0),
        .ecall(id_ecall0), .halt(id_halt0),
        .csr_read(id_csr_read0), .csr_write(id_csr_write0)
    );

    wire [31:0] id_imm0;
    imm_gen ig0 (.instr(if_id_instr0), .imm_type(id_imm_type0), .imm(id_imm0));

    wire [6:0] id_opcode1 = if_id_instr1[6:0];
    wire [2:0] id_funct31 = if_id_instr1[14:12];
    wire [6:0] id_funct71 = if_id_instr1[31:25];
    wire [4:0] id_rd1_w   = if_id_instr1[11:7];
    wire [4:0] id_rs1_1   = if_id_instr1[19:15];
    wire [4:0] id_rs2_1   = if_id_instr1[24:20];
    wire [11:0] id_csr1   = if_id_instr1[31:20];
    wire        id_use_rs1_1 = (id_opcode1 == `OPCODE_LOAD)   ||
                               (id_opcode1 == `OPCODE_STORE)  ||
                               (id_opcode1 == `OPCODE_BRANCH) ||
                               (id_opcode1 == `OPCODE_JALR)   ||
                               (id_opcode1 == `OPCODE_OP_IMM) ||
                               (id_opcode1 == `OPCODE_OP)     ||
                               ((id_opcode1 == `OPCODE_CSR) && (id_funct31 != 3'b000) && !id_funct31[2]);
    wire        id_use_rs2_1 = (id_opcode1 == `OPCODE_STORE)  ||
                               (id_opcode1 == `OPCODE_BRANCH) ||
                               (id_opcode1 == `OPCODE_OP);

    wire id_mem_read1, id_mem_write1, id_reg_write1, id_mem_to_reg1;
    wire id_alu_src1, id_auipc1, id_is_lui1;
    wire [1:0] id_alu_op1;
    wire [2:0] id_imm_type1;
    wire id_branch1, id_jal1, id_jalr1, id_ecall1, id_halt1;
    wire id_csr_read1, id_csr_write1;

    control ctrl1 (
        .opcode(id_opcode1), .funct3(id_funct31), .funct7(id_funct71),
        .mem_read(id_mem_read1), .mem_write(id_mem_write1),
        .reg_write(id_reg_write1), .mem_to_reg(id_mem_to_reg1),
        .alu_src(id_alu_src1), .alu_op(id_alu_op1),
        .auipc(id_auipc1), .is_lui(id_is_lui1), .imm_type(id_imm_type1),
        .branch(id_branch1), .jal(id_jal1), .jalr(id_jalr1),
        .ecall(id_ecall1), .halt(id_halt1),
        .csr_read(id_csr_read1), .csr_write(id_csr_write1)
    );

    wire [31:0] id_imm1;
    imm_gen ig1 (.instr(if_id_instr1), .imm_type(id_imm_type1), .imm(id_imm1));

    wire id_is_rtype0 = (id_opcode0 == `OPCODE_OP);
    wire id_is_rtype1 = (id_opcode1 == `OPCODE_OP);
    // Iterative-M decode in ID (R-type, funct7=M, funct3!=MUL): matches muldiv op_is_m.
    wire s0_id_is_m = id_is_rtype0 && (if_id_instr0[31:25] == 7'b0000001) && (if_id_instr0[14:12] != 3'b000);
    wire s1_id_is_m = id_is_rtype1 && (if_id_instr1[31:25] == 7'b0000001) && (if_id_instr1[14:12] != 3'b000);

    wire [31:0] id_rd1_raw0, id_rd2_raw0, id_rd1_raw1, id_rd2_raw1;

    registers regs (
        .clk(clk), .rst(rst),
        .we0(reg_write0), .wa0(reg_wa0), .wd0(reg_wd0),
        .we1(reg_write1), .wa1(reg_wa1), .wd1(reg_wd1),
        .ra1(id_rs1_0), .rd1(id_rd1_raw0),
        .ra2(id_rs2_0), .rd2(id_rd2_raw0),
        .ra3(id_rs1_1), .rd3(id_rd1_raw1),
        .ra4(id_rs2_1), .rd4(id_rd2_raw1)
    );

    // WB→ID bypass
    wire [31:0] id_rd1_0 = (reg_write1 && reg_wa1 != 0 && reg_wa1 == id_rs1_0) ? reg_wd1 :
                           (reg_write0 && reg_wa0 != 0 && reg_wa0 == id_rs1_0) ? reg_wd0 :
                           id_rd1_raw0;
    wire [31:0] id_rd2_0 = (reg_write1 && reg_wa1 != 0 && reg_wa1 == id_rs2_0) ? reg_wd1 :
                           (reg_write0 && reg_wa0 != 0 && reg_wa0 == id_rs2_0) ? reg_wd0 :
                           id_rd2_raw0;
    wire [31:0] id_rd1_1 = (reg_write1 && reg_wa1 != 0 && reg_wa1 == id_rs1_1) ? reg_wd1 :
                           (reg_write0 && reg_wa0 != 0 && reg_wa0 == id_rs1_1) ? reg_wd0 :
                           id_rd1_raw1;
    wire [31:0] id_rd2_1 = (reg_write1 && reg_wa1 != 0 && reg_wa1 == id_rs2_1) ? reg_wd1 :
                           (reg_write0 && reg_wa0 != 0 && reg_wa0 == id_rs2_1) ? reg_wd0 :
                           id_rd2_raw1;

    // Inter-slot memory dependency check (luopt): only treat as dependency when
    // store/load widths match and low address bits alias.
    wire s0_is_store = id_mem_write0;
    wire s1_is_load = id_mem_read1;
    wire s0_store_word = s0_is_store && (id_funct30 == 3'b010);
    wire s0_store_half = s0_is_store && (id_funct30 == 3'b001);
    wire s0_store_byte = s0_is_store && (id_funct30 == 3'b000);
    wire s1_load_word = s1_is_load && (id_funct31 == 3'b010);
    wire s1_load_half = s1_is_load && ((id_funct31 == 3'b001) || (id_funct31 == 3'b101));
    wire s1_load_byte = s1_is_load && ((id_funct31 == 3'b000) || (id_funct31 == 3'b100));
    wire s0s1_addr_alias_w = (id_imm0[1:0] == id_imm1[1:0]);
    wire s0s1_addr_alias_h = (id_imm0[1] == id_imm1[1]);
    wire s0s1_addr_alias_b = 1'b1;
    wire s0_s1_mem_dep = (s0_store_word && s1_load_word && s0s1_addr_alias_w) ||
                         (s0_store_half && s1_load_half && s0s1_addr_alias_h) ||
                         (s0_store_byte && s1_load_byte && s0s1_addr_alias_b);

    // squash_s1: zero out all slot 1 control signals
    wire eff_id_mem_read1   = squash_s1 ? 1'b0 : id_mem_read1;
    wire eff_id_mem_write1  = squash_s1 ? 1'b0 : id_mem_write1;
    wire eff_id_reg_write1  = squash_s1 ? 1'b0 : id_reg_write1;
    wire eff_id_mem_to_reg1 = squash_s1 ? 1'b0 : id_mem_to_reg1;
    wire eff_id_alu_src1    = squash_s1 ? 1'b0 : id_alu_src1;
    wire [1:0] eff_id_alu_op1 = squash_s1 ? 2'b0 : id_alu_op1;
    wire eff_id_auipc1      = squash_s1 ? 1'b0 : id_auipc1;
    wire eff_id_is_lui1     = squash_s1 ? 1'b0 : id_is_lui1;
    wire eff_id_branch1     = squash_s1 ? 1'b0 : id_branch1;
    wire eff_id_jal1        = squash_s1 ? 1'b0 : id_jal1;
    wire eff_id_jalr1       = squash_s1 ? 1'b0 : id_jalr1;
    wire eff_id_ecall1      = squash_s1 ? 1'b0 : id_ecall1;
    wire eff_id_halt1       = squash_s1 ? 1'b0 : id_halt1;
    wire eff_id_csr_read1   = squash_s1 ? 1'b0 : id_csr_read1;
    wire eff_id_csr_write1  = squash_s1 ? 1'b0 : id_csr_write1;
    wire eff_id_is_rtype1   = squash_s1 ? 1'b0 : id_is_rtype1;
    wire [4:0] eff_id_rd1   = squash_s1 ? 5'b0 : id_rd1_w;

    // =========================================================
    // ID/EX — slot 0
    // =========================================================
    reg [31:0] id_ex_pc0, id_ex_rd1_0, id_ex_rd2_0, id_ex_imm0;
    reg [4:0]  id_ex_rs1_0, id_ex_rs2_0, id_ex_rd0;
    reg [2:0]  id_ex_funct3_0;
    reg [6:0]  id_ex_funct7_0;
    reg [11:0] id_ex_csr0;
    reg        id_ex_mem_read0, id_ex_mem_write0, id_ex_reg_write0, id_ex_mem_to_reg0;
    reg        id_ex_alu_src0, id_ex_auipc0, id_ex_is_lui0;
    reg [1:0]  id_ex_alu_op0;
    reg        id_ex_branch0, id_ex_jal0, id_ex_jalr0;
    reg        id_ex_ecall0, id_ex_halt0, id_ex_csr_read0, id_ex_csr_write0;
    reg        id_ex_is_rtype0;
    reg        id_ex_valid0;
    reg        id_ex_pred_taken0;
    reg [31:0] id_ex_pred_target0;
    reg [HYBP_IDX_BITS-1:0] id_ex_local_idx0;
    reg [HYBP_IDX_BITS-1:0] id_ex_global_idx0;
    reg        id_ex_local_pred_taken0;
    reg        id_ex_global_pred_taken0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            id_ex_pc0 <= 0; id_ex_rd1_0 <= 0; id_ex_rd2_0 <= 0; id_ex_imm0 <= 0;
            id_ex_rs1_0 <= 0; id_ex_rs2_0 <= 0; id_ex_rd0 <= 0;
            id_ex_funct3_0 <= 0; id_ex_funct7_0 <= 0; id_ex_csr0 <= 0;
            id_ex_mem_read0 <= 0; id_ex_mem_write0 <= 0; id_ex_reg_write0 <= 0;
            id_ex_mem_to_reg0 <= 0; id_ex_alu_src0 <= 0; id_ex_alu_op0 <= 0;
            id_ex_auipc0 <= 0; id_ex_is_lui0 <= 0; id_ex_branch0 <= 0;
            id_ex_jal0 <= 0; id_ex_jalr0 <= 0; id_ex_ecall0 <= 0;
            id_ex_halt0 <= 0; id_ex_csr_read0 <= 0; id_ex_csr_write0 <= 0;
            id_ex_is_rtype0 <= 0;
            id_ex_valid0 <= 0;
            id_ex_pred_taken0 <= 1'b0;
            id_ex_pred_target0 <= 32'b0;
            id_ex_local_idx0 <= {HYBP_IDX_BITS{1'b0}};
            id_ex_global_idx0 <= {HYBP_IDX_BITS{1'b0}};
            id_ex_local_pred_taken0 <= 1'b0;
            id_ex_global_pred_taken0 <= 1'b0;
        end else if (flush_ex_idex) begin
            id_ex_pc0 <= 0; id_ex_rd1_0 <= 0; id_ex_rd2_0 <= 0; id_ex_imm0 <= 0;
            id_ex_rs1_0 <= 0; id_ex_rs2_0 <= 0; id_ex_rd0 <= 0;
            id_ex_funct3_0 <= 0; id_ex_funct7_0 <= 0; id_ex_csr0 <= 0;
            id_ex_mem_read0 <= 0; id_ex_mem_write0 <= 0; id_ex_reg_write0 <= 0;
            id_ex_mem_to_reg0 <= 0; id_ex_alu_src0 <= 0; id_ex_alu_op0 <= 0;
            id_ex_auipc0 <= 0; id_ex_is_lui0 <= 0; id_ex_branch0 <= 0;
            id_ex_jal0 <= 0; id_ex_jalr0 <= 0; id_ex_ecall0 <= 0;
            id_ex_halt0 <= 0; id_ex_csr_read0 <= 0; id_ex_csr_write0 <= 0;
            id_ex_is_rtype0 <= 0;
            id_ex_valid0 <= 0;
            id_ex_pred_taken0 <= 1'b0;
            id_ex_pred_target0 <= 32'b0;
            id_ex_local_idx0 <= {HYBP_IDX_BITS{1'b0}};
            id_ex_global_idx0 <= {HYBP_IDX_BITS{1'b0}};
            id_ex_local_pred_taken0 <= 1'b0;
            id_ex_global_pred_taken0 <= 1'b0;
        end else if (!pipe_halt && !md_stall && !csr_stall) begin
            id_ex_pc0         <= if_id_pc0;
            id_ex_rd1_0       <= id_rd1_0;
            id_ex_rd2_0       <= id_rd2_0;
            id_ex_imm0        <= id_imm0;
            id_ex_rs1_0       <= id_rs1_0;
            id_ex_rs2_0       <= id_rs2_0;
            id_ex_rd0         <= id_rd0;
            id_ex_funct3_0    <= id_funct30;
            id_ex_funct7_0    <= id_funct70;
            id_ex_csr0        <= id_csr0;
            id_ex_mem_read0   <= id_mem_read0;
            id_ex_mem_write0  <= id_mem_write0;
            id_ex_reg_write0  <= id_reg_write0;
            id_ex_mem_to_reg0 <= id_mem_to_reg0;
            id_ex_alu_src0    <= id_alu_src0;
            id_ex_alu_op0     <= id_alu_op0;
            id_ex_auipc0      <= id_auipc0;
            id_ex_is_lui0     <= id_is_lui0;
            // Slot 0 control resolves in EX (registered redirect below).
            id_ex_branch0     <= id_branch0;
            id_ex_jal0        <= id_jal0;
            id_ex_jalr0       <= id_jalr0;
            id_ex_ecall0      <= id_ecall0;
            id_ex_halt0       <= id_halt0;
            id_ex_csr_read0   <= id_csr_read0;
            id_ex_csr_write0  <= id_csr_write0;
            id_ex_is_rtype0   <= id_is_rtype0;
            id_ex_valid0      <= if_id_valid0;
            id_ex_pred_taken0 <= if_id_pred_taken0;
            id_ex_pred_target0 <= if_id_pred_target0;
            id_ex_local_idx0 <= if_id_local_idx0;
            id_ex_global_idx0 <= if_id_global_idx0;
            id_ex_local_pred_taken0 <= if_id_local_pred_taken0;
            id_ex_global_pred_taken0 <= if_id_global_pred_taken0;
        end else if (md_stall && !pipe_halt) begin
            // M-unit running: the back end keeps draining, so producers
            // write back mid-stall. Refresh the held fallbacks from live
            // WB or the held pair's EX inputs decay to stale values once
            // their EX/MEM forward drains away. Priority matches the
            // ID-stage forward and the register file (slot 1 wins).
            id_ex_rd1_0 <= (reg_write1 && reg_wa1 != 5'b0 && reg_wa1 == id_ex_rs1_0) ? reg_wd1 :
                           (reg_write0 && reg_wa0 != 5'b0 && reg_wa0 == id_ex_rs1_0) ? reg_wd0 : id_ex_rd1_0;
            id_ex_rd2_0 <= (reg_write1 && reg_wa1 != 5'b0 && reg_wa1 == id_ex_rs2_0) ? reg_wd1 :
                           (reg_write0 && reg_wa0 != 5'b0 && reg_wa0 == id_ex_rs2_0) ? reg_wd0 : id_ex_rd2_0;
        end
    end

    // =========================================================
    // ID/EX — slot 1
    // =========================================================
    reg [31:0] id_ex_pc1, id_ex_rd1_1, id_ex_rd2_1, id_ex_imm1;
    reg [4:0]  id_ex_rs1_1, id_ex_rs2_1, id_ex_rd1;
    reg [2:0]  id_ex_funct3_1;
    reg [6:0]  id_ex_funct7_1;
    reg [11:0] id_ex_csr1;
    reg        id_ex_mem_read1, id_ex_mem_write1, id_ex_reg_write1, id_ex_mem_to_reg1;
    reg        id_ex_alu_src1, id_ex_auipc1, id_ex_is_lui1;
    reg [1:0]  id_ex_alu_op1;
    reg        id_ex_branch1, id_ex_jal1, id_ex_jalr1;
    reg        id_ex_ecall1, id_ex_halt1, id_ex_csr_read1, id_ex_csr_write1;
    reg        id_ex_is_rtype1;
    reg        id_ex_valid1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            id_ex_pc1 <= 0; id_ex_rd1_1 <= 0; id_ex_rd2_1 <= 0; id_ex_imm1 <= 0;
            id_ex_rs1_1 <= 0; id_ex_rs2_1 <= 0; id_ex_rd1 <= 0;
            id_ex_funct3_1 <= 0; id_ex_funct7_1 <= 0; id_ex_csr1 <= 0;
            id_ex_mem_read1 <= 0; id_ex_mem_write1 <= 0; id_ex_reg_write1 <= 0;
            id_ex_mem_to_reg1 <= 0; id_ex_alu_src1 <= 0; id_ex_alu_op1 <= 0;
            id_ex_auipc1 <= 0; id_ex_is_lui1 <= 0; id_ex_branch1 <= 0;
            id_ex_jal1 <= 0; id_ex_jalr1 <= 0; id_ex_ecall1 <= 0;
            id_ex_halt1 <= 0; id_ex_csr_read1 <= 0; id_ex_csr_write1 <= 0;
            id_ex_is_rtype1 <= 0;
            id_ex_valid1 <= 0;
        end else if (flush_ex_idex) begin
            id_ex_pc1 <= 0; id_ex_rd1_1 <= 0; id_ex_rd2_1 <= 0; id_ex_imm1 <= 0;
            id_ex_rs1_1 <= 0; id_ex_rs2_1 <= 0; id_ex_rd1 <= 0;
            id_ex_funct3_1 <= 0; id_ex_funct7_1 <= 0; id_ex_csr1 <= 0;
            id_ex_mem_read1 <= 0; id_ex_mem_write1 <= 0; id_ex_reg_write1 <= 0;
            id_ex_mem_to_reg1 <= 0; id_ex_alu_src1 <= 0; id_ex_alu_op1 <= 0;
            id_ex_auipc1 <= 0; id_ex_is_lui1 <= 0; id_ex_branch1 <= 0;
            id_ex_jal1 <= 0; id_ex_jalr1 <= 0; id_ex_ecall1 <= 0;
            id_ex_halt1 <= 0; id_ex_csr_read1 <= 0; id_ex_csr_write1 <= 0;
            id_ex_is_rtype1 <= 0;
            id_ex_valid1 <= 0;
        end else if (!pipe_halt && !md_stall && !csr_stall) begin
            id_ex_pc1         <= if_id_pc1;
            id_ex_rd1_1       <= id_rd1_1;
            id_ex_rd2_1       <= id_rd2_1;
            id_ex_imm1        <= id_imm1;
            id_ex_rs1_1       <= id_rs1_1;
            id_ex_rs2_1       <= id_rs2_1;
            id_ex_rd1         <= eff_id_rd1;
            id_ex_funct3_1    <= id_funct31;
            id_ex_funct7_1    <= id_funct71;
            id_ex_csr1        <= id_csr1;
            id_ex_mem_read1   <= eff_id_mem_read1;
            id_ex_mem_write1  <= eff_id_mem_write1;
            id_ex_reg_write1  <= eff_id_reg_write1;
            id_ex_mem_to_reg1 <= eff_id_mem_to_reg1;
            id_ex_alu_src1    <= eff_id_alu_src1;
            id_ex_alu_op1     <= eff_id_alu_op1;
            id_ex_auipc1      <= eff_id_auipc1;
            id_ex_is_lui1     <= eff_id_is_lui1;
            id_ex_branch1     <= eff_id_branch1;
            id_ex_jal1        <= eff_id_jal1;
            id_ex_jalr1       <= eff_id_jalr1;
            id_ex_ecall1      <= eff_id_ecall1;
            id_ex_halt1       <= eff_id_halt1;
            id_ex_csr_read1   <= eff_id_csr_read1;
            id_ex_csr_write1  <= eff_id_csr_write1;
            id_ex_is_rtype1   <= eff_id_is_rtype1;
            id_ex_valid1      <= if_id_valid1 && !squash_s1;
        end else if (md_stall && !pipe_halt) begin
            // Same fallback refresh as slot 0 (see above).
            id_ex_rd1_1 <= (reg_write1 && reg_wa1 != 5'b0 && reg_wa1 == id_ex_rs1_1) ? reg_wd1 :
                           (reg_write0 && reg_wa0 != 5'b0 && reg_wa0 == id_ex_rs1_1) ? reg_wd0 : id_ex_rd1_1;
            id_ex_rd2_1 <= (reg_write1 && reg_wa1 != 5'b0 && reg_wa1 == id_ex_rs2_1) ? reg_wd1 :
                           (reg_write0 && reg_wa0 != 5'b0 && reg_wa0 == id_ex_rs2_1) ? reg_wd0 : id_ex_rd2_1;
        end
    end

    // =========================================================
    // EX — forwarding data buses (declared early, driven later)
    // =========================================================
    wire [31:0] ex_mem_fwd_val0, ex_mem_fwd_val1;
    wire [31:0] mem_wb_fwd_val0, mem_wb_fwd_val1;

    // =========================================================
    // EX — slot 0 MEM/WB mux disambiguation
    // =========================================================
    // forward.v encodes both s0_mem_wb and s1_mem_wb hits as 2'b01.
    // Slot 1 is younger than slot 0 inside a pair, so it has priority when both match.
    wire [31:0] mem_wb_sel_s0_rs1 = (mem_wb_reg_write1 && mem_wb_rd1 != 0 &&
                                       mem_wb_rd1 == id_ex_rs1_0) ? mem_wb_fwd_val1
                                                                   : mem_wb_fwd_val0;
    wire [31:0] mem_wb_sel_s0_rs2 = (mem_wb_reg_write1 && mem_wb_rd1 != 0 &&
                                       mem_wb_rd1 == id_ex_rs2_0) ? mem_wb_fwd_val1
                                                                   : mem_wb_fwd_val0;

    wire [31:0] ex_rs1_fwd0 = (fwd_a0 == 2'b10) ? ex_mem_fwd_val0   :
                               (fwd_a0 == 2'b11) ? ex_mem_fwd_val1   :
                               (fwd_a0 == 2'b01) ? mem_wb_sel_s0_rs1 : id_ex_rd1_0;
    wire [31:0] ex_rs2_fwd0 = (fwd_b0 == 2'b10) ? ex_mem_fwd_val0   :
                               (fwd_b0 == 2'b11) ? ex_mem_fwd_val1   :
                               (fwd_b0 == 2'b01) ? mem_wb_sel_s0_rs2 : id_ex_rd2_0;

    wire [31:0] ex_alu_a0 = id_ex_auipc0  ? id_ex_pc0  :
                            id_ex_is_lui0 ? 32'b0      : ex_rs1_fwd0;
    wire [31:0] ex_alu_b0 = id_ex_alu_src0 ? id_ex_imm0 : ex_rs2_fwd0;

    wire ex_is_shift0  = (id_ex_alu_op0 == 2'b10) && (id_ex_funct3_0 == 3'b101);
    wire ex_funct7_5_0 = (ex_is_shift0 || id_ex_is_rtype0) ? id_ex_funct7_0[5] : 1'b0;

    wire [4:0] ex_alu_ctrl0;
    alu_ctrl ac0 (.alu_op(id_ex_alu_op0), .funct3(id_ex_funct3_0),
                  .funct7(id_ex_funct7_0), .funct7_5(ex_funct7_5_0),
                  .is_rtype(id_ex_is_rtype0),
                  .is_lui(id_ex_is_lui0), .alu_ctrl(ex_alu_ctrl0));

    wire [31:0] ex_alu_result0;
    wire        ex_alu_zero0;
    alu alu0 (.clk(clk), .rst(rst),
              .a(ex_alu_a0), .b(ex_alu_b0), .alu_op(ex_alu_ctrl0),
              .result(ex_alu_result0), .zero(ex_alu_zero0),
              .md_busy(md_busy0), .md_done(md_done0));

    wire ex_branch_taken0;
    branch_compare bc0 (.rs1(ex_rs1_fwd0), .rs2(ex_rs2_fwd0),
                        .funct3(id_ex_funct3_0), .branch_taken(ex_branch_taken0));

    wire ex_take_branch0 = id_ex_branch0 && ex_branch_taken0;
    wire [31:0] ex_branch_target0 = id_ex_pc0 + id_ex_imm0;
    wire [31:0] ex_jalr_target0 = (ex_rs1_fwd0 + id_ex_imm0) & ~32'd1;
    wire [31:0] ex_actual_pc0 = id_ex_branch0 ? (ex_branch_taken0 ? ex_branch_target0 : (id_ex_pc0 + 32'd4)) :
                                id_ex_jal0    ? ex_branch_target0 :
                                id_ex_jalr0   ? ex_jalr_target0 : 32'b0;
    wire [31:0] ex_expected_pc0 = id_ex_pred_taken0 ? id_ex_pred_target0 : (id_ex_pc0 + 32'd4);
    wire ex_redirect0 = (id_ex_branch0 || id_ex_jal0 || id_ex_jalr0) &&
                        (ex_actual_pc0 != ex_expected_pc0);

    wire [31:0] ex_link0 = id_ex_pc0 + 32'd4;
    // Single shared CSR file. The two slots can never access it together
    // (the hazard unit splits CSR+CSR pairs), so one read port suffices;
    // slot 0 has priority on the select muxes by construction.
    wire s0_csr_active = id_ex_csr_read0 || id_ex_csr_write0;
    wire [31:0] ex_csr_rdata_q;
    csr_reg csr_file (.clk(clk), .rst(rst),
                  .we(s0_csr_active ? csr_we0 : csr_we1),
                  .addr(s0_csr_active ? id_ex_csr0 : id_ex_csr1),
                  .wdata(s0_csr_active ? ex_rs1_fwd0 : ex_rs1_fwd1),
                  .funct3(s0_csr_active ? id_ex_funct3_0 : id_ex_funct3_1),
                  .rs1_data(s0_csr_active ? ex_rs1_fwd0 : ex_rs1_fwd1),
                  .rdata_q(ex_csr_rdata_q));

    // NOTE: CSR data joins writeback only at EX/MEM (see below), never here —
    // that keeps the slow CSR cone out of the EX->EX/ID forwarding paths.
    wire [31:0] ex_wb_val0 = (id_ex_jal0 || id_ex_jalr0) ? ex_link0 : ex_alu_result0;

    // =========================================================
    // EX — slot 1 MEM/WB mux disambiguation
    // =========================================================
    // Same principle: forward.v encodes both s0_mem_wb and s1_mem_wb hits as 3'b001.
    // Slot 1 is younger than slot 0 inside a pair, so it has priority when both match.
    wire [31:0] mem_wb_sel_s1_rs1 = (mem_wb_reg_write1 && mem_wb_rd1 != 0 &&
                                       mem_wb_rd1 == id_ex_rs1_1) ? mem_wb_fwd_val1
                                                                   : mem_wb_fwd_val0;
    wire [31:0] mem_wb_sel_s1_rs2 = (mem_wb_reg_write1 && mem_wb_rd1 != 0 &&
                                       mem_wb_rd1 == id_ex_rs2_1) ? mem_wb_fwd_val1
                                                                   : mem_wb_fwd_val0;

    wire [31:0] ex_rs1_fwd1 = (fwd_a1 == 3'b100) ? ex_wb_val0        :
                               (fwd_a1 == 3'b010) ? ex_mem_fwd_val0   :
                               (fwd_a1 == 3'b011) ? ex_mem_fwd_val1   :
                               (fwd_a1 == 3'b001) ? mem_wb_sel_s1_rs1 : id_ex_rd1_1;
    wire [31:0] ex_rs2_fwd1 = (fwd_b1 == 3'b100) ? ex_wb_val0        :
                               (fwd_b1 == 3'b010) ? ex_mem_fwd_val0   :
                               (fwd_b1 == 3'b011) ? ex_mem_fwd_val1   :
                               (fwd_b1 == 3'b001) ? mem_wb_sel_s1_rs2 : id_ex_rd2_1;

    wire [31:0] ex_alu_a1 = id_ex_auipc1  ? id_ex_pc1  :
                            id_ex_is_lui1 ? 32'b0      : ex_rs1_fwd1;
    wire [31:0] ex_alu_b1 = id_ex_alu_src1 ? id_ex_imm1 : ex_rs2_fwd1;

    wire ex_is_shift1  = (id_ex_alu_op1 == 2'b10) && (id_ex_funct3_1 == 3'b101);
    wire ex_funct7_5_1 = (ex_is_shift1 || id_ex_is_rtype1) ? id_ex_funct7_1[5] : 1'b0;

    wire [4:0] ex_alu_ctrl1;
    alu_ctrl ac1 (.alu_op(id_ex_alu_op1), .funct3(id_ex_funct3_1),
                  .funct7(id_ex_funct7_1), .funct7_5(ex_funct7_5_1),
                  .is_rtype(id_ex_is_rtype1),
                  .is_lui(id_ex_is_lui1), .alu_ctrl(ex_alu_ctrl1));

    wire [31:0] ex_alu_result1;
    wire        ex_alu_zero1;
    alu alu1 (.clk(clk), .rst(rst),
              .a(ex_alu_a1), .b(ex_alu_b1), .alu_op(ex_alu_ctrl1),
              .result(ex_alu_result1), .zero(ex_alu_zero1),
              .md_busy(md_busy1), .md_done(md_done1));

    wire ex_branch_taken1;
    branch_compare bc1 (.rs1(ex_rs1_fwd1), .rs2(ex_rs2_fwd1),
                        .funct3(id_ex_funct3_1), .branch_taken(ex_branch_taken1));

    wire ex_take_branch1 = id_ex_branch1 && ex_branch_taken1;

    wire [31:0] ex_branch_target1 = id_ex_pc1 + id_ex_imm1;
    wire [31:0] ex_jalr_target1 = (ex_rs1_fwd1 + id_ex_imm1) & ~32'd1;
    wire [31:0] ex_actual_pc1 = ex_take_branch1 ? ex_branch_target1 :
                                id_ex_jal1      ? ex_branch_target1 :
                                id_ex_jalr1     ? ex_jalr_target1 : 32'b0;
    wire ex_redirect1_raw = ex_take_branch1 || id_ex_jal1 || id_ex_jalr1;
    // Slot 1 sits on slot 0's fallthrough: when slot 0 redirects, slot 1 is
    // wrong-path, so its own redirect is suppressed (and its writeback is
    // masked at EX/MEM by ex_s1_kill).
    wire ex_redirect1 = ex_redirect1_raw && !ex_redirect0;
    wire ex_s1_kill = ex_redirect0;

    wire [31:0] ex_link1 = id_ex_pc1 + 32'd4;
    // NOTE: CSR data joins writeback only at EX/MEM (see below), never here.
    // (The single shared CSR file lives in the slot-0 section above.)
    wire [31:0] ex_wb_val1 = (id_ex_jal1 || id_ex_jalr1) ? ex_link1 : ex_alu_result1;

    // =========================================================
    // CSR settle stall + write gating (timing)
    // =========================================================
    // The CSR file read is registered (rdata_q settles a cycle after the
    // address is presented), so an EX stage holding a CSR op is frozen for
    // one extra cycle. csr_stall_q arms on the first cycle and releases on
    // the second; back-to-back CSR ops re-arm automatically.
    assign ex_csr_active = id_ex_csr_read0 || id_ex_csr_write0 ||
                           id_ex_csr_read1 || id_ex_csr_write1;
    assign csr_stall = ex_csr_active && !csr_stall_q;

    always @(posedge clk or posedge rst) begin
        if (rst) csr_stall_q <= 1'b0;
        else if (!pipe_halt) csr_stall_q <= csr_stall && !md_stall && !md_release;
    end

    // The CSR write commits exactly once, on the cycle the op leaves EX:
    // suppressed while EX is held (settle cycle, M-unit stall, halt) and —
    // via ex_s1_kill — when a slot-1 CSR turns out to be on slot 0's
    // wrong path. A flush that accompanies the op's own exit (EX redirect
    // resolving live, M-unit release) still commits.
    assign csr_hold = pipe_halt || md_stall || (csr_stall && !flush_ex && !md_release);
    assign csr_we0 = id_ex_csr_write0 && !csr_hold;
    assign csr_we1 = id_ex_csr_write1 && !csr_hold && !ex_s1_kill;

    // =========================================================
    // Registered EX redirect (timing)
    // =========================================================
    // Both slots resolve control in EX; the redirect takes effect a cycle
    // later through exr_valid/exr_pc, and the flush is extended by the same
    // cycle (see flush_id/flush_ex below). Capture is blocked while EX is
    // held so a resolving pair is sampled exactly once, on its exit cycle.
    wire ex_redirect = ex_redirect0 || ex_redirect1;
    wire [31:0] ex_redirect_pc = ex_redirect0 ? ex_actual_pc0 : ex_actual_pc1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            exr_valid <= 1'b0;
            exr_pc    <= 32'b0;
        end else if (!pipe_halt && !md_stall && !csr_stall) begin
            exr_valid <= ex_redirect;
            exr_pc    <= ex_redirect_pc;
        end
    end

    // PC mux — the registered EX redirect takes priority, then the
    // single-issue replay, then the IF prediction, then sequential.
    // squash_s1 is decided in ID for if_id_pc0/if_id_pc1 while pc_current is already
    // one fetch group ahead, so replay from if_id_pc0+4 (single-issue fallback).
    // No replay when slot 0 leaves the fetch stream — the squashed slot 1 is
    // wrong-path then, and the EX redirect (jal/jalr always, branch only on
    // mispredict) steers the front end instead.
    wire [31:0] squash_replay_pc = if_id_pc0 + 32'd4;
    wire id_s0_fetch_leaves = if_id_valid0 &&
                              (id_jal0 || id_jalr0 || (id_branch0 && if_id_pred_taken0));
    wire squash_replay_en = squash_s1 && !id_s0_fetch_leaves;
    assign pc_next = exr_valid        ? exr_pc           :
                     squash_replay_en ? squash_replay_pc :
                     if_pred_taken0   ? if_pred_target0  :
                     pc_plus8;

    // =========================================================
    // EX/MEM — slot 0
    // =========================================================
    reg [31:0] ex_mem_alu0, ex_mem_rs2_0, ex_mem_wb0;
    reg [4:0]  ex_mem_rd0;
    reg [2:0]  ex_mem_funct3_0;
    reg        ex_mem_mem_read0, ex_mem_mem_write0;
    reg        ex_mem_reg_write0, ex_mem_mem_to_reg0;
    reg        ex_mem_ecall0, ex_mem_halt0;
    reg        ex_mem_valid0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ex_mem_alu0 <= 0; ex_mem_rs2_0 <= 0; ex_mem_wb0 <= 0;
            ex_mem_rd0 <= 0; ex_mem_funct3_0 <= 0;
            ex_mem_mem_read0 <= 0; ex_mem_mem_write0 <= 0;
            ex_mem_reg_write0 <= 0; ex_mem_mem_to_reg0 <= 0;
            ex_mem_ecall0 <= 0; ex_mem_halt0 <= 0;
            ex_mem_valid0 <= 0;
        end else if (!ex_mem_halt0) begin
            // NOTE (flush-hole fix): exr_valid extends the redirect flush by
            // one cycle, so the pair sitting in ID/EX during that cycle is
            // wrong-path. Bubble EX/MEM as well or it executes and commits
            // (RF + dmem + instret) one cycle after every taken redirect.
            if (md_stall || csr_stall || exr_valid) begin
                // M-unit running, or EX holding a CSR op for its settle
                // cycle: retire a bubble, keep the back end draining.
                ex_mem_alu0 <= 0; ex_mem_rs2_0 <= 0; ex_mem_wb0 <= 0;
                ex_mem_rd0 <= 0; ex_mem_funct3_0 <= 0;
                ex_mem_mem_read0 <= 0; ex_mem_mem_write0 <= 0;
                ex_mem_reg_write0 <= 0; ex_mem_mem_to_reg0 <= 0;
                ex_mem_ecall0 <= 0; ex_mem_halt0 <= 0;
                ex_mem_valid0 <= 0;
            end else begin
                ex_mem_alu0        <= ex_alu_result0;
                ex_mem_rs2_0       <= ex_rs2_fwd0;
                ex_mem_wb0         <= id_ex_csr_read0 ? ex_csr_rdata_q : ex_wb_val0;
                ex_mem_rd0         <= id_ex_rd0;
                ex_mem_funct3_0    <= id_ex_funct3_0;
                ex_mem_mem_read0   <= id_ex_mem_read0;
                ex_mem_mem_write0  <= id_ex_mem_write0;
                ex_mem_reg_write0  <= id_ex_reg_write0;
                ex_mem_mem_to_reg0 <= id_ex_mem_to_reg0;
                ex_mem_ecall0      <= id_ex_ecall0;
                ex_mem_halt0       <= id_ex_halt0;
                ex_mem_valid0      <= id_ex_valid0;
            end
        end
    end

    assign ex_mem_fwd_val0 = ex_mem_mem_to_reg0 ? mem_read_data0 : ex_mem_wb0;

    // =========================================================
    // EX/MEM — slot 1
    // =========================================================
    reg [31:0] ex_mem_alu1, ex_mem_rs2_1, ex_mem_wb1;
    reg [4:0]  ex_mem_rd1;
    reg [2:0]  ex_mem_funct3_1;
    reg        ex_mem_mem_read1, ex_mem_mem_write1;
    reg        ex_mem_reg_write1, ex_mem_mem_to_reg1;
    reg        ex_mem_ecall1, ex_mem_halt1;
    reg        ex_mem_valid1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ex_mem_alu1 <= 0; ex_mem_rs2_1 <= 0; ex_mem_wb1 <= 0;
            ex_mem_rd1 <= 0; ex_mem_funct3_1 <= 0;
            ex_mem_mem_read1 <= 0; ex_mem_mem_write1 <= 0;
            ex_mem_reg_write1 <= 0; ex_mem_mem_to_reg1 <= 0;
            ex_mem_ecall1 <= 0; ex_mem_halt1 <= 0;
            ex_mem_valid1 <= 0;
        end else if (!ex_mem_halt1) begin
            // NOTE (flush-hole fix): same as slot 0 — bubble the wrong-path
            // pair executing here during the extended redirect flush cycle.
            if (md_stall || csr_stall || exr_valid) begin
                // M-unit running, or EX holding a CSR op for its settle
                // cycle: retire a bubble, keep the back end draining.
                ex_mem_alu1 <= 0; ex_mem_rs2_1 <= 0; ex_mem_wb1 <= 0;
                ex_mem_rd1 <= 0; ex_mem_funct3_1 <= 0;
                ex_mem_mem_read1 <= 0; ex_mem_mem_write1 <= 0;
                ex_mem_reg_write1 <= 0; ex_mem_mem_to_reg1 <= 0;
                ex_mem_ecall1 <= 0; ex_mem_halt1 <= 0;
                ex_mem_valid1 <= 0;
            end else begin
                // Lateral kill: slot 0 redirected, so slot 1 (its
                // fallthrough) is wrong-path and retires as a bubble.
                ex_mem_alu1        <= ex_s1_kill ? 32'b0 : ex_alu_result1;
                ex_mem_rs2_1       <= ex_s1_kill ? 32'b0 : ex_rs2_fwd1;
                ex_mem_wb1         <= ex_s1_kill ? 32'b0 :
                                      id_ex_csr_read1 ? ex_csr_rdata_q : ex_wb_val1;
                ex_mem_rd1         <= ex_s1_kill ? 5'b0 : id_ex_rd1;
                ex_mem_funct3_1    <= ex_s1_kill ? 3'b0 : id_ex_funct3_1;
                ex_mem_mem_read1   <= ex_s1_kill ? 1'b0 : id_ex_mem_read1;
                ex_mem_mem_write1  <= ex_s1_kill ? 1'b0 : id_ex_mem_write1;
                ex_mem_reg_write1  <= ex_s1_kill ? 1'b0 : id_ex_reg_write1;
                ex_mem_mem_to_reg1 <= ex_s1_kill ? 1'b0 : id_ex_mem_to_reg1;
                ex_mem_ecall1      <= ex_s1_kill ? 1'b0 : id_ex_ecall1;
                ex_mem_halt1       <= ex_s1_kill ? 1'b0 : id_ex_halt1;
                ex_mem_valid1      <= ex_s1_kill ? 1'b0 : id_ex_valid1;
            end
        end
    end

    assign ex_mem_fwd_val1 = ex_mem_mem_to_reg1 ? mem_read_data1 : ex_mem_wb1;

    // =========================================================
    // MEM
    // =========================================================
    assign mem_read0   = ex_mem_mem_read0;
    assign mem_write0  = ex_mem_mem_write0;
    assign mem_addr0   = ex_mem_alu0;
    assign mem_wdata0  = ex_mem_rs2_0;
    assign mem_funct30 = ex_mem_funct3_0;

    assign mem_read1   = ex_mem_mem_read1;
    assign mem_write1  = ex_mem_mem_write1;
    assign mem_addr1   = ex_mem_alu1;
    assign mem_wdata1  = ex_mem_rs2_1;
    assign mem_funct31 = ex_mem_funct3_1;

    // =========================================================
    // MEM/WB — slot 0
    // =========================================================
    reg [31:0] mem_wb_wb0, mem_wb_mem0;
    reg [4:0]  mem_wb_rd0;
    reg        mem_wb_reg_write0, mem_wb_mem_to_reg0;
    reg        mem_wb_ecall0, mem_wb_halt0;
    reg        mem_wb_valid0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mem_wb_wb0 <= 0; mem_wb_mem0 <= 0; mem_wb_rd0 <= 0;
            mem_wb_reg_write0 <= 0; mem_wb_mem_to_reg0 <= 0;
            mem_wb_ecall0 <= 0; mem_wb_halt0 <= 0;
            mem_wb_valid0 <= 0;
        end else begin
            mem_wb_wb0         <= ex_mem_wb0;
            mem_wb_mem0        <= mem_read_data0;
            mem_wb_rd0         <= ex_mem_rd0;
            mem_wb_reg_write0  <= ex_mem_reg_write0;
            mem_wb_mem_to_reg0 <= ex_mem_mem_to_reg0;
            mem_wb_ecall0      <= ex_mem_ecall0;
            mem_wb_halt0       <= ex_mem_halt0;
            mem_wb_valid0      <= ex_mem_valid0;
        end
    end

    // =========================================================
    // MEM/WB — slot 1
    // =========================================================
    reg [31:0] mem_wb_wb1, mem_wb_mem1;
    reg [4:0]  mem_wb_rd1;
    reg        mem_wb_reg_write1, mem_wb_mem_to_reg1;
    reg        mem_wb_ecall1, mem_wb_halt1;
    reg        mem_wb_valid1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mem_wb_wb1 <= 0; mem_wb_mem1 <= 0; mem_wb_rd1 <= 0;
            mem_wb_reg_write1 <= 0; mem_wb_mem_to_reg1 <= 0;
            mem_wb_ecall1 <= 0; mem_wb_halt1 <= 0;
            mem_wb_valid1 <= 0;
        end else begin
            mem_wb_wb1         <= ex_mem_wb1;
            mem_wb_mem1        <= mem_read_data1;
            mem_wb_rd1         <= ex_mem_rd1;
            mem_wb_reg_write1  <= ex_mem_reg_write1;
            mem_wb_mem_to_reg1 <= ex_mem_mem_to_reg1;
            mem_wb_ecall1      <= ex_mem_ecall1;
            mem_wb_halt1       <= ex_mem_halt1;
            mem_wb_valid1      <= ex_mem_valid1;
        end
    end

    // =========================================================
    // WB
    // =========================================================
    assign reg_wd0    = mem_wb_mem_to_reg0 ? mem_wb_mem0 : mem_wb_wb0;
    assign reg_wa0    = mem_wb_rd0;
    assign reg_write0 = mem_wb_reg_write0;

    assign reg_wd1    = mem_wb_mem_to_reg1 ? mem_wb_mem1 : mem_wb_wb1;
    assign reg_wa1    = mem_wb_rd1;
    assign reg_write1 = mem_wb_reg_write1;

    assign ecall = (mem_wb_ecall0 && mem_wb_valid0) || (mem_wb_ecall1 && mem_wb_valid1);
    assign halt  = (mem_wb_halt0  && mem_wb_valid0) || (mem_wb_halt1  && mem_wb_valid1);

    assign mem_wb_fwd_val0 = reg_wd0;
    assign mem_wb_fwd_val1 = reg_wd1;

    // =========================================================
    // Hazard unit
    // =========================================================
    hazard hz (
        .s1_if_id_rs1       (id_rs1_1),
        .s1_if_id_rs2       (id_rs2_1),
        .s1_if_id_use_rs1   (id_use_rs1_1),
        .s1_if_id_use_rs2   (id_use_rs2_1),
        .s0_ex_redirect   (ex_redirect0),
        .s1_ex_branch_taken (ex_take_branch1),
        .s1_ex_jal          (id_ex_jal1),
        .s1_ex_jalr         (id_ex_jalr1),
        .s0_id_rd           (id_rd0),
        .s0_id_branch       (id_branch0),
        .s0_id_branch_pred_taken(if_id_pred_taken0),
        .s0_id_jal          (id_jal0),
        .s0_id_jalr         (id_jalr0),
        .s0_id_mem_read     (id_mem_read0),
        .s0_id_csr_read     (id_csr_read0),
        .s0_id_csr_any      (id_csr_read0 || id_csr_write0),
        .s1_id_csr_any      (id_csr_read1 || id_csr_write1),
        .s0_s1_mem_dep      (s0_s1_mem_dep),
        .md_stall           (md_stall),
        .csr_stall          (csr_stall),
        .s0_id_is_m         (s0_id_is_m),
        .s1_id_is_m         (s1_id_is_m),
        .flush_id           (hz_flush_id),
        .flush_ex           (hz_flush_ex),
        .squash_s1          (squash_s1)
    );

    // The only front-end stall left is the CSR settle cycle (IF/ID/EX all
    // hold); the load-use stall is gone — nothing consumes in ID anymore.
    assign stall_if = csr_stall;
    assign stall_id = csr_stall;
    // The EX redirect lands a cycle late through exr_*, so the flush runs
    // for the resolve cycle (hz_flush, from the live EX signals) plus the
    // redirect cycle (exr_valid).
    assign flush_ex = hz_flush_ex || md_release || exr_valid;
    assign flush_id = hz_flush_id || exr_valid;
    // NOTE (squash/release fix): ID/EX must still ADVANCE slot 0 when a
    // squash coincides with md_release. Flushing here drops the slot-0
    // instr (it never executes and the replay PC only re-fetches slot 1),
    // so its rd goes stale for the consumer. Redirect flushes still win.
    wire flush_ex_idex = hz_flush_ex || exr_valid || (md_release && !squash_s1);

    // =========================================================
    // Forwarding unit
    // =========================================================
    forward fwd_unit (
        .s0_id_ex_rs1       (id_ex_rs1_0),
        .s0_id_ex_rs2       (id_ex_rs2_0),
        .s1_id_ex_rs1       (id_ex_rs1_1),
        .s1_id_ex_rs2       (id_ex_rs2_1),
        .s0_ex_mem_rd       (ex_mem_rd0),
        .s0_ex_mem_reg_write(ex_mem_reg_write0),
        .s1_ex_mem_rd       (ex_mem_rd1),
        .s1_ex_mem_reg_write(ex_mem_reg_write1),
        .s0_mem_wb_rd       (mem_wb_rd0),
        .s0_mem_wb_reg_write(mem_wb_reg_write0),
        .s1_mem_wb_rd       (mem_wb_rd1),
        .s1_mem_wb_reg_write(mem_wb_reg_write1),
        .s0_ex_rd           (id_ex_rd0),
        .s0_ex_reg_write    (id_ex_reg_write0),
        .fwd_a0(fwd_a0), .fwd_b0(fwd_b0),
        .fwd_a1(fwd_a1), .fwd_b1(fwd_b1)
    );

    // RAS call/ret detect in EX (slot 0 only, as before).
    wire ex_is_ret0 = id_ex_jalr0 && (id_ex_rd0 == 5'd0) &&
                      ((id_ex_rs1_0 == 5'd1) || (id_ex_rs1_0 == 5'd5)) && (id_ex_imm0 == 32'd0);
    wire ex_is_call0 = (id_ex_jal0 || id_ex_jalr0) && ((id_ex_rd0 == 5'd1) || (id_ex_rd0 == 5'd5)) && !ex_is_ret0;

    // Hybrid predictor update on resolved slot 0 conditional branches.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hybp_ghr <= {HYBP_GHR_BITS{1'b0}};
            ras_top_ptr <= {RAS_PTR_BITS{1'b0}};
            ras_count <= {(RAS_PTR_BITS+1){1'b0}};
            for (hybp_i = 0; hybp_i < HYBP_ENTRIES; hybp_i = hybp_i + 1) begin
                hybp_local_pht[hybp_i]  <= 2'b00;
                hybp_global_pht[hybp_i] <= 2'b00;
                hybp_choice_pht[hybp_i] <= 2'b01;
                btb_valid[hybp_i] <= 1'b0;
                btb_tag[hybp_i] <= 32'b0;
                btb_target[hybp_i] <= 32'b0;
            end
            for (ras_i = 0; ras_i < RAS_DEPTH; ras_i = ras_i + 1)
                ras_stack[ras_i] <= 32'b0;
        end else if (!pipe_halt && !md_stall && !csr_stall) begin
            if (id_ex_branch0) begin
                case (hybp_local_pht[id_ex_local_idx0])
                    2'b00: hybp_local_pht[id_ex_local_idx0] <= ex_branch_taken0 ? 2'b01 : 2'b00;
                    2'b01: hybp_local_pht[id_ex_local_idx0] <= ex_branch_taken0 ? 2'b10 : 2'b00;
                    2'b10: hybp_local_pht[id_ex_local_idx0] <= ex_branch_taken0 ? 2'b11 : 2'b01;
                    2'b11: hybp_local_pht[id_ex_local_idx0] <= ex_branch_taken0 ? 2'b11 : 2'b10;
                    default: hybp_local_pht[id_ex_local_idx0] <= 2'b00;
                endcase

                case (hybp_global_pht[id_ex_global_idx0])
                    2'b00: hybp_global_pht[id_ex_global_idx0] <= ex_branch_taken0 ? 2'b01 : 2'b00;
                    2'b01: hybp_global_pht[id_ex_global_idx0] <= ex_branch_taken0 ? 2'b10 : 2'b00;
                    2'b10: hybp_global_pht[id_ex_global_idx0] <= ex_branch_taken0 ? 2'b11 : 2'b01;
                    2'b11: hybp_global_pht[id_ex_global_idx0] <= ex_branch_taken0 ? 2'b11 : 2'b10;
                    default: hybp_global_pht[id_ex_global_idx0] <= 2'b00;
                endcase

                if (id_ex_global_pred_taken0 != id_ex_local_pred_taken0) begin
                    if (id_ex_global_pred_taken0 == ex_branch_taken0) begin
                        case (hybp_choice_pht[id_ex_global_idx0])
                            2'b00: hybp_choice_pht[id_ex_global_idx0] <= 2'b01;
                            2'b01: hybp_choice_pht[id_ex_global_idx0] <= 2'b10;
                            2'b10: hybp_choice_pht[id_ex_global_idx0] <= 2'b11;
                            2'b11: hybp_choice_pht[id_ex_global_idx0] <= 2'b11;
                            default: hybp_choice_pht[id_ex_global_idx0] <= 2'b01;
                        endcase
                    end else begin
                        case (hybp_choice_pht[id_ex_global_idx0])
                            2'b00: hybp_choice_pht[id_ex_global_idx0] <= 2'b00;
                            2'b01: hybp_choice_pht[id_ex_global_idx0] <= 2'b00;
                            2'b10: hybp_choice_pht[id_ex_global_idx0] <= 2'b01;
                            2'b11: hybp_choice_pht[id_ex_global_idx0] <= 2'b10;
                            default: hybp_choice_pht[id_ex_global_idx0] <= 2'b01;
                        endcase
                    end
                end

                hybp_ghr <= {hybp_ghr[HYBP_GHR_BITS-2:0], ex_branch_taken0};

                if (ex_branch_taken0) begin
                    btb_valid[id_ex_pc0[BTB_IDX_BITS+1:2]] <= 1'b1;
                    btb_tag[id_ex_pc0[BTB_IDX_BITS+1:2]] <= id_ex_pc0;
                    btb_target[id_ex_pc0[BTB_IDX_BITS+1:2]] <= id_ex_pc0 + id_ex_imm0;
                end
            end else if (id_ex_jal0) begin
                btb_valid[id_ex_pc0[BTB_IDX_BITS+1:2]] <= 1'b1;
                btb_tag[id_ex_pc0[BTB_IDX_BITS+1:2]] <= id_ex_pc0;
                btb_target[id_ex_pc0[BTB_IDX_BITS+1:2]] <= ex_branch_target0;
            end else if (id_ex_jalr0) begin
                btb_valid[id_ex_pc0[BTB_IDX_BITS+1:2]] <= 1'b1;
                btb_tag[id_ex_pc0[BTB_IDX_BITS+1:2]] <= id_ex_pc0;
                btb_target[id_ex_pc0[BTB_IDX_BITS+1:2]] <= ex_jalr_target0;
            end

            if (ex_is_ret0 && (ras_count != 0)) begin
                if (ras_count == 1) begin
                    ras_count <= 0;
                end else begin
                    ras_count <= ras_count - 1'b1;
                    ras_top_ptr <= ras_top_ptr - 1'b1;
                end
            end

            if (ex_is_call0 && (ras_count < RAS_DEPTH)) begin
                if (ras_count == 0) begin
                    ras_top_ptr <= {RAS_PTR_BITS{1'b0}};
                    ras_stack[0] <= id_ex_pc0 + 32'd4;
                end else begin
                    ras_top_ptr <= ras_top_ptr + 1'b1;
                    ras_stack[ras_top_ptr + 1'b1] <= id_ex_pc0 + 32'd4;
                end
                ras_count <= ras_count + 1'b1;
            end
        end
    end

endmodule
