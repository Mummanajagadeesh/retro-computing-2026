// mem_top_fpga.v -- DE0-Nano memory system for the rv32i core.
//
// Same core-side interface as mem_top (2 fetch + dual data ports with
// single-cycle combinational-read semantics), served from 32 MB SDRAM
// behind a gated core clock. core_top is UNCHANGED: all adaptation lives
// here. Single 50 MHz clock everywhere; no PLL.
//
// Address map (checked BEFORE the SDRAM window, like mem_top_dg):
//   0xFFF00000..0xFFF0FFFF  framebuffer -> SDRAM top 64 KB
//                           (byte 0x1FF0000.., word 0x7FC000..0x7FFFFF)
//   0xFFFFF000..            MMIO registers (same offsets as mem_top_dg)
//   else                    SDRAM word = byte_addr[24:2] (wraps at 32 MB)
//
// MMIO: +0x000 w EXIT (halts the core clock, LEDs show the code),
// +0x004/+0x008 r CYC (gated core clocks), +0x00C/+0x010 r INS (register
// writes with wa!=0 -- the core's internal wb_valid has no ports, and the
// core is not modified for this), +0x014 r/w KEY (bit31 valid, bit30
// release, [7:0] doomkeys; any w = ack), +0x018 r FRAMES, +0x01C rw
// FB_BASE, +0x020 r STATUS (bit0 = exit), +0x024 w UART (into the TX
// FIFO; a full FIFO stalls the core -- backpressure, zero drops),
// +0x028 w DUMP (frame_cnt++, streams the frame over UART; wdata 2 = 64x32 tiny mode).
//
// Speed: a direct-mapped 1K-word I-cache (dual-port M9K, both slots look
// up in parallel) serves fetches in 2 sys cycles on a hit; D ports go
// straight to SDRAM (~15 sys cycles). No D-cache in this phase.
//
// Boot: UART bootloader owns the SDRAM until the PC uploader finishes
// (protocol in fpga/uploader.py), then releases the core. KEY0 reboots
// the core from the intact SDRAM image (no re-upload); KEY1 returns to
// the bootloader.
module mem_top_fpga (
    input          sys_clk,
    input          sys_rst,        // full reset: SDRAM re-init + bootloader
    input          core_rst_req,   // active high: reboot core, keep SDRAM
    input          tb_bypass_boot,   // tb only: skip upload (tie 0 in HW)
    output         core_clk,       // gated core clock (ALTCLKCTRL in HW)
    output         core_rst,

    // core fetch: slot 0 = pc, slot 1 = pc+4
    input  [31:0]  inst_addr0,
    output reg [31:0] inst_data0,
    input  [31:0]  inst_addr1,
    output reg [31:0] inst_data1,

    // core data port 0
    input          mem_we0,
    input          mem_re0,
    input  [31:0]  mem_addr0,
    input  [31:0]  mem_wdata0,
    input  [2:0]   mem_funct3_0,
    output reg [31:0] mem_rdata0,

    // core data port 1
    input          mem_we1,
    input          mem_re1,
    input  [31:0]  mem_addr1,
    input  [31:0]  mem_wdata1,
    input  [2:0]   mem_funct3_1,
    output reg [31:0] mem_rdata1,

    // retire counting (no core changes: observe the reg-write ports)
    input          reg_write0,
    input  [4:0]   reg_wa0,
    input          reg_write1,
    input  [4:0]   reg_wa1,

    // UART to the PC (2 Mbaud)
    input          uart_rxd,
    output         uart_txd,

    // SDRAM pins
    output [12:0]  DRAM_ADDR,
    output [1:0]   DRAM_BA,
    inout  [15:0]  DRAM_DQ,
    output         DRAM_CAS_N,
    output         DRAM_CKE,
    output         DRAM_CLK,
    output         DRAM_CS_N,
    output [1:0]   DRAM_DQM,
    output         DRAM_RAS_N,
    output         DRAM_WE_N,

    // status to the top (LEDs)
    output reg     booted,
    output         exit_req,
    output [7:0]   exit_code_lo,
    output [31:0]  frame_cnt,
    output         tx_active,
    output         rx_active,
    output [7:0]   bl_progress,

    // OLED framebuffer stream tap
    output         fb_stream_valid,
    output [10:0]  fb_stream_addr,
    output [7:0]   fb_stream_data
);
    assign fb_stream_valid = dump_tiny && fifo_wr && (a_state == A_DMP_BYTE);
    assign fb_stream_addr  = {dump_widx[8:0], dump_bidx};
    assign fb_stream_data  = fifo_wdata;

    localparam FB_BASE      = 32'hFFF00000;
    localparam MMIO_BASE    = 32'hFFFFF000;
    localparam FB_SDR_WORD  = 23'h7FC000;   // top 16K words of SDRAM
    localparam SDRAM_TOP    = 32'h02000000;
    localparam FB_BYTE_LO   = 32'h01FF0000;
    localparam FB_BYTE_TOP  = 32'h02000000;

    // ------------------------------------------------------- helpers
    // Sub-word load extract, same cases as data_mem.v.
    function [31:0] load_extract(input [31:0] w, input [2:0] f3,
                                 input [1:0] bo);
        case (f3)
            3'b000: case (bo)   // LB
                2'b00: load_extract = {{24{w[7]}}, w[7:0]};
                2'b01: load_extract = {{24{w[15]}}, w[15:8]};
                2'b10: load_extract = {{24{w[23]}}, w[23:16]};
                2'b11: load_extract = {{24{w[31]}}, w[31:24]};
            endcase
            3'b001: case (bo[1])   // LH
                1'b0: load_extract = {{16{w[15]}}, w[15:0]};
                1'b1: load_extract = {{16{w[31]}}, w[31:16]};
            endcase
            3'b010: load_extract = w;   // LW
            3'b100: case (bo)   // LBU
                2'b00: load_extract = {24'd0, w[7:0]};
                2'b01: load_extract = {24'd0, w[15:8]};
                2'b10: load_extract = {24'd0, w[23:16]};
                2'b11: load_extract = {24'd0, w[31:24]};
            endcase
            3'b101: case (bo[1])   // LHU
                1'b0: load_extract = {16'd0, w[15:0]};
                1'b1: load_extract = {16'd0, w[31:16]};
            endcase
            default: load_extract = w;
        endcase
    endfunction

    // One byte of IEEE CRC32 (zlib-compatible), combinational.
    function [31:0] crc32_step(input [31:0] crc_in, input [7:0] b);
        reg [31:0] c;
        integer k;
        begin
            c = crc_in ^ {24'd0, b};
            for (k = 0; k < 8; k = k + 1)
                c = (c >> 1) ^ (c[0] ? 32'hEDB88320 : 32'd0);
            crc32_step = c;
        end
    endfunction

    // ------------------------------------------------- reset / clock
    reg crr_a, crr_s, reboot_hold;
    reg [3:0] reboot_cnt;
    always @(posedge sys_clk) begin
        if (sys_rst) begin
            crr_a <= 1'b0; crr_s <= 1'b0;
            reboot_hold <= 1'b0; reboot_cnt <= 4'd0;
        end else begin
            crr_a <= core_rst_req;
            crr_s <= crr_a;
            if (crr_s) begin
                reboot_hold <= 1'b1;
                reboot_cnt  <= 4'd15;
            end else if (reboot_cnt != 4'd0) begin
                reboot_cnt <= reboot_cnt - 4'd1;
            end else begin
                reboot_hold <= 1'b0;
            end
        end
    end

    reg core_run_d;
    assign core_rst = sys_rst | ~booted | reboot_hold;
`ifdef FPGA_SYNTH
    altclkctrl #(
        .clock_type("Global Clock"),
        .ena_register_mode("falling edge"),
        .intended_device_family("Cyclone IV E"),
        .lpm_type("altclkctrl")
    ) core_clk_buf (
        .inclk(sys_clk),
        .ena(core_run_d),
        .outclk(core_clk)
    );
`else
    reg core_run_q;
    always @(negedge sys_clk) core_run_q <= core_run_d;
    assign core_clk = sys_clk & core_run_q;
`endif

    // ------------------------------------------------- UART + FIFO
    wire [7:0] rx_data;
    wire rx_valid, rx_ferr;
    uart_rx #(.CLK_FREQ(50_000_000), .BAUD(921_600), .OVR(6)) urx (
        .clk(sys_clk), .rst(sys_rst), .rx(uart_rxd),
        .data(rx_data), .valid(rx_valid), .frame_err(rx_ferr)
    );

    wire tx_busy;
    reg bl_tx_valid, feed_tx_valid;
    reg [7:0] bl_tx_data, feed_tx_data;
    uart_tx #(.CLK_FREQ(50_000_000), .BAUD(921_600)) utx (
        .clk(sys_clk), .rst(sys_rst),
        .data(booted ? feed_tx_data : bl_tx_data),
        .valid(booted ? feed_tx_valid : bl_tx_valid),
        .busy(tx_busy), .tx(uart_txd)
    );

    reg fifo_wr;
    reg [7:0] fifo_wdata;
    reg fifo_rd;
    wire [7:0] fifo_rdata;
    wire fifo_full, fifo_empty;
    wire [12:0] fifo_count;
    wire fifo_has_space = (fifo_count < 13'd4090);
    fifo_sync #(.WIDTH(8), .DEPTH(4096)) txfifo (
        .clk(sys_clk), .rst(core_rst),
        .wr_en(fifo_wr), .wr_data(fifo_wdata),
        .rd_en(fifo_rd), .rd_data(fifo_rdata),
        .full(fifo_full), .empty(fifo_empty), .count(fifo_count)
    );

    // TX feeder: FIFO -> uart_tx (owns TX once booted).
    // Fully registered: F_RD commits the pop, F_WAIT lets the BRAM
    // output settle (else feed_tx_data goes metastable / stale-by-one),
    // F_HOLD captures data, F_SEND pulses valid with data stable,
    // F_GAP lets busy assert before F_IDLE samples it again.
    localparam F_IDLE = 3'd0, F_RD = 3'd1, F_WAIT = 3'd2,
               F_HOLD = 3'd3, F_SEND = 3'd4, F_GAP = 3'd5;
    reg [2:0] feed_state;
    always @(posedge sys_clk) begin
        if (core_rst) begin
            feed_state    <= F_IDLE;
            fifo_rd       <= 1'b0;
            feed_tx_valid <= 1'b0;
            feed_tx_data  <= 8'd0;
        end else begin
            fifo_rd       <= 1'b0;
            feed_tx_valid <= 1'b0;
            case (feed_state)
                F_IDLE: begin
                    if (booted && !fifo_empty && !tx_busy)
                        feed_state <= F_RD;
                end
                F_RD: begin
                    fifo_rd    <= 1'b1;
                    feed_state <= F_WAIT;
                end
                F_WAIT: begin
                    feed_state <= F_HOLD;
                end
                F_HOLD: begin
                    feed_tx_data <= fifo_rdata;
                    feed_state   <= F_SEND;
                end
                F_SEND: begin
                    feed_tx_valid <= 1'b1;
                    feed_state    <= F_GAP;
                end
                F_GAP: begin
                    feed_state <= F_IDLE;
                end
                default: feed_state <= F_IDLE;
            endcase
        end
    end

    // ------------------------------------------------- SDRAM + mux
    // Bootloader owns the controller until booted; arbiter after.
    // (The bootloader never reads: its rd side of the mux is tied 0,
    // and its writes are always full-word.)
    reg b_wr_req, a_rd_req, a_wr_req;
    reg [22:0] b_addr, a_addr;
    reg [31:0] b_wr_data, a_wr_data;
    reg [3:0] a_wr_be;
    wire c_rd_ack, c_wr_ack, c_ready;
    wire [31:0] c_rd_data;
    sdram_ctrl #(.CLK_FREQ(50_000_000)) ctrl (
        .clk(sys_clk), .rst(sys_rst), .ready(c_ready),
        .rd_req(booted ? a_rd_req : 1'b0),
        .wr_req(booted ? a_wr_req : b_wr_req),
        .addr(booted ? a_addr : b_addr),
        .wr_data(booted ? a_wr_data : b_wr_data),
        .wr_be(booted ? a_wr_be : 4'b1111),
        .rd_ack(c_rd_ack), .rd_data(c_rd_data), .wr_ack(c_wr_ack),
        .DRAM_CLK(DRAM_CLK), .DRAM_CKE(DRAM_CKE),
        .DRAM_CS_N(DRAM_CS_N), .DRAM_RAS_N(DRAM_RAS_N),
        .DRAM_CAS_N(DRAM_CAS_N), .DRAM_WE_N(DRAM_WE_N),
        .DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA),
        .DRAM_DQ(DRAM_DQ), .DRAM_DQM(DRAM_DQM)
    );

    // ------------------------------------------------- I-cache
    // 1024 words, direct-mapped, true dual-port (one port per slot).
    reg [31:0] ic_data [0:1023];
    reg [13:0] ic_tag [0:1023];   // [13]=valid, [12:0]=tag
    // Port A feeds are wires: the bootloader flush owns them pre-boot,
    // the arbiter after. Port B belongs to the arbiter outright.
    wire [9:0] ic_da_a, ic_ta_a;
    wire [31:0] ic_dd_a;
    wire [13:0] ic_td_a;
    wire ic_dw_a, ic_tw_a;
    reg [9:0] a_da_a, a_ta_a;
    reg [31:0] a_dd_a;
    reg [13:0] a_td_a;
    reg a_dw_a, a_tw_a;
    reg [9:0] ic_da_b, ic_ta_b;
    reg [31:0] ic_dd_b;
    reg [13:0] ic_td_b;
    reg ic_dw_b, ic_tw_b;
    reg [31:0] ic_dq_a, ic_dq_b;
    reg [13:0] ic_tq_a, ic_tq_b;
    always @(posedge sys_clk) begin
        if (ic_dw_a) ic_data[ic_da_a] <= ic_dd_a;
        ic_dq_a <= ic_data[ic_da_a];
    end
    always @(posedge sys_clk) begin
        if (ic_dw_b) ic_data[ic_da_b] <= ic_dd_b;
        ic_dq_b <= ic_data[ic_da_b];
    end
    always @(posedge sys_clk) begin
        if (ic_tw_a) ic_tag[ic_ta_a] <= ic_td_a;
        ic_tq_a <= ic_tag[ic_ta_a];
    end
    always @(posedge sys_clk) begin
        if (ic_tw_b) ic_tag[ic_ta_b] <= ic_td_b;
        ic_tq_b <= ic_tag[ic_ta_b];
    end
    // (Port-A muxes live next to the bootloader below.)

    // ------------------------------------------------- MMIO state
    reg [63:0] cycle_q, instret_q;
    reg [7:0] key_reg;
    reg key_rel, key_valid;
    reg exit_req_r;
    reg [31:0] exit_code;
    reg [31:0] frame_cnt_r;
    reg [31:0] fb_base_reg;

    assign exit_req     = exit_req_r;
    assign exit_code_lo = exit_code[7:0];
    assign frame_cnt    = frame_cnt_r;
    assign tx_active    = tx_busy | ~fifo_empty;
    assign rx_active    = rx_valid;

    function [31:0] mmio_read(input [11:0] a);
        case (a)
            12'h004: mmio_read = cycle_q[31:0];
            12'h008: mmio_read = cycle_q[63:32];
            12'h00C: mmio_read = instret_q[31:0];
            12'h010: mmio_read = instret_q[63:32];
            12'h014: mmio_read = {key_valid, key_rel, 22'd0, key_reg};
            12'h018: mmio_read = frame_cnt_r;
            12'h01C: mmio_read = fb_base_reg;
            12'h020: mmio_read = {31'd0, exit_req_r};
            12'h02C: mmio_read = wall_q[31:0];
            12'h030: mmio_read = wall_q[63:32];
            default: mmio_read = 32'd0;
        endcase
    endfunction

    // Key taps from UART once booted (press + release + streaming controls).
    // Single driver: the arbiter clears via key_ack, RX sets on a byte.
    reg key_ack;
    reg key_rel_prefix;
    reg dump_half;      // 0 = 320x200 @ ~1.4 FPS, 1 = 160x100 @ ~5.8 FPS
    reg dump_enable;    // 1 = stream frames, 0 = pause streaming
    always @(posedge sys_clk) begin
        if (core_rst) begin
            key_reg        <= 8'd0;
            key_rel        <= 1'b0;
            key_valid      <= 1'b0;
            key_rel_prefix <= 1'b0;
            dump_half      <= 1'b1;   // default to half resolution 160x100 (smooth 5.8 FPS)
            dump_enable    <= 1'b1;   // streaming enabled by default
        end else if (key_ack) begin
            key_valid <= 1'b0;
        end else if (booted && rx_valid) begin
            if (rx_data == 8'hF0) begin
                key_rel_prefix <= 1'b1;
            end else if (rx_data == 8'hFC) begin
                dump_half <= 1'b0;    // full resolution 320x200
            end else if (rx_data == 8'hFD) begin
                dump_half <= 1'b1;    // half resolution 160x100
            end else if (rx_data == 8'hFE) begin
                dump_enable <= ~dump_enable; // toggle streaming
            end else begin
                key_reg        <= rx_data;
                key_rel        <= key_rel_prefix;
                key_valid      <= 1'b1;
                key_rel_prefix <= 1'b0;
            end
        end
    end

    // ------------------------------------------------- bootloader
    // Owns SDRAM + TX + RX until booted. The PC side is fpga/uploader.py:
    // HELLO -> BLRDY1, u16 nseg, then per segment addr/len/data, then the
    // WAD addr/len/data, then GO + crc32 -> OK + crc echo, or BAD / RNG.
    // A '.' goes out per 4 KB received so the PC shows progress.
    localparam B_LISTEN=5'd0, B_SEND=5'd1, B_SENDW1=5'd2, B_SENDW2=5'd3,
               B_NSEG0=5'd4, B_NSEG1=5'd5, B_ADDR=5'd6, B_LEN=5'd7,
               B_DATA=5'd8, B_WADDR=5'd9, B_WLEN=5'd10, B_WDATA=5'd11,
               B_GO_G=5'd12, B_GO_O=5'd13, B_CRCB=5'd14, B_CMP=5'd15,
               B_FLUSH=5'd16, B_DONE=5'd17,
               B_SCHK=5'd18, B_WCHK=5'd19;
    reg [4:0] b_state, b_send_next;
    reg [7:0] h0, h1, h2, h3, h4;   // HELLO shift matcher
    reg [25:0] beacon_cnt;          // unsolicited BLRDY1 every 1 s
    reg [2:0] b_msg;   // 0=BLRDY1 1=. 2=OK+crc 3=BAD 4=RNG
    reg [2:0] b_sidx;
    reg [15:0] b_nseg, b_seg;
    reg [31:0] b_addr_r, b_len, b_cnt, b_off;
    reg [1:0] b_bcnt;
    reg [31:0] b_wshift;
    reg b_wr_pend;
    reg [31:0] b_crc, b_crc_rx, b_total;
    reg [9:0] b_flush;
    // 1-byte RX skid: the bootloader cannot consume while it is sending
    // (a dot takes ~250 sys cycles and bytes arrive every 250), so bytes
    // wait here. Depth 1 is provably enough: the longest send concurrent
    // with payload is one dot (< 500 sys cycles, so at most one byte can
    // land mid-send). Post-boot taps bypass the skid (key block above).
    reg [7:0] skid_data;
    reg skid_valid_r, bl_rx_take;
    // Hide the clear latency: while take is high the byte reads as
    // already gone, so the bootloader can never take it twice.
    wire skid_valid = skid_valid_r && !bl_rx_take;
    wire [31:0] b_crc_final = ~b_crc;
    assign bl_progress = b_total[16:9];

    reg [7:0] send_byte;
    reg [2:0] send_len;
    always @(*) begin
        case (b_msg)
            3'd0: begin   // BLRDY1
                send_len = 3'd6;
                case (b_sidx)
                    3'd0: send_byte = "B";
                    3'd1: send_byte = "L";
                    3'd2: send_byte = "R";
                    3'd3: send_byte = "D";
                    3'd4: send_byte = "Y";
                    default: send_byte = "1";
                endcase
            end
            3'd1: begin send_len = 3'd1; send_byte = "."; end
            3'd2: begin   // OK + crc LE
                send_len = 3'd6;
                case (b_sidx)
                    3'd0: send_byte = "O";
                    3'd1: send_byte = "K";
                    3'd2: send_byte = b_crc_final[7:0];
                    3'd3: send_byte = b_crc_final[15:8];
                    3'd4: send_byte = b_crc_final[23:16];
                    default: send_byte = b_crc_final[31:24];
                endcase
            end
            3'd3: begin   // BAD
                send_len = 3'd3;
                case (b_sidx)
                    3'd0: send_byte = "B";
                    3'd1: send_byte = "A";
                    default: send_byte = "D";
                endcase
            end
            default: begin   // RNG
                send_len = 3'd3;
                case (b_sidx)
                    3'd0: send_byte = "R";
                    3'd1: send_byte = "N";
                    default: send_byte = "G";
                endcase
            end
        endcase
    end

    wire [32:0] b_end33 = {1'b0, b_addr_r} + {1'b0, b_len};
    wire b_range_ok = (b_addr_r[1:0] == 2'b0) && (b_len[1:0] == 2'b0)
        && (b_end33 <= 33'h02000000)
        && !(b_addr_r < FB_BYTE_TOP && b_end33[31:0] > FB_BYTE_LO);

    // I-cache port-A muxes (bootloader flush pre-boot, arbiter after).
    assign ic_da_a = booted ? a_da_a : 10'd0;
    assign ic_dd_a = a_dd_a;
    assign ic_dw_a = booted ? a_dw_a : 1'b0;
    assign ic_ta_a = booted ? a_ta_a : b_flush;
    assign ic_td_a = booted ? a_td_a : 14'd0;
    assign ic_tw_a = booted ? a_tw_a : (b_state == B_FLUSH);

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            b_state <= B_LISTEN; b_send_next <= B_LISTEN;
            h0 <= 8'd0; h1 <= 8'd0; h2 <= 8'd0; h3 <= 8'd0; h4 <= 8'd0;
            beacon_cnt <= 26'd0;
            b_msg <= 3'd0; b_sidx <= 3'd0;
            b_nseg <= 16'd0; b_seg <= 16'd0;
            b_addr_r <= 32'd0; b_len <= 32'd0;
            b_cnt <= 32'd0; b_off <= 32'd0;
            b_bcnt <= 2'd0; b_wshift <= 32'd0;
            b_wr_pend <= 1'b0; b_wr_req <= 1'b0;
            b_wr_data <= 32'd0; b_addr <= 23'd0;
            b_crc <= 32'hFFFFFFFF; b_crc_rx <= 32'd0; b_total <= 32'd0;
            b_flush <= 10'd0;
            booted <= 1'b0;
            bl_tx_valid <= 1'b0; bl_tx_data <= 8'd0;
            bl_rx_take <= 1'b0;
        end else begin
            bl_tx_valid <= 1'b0;   // defaults; states re-assert
            bl_rx_take  <= 1'b0;
            case (b_state)
                B_LISTEN: begin
                    if (tb_bypass_boot) begin
                        // Test only: skip the upload, still flush + boot.
                        b_flush <= 10'd0;
                        b_state <= B_FLUSH;
                    end else if (skid_valid) begin
                        bl_rx_take <= 1'b1;
                        h0 <= h1; h1 <= h2; h2 <= h3; h3 <= h4;
                        h4 <= skid_data;
`ifdef BL_DEBUG
                        $display("[bl] take %02x  h=%02x %02x %02x %02x", skid_data, h1, h2, h3, h4);
`endif
                        // Gate on c_ready: pre-ready takes would stall the
                        // skid through SDRAM init and silently drop bytes.
                        // The uploader retries HELLO until we answer.
                        if (h1 == "H" && h2 == "E" && h3 == "L" && h4 == "L"
                                && skid_data == "O" && c_ready) begin
                            h0 <= 8'd0; h1 <= 8'd0; h2 <= 8'd0;
                            h3 <= 8'd0; h4 <= 8'd0;
                            b_crc <= 32'hFFFFFFFF; b_total <= 32'd0;
                            b_seg <= 16'd0;
                            b_msg <= 3'd0; b_sidx <= 3'd0;
                            b_send_next <= B_NSEG0;
                            beacon_cnt <= 26'd0;
                            b_state <= B_SEND;
                        end
                    end else if (c_ready && beacon_cnt == 26'd50_000_000 - 1) begin
                        beacon_cnt <= 26'd0;
                        b_msg <= 3'd0; b_sidx <= 3'd0;
                        b_send_next <= B_LISTEN;
                        b_state <= B_SEND;
                    end else begin
                        beacon_cnt <= beacon_cnt + 26'd1;
                    end
                end
                B_SEND: begin
                    bl_tx_data  <= send_byte;
                    bl_tx_valid <= 1'b1;
                    b_state <= B_SENDW1;
`ifdef BL_DEBUG
                    $display("[bl] send msg=%0d idx=%0d byte=0x%02x next=%0d", b_msg, b_sidx, send_byte, b_send_next);
`endif
                end
                B_SENDW1: begin
                    if (tx_busy) b_state <= B_SENDW2;
                end
                B_SENDW2: begin
                    if (!tx_busy) begin
                        if (b_sidx + 3'd1 == send_len) begin
                            b_sidx  <= 3'd0;
                            b_state <= b_send_next;
                        end else begin
                            b_sidx  <= b_sidx + 3'd1;
                            b_state <= B_SEND;
                        end
                    end
                end
                B_NSEG0: begin
                    if (skid_valid) begin
                        bl_rx_take <= 1'b1;
                        b_nseg[7:0] <= skid_data;
                        b_state <= B_NSEG1;
                    end
                end
                B_NSEG1: begin
                    if (skid_valid) begin
                        bl_rx_take <= 1'b1;
                        b_nseg[15:8] <= skid_data;
                        if ({skid_data, b_nseg[7:0]} == 16'd0) begin
                            b_msg <= 3'd4; b_sidx <= 3'd0;   // RNG
                            b_send_next <= B_LISTEN;
                            b_state <= B_SEND;
                        end else begin
                            b_bcnt  <= 2'd0;
                            b_state <= B_ADDR;
                        end
                    end
                end
                B_ADDR: begin
                    if (skid_valid) begin
                        bl_rx_take <= 1'b1;
                        b_addr_r <= {skid_data, b_addr_r[31:8]};
                        if (b_bcnt == 2'd3) begin
                            b_bcnt  <= 2'd0;
                            b_state <= B_LEN;
                        end else begin
                            b_bcnt <= b_bcnt + 2'd1;
                        end
                    end
                end
                B_LEN: begin
                    if (skid_valid) begin
                        bl_rx_take <= 1'b1;
                        b_len <= {skid_data, b_len[31:8]};
                        if (b_bcnt == 2'd3) begin
                            b_bcnt  <= 2'd0;
                            b_state <= B_SCHK;   // b_len stable next cycle
                        end else begin
                            b_bcnt <= b_bcnt + 2'd1;
                        end
                    end
                end
                B_SCHK: begin   // segment range gate
`ifdef BL_DEBUG
                    $display("[bl] SCHK addr=%08x len=%08x end=%09x ok=%0d", b_addr_r, b_len, b_end33, b_range_ok);
`endif
                    if (!b_range_ok) begin
                        h0 <= 8'd0; h1 <= 8'd0; h2 <= 8'd0;
                        h3 <= 8'd0; h4 <= 8'd0;
                        b_msg <= 3'd4; b_sidx <= 3'd0;   // RNG
                        b_send_next <= B_LISTEN;
                        b_state <= B_SEND;
                    end else if (b_len == 32'd0) begin
                        b_seg <= b_seg + 16'd1;   // empty seg: skip it
                        b_bcnt <= 2'd0;
                        if (b_seg + 16'd1 == b_nseg)
                            b_state <= B_WADDR;
                        else
                            b_state <= B_ADDR;
                    end else begin
                        b_cnt   <= b_len;
                        b_off   <= 32'd0;
                        b_bcnt  <= 2'd0;
                        b_state <= B_DATA;
                    end
                end
                B_DATA: begin
                    b_wr_req <= b_wr_pend;
                    if (c_wr_ack) begin
                        b_wr_req  <= 1'b0;
                        b_wr_pend <= 1'b0;
                        b_off   <= b_off + 32'd4;
                        b_cnt   <= b_cnt - 32'd4;
                        b_total <= b_total + 32'd4;
                        if (b_cnt == 32'd4) begin
                            b_seg <= b_seg + 16'd1;
                            b_bcnt <= 2'd0;
                            if (b_seg + 16'd1 == b_nseg)
                                b_state <= B_WADDR;
                            else
                                b_state <= B_ADDR;
                        end else if (((b_total + 32'd4) & 32'h00000FFF)
                                == 32'd0) begin
                            b_msg <= 3'd1; b_sidx <= 3'd0;   // dot
                            b_send_next <= B_DATA;
                            b_state <= B_SEND;
                        end
                    end else if (!b_wr_pend && skid_valid) begin
                        bl_rx_take <= 1'b1;
                        b_crc    <= crc32_step(b_crc, skid_data);
                        b_wshift <= {skid_data, b_wshift[31:8]};
                        if (b_bcnt == 2'd3) begin
                            b_bcnt    <= 2'd0;
                            b_wr_data <= {skid_data, b_wshift[31:8]};
                            b_addr    <= (b_addr_r + b_off) >> 2;
                            b_wr_pend <= 1'b1;
                        end else begin
                            b_bcnt <= b_bcnt + 2'd1;
                        end
                    end
                end
                B_WADDR: begin
                    if (skid_valid) begin
                        bl_rx_take <= 1'b1;
                        b_addr_r <= {skid_data, b_addr_r[31:8]};
                        if (b_bcnt == 2'd3) begin
                            b_bcnt  <= 2'd0;
                            b_state <= B_WLEN;
                        end else begin
                            b_bcnt <= b_bcnt + 2'd1;
                        end
                    end
                end
                B_WLEN: begin
                    if (skid_valid) begin
                        bl_rx_take <= 1'b1;
                        b_len <= {skid_data, b_len[31:8]};
                        if (b_bcnt == 2'd3) begin
                            b_bcnt  <= 2'd0;
                            b_state <= B_WCHK;
                        end else begin
                            b_bcnt <= b_bcnt + 2'd1;
                        end
                    end
                end
                B_WCHK: begin
`ifdef BL_DEBUG
                    $display("[bl] WCHK addr=%08x len=%08x end=%09x ok=%0d", b_addr_r, b_len, b_end33, b_range_ok);
`endif
                    if (!b_range_ok) begin
                        h0 <= 8'd0; h1 <= 8'd0; h2 <= 8'd0;
                        h3 <= 8'd0; h4 <= 8'd0;
                        b_msg <= 3'd4; b_sidx <= 3'd0;   // RNG
                        b_send_next <= B_LISTEN;
                        b_state <= B_SEND;
                    end else if (b_len == 32'd0) begin
                        b_state <= B_GO_G;
                    end else begin
                        b_cnt   <= b_len;
                        b_off   <= 32'd0;
                        b_bcnt  <= 2'd0;
                        b_state <= B_WDATA;
                    end
                end
                B_WDATA: begin   // same shape as B_DATA, then GO
                    b_wr_req <= b_wr_pend;
                    if (c_wr_ack) begin
                        b_wr_req  <= 1'b0;
                        b_wr_pend <= 1'b0;
                        b_off   <= b_off + 32'd4;
                        b_cnt   <= b_cnt - 32'd4;
                        b_total <= b_total + 32'd4;
                        if (b_cnt == 32'd4) begin
                            b_state <= B_GO_G;
                        end else if (((b_total + 32'd4) & 32'h00000FFF)
                                == 32'd0) begin
                            b_msg <= 3'd1; b_sidx <= 3'd0;   // dot
                            b_send_next <= B_WDATA;
                            b_state <= B_SEND;
                        end
                    end else if (!b_wr_pend && skid_valid) begin
                        bl_rx_take <= 1'b1;
                        b_crc    <= crc32_step(b_crc, skid_data);
                        b_wshift <= {skid_data, b_wshift[31:8]};
                        if (b_bcnt == 2'd3) begin
                            b_bcnt    <= 2'd0;
                            b_wr_data <= {skid_data, b_wshift[31:8]};
                            b_addr    <= (b_addr_r + b_off) >> 2;
                            b_wr_pend <= 1'b1;
                        end else begin
                            b_bcnt <= b_bcnt + 2'd1;
                        end
                    end
                end
                B_GO_G: begin
                    if (skid_valid) begin
                        bl_rx_take <= 1'b1;
                        if (skid_data == "G") b_state <= B_GO_O;
                    end
                end
                B_GO_O: begin
                    if (skid_valid) begin
                        bl_rx_take <= 1'b1;
                        if (skid_data == "O") begin
                            b_bcnt  <= 2'd0;
                            b_state <= B_CRCB;
                        end
                    end
                end
                B_CRCB: begin
                    if (skid_valid) begin
                        bl_rx_take <= 1'b1;
                        b_crc_rx <= {skid_data, b_crc_rx[31:8]};
                        if (b_bcnt == 2'd3) begin
                            b_bcnt  <= 2'd0;
                            b_state <= B_CMP;
                        end else begin
                            b_bcnt <= b_bcnt + 2'd1;
                        end
                    end
                end
                B_CMP: begin
                    b_sidx <= 3'd0;
`ifdef BL_DEBUG
                    $display("[bl %0t] CMP local=%08x rx=%08x", $time, b_crc_final, b_crc_rx);
`endif
                    if (b_crc_final == b_crc_rx) begin
                        b_msg <= 3'd2;   // OK + crc echo
                        b_send_next <= B_FLUSH;
                        b_flush <= 10'd0;
                    end else begin
                        h0 <= 8'd0; h1 <= 8'd0; h2 <= 8'd0;
                        h3 <= 8'd0; h4 <= 8'd0;
                        b_msg <= 3'd3;   // BAD
                        b_send_next <= B_LISTEN;
                    end
                    b_state <= B_SEND;
                end
                B_FLUSH: begin
                    if (b_flush == 10'd1023) begin
                        booted  <= 1'b1;
                        b_state <= B_DONE;
                    end else begin
                        b_flush <= b_flush + 10'd1;
                    end
                end
                B_DONE: begin
                    b_wr_req <= 1'b0;
                end
                default: b_state <= B_LISTEN;
            endcase
        end
    end

    // ------------------------------------------------- RX skid driver
    always @(posedge sys_clk) begin
        if (sys_rst) begin
            skid_data  <= 8'd0;
            skid_valid_r <= 1'b0;
        end else if (rx_valid && bl_rx_take) begin
            skid_data  <= rx_data;   // take + arrival: new byte wins
            skid_valid_r <= 1'b1;
        end else if (bl_rx_take) begin
            skid_valid_r <= 1'b0;
        end else if (rx_valid) begin
            skid_data  <= rx_data;
            skid_valid_r <= 1'b1;
        end
    end

    // ------------------------------------------------- core arbiter
    // One gated core clock per pass: tick the core, let its outputs
    // settle, latch everything, serve both fetch slots (I-cache, fill on
    // miss), then both data ports (MMIO regs or SDRAM with sub-word
    // extract/merge), then tick again. EXIT parks the clock.
    localparam [4:0] A_HELD=5'd0, A_TICK=5'd1, A_SET1=5'd2, A_SET2=5'd3,
                     A_LATCH=5'd4, A_ILOOK=5'd5, A_ICAP=5'd6, A_IF0=5'd7,
                     A_IF1=5'd8, A_D0=5'd9, A_D1=5'd10, A_IWAIT=5'd11,
                     A_DMP_HDR=5'd12, A_DMP_REQ=5'd13, A_DMP_WAIT=5'd14, A_DMP_BYTE=5'd15;
    reg [4:0] a_state;
    reg [22:0] l_iw0, l_iw1;
    reg [12:0] l_tag0, l_tag1;
    reg [9:0] l_idx0, l_idx1;
    reg l_hit0, l_hit1;
    reg [31:0] l_d0a, l_d0w, l_d1a, l_d1w;
    reg [2:0] l_d0f, l_d1f;
    reg l_d0re, l_d0we, l_d1re, l_d1we, l_d0mm, l_d0fb, l_d1mm, l_d1fb;

    // Frame dump streamer registers
    reg dump_req;
    reg dump_tiny;      // 1 = this dump is a 64x32 tiny frame (DUMP=2)
    // wall clock: free-running sys-cycle counter (true wall time for games;
    // cycle_q only advances with the core, which the arbiter throttles)
    reg [63:0] wall_q;
    always @(posedge sys_clk) begin
        if (core_rst) wall_q <= 64'd0;
        else wall_q <= wall_q + 64'd1;
    end
    reg [3:0] dump_hidx;
    reg [14:0] dump_widx;
    reg [7:0] dump_row;
    reg [6:0] dump_col;
    reg [1:0] dump_bidx;
    reg [31:0] dump_latch;

    reg [7:0] dmp_hdr_byte;
    always @(*) begin
        case (dump_hidx)
            4'd0: dmp_hdr_byte = 8'h55;
            4'd1: dmp_hdr_byte = 8'hAA;
            4'd2: dmp_hdr_byte = 8'h5A;
            4'd3: dmp_hdr_byte = 8'hA5;
            4'd4: dmp_hdr_byte = {6'd0, dump_tiny, dump_half};
            4'd5: dmp_hdr_byte = frame_cnt_r[7:0];
            4'd6: dmp_hdr_byte = frame_cnt_r[15:8];
            4'd7: dmp_hdr_byte = dump_tiny ? 8'd64 : (dump_half ? 8'd160 : 8'h40);
            4'd8: dmp_hdr_byte = dump_tiny ? 8'd0  : (dump_half ? 8'd0   : 8'h01);
            default: dmp_hdr_byte = dump_tiny ? 8'd32 : (dump_half ? 8'd100 : 8'd200); // 4'd9
        endcase
    end

    wire [31:0] d_addr   = (a_state == A_D1) ? l_d1a : l_d0a;
    wire [31:0] d_wdata  = (a_state == A_D1) ? l_d1w : l_d0w;
    wire [2:0]  d_funct3 = (a_state == A_D1) ? l_d1f : l_d0f;
    wire d_re = (a_state == A_D1) ? l_d1re : l_d0re;
    wire d_we = (a_state == A_D1) ? l_d1we : l_d0we;
    wire d_mm = (a_state == A_D1) ? l_d1mm : l_d0mm;
    wire d_fb = (a_state == A_D1) ? l_d1fb : l_d0fb;
    wire [22:0] d_word = d_fb ? (FB_SDR_WORD + d_addr[15:2]) : d_addr[24:2];

    reg [3:0] d_be;
    reg [31:0] d_wd;
    always @(*) begin
        case (d_funct3)
            3'b000: begin   // SB: one byte lane, byte on all lanes
                d_be = 4'b0001 << d_addr[1:0];
                d_wd = {4{d_wdata[7:0]}};
            end
            3'b001: begin   // SH: half lanes
                d_be = d_addr[1] ? 4'b1100 : 4'b0011;
                d_wd = {2{d_wdata[15:0]}};
            end
            default: begin   // SW
                d_be = 4'b1111;
                d_wd = d_wdata;
            end
        endcase
    end

    always @(posedge sys_clk) begin
        if (core_rst) begin
            a_state <= A_HELD;
            core_run_d <= 1'b0;
            a_rd_req <= 1'b0; a_wr_req <= 1'b0;
            a_addr <= 23'd0; a_wr_data <= 32'd0; a_wr_be <= 4'd0;
            a_da_a <= 10'd0; a_ta_a <= 10'd0; a_dd_a <= 32'd0;
            a_td_a <= 14'd0; a_dw_a <= 1'b0; a_tw_a <= 1'b0;
            ic_da_b <= 10'd0; ic_ta_b <= 10'd0; ic_dd_b <= 32'd0;
            ic_td_b <= 14'd0; ic_dw_b <= 1'b0; ic_tw_b <= 1'b0;
            cycle_q <= 64'd0; instret_q <= 64'd0;
            exit_req_r <= 1'b0; exit_code <= 32'd0;
            frame_cnt_r <= 32'd0; fb_base_reg <= FB_BASE;
            fifo_wr <= 1'b0; fifo_wdata <= 8'd0;
            key_ack <= 1'b0;
            dump_req <= 1'b0; dump_tiny <= 1'b0; dump_hidx <= 4'd0; dump_widx <= 15'd0;
            dump_row <= 8'd0; dump_col <= 7'd0; dump_bidx <= 2'd0;
            dump_latch <= 32'd0;
            inst_data0 <= 32'd0; inst_data1 <= 32'd0;
            mem_rdata0 <= 32'd0; mem_rdata1 <= 32'd0;
            l_iw0 <= 23'd0; l_iw1 <= 23'd0;
            l_tag0 <= 13'd0; l_tag1 <= 13'd0;
            l_idx0 <= 10'd0; l_idx1 <= 10'd0;
            l_hit0 <= 1'b0; l_hit1 <= 1'b0;
            l_d0a <= 32'd0; l_d0w <= 32'd0;
            l_d1a <= 32'd0; l_d1w <= 32'd0;
            l_d0f <= 3'd0; l_d1f <= 3'd0;
            l_d0re <= 1'b0; l_d0we <= 1'b0;
            l_d1re <= 1'b0; l_d1we <= 1'b0;
            l_d0mm <= 1'b0; l_d0fb <= 1'b0;
            l_d1mm <= 1'b0; l_d1fb <= 1'b0;
        end else begin
            key_ack <= 1'b0;   // default; the MMIO ack re-asserts
            case (a_state)
                A_HELD: begin
                    core_run_d <= 1'b0;
                    a_rd_req <= 1'b0; a_wr_req <= 1'b0;
                    fifo_wr <= 1'b0;
                    a_dw_a <= 1'b0; a_tw_a <= 1'b0;
                    ic_dw_b <= 1'b0; ic_tw_b <= 1'b0;
                    if (booted && !exit_req_r) a_state <= A_TICK;
                end
                A_TICK: begin
                    fifo_wr <= 1'b0;
                    if (exit_req_r) begin
                        a_state <= A_HELD;
                    end else begin
                        core_run_d <= 1'b1;
                        a_state <= A_SET1;
                    end
                end
                A_SET1: begin
                    fifo_wr <= 1'b0;
                    core_run_d <= 1'b0;
                    cycle_q <= cycle_q + 64'd1;
                    a_state <= A_SET2;
                end
                A_SET2: begin
                    fifo_wr <= 1'b0;
                    a_state <= A_LATCH;
                end
                A_LATCH: begin
                    fifo_wr <= 1'b0;
                    l_iw0 <= inst_addr0[24:2];
                    l_iw1 <= inst_addr1[24:2];
                    l_tag0 <= inst_addr0[24:12];
                    l_tag1 <= inst_addr1[24:12];
                    l_idx0 <= inst_addr0[11:2];
                    l_idx1 <= inst_addr1[11:2];
                    l_d0a <= mem_addr0; l_d0w <= mem_wdata0;
                    l_d0f <= mem_funct3_0;
                    l_d0re <= mem_re0; l_d0we <= mem_we0;
                    l_d0mm <= (mem_addr0[31:12] == MMIO_BASE[31:12]);
                    l_d0fb <= (mem_addr0[31:16] == FB_BASE[31:16]);
                    l_d1a <= mem_addr1; l_d1w <= mem_wdata1;
                    l_d1f <= mem_funct3_1;
                    l_d1re <= mem_re1; l_d1we <= mem_we1;
                    l_d1mm <= (mem_addr1[31:12] == MMIO_BASE[31:12]);
                    l_d1fb <= (mem_addr1[31:16] == FB_BASE[31:16]);
                    instret_q <= instret_q
                        + {63'd0, (reg_write0 && reg_wa0 != 5'd0)}
                        + {63'd0, (reg_write1 && reg_wa1 != 5'd0)};
                    a_state <= A_ILOOK;
                end
                A_ILOOK: begin
                    a_da_a <= l_idx0; a_ta_a <= l_idx0;
                    ic_da_b <= l_idx1; ic_ta_b <= l_idx1;
                    fifo_wr <= 1'b0;
                    a_dw_a <= 1'b0; a_tw_a <= 1'b0;
                    ic_dw_b <= 1'b0; ic_tw_b <= 1'b0;
                    a_state <= A_IWAIT;
                end
                A_IWAIT: begin
                    // Settle: the A_ILOOK-presented index needs one sys_clk
                    // to propagate through the registered RAM outputs
                    // (ic_tq/ic_dq) before A_ICAP may sample them.
                    fifo_wr <= 1'b0;
                    a_state <= A_ICAP;
                end
                A_ICAP: begin
                    fifo_wr <= 1'b0;
                    l_hit0 <= ic_tq_a[13] && (ic_tq_a[12:0] == l_tag0);
                    l_hit1 <= ic_tq_b[13] && (ic_tq_b[12:0] == l_tag1);
                    if (ic_tq_a[13] && (ic_tq_a[12:0] == l_tag0))
                        inst_data0 <= ic_dq_a;
                    if (ic_tq_b[13] && (ic_tq_b[12:0] == l_tag1))
                        inst_data1 <= ic_dq_b;
                    a_state <= A_IF0;
                end
                A_IF0: begin
                    fifo_wr <= 1'b0;
                    if (l_hit0) begin
                        a_state <= A_IF1;
                    end else begin
                        a_rd_req <= 1'b1;
                        a_addr <= l_iw0;
                        if (c_rd_ack) begin
                            a_rd_req <= 1'b0;
                            inst_data0 <= c_rd_data;
                            a_da_a <= l_idx0; a_dd_a <= c_rd_data;
                            a_dw_a <= 1'b1;
                            a_ta_a <= l_idx0;
                            a_td_a <= {1'b1, l_tag0};
                            a_tw_a <= 1'b1;
                            a_state <= A_IF1;
                        end
                    end
                end
                A_IF1: begin
                    fifo_wr <= 1'b0;
                    a_dw_a <= 1'b0; a_tw_a <= 1'b0;
                    if (l_hit1) begin
                        a_state <= A_D0;
                    end else begin
                        a_rd_req <= 1'b1;
                        a_addr <= l_iw1;
                        if (c_rd_ack) begin
                            a_rd_req <= 1'b0;
                            inst_data1 <= c_rd_data;
                            ic_da_b <= l_idx1; ic_dd_b <= c_rd_data;
                            ic_dw_b <= 1'b1;
                            ic_ta_b <= l_idx1;
                            ic_td_b <= {1'b1, l_tag1};
                            ic_tw_b <= 1'b1;
                            a_state <= A_D0;
                        end
                    end
                end
                A_D0: begin
                    fifo_wr <= 1'b0;
                    a_dw_a <= 1'b0; a_tw_a <= 1'b0;
                    ic_dw_b <= 1'b0; ic_tw_b <= 1'b0;
                    if (!d_re && !d_we) begin
                        a_state <= A_D1;
                    end else if (d_mm) begin
                        if (d_we) begin
                            case (d_addr[11:0])
                                12'h000: begin
                                    exit_req_r <= 1'b1;
                                    exit_code <= d_wdata;
                                    a_state <= A_D1;
                                end
                                12'h014: begin
                                    key_ack <= 1'b1;
                                    a_state <= A_D1;
                                end
                                12'h01C: begin
                                    fb_base_reg <= d_wdata;
                                    a_state <= A_D1;
                                end
                                12'h024: begin
                                    if (fifo_has_space) begin
                                        fifo_wr <= 1'b1;
                                        fifo_wdata <= d_wdata[7:0];
                                        a_state <= A_D1;
                                    end
                                    // else STAY: backpressure stall
                                end
                                12'h028: begin
                                    frame_cnt_r <= frame_cnt_r + 32'd1;
                                    if (dump_enable) begin
                                        dump_req <= 1'b1;
                                        dump_tiny <= (d_wdata == 32'd2);
                                    end
                                    a_state <= A_D1;
                                end
                                default: a_state <= A_D1;
                            endcase
                        end else begin
                            mem_rdata0 <= mmio_read(d_addr[11:0]);
                            a_state <= A_D1;
                        end
                    end else if (d_we) begin
                        a_wr_req <= 1'b1;
                        a_addr <= d_word;
                        a_wr_data <= d_wd;
                        a_wr_be <= d_be;
                        if (c_wr_ack) begin
                            a_wr_req <= 1'b0;
                            a_state <= A_D1;
                        end
                    end else begin
                        a_rd_req <= 1'b1;
                        a_addr <= d_word;
                        if (c_rd_ack) begin
                            a_rd_req <= 1'b0;
                            mem_rdata0 <= load_extract(c_rd_data, d_funct3,
                                                       d_addr[1:0]);
                            a_state <= A_D1;
                        end
                    end
                end
                A_D1: begin
                    fifo_wr <= 1'b0;
                    a_dw_a <= 1'b0; a_tw_a <= 1'b0;
                    ic_dw_b <= 1'b0; ic_tw_b <= 1'b0;
                    if (!d_re && !d_we) begin
                        a_state <= dump_req ? A_DMP_HDR : A_TICK;
                    end else if (d_mm) begin
                        if (d_we) begin
                            case (d_addr[11:0])
                                12'h000: begin
                                    exit_req_r <= 1'b1;
                                    exit_code <= d_wdata;
                                    a_state <= A_TICK;
                                end
                                12'h014: begin
                                    key_ack <= 1'b1;
                                    a_state <= dump_req ? A_DMP_HDR : A_TICK;
                                end
                                12'h01C: begin
                                    fb_base_reg <= d_wdata;
                                    a_state <= dump_req ? A_DMP_HDR : A_TICK;
                                end
                                12'h024: begin
                                    if (fifo_has_space) begin
                                        fifo_wr <= 1'b1;
                                        fifo_wdata <= d_wdata[7:0];
                                        a_state <= dump_req ? A_DMP_HDR : A_TICK;
                                    end
                                    // else STAY: backpressure stall
                                end
                                12'h028: begin
                                    frame_cnt_r <= frame_cnt_r + 32'd1;
                                    if (dump_enable) dump_tiny <= (d_wdata == 32'd2);
                                    a_state <= dump_enable ? A_DMP_HDR : A_TICK;
                                end
                                default: a_state <= dump_req ? A_DMP_HDR : A_TICK;
                            endcase
                        end else begin
                            mem_rdata1 <= mmio_read(d_addr[11:0]);
                            a_state <= dump_req ? A_DMP_HDR : A_TICK;
                        end
                    end else if (d_we) begin
                        a_wr_req <= 1'b1;
                        a_addr <= d_word;
                        a_wr_data <= d_wd;
                        a_wr_be <= d_be;
                        if (c_wr_ack) begin
                            a_wr_req <= 1'b0;
                            a_state <= dump_req ? A_DMP_HDR : A_TICK;
                        end
                    end else begin
                        a_rd_req <= 1'b1;
                        a_addr <= d_word;
                        if (c_rd_ack) begin
                            a_rd_req <= 1'b0;
                            mem_rdata1 <= load_extract(c_rd_data, d_funct3,
                                                       d_addr[1:0]);
                            a_state <= dump_req ? A_DMP_HDR : A_TICK;
                        end
                    end
                end
                A_DMP_HDR: begin
                    dump_req <= 1'b0;
                    if (fifo_has_space) begin
                        fifo_wr    <= 1'b1;
                        fifo_wdata <= dmp_hdr_byte;
                        if (dump_hidx == 4'd9) begin
                            dump_hidx <= 4'd0;
                            dump_widx <= 15'd0;
                            dump_row  <= 8'd0;
                            dump_col  <= 7'd0;
                            a_state   <= A_DMP_REQ;
                        end else begin
                            dump_hidx <= dump_hidx + 4'd1;
                        end
                    end else begin
                        fifo_wr <= 1'b0;
                    end
                end
                A_DMP_REQ: begin
                    fifo_wr  <= 1'b0;
                    a_rd_req <= 1'b1;
                    a_addr   <= FB_SDR_WORD + {8'd0, dump_widx};
                    a_state  <= A_DMP_WAIT;
                end
                A_DMP_WAIT: begin
                    fifo_wr <= 1'b0;
                    if (c_rd_ack) begin
                        a_rd_req   <= 1'b0;
                        dump_latch <= c_rd_data;
                        dump_bidx  <= 2'd0;
                        a_state    <= A_DMP_BYTE;
                    end
                end
                A_DMP_BYTE: begin
                    if (dump_half && !dump_tiny) begin
                        // 160x100 mode: 2 pixels per word (byte 0 and byte 2) on even rows
                        if (dump_bidx == 2'd0) begin
                            if (fifo_has_space) begin
                                fifo_wr    <= 1'b1;
                                fifo_wdata <= dump_latch[7:0];
                                dump_bidx  <= 2'd2;
                            end else begin
                                fifo_wr <= 1'b0;
                            end
                        end else begin // dump_bidx == 2'd2
                            if (fifo_has_space) begin
                                fifo_wr    <= 1'b1;
                                fifo_wdata <= dump_latch[23:16];
                                dump_bidx  <= 2'd0;
                                if (dump_col == 7'd79) begin
                                    dump_col <= 7'd0;
                                    dump_row <= dump_row + 8'd2;
                                    if (dump_row + 8'd2 == 8'd200) begin
                                        a_state <= A_TICK;
                                    end else begin
                                        dump_widx <= dump_widx + 15'd81;
                                        a_state   <= A_DMP_REQ;
                                    end
                                end else begin
                                    dump_col  <= dump_col + 7'd1;
                                    dump_widx <= dump_widx + 15'd1;
                                    a_state   <= A_DMP_REQ;
                                end
                            end else begin
                                fifo_wr <= 1'b0;
                            end
                        end
                    end else begin
                        // 320x200 mode: all 4 bytes of each word
                        if (fifo_has_space) begin
                            fifo_wr <= 1'b1;
                            case (dump_bidx)
                                2'd0: fifo_wdata <= dump_latch[7:0];
                                2'd1: fifo_wdata <= dump_latch[15:8];
                                2'd2: fifo_wdata <= dump_latch[23:16];
                                default: fifo_wdata <= dump_latch[31:24];
                            endcase
                            if (dump_bidx == 2'd3) begin
                                dump_bidx <= 2'd0;
                                if (dump_widx == (dump_tiny ? 15'd511 : 15'd15999)) begin
                                    a_state <= A_TICK;
                                end else begin
                                    dump_widx <= dump_widx + 15'd1;
                                    a_state   <= A_DMP_REQ;
                                end
                            end else begin
                                dump_bidx <= dump_bidx + 2'd1;
                            end
                        end else begin
                            fifo_wr <= 1'b0;
                        end
                    end
                end
                default: a_state <= A_HELD;
            endcase
        end
    end
`ifdef BL_DEBUG
    // Temporary: log every bootloader state change with its counters.
    reg [4:0] dbg_prev;
    always @(posedge sys_clk) begin
        if (sys_rst) begin
            dbg_prev <= B_LISTEN;
        end else if (b_state != dbg_prev) begin
            $display("[bl] state %0d -> %0d  seg=%0d/%0d total=%0d cnt=%0d next=%0d",
                     dbg_prev, b_state, b_seg, b_nseg, b_total, b_cnt, b_send_next);
            dbg_prev <= b_state;
        end
    end
`endif
endmodule