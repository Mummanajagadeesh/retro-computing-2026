// sdram_model.v -- behavioral IS42S16160, functional only (no timing checks).
// 16M x16 storage, CL=2, BL=2 sequential. Read DQ is driven
// combinationally from the registered pipeline so beats land when a real
// part would drive them. Assumes DQM=0 on reads, as our controller does.
module sdram_model (
    input         clk,
    input         cke,
    input         cs_n,
    input         ras_n,
    input         cas_n,
    input         we_n,
    input  [12:0] addr,
    input  [1:0]  ba,
    inout  [15:0] dq,
    input  [1:0]  dqm
);
    reg [15:0] mem [0:16777215];

    reg [12:0] open_row [0:3];
    reg [3:0]  bank_active;

    reg [23:0] raddr0, raddr1;
    reg        rval0, rval1;
    reg [23:0] beat1_addr;
    reg        beat1_pend;
    reg [23:0] waddr;
    reg        wpend;

    // combinational read data: beat0 appears the cycle after the pipeline
    // fills, exactly CL edges after the READ was sampled
    assign dq = beat1_pend ? mem[beat1_addr] :
                (rval1 ? mem[raddr1] : 16'hzzzz);

    always @(posedge clk) begin
        // read pipeline advance
        raddr1 <= raddr0;
        rval1  <= rval0;
        rval0  <= 1'b0;
        if (beat1_pend) begin
            beat1_pend <= 1'b0;
        end else if (rval1) begin
            beat1_addr <= raddr1 + 24'd1;
            beat1_pend <= 1'b1;
        end
        // pending write beat 1 (high halfword, current DQM: zero latency)
        if (wpend) begin
            if (!dqm[0]) mem[waddr][7:0]  <= dq[7:0];
            if (!dqm[1]) mem[waddr][15:8] <= dq[15:8];
            wpend <= 1'b0;
        end
        // command decode
        if (cke && !cs_n) begin
            if (!ras_n && cas_n && we_n) begin                 // ACTIVATE
                open_row[ba]    <= addr;
                bank_active[ba] <= 1'b1;
            end else if (ras_n && !cas_n && we_n) begin        // READ
                raddr0 <= {ba, open_row[ba], addr[8:0]};
                rval0  <= 1'b1;
                if (addr[10]) bank_active[ba] <= 1'b0;
            end else if (ras_n && !cas_n && !we_n) begin       // WRITE
                // beat 0 (low halfword) is coincident with the command
                if (!dqm[0])
                    mem[{ba, open_row[ba], addr[8:0]}][7:0] <= dq[7:0];
                if (!dqm[1])
                    mem[{ba, open_row[ba], addr[8:0]}][15:8] <= dq[15:8];
                waddr <= {ba, open_row[ba], addr[8:0]} + 24'd1;
                wpend <= 1'b1;
                if (addr[10]) bank_active[ba] <= 1'b0;
            end else if (!ras_n && cas_n && !we_n) begin       // PRECHARGE
                if (addr[10]) bank_active <= 4'b0;
                else bank_active[ba] <= 1'b0;
            end
            // REFRESH / MRS: accepted, no functional effect here
        end
    end
endmodule
