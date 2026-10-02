// fifo_sync.v -- single-clock sync FIFO, block-RAM friendly.
// Standard (non-FWFT): rd_en -> rdata valid next cycle. Depth power of two.
module fifo_sync #(
    parameter WIDTH = 8,
    parameter DEPTH = 4096,
    parameter AW = $clog2(DEPTH)
) (
    input                  clk,
    input                  rst,
    input                  wr_en,
    input      [WIDTH-1:0] wr_data,
    input                  rd_en,
    output reg [WIDTH-1:0] rd_data,
    output                 full,
    output                 empty,
    output     [AW:0]      count
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW-1:0] wr_ptr, rd_ptr;
    reg [AW:0] cnt;

    assign full  = (cnt == DEPTH);
    assign empty = (cnt == 0);
    assign count = cnt;

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr  <= {AW{1'b0}};
            rd_ptr  <= {AW{1'b0}};
            cnt     <= {(AW+1){1'b0}};
            rd_data <= {WIDTH{1'b0}};
        end else begin
            if (do_wr) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (do_rd) begin
                rd_data <= mem[rd_ptr];
                rd_ptr  <= rd_ptr + 1'b1;
            end
            case ({do_wr, do_rd})
                2'b10:   cnt <= cnt + 1'b1;
                2'b01:   cnt <= cnt - 1'b1;
                default: cnt <= cnt;
            endcase
        end
    end
endmodule
