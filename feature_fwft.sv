`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 8-wide, 27x27-deep
//////////////////////////////////////////////////////////////////////////////////


module feature_fwft(
    input        clk,
    input        rst,
    input        rd_en,
    input  [7:0] in_feature,
    output [7:0] out_feature
);

    localparam FIFO_WIDTH = 8;
    localparam FIFO_DEPTH = 27*27;
    localparam FIFO_ADDRW = $clog2(FIFO_DEPTH);
    
    logic [FIFO_WIDTH-1:0] fifo_data [0:FIFO_DEPTH-1];
    
    logic [FIFO_ADDRW-1:0] fifo_rd_addr;
    logic [FIFO_ADDRW-1:0] fifo_wr_addr;
    
    always_ff @(clk)
    begin
        if (rst) begin
            fifo_rd_addr <= 'b0;
            fifo_wr_addr <= 'b0;
        end else begin
            if (fifo_wr_addr < FIFO_DEPTH)
                fifo_data[fifo_wr_addr] <= in_feature;
            
            if (rd_en)
                fifo_rd_addr <= fifo_rd_addr + 1;
        end
    end
    
    assign feature_out = fifo_data[fifo_rd_addr];

endmodule
