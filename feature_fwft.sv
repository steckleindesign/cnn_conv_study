`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 8-wide, 27x27-deep
//////////////////////////////////////////////////////////////////////////////////

module feature_fwft(
    input        clk,
    input        rst,
    input        rd_en,
    input  [7:0] in_feature,
    output       feature_valid,
    output [7:0] out_feature
);

    localparam FIFO_WIDTH = 8;
    localparam FIFO_DEPTH = 27*27;
    localparam FIFO_ADDRW = $clog2(FIFO_DEPTH);
    
    logic [FIFO_WIDTH-1:0] fifo_data [0:FIFO_DEPTH-1];
    logic [FIFO_ADDRW-1:0] fifo_rd_addr;
    logic [FIFO_ADDRW-1:0] fifo_wr_addr;
    logic                  valid;
    
    always_ff @(posedge clk)
    begin
        if (rst) begin
            fifo_data    <= '{default: 0};
            fifo_rd_addr <= 'b0;
            fifo_wr_addr <= 'b0;
            valid        <= 0;
        end else begin
            // TODO: Need more useful valid signal
            valid <= 1;
            if (fifo_wr_addr < FIFO_DEPTH) begin
                fifo_data[fifo_wr_addr] <= in_feature;
                fifo_wr_addr <= fifo_wr_addr + 1;
            end
            if (fifo_wr_addr > 0 && rd_en) begin
                fifo_rd_addr <= fifo_rd_addr + 1;
            end
        end
    end
    
    assign feature_valid = valid;
    // Should this be registered or is it ok
    // since we process the data in conv in a sequential process
    assign out_feature   = fifo_data[fifo_rd_addr];

endmodule
