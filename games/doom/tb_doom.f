// DOOM needs far more memory than the stock testbenches.
// Overridden HERE rather than in defines.v so that tb_program.f still
// builds with the original 4096/2048 and the published CoreMark cycle
// counts stay valid (their ELFs depend on sp=0x80001c00 wrapping).
//
// data_mem.v reaches only 2*DATA_MEM_WORDS bytes (its index slice is
// $clog2(W) bits wide), so 16777216 words gives a 64 MB window -- enough
// for code + a 12 MB heap + stack + the 27.5 MB IWAD. doom/build.sh
// checks _wad_end against that window and fails the build if it spills.
+define+INST_MEM_WORDS=524288
+define+DATA_MEM_WORDS=16777216

defines.v
rtl/core/alu.v
rtl/core/muldiv.v
rtl/core/alu_ctrl.v
rtl/core/hazard.v
rtl/core/forward.v
rtl/core/registers.v
rtl/core/imm_gen.v
rtl/core/branch_compare.v
rtl/core/csr_reg.v
rtl/core/pc_reg.v
rtl/core/control.v
rtl/core/core_top.v
rtl/mem/inst_mem.v
rtl/mem/data_mem.v
rtl/mem/mem_top_dg.v
rtl/top/rv32i_top_dg.v
tb/tb_doom.v
