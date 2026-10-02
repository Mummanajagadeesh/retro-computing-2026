`include "defines.v"

module registers (
    input         clk,
    input         rst,
    // port 0
    input         we0,
    input  [4:0]  wa0,
    input  [31:0] wd0,
    // port 1
    input         we1,
    input  [4:0]  wa1,
    input  [31:0] wd1,
    // read ports (4 total)
    input  [4:0]  ra1, ra2, ra3, ra4,
    output [31:0] rd1, rd2, rd3, rd4
);
    reg [31:0] rf [0:31];
    integer i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1)
                rf[i] <= 32'b0;
        end else begin
            if (we0 && wa0 != 5'b0) rf[wa0] <= wd0;
            if (we1 && wa1 != 5'b0) rf[wa1] <= wd1;
        end
    end

    assign rd1 = (ra1 == 5'b0) ? 32'b0 : rf[ra1];
    assign rd2 = (ra2 == 5'b0) ? 32'b0 : rf[ra2];
    assign rd3 = (ra3 == 5'b0) ? 32'b0 : rf[ra3];
    assign rd4 = (ra4 == 5'b0) ? 32'b0 : rf[ra4];
endmodule

