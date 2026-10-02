`ifndef RV32I_DEFINES_V
`define RV32I_DEFINES_V

`define DATA_WIDTH     32
`define ADDR_WIDTH     32
`define REG_ADDR_WIDTH 5
`define INST_WIDTH     32
`define ZERO_WORD      32'h00000000
`define ZERO_REG       5'b00000

`define OPCODE_LUI     7'b0110111
`define OPCODE_AUIPC   7'b0010111
`define OPCODE_JAL     7'b1101111
`define OPCODE_JALR    7'b1100111
`define OPCODE_BRANCH  7'b1100011
`define OPCODE_LOAD    7'b0000011
`define OPCODE_STORE   7'b0100011
`define OPCODE_OP_IMM  7'b0010011
`define OPCODE_OP      7'b0110011
`define OPCODE_FENCE   7'b0001111
`define OPCODE_ECALL   7'b1110011
`define OPCODE_CSR     7'b1110011

`define ALU_ADD   4'b0000
`define ALU_SUB   4'b0001
`define ALU_AND   4'b0010
`define ALU_OR    4'b0011
`define ALU_XOR   4'b0100
`define ALU_SLL   4'b0101
`define ALU_SRL   4'b0110
`define ALU_SRA   4'b0111
`define ALU_SLT   4'b1000
`define ALU_SLTU  4'b1001
`define ALU_LUI   4'b1010
`define ALU_AUIPC 4'b1011
`define ALU_MUL   4'b1100
`define ALU_MULH  4'b1101
`define ALU_MULHSU 4'b1110
`define ALU_MULHU 4'b1111
`define ALU_DIV   5'b10000
`define ALU_DIVU  5'b10001
`define ALU_REM   5'b10010
`define ALU_REMU  5'b10011
`define ALU_NOP   5'b11111

// Memory sizes.
//
// These are overridable from the simulator command line (-DINST_MEM_WORDS=...)
// so that a larger memory image can be built for a specific testbench WITHOUT
// changing the values the published results were measured with. doom/tb_doom.f
// does exactly that; the stock tb_program.f does not, so tb_program keeps the
// original 4096/2048 and CoreMark's cycle counts are unchanged.
//
// Note the values are load-bearing for the shipped ELFs: crt0.S sets
// sp = 0x80001c00, far outside any of these arrays. data_mem.v indexes with
// offset[$clog2(DATA_MEM_WORDS)+1:2] -- $clog2(W) bits -- so addresses wrap
// modulo 2*W bytes, and 0x80001c00 wraps into low memory. That is why the
// stock programs run at all. Enlarging DATA_MEM_WORDS globally moves that
// wrapped stack and the stock ELFs stop halting (verified: 60M-cycle timeout
// with DATA_MEM_WORDS 16777216 vs 21,484,387 cycles at 2048).
`ifndef INST_MEM_WORDS
  `define INST_MEM_WORDS 4096
`endif
`ifndef DATA_MEM_WORDS
  `define DATA_MEM_WORDS 2048
`endif

`define PC_WIDTH 32

`define CSR_MSTATUS  12'h300
`define CSR_MIE      12'h304
`define CSR_MTVEC    12'h305
`define CSR_MSCRATCH 12'h340
`define CSR_MEPC     12'h341
`define CSR_MCAUSE   12'h342
`define CSR_MTVAL    12'h343
`define CSR_MIP      12'h344
`define CSR_MVENDORID 12'hF11
`define CSR_MARCHID  12'hF12
`define CSR_MIMPID   13'hF13
`define CSR_MHARTID  14'hF14

`endif
