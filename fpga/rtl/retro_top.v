// retro_top.v -- DE0-Nano retro console top: the rv32i core behind mem_top_fpga.
// Same JP1 UART wiring as phase 1 (pin 2 = RX <- TTL TX, pin 4 = TX ->
// TTL RX, pin 12 = GND), now at 921600 baud. Upload with host/uploader.py,
// then the transcript streams out of the same port.
//
// KEY0 (active low) = reboot the core from the intact SDRAM image: the
// game restarts in about a second with no re-upload. KEY1 (active low) =
// full reset back to the bootloader (re-upload required).
//
// LED map: 0 heartbeat 1 Hz, 1 uart-tx activity, 2 uart-rx activity,
//          3 booted, 4 frame tick, 5 exit seen,
//          7:6 upload progress pre-boot, frame nibble running, code on exit.
module retro_top (
    input            CLOCK_50,
    input     [1:0]  KEY,
    output reg [7:0] LED,
    input            UART_RX,
    output           UART_TX,
    inout            OLED_SCL,
    inout            OLED_SDA,
    output    [12:0] DRAM_ADDR,
    output    [1:0]  DRAM_BA,
    inout     [15:0] DRAM_DQ,
    output           DRAM_CAS_N,
    output           DRAM_CKE,
    output           DRAM_CLK,
    output           DRAM_CS_N,
    output    [1:0]  DRAM_DQM,
    output           DRAM_RAS_N,
    output           DRAM_WE_N
);
    wire clk = CLOCK_50;

    // reset: power-on hold + KEY1, synchronized (same shape as phase 1)
    reg [15:0] por_cnt;
    reg key1_a, key1_s;
    reg sys_rst;
    initial begin
        por_cnt = 16'd0;
        key1_a  = 1'b1;
        key1_s  = 1'b1;
        sys_rst = 1'b1;
    end
    always @(posedge clk) begin
        key1_a <= KEY[1];
        key1_s <= key1_a;
        if (por_cnt != 16'hFFFF)
            por_cnt <= por_cnt + 16'd1;
        sys_rst <= (por_cnt != 16'hFFFF) | ~key1_s;
    end

    // core <-> memory wiring (slot 1 fetches pc+4, like mem_top)
    wire core_clk, core_rst;
    wire [31:0] pc_out;
    wire [31:0] inst_addr0, inst_addr1, inst_data0, inst_data1;
    assign inst_addr0 = pc_out;
    assign inst_addr1 = pc_out + 32'd4;
    wire mem_we0, mem_re0, mem_we1, mem_re1;
    wire [31:0] mem_addr0, mem_wdata0, mem_addr1, mem_wdata1;
    wire [2:0] mem_funct3_0, mem_funct3_1;
    wire [31:0] mem_rdata0, mem_rdata1;
    wire reg_write0, reg_write1;
    wire [4:0] reg_wa0, reg_wa1;

    core_top #(.RESET_PC(32'h00000000)) cpu (
        .clk(core_clk),
        .rst(core_rst),
        .pc_out(pc_out),
        .instr0(inst_data0),
        .instr1(inst_data1),
        .mem_read_data0(mem_rdata0),
        .mem_read_data1(mem_rdata1),
        .mem_read0(mem_re0),
        .mem_write0(mem_we0),
        .mem_addr0(mem_addr0),
        .mem_wdata0(mem_wdata0),
        .mem_funct30(mem_funct3_0),
        .mem_read1(mem_re1),
        .mem_write1(mem_we1),
        .mem_addr1(mem_addr1),
        .mem_wdata1(mem_wdata1),
        .mem_funct31(mem_funct3_1),
        .reg_write0(reg_write0),
        .reg_wa0(reg_wa0),
        .reg_write1(reg_write1),
        .reg_wa1(reg_wa1)
    );

    wire booted, exit_req, tx_active, rx_active;
    wire [7:0] exit_code_lo, bl_progress;
    wire [31:0] frame_cnt;
    mem_top_fpga mem (
        .sys_clk(clk),
        .sys_rst(sys_rst),
        .core_rst_req(~KEY[0]),
        .tb_bypass_boot(1'b0),
        .core_clk(core_clk),
        .core_rst(core_rst),
        .inst_addr0(inst_addr0),
        .inst_data0(inst_data0),
        .inst_addr1(inst_addr1),
        .inst_data1(inst_data1),
        .mem_we0(mem_we0),
        .mem_re0(mem_re0),
        .mem_addr0(mem_addr0),
        .mem_wdata0(mem_wdata0),
        .mem_funct3_0(mem_funct3_0),
        .mem_rdata0(mem_rdata0),
        .mem_we1(mem_we1),
        .mem_re1(mem_re1),
        .mem_addr1(mem_addr1),
        .mem_wdata1(mem_wdata1),
        .mem_funct3_1(mem_funct3_1),
        .mem_rdata1(mem_rdata1),
        .reg_write0(reg_write0),
        .reg_wa0(reg_wa0),
        .reg_write1(reg_write1),
        .reg_wa1(reg_wa1),
        .uart_rxd(UART_RX),
        .uart_txd(UART_TX),
        .DRAM_ADDR(DRAM_ADDR),
        .DRAM_BA(DRAM_BA),
        .DRAM_DQ(DRAM_DQ),
        .DRAM_CAS_N(DRAM_CAS_N),
        .DRAM_CKE(DRAM_CKE),
        .DRAM_CLK(DRAM_CLK),
        .DRAM_CS_N(DRAM_CS_N),
        .DRAM_DQM(DRAM_DQM),
        .DRAM_RAS_N(DRAM_RAS_N),
        .DRAM_WE_N(DRAM_WE_N),
        .booted(booted),
        .exit_req(exit_req),
        .exit_code_lo(exit_code_lo),
        .frame_cnt(frame_cnt),
        .tx_active(tx_active),
        .rx_active(rx_active),
        .bl_progress(bl_progress),
        .fb_stream_valid(fb_stream_valid),
        .fb_stream_addr(fb_stream_addr),
        .fb_stream_data(fb_stream_data)
    );

    // Autonomous SSD1306 0.96" I2C OLED Driver (128x64, 2x2 upscale)
    wire fb_stream_valid;
    wire [10:0] fb_stream_addr;
    wire [7:0] fb_stream_data;
    wire oled_ready;
    wire [31:0] oled_frame_cnt;

    ssd1306_i2c oled (
        .clk(clk),
        .rst(sys_rst),
        .fb_write_en(fb_stream_valid),
        .fb_write_addr(fb_stream_addr),
        .fb_write_data(fb_stream_data),
        .OLED_SCL(OLED_SCL),
        .OLED_SDA(OLED_SDA),
        .oled_ready(oled_ready),
        .oled_frame_cnt(oled_frame_cnt)
    );

    // LEDs: heartbeat + stretchered activity + boot/frame/exit status
    reg [24:0] hb_cnt;
    reg hb;
    reg [22:0] rx_stretch, tx_stretch;
    always @(posedge clk) begin
        if (sys_rst) begin
            hb_cnt     <= 25'd0;
            hb         <= 1'b0;
            rx_stretch <= 23'd0;
            tx_stretch <= 23'd0;
            LED        <= 8'd0;
        end else begin
            if (hb_cnt == 25'd25000000-1) begin
                hb_cnt <= 25'd0;
                hb     <= ~hb;
            end else begin
                hb_cnt <= hb_cnt + 25'd1;
            end
            rx_stretch <= rx_active ? 23'd5000000 :
                          (|rx_stretch ? rx_stretch - 23'd1 : 23'd0);
            tx_stretch <= tx_active ? 23'd5000000 :
                          (|tx_stretch ? tx_stretch - 23'd1 : 23'd0);
            LED[0] <= hb;
            LED[1] <= |tx_stretch;
            LED[2] <= |rx_stretch;
            LED[3] <= booted;
            LED[4] <= frame_cnt[2];
            LED[5] <= exit_req;
            LED[7:6] <= exit_req ? exit_code_lo[1:0] :
                        booted   ? frame_cnt[3:2]   : bl_progress[5:4];
        end
    end
endmodule
