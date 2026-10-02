`include "defines.v"

// Iterative multiply/divide unit, one instance per EX slot.
//
// The two slots never arbitrate: each ALU carries its own unit and the
// core stalls until both are done.
//
// The fast ops (ADD/SUB/shifts/compares/logic/LUI/MUL-low/NOP) stay
// combinational in alu.v. Only the seven M ops that need wide arithmetic
// come here: MULH/MULHSU/MULHU and DIV/DIVU/REM/REMU. The wide
// combinational multipliers and dividers these replace priced at several
// thousand LEs each in synthesis, which is why they now iterate.
//
// Protocol (self-starting, no start port):
//   IDLE: if alu_op is one of the seven M ops, latch a/b and run.
//   RUN:  32 iterations, md_busy high. If alu_op stops being an M op
//         (the pipe flushed ID/EX to a bubble), abort back to IDLE.
//   DONE: md_busy low, result valid combinationally for one cycle. The
//         next state is always IDLE; a back-to-back M op starts from
//         there with the core still holding ID/EX, so no operand gap.
// The core freezes IF/ID/ID/EX/PC while md_busy is high and feeds bubbles
// to EX/MEM, so nothing samples the unit's outputs mid-run.
//
// MULH/MULHSU/MULHU: classic right-shifting shift-add over 32 steps.
// P is 33 bits (32 plus a sign guard), B shifts logically, P shifts
// arithmetically into the top of B, and the full 64 bit product lands in
// {P[31:0], B}. A signed multiplier's top bit has negative weight, so the
// last step subtracts instead of adding when B is signed. The result is
// the upper half P[31:0].
//
// DIV/DIVU/REM/REMU: restoring division over 32 steps on magnitudes, with
// the signs fixed at the end (quotient takes a^b's sign, remainder takes
// a's). Each step shifts {R, Q} left one, subtracts the divisor, and keeps
// the subtraction only if it did not go negative. Divide-by-zero never
// iterates meaningfully: DIV/DIVU return all ones and REM/REMU return the
// dividend, matching the old combinational behavior. INT_MIN/-1 falls out
// of the iteration naturally (magnitude 2^31 over 1 with no sign flip
// gives INT_MIN quotient and zero remainder).
module muldiv (
    input         clk,
    input         rst,
    input  [31:0] a,
    input  [31:0] b,
    input  [4:0]  alu_op,
    output [31:0] result,
    output        md_busy,
    output        md_done
);
    wire op_is_mulh = (alu_op == `ALU_MULH)  || (alu_op == `ALU_MULHSU) ||
                      (alu_op == `ALU_MULHU);
    wire op_is_div  = (alu_op == `ALU_DIV)   || (alu_op == `ALU_DIVU) ||
                      (alu_op == `ALU_REM)   || (alu_op == `ALU_REMU);
    wire op_is_m = op_is_mulh || op_is_div;

    // MULH (ss): A signed, B signed. MULHSU (su): A signed, B unsigned.
    // MULHU (uu): both unsigned.
    wire mul_a_signed = (alu_op == `ALU_MULH) || (alu_op == `ALU_MULHSU);
    wire mul_b_signed = (alu_op == `ALU_MULH);
    // DIV/REM signed, DIVU/REMU unsigned; op[1] picks quotient/remainder.
    wire div_signed = !alu_op[0];
    wire div_want_rem = alu_op[1];

    localparam [1:0] MD_IDLE = 2'b00,
                     MD_RUN  = 2'b01,
                     MD_DONE = 2'b10;

    reg [1:0] md_state;
    reg [5:0] md_count;      // iteration index 0..31
    reg       md_is_mul;     // latched op class for this run
    reg       md_a_signed, md_b_signed, md_q_neg, md_r_neg;
    reg       md_div_want_rem;
    reg       md_div_by_zero;
    reg [31:0] md_div_a;     // latched dividend (REM-by-zero returns it)

    // Multiply datapath.
    reg [32:0] md_m_p;       // 33 bit accumulator with sign guard
    reg [32:0] md_m_a;       // sign/zero-extended multiplicand
    reg [31:0] md_m_b;       // multiplier, holds low half as it shifts
    reg [31:0] md_m_hi;      // upper half, latched at the last step
    // Divide datapath.
    reg [32:0] md_d_r;       // 33 bit remainder with sign bit
    reg [31:0] md_d_q;       // quotient being built
    reg [31:0] md_d_d;       // divisor magnitude

    initial md_state = MD_IDLE;

    wire [32:0] mul_p_add = md_m_p + md_m_a;
    wire [32:0] mul_p_sub = md_m_p - md_m_a;
    wire [32:0] div_r_shift = {md_d_r[31:0], md_d_q[31]};
    wire [32:0] div_r_sub = div_r_shift - {1'b0, md_d_d};
    // Unsigned accumulation (MULHU) shifts logically: a set bit 32
    // there is data, not sign. Signed runs shift arithmetically.
    wire mul_in_add = md_a_signed ? mul_p_add[32] : 1'b0;
    wire mul_in_sub = md_a_signed ? mul_p_sub[32] : 1'b0;
    wire mul_in_p   = md_a_signed ? md_m_p[32]    : 1'b0;

    assign md_busy = (md_state == MD_RUN) ||
                     (md_state == MD_IDLE && op_is_m);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            md_state   <= MD_IDLE;
            md_count   <= 6'd0;
            md_is_mul  <= 1'b0;
            md_a_signed <= 1'b0;
            md_b_signed <= 1'b0;
            md_q_neg   <= 1'b0;
            md_r_neg   <= 1'b0;
            md_div_want_rem <= 1'b0;
            md_div_by_zero  <= 1'b0;
            md_m_p     <= 34'd0;
            md_m_a     <= 34'd0;
            md_m_b     <= 32'd0;
            md_m_hi    <= 32'd0;
            md_d_r     <= 34'd0;
            md_d_q     <= 32'd0;
            md_d_d     <= 32'd0;
            md_div_a   <= 32'd0;
        end else begin
            case (md_state)
                MD_IDLE: begin
                    if (op_is_m) begin
                        md_is_mul     <= op_is_mulh;
                        md_a_signed   <= mul_a_signed;
                        md_b_signed   <= mul_b_signed;
                        md_q_neg      <= div_signed && (a[31] ^ b[31]);
                        md_r_neg      <= div_signed && a[31];
                        md_div_want_rem <= div_want_rem;
                        md_div_by_zero  <= (b == 32'd0);
                        md_div_a      <= a;
                        md_count      <= 6'd0;
                        // Multiply side.
                        md_m_p <= 34'd0;
                        md_m_a <= mul_a_signed ? {a[31], a} : {1'b0, a};
                        md_m_b <= b;
                        // Divide side (magnitudes; corners fixed at DONE).
                        md_d_r <= 34'd0;
                        md_d_q <= (div_signed && a[31]) ? (~a + 32'd1) : a;
                        md_d_d <= (div_signed && b[31]) ? (~b + 32'd1) : b;
                        md_state <= MD_RUN;
                    end
                end
                MD_RUN: begin
                    if (!op_is_m) begin
                        // ID/EX was flushed mid-run; drop the operation.
                        md_state <= MD_IDLE;
                    end else if (md_is_mul) begin
                        if (md_m_b[0] && !(md_count == 6'd31 && md_b_signed))
                            {md_m_p, md_m_b} <= {mul_in_add, mul_p_add[32:1],
                                                mul_p_add[0], md_m_b[31:1]};
                        else if (md_count == 6'd31 && md_b_signed && md_m_b[0])
                            {md_m_p, md_m_b} <= {mul_in_sub, mul_p_sub[32:1],
                                                mul_p_sub[0], md_m_b[31:1]};
                        else
                            {md_m_p, md_m_b} <= {mul_in_p, md_m_p[32:1],
                                                md_m_p[0], md_m_b[31:1]};
                        if (md_count == 6'd31) begin
                            // Full product is {P[31:0], B}; keep the top.
                            if (md_b_signed && md_m_b[0])
                                md_m_hi <= mul_p_sub[32:1];
                            else if (md_m_b[0])
                                md_m_hi <= mul_p_add[32:1];
                            else
                                md_m_hi <= {md_m_p[32], md_m_p[31:1]};
                            md_state <= MD_DONE;
                        end
                        md_count <= md_count + 6'd1;
                    end else begin
                        // Restoring divide step: shift, subtract, keep the
                        // subtraction only if it did not go negative.
                        if (div_r_sub[32])
                            {md_d_r, md_d_q} <= {div_r_shift,
                                                md_d_q[30:0], 1'b0};
                        else
                            {md_d_r, md_d_q} <= {div_r_sub,
                                                md_d_q[30:0], 1'b1};
                        md_count <= md_count + 6'd1;
                        if (md_count == 6'd31)
                            md_state <= MD_DONE;
                    end
                end
                MD_DONE: begin
                    md_state <= MD_IDLE;
                end
                default: md_state <= MD_IDLE;
            endcase
        end
    end

    // DONE presents the result combinationally: the multiply half was
    // latched at the last step, the divide side settled at the last step.
    wire [31:0] div_q_fix = md_q_neg ? (~md_d_q + 32'd1) : md_d_q;
    wire [31:0] div_r_fix = md_r_neg ? (~md_d_r[31:0] + 32'd1) : md_d_r[31:0];
    wire [31:0] div_zero_out = md_div_want_rem ? md_div_a : 32'hFFFFFFFF;
    wire [31:0] div_done_out = md_div_by_zero ? div_zero_out :
                               (md_div_want_rem ? div_r_fix : div_q_fix);
    wire [31:0] md_done_result = md_is_mul ? md_m_hi : div_done_out;
    assign result = (md_state == MD_DONE) ? md_done_result : 32'd0;
// Release edge: high for the single DONE cycle. The core ORs the two
// slots' md_done into flush_ex so ID/EX takes a bubble while IF/ID
// reloads the held pair from the held PC (load-use shape; without it
// the pair would enter both stages at once and execute twice).
assign md_done = (md_state == MD_DONE);

endmodule
