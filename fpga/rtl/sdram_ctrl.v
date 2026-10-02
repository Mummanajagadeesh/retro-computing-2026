// sdram_ctrl.v -- minimal 32-bit SDRAM controller for the DE0-Nano's
// IS42S16160 (32 MB = 4 banks x 8K rows x 512 x16).
//
// One access = ACTIVATE + READ/WRITE with auto-precharge. No row
// tracking: ~15 cycles per 32-bit word at 50 MHz. Correctness first;
// open-row and caches come with the DOOM port if the speed needs it.
//
// Address map, word addr[22:0] (8M words = 32 MB):
//   bank = addr[22:21], row = addr[20:8], col = {addr[7:0], 1'b0}
// Burst length 2 sequential: one READ returns both halfwords of the word.
//
// Request interface: master holds rd_req/wr_req until the matching ack
// pulses for one cycle (rd_data valid with rd_ack). Requests are edge
// detected, so a held req performs exactly one access.
module sdram_ctrl #(
    parameter CLK_FREQ   = 50_000_000,
    parameter CAS        = 2,        // 2 is safe to 100 MHz on the -7 part
    parameter T_INIT     = 12000,   // 200 us power-up wait
    parameter T_RP       = 2,
    parameter T_RCD      = 2,
    parameter T_RFC      = 4,
    parameter T_MRD      = 2,
    parameter T_READ_GAP = 8,       // READ(+autoprecharge) to next ACT;
                                    // keep > CAS+3 if CAS changes
    parameter T_WR_GAP   = 7,       // WRITE(+autoprecharge) to next ACT
    parameter T_REFI     = 350      // auto-refresh interval (spec 7.8 us)
) (
    input           clk,
    input           rst,
    output reg      ready,        // init done AND idle: may take requests

    input           rd_req,
    input           wr_req,
    input  [22:0]   addr,
    input  [31:0]   wr_data,
    input  [3:0]    wr_be,        // 1 = write this byte
    output reg      rd_ack,       // 1-cycle pulse
    output reg [31:0] rd_data,    // valid with rd_ack
    output reg      wr_ack,       // 1-cycle pulse when committed

    output          DRAM_CLK,
    output reg      DRAM_CKE,
    output reg      DRAM_CS_N,
    output reg      DRAM_RAS_N,
    output reg      DRAM_CAS_N,
    output reg      DRAM_WE_N,
    output reg [12:0] DRAM_ADDR,
    output reg [1:0]  DRAM_BA,
    inout  [15:0]   DRAM_DQ,
    output reg [1:0]  DRAM_DQM
);
    assign DRAM_CLK = clk;

    reg [15:0] dq_out;
    reg        dq_oe;
    assign DRAM_DQ = dq_oe ? dq_out : 16'hzzzz;
    wire [15:0] dq_in = DRAM_DQ;

    // latched request
    reg        is_read;
    reg [22:0] laddr;
    reg [31:0] ldata;
    reg [3:0]  lbe;
    wire [1:0]  bank = laddr[22:21];
    wire [12:0] row  = laddr[20:8];
    wire [8:0]  col  = {laddr[7:0], 1'b0};   // even column, burst-of-2

    localparam S_INIT_WAIT = 4'd0,
               S_INIT_PRE  = 4'd1,
               S_GAP       = 4'd2,
               S_INIT_REF  = 4'd3,
               S_INIT_MRS  = 4'd4,
               S_IDLE      = 4'd5,
               S_REF       = 4'd6,
               S_ACT       = 4'd7,
               S_READ      = 4'd8,
               S_READ_D    = 4'd9,
               S_WRITE     = 4'd10,
               S_WRITE_D   = 4'd11,
               S_ACK       = 4'd12;

    reg [3:0]  state, next_state;
    reg [13:0] wait_cnt, gap_target;
    reg [8:0]  ref_cnt;
    reg        ref_pend, ref_overdue;
    reg [3:0]  init_ref_n;
    reg        rd_req_d, wr_req_d;
    reg        rd_pend, wr_pend;
    reg [15:0] beat0, beat1;

    wire rd_edge = rd_req & ~rd_req_d;
    wire wr_edge = wr_req & ~wr_req_d;

    always @(posedge clk) begin
        if (rst) begin
            DRAM_CKE   <= 1'b0;
            DRAM_CS_N  <= 1'b1;
            DRAM_RAS_N <= 1'b1;
            DRAM_CAS_N <= 1'b1;
            DRAM_WE_N  <= 1'b1;
            DRAM_ADDR  <= 13'd0;
            DRAM_BA    <= 2'd0;
            DRAM_DQM   <= 2'b00;
            dq_out <= 16'd0;
            dq_oe  <= 1'b0;
            ready   <= 1'b0;
            rd_ack  <= 1'b0;
            rd_data <= 32'd0;
            wr_ack  <= 1'b0;
            state      <= S_INIT_WAIT;
            next_state <= S_INIT_WAIT;
            wait_cnt   <= 14'd0;
            gap_target <= 14'd0;
            ref_cnt    <= 9'd0;
            ref_pend   <= 1'b0;
            ref_overdue <= 1'b0;
            init_ref_n <= 4'd0;
            rd_req_d <= 1'b0;
            wr_req_d <= 1'b0;
            rd_pend <= 1'b0;
            wr_pend <= 1'b0;
            is_read <= 1'b0;
            laddr   <= 23'd0;
            ldata   <= 32'd0;
            lbe     <= 4'd0;
            beat0 <= 16'd0;
            beat1 <= 16'd0;
        end else begin
            // idle bus = NOP, CKE on
            DRAM_CKE   <= 1'b1;
            DRAM_CS_N  <= 1'b0;
            DRAM_RAS_N <= 1'b1;
            DRAM_CAS_N <= 1'b1;
            DRAM_WE_N  <= 1'b1;
            dq_oe      <= 1'b0;
            DRAM_DQM   <= 2'b00;
            rd_ack <= 1'b0;
            wr_ack <= 1'b0;
            rd_req_d <= rd_req;
            wr_req_d <= wr_req;
            // sticky: an edge arriving while busy (refresh) waits here
            if (rd_edge) rd_pend <= 1'b1;
            if (wr_edge) wr_pend <= 1'b1;

            if (ready) begin
                if (ref_cnt == T_REFI-1) begin
                    ref_cnt <= 9'd0;
                    // a second wrap with refresh still pending = overdue:
                    // the next IDLE serves refresh ahead of requests
                    if (ref_pend) ref_overdue <= 1'b1;
                    ref_pend <= 1'b1;
                end else begin
                    ref_cnt <= ref_cnt + 9'd1;
                end
            end

            case (state)
                S_INIT_WAIT: begin
                    DRAM_CS_N <= 1'b1;   // inhibit during power-up
                    if (wait_cnt == T_INIT-1) begin
                        wait_cnt <= 14'd0;
                        state    <= S_INIT_PRE;
                    end else begin
                        wait_cnt <= wait_cnt + 14'd1;
                    end
                end
                S_INIT_PRE: begin        // PRECHARGE ALL
                    DRAM_RAS_N <= 1'b0;
                    DRAM_WE_N  <= 1'b0;
                    DRAM_ADDR  <= 13'h400;   // A10: all banks
                    gap_target <= T_RP-1;
                    next_state <= S_INIT_REF;
                    init_ref_n <= 4'd0;
                    wait_cnt   <= 14'd0;
                    state      <= S_GAP;
                end
                S_GAP: begin
                    if (wait_cnt == gap_target) begin
                        wait_cnt <= 14'd0;
                        state    <= next_state;
                    end else begin
                        wait_cnt <= wait_cnt + 14'd1;
                    end
                end
                S_INIT_REF: begin        // AUTO REFRESH x8
                    DRAM_RAS_N <= 1'b0;
                    DRAM_CAS_N <= 1'b0;
                    gap_target <= T_RFC-1;
                    if (init_ref_n == 4'd7) begin
                        next_state <= S_INIT_MRS;
                    end else begin
                        next_state <= S_INIT_REF;
                    end
                    init_ref_n <= init_ref_n + 4'd1;
                    wait_cnt   <= 14'd0;
                    state      <= S_GAP;
                end
                S_INIT_MRS: begin   // MODE REGISTER: CL2, BL2 sequential
                    DRAM_RAS_N <= 1'b0;
                    DRAM_CAS_N <= 1'b0;
                    DRAM_WE_N  <= 1'b0;
                    DRAM_BA    <= 2'd0;
                    DRAM_ADDR  <= 13'h021;   // A5,A0: CL=2, BL=2
                    gap_target <= T_MRD-1;
                    next_state <= S_IDLE;
                    wait_cnt   <= 14'd0;
                    state      <= S_GAP;
                end
                S_IDLE: begin
                    ready <= 1'b1;   // raised here (not at MRS) so the first
                                     // request can only arrive when idle
                    if (ref_overdue) begin
                        ref_pend    <= 1'b0;
                        ref_overdue <= 1'b0;
                        state       <= S_REF;
                    end else if (rd_pend | wr_pend) begin
                        if (rd_pend) begin
                            is_read <= 1'b1;
                            rd_pend <= 1'b0;
                        end else begin
                            is_read <= 1'b0;
                            wr_pend <= 1'b0;
                        end
                        laddr   <= addr;
                        ldata   <= wr_data;
                        lbe     <= wr_be;
                        state   <= S_ACT;
                    end else if (ref_pend) begin
                        ref_pend <= 1'b0;
                        state    <= S_REF;
                    end
                end
                S_REF: begin             // AUTO REFRESH
                    DRAM_RAS_N <= 1'b0;
                    DRAM_CAS_N <= 1'b0;
                    gap_target <= T_RFC-1;
                    next_state <= S_IDLE;
                    wait_cnt   <= 14'd0;
                    state      <= S_GAP;
                end
                S_ACT: begin             // ACTIVATE
                    DRAM_RAS_N <= 1'b0;
                    DRAM_BA    <= bank;
                    DRAM_ADDR  <= row;
                    gap_target <= T_RCD-1;
                    next_state <= is_read ? S_READ : S_WRITE;
                    wait_cnt   <= 14'd0;
                    state      <= S_GAP;
                end
                S_READ: begin            // READ with auto-precharge
                    DRAM_CAS_N <= 1'b0;
                    DRAM_WE_N  <= 1'b1;
                    DRAM_BA    <= bank;
                    DRAM_ADDR  <= {2'd0, 1'b1, 1'b0, col};  // A10, A9=0, col
                    wait_cnt   <= 14'd0;
                    state      <= S_READ_D;
                end
                S_READ_D: begin
                    // READ sampled by the SDRAM one edge after issue, so
                    // beat 0/1 sample CAS/CAS+1 edges into this wait
                    if (wait_cnt == CAS)     beat0 <= dq_in;
                    if (wait_cnt == CAS + 1) beat1 <= dq_in;
                    if (wait_cnt == T_READ_GAP-1) begin
                        wait_cnt <= 14'd0;
                        state    <= S_ACK;
                    end else begin
                        wait_cnt <= wait_cnt + 14'd1;
                    end
                end
                S_WRITE: begin   // WRITE with auto-precharge + beat 0
                    DRAM_CAS_N <= 1'b0;
                    DRAM_WE_N  <= 1'b0;
                    DRAM_BA    <= bank;
                    DRAM_ADDR  <= {2'd0, 1'b1, 1'b0, col};
                    dq_out     <= ldata[15:0];
                    dq_oe      <= 1'b1;
                    DRAM_DQM   <= ~lbe[1:0];   // DQM masks on this same beat
                    wait_cnt   <= 14'd0;
                    state      <= S_WRITE_D;
                end
                S_WRITE_D: begin
                    if (wait_cnt == 14'd0) begin
                        dq_out   <= ldata[31:16];   // beat 1
                        dq_oe    <= 1'b1;
                        DRAM_DQM <= ~lbe[3:2];
                    end
                    if (wait_cnt == T_WR_GAP-1) begin
                        wait_cnt <= 14'd0;
                        state    <= S_ACK;
                    end else begin
                        wait_cnt <= wait_cnt + 14'd1;
                    end
                end
                S_ACK: begin
                    if (is_read) begin
                        rd_data <= {beat1, beat0};   // burst order: low first
                        rd_ack  <= 1'b1;
                    end else begin
                        wr_ack  <= 1'b1;
                    end
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
