// tb_rt.f -- file list for the untimed real-time sim (tb_rt + sim_rt.cpp).
// Same memory overrides as doom/tb_doom.f (DOOM needs the 64 MB window),
// plus RT_LIVE to route frames/UART through DPI instead of PGM files.
+define+INST_MEM_WORDS=524288
+define+DATA_MEM_WORDS=16777216
+define+RT_LIVE

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
doom/rt/tb_rt.v
