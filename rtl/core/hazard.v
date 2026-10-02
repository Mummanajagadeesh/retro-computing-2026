`include "defines.v"

module hazard (
    input  [4:0]  s1_if_id_rs1,
    input  [4:0]  s1_if_id_rs2,
    input         s1_if_id_use_rs1,
    input         s1_if_id_use_rs2,
    input         s0_ex_redirect,
    input         s1_ex_branch_taken,
    input         s1_ex_jal,
    input         s1_ex_jalr,
    input  [4:0]  s0_id_rd,
    // slot 0 ID-stage control — needed to squash slot 1 when s0 leaves the
    // fetch stream (branch predicted taken / jal / jalr)
    input         s0_id_branch,
    input         s0_id_branch_pred_taken,
    input         s0_id_jal,
    input         s0_id_jalr,
    // slot 0/1 ID-stage operations — needed for inter-slot squash checks
    input         s0_id_mem_read,
    input         s0_id_csr_read,
    input         s0_id_csr_any,
    input         s1_id_csr_any,
    input         s0_s1_mem_dep,
    input         md_stall,
    input         csr_stall,
    input         s0_id_is_m,
    input         s1_id_is_m,
    output        flush_id,
    output        flush_ex,
    output        squash_s1
);
    // NOTE: there is no load-use stall in this core. Slot-0 control resolves
    // in EX (not ID), so nothing consumes forwarded data in ID anymore and
    // every producer — ALU, load (via MEM forward), CSR (via MEM forward) —
    // is visible to EX consumers in time without stalling. The only stalls
    // left are md_stall (M-unit) and csr_stall (CSR read settle), both of
    // which freeze the whole front end (IF/ID/EX) directly in core_top.

    // Branch/jump flush (both slots resolve in EX now). Slot 0 is predicted,
    // so it flushes only on an actual redirect; slot 1 is never predicted,
    // so any taken control transfer there always flushes.
    wire do_flush = s0_ex_redirect ||
                    s1_ex_branch_taken || s1_ex_jal || s1_ex_jalr;

    // Inter-slot RAW squash:
    // Case 1: slot 0 in ID is a load and slot 1 in ID reads the same rd.
    // Slot 1 must be replayed (single-issue fallback) because slot 0 load result
    // is not available until MEM stage.
    wire inter_slot_load_raw = s0_id_mem_read && s0_id_rd != 0 &&
                               ((s1_if_id_use_rs1 && (s0_id_rd == s1_if_id_rs1)) ||
                                (s1_if_id_use_rs2 && (s0_id_rd == s1_if_id_rs2)));

    // Case 1b: slot 0 in ID is a CSR read and slot 1 in ID reads the same rd.
    // Same shape as the load case: the CSR read value is only committed to
    // EX/MEM when slot 0 leaves EX, so a same-pair slot 1 consumer would see
    // stale data. Replay it solo.
    wire inter_slot_csr_raw = s0_id_csr_read && s0_id_rd != 0 &&
                              ((s1_if_id_use_rs1 && (s0_id_rd == s1_if_id_rs1)) ||
                               (s1_if_id_use_rs2 && (s0_id_rd == s1_if_id_rs2)));

    // Case 1c: CSR paired with CSR. Slot 1's registered read would sample the
    // CSR file before slot 0's write commits, so it would read a stale value.
    // Split the pair (rare enough to cost nothing measurable).
    wire inter_slot_csr_pair = s0_id_csr_any && s1_id_csr_any;

    // Case 4: slot 0 in ID is an iterative M op and slot 1 in ID is an M op
    // reading the same rd. Slot 1 would latch its operands before slot 0's
    // result exists, so replay it solo (single-issue fallback) after the
    // slot-0 stall releases, exactly like the load-RAW case above.
    wire inter_slot_m_raw = s0_id_is_m && s1_id_is_m && s0_id_rd != 0 &&
                            ((s1_if_id_use_rs1 && (s0_id_rd == s1_if_id_rs1)) ||
                             (s1_if_id_use_rs2 && (s0_id_rd == s1_if_id_rs2)));

    // Case 2: slot 0 in ID leaves the fetch stream — slot 1 at PC+4 is wrong-path.
    // Taken-ness is resolved in EX now, so for branches this uses the IF
    // prediction; jal/jalr always redirect. A predicted-not-taken branch that
    // turns out taken kills its (already issued) slot 1 via the EX-stage
    // lateral kill (ex_s1_kill in core_top), so no always-squash is needed.
    wire inter_slot_ctrl = (s0_id_branch && s0_id_branch_pred_taken) ||
                           s0_id_jal || s0_id_jalr;

    // Case 3: Inter-slot memory dependency (from core_top alias check).
    wire inter_slot_mem = s0_s1_mem_dep;

    // While the M-unit iterates, or while EX holds a CSR op for its extra
    // settle cycle, the front of the pipe holds its ground: every hazard
    // output stays silent until the stall releases and everything recomputes
    // from the settled state. (Flushing IF/ID mid-stall would kill the held
    // pair unrecoverably, since its PC/replay side is frozen.)
    wire hz_hold = md_stall || csr_stall;
    // squash_s1 requests slot-1 replay at PC=s0_pc+4. IF/ID captures using the
    // current fetch group in the same edge, so we must flush IF/ID on squash to
    // avoid latching an out-of-order pair — except when the fetch stream has
    // already left (predicted taken), in which case IF/ID is about to latch
    // the on-path target group and must be left alone.
    assign flush_id  = (do_flush || ((inter_slot_load_raw || inter_slot_csr_raw ||
                        inter_slot_csr_pair ||
                        (inter_slot_ctrl && !s0_id_branch_pred_taken) ||
                        inter_slot_mem || inter_slot_m_raw))) && !hz_hold;
    assign flush_ex  = do_flush && !hz_hold;
    assign squash_s1 = (inter_slot_load_raw || inter_slot_csr_raw ||
                        inter_slot_csr_pair || inter_slot_ctrl ||
                        inter_slot_mem || inter_slot_m_raw) && !hz_hold;
endmodule
