`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 8-wide, 27x27-deep
//////////////////////////////////////////////////////////////////////////////////

module feature_fwft(
    input  logic       i_clk,
    input  logic       i_rst,
    input  logic       i_rd_en,
    input  logic [7:0] i_in_feature,
    output logic       o_feature_valid,
    output logic [7:0] o_out_feature
);

    localparam FIFO_WIDTH = 8;
    localparam FIFO_DEPTH = 27*27;
    localparam FIFO_ADDRW = $clog2(FIFO_DEPTH);
    
    logic [FIFO_WIDTH-1:0] fifo_data[0:FIFO_DEPTH-1];
    logic [FIFO_ADDRW-1:0] fifo_rd_addr;
    logic [FIFO_ADDRW-1:0] fifo_wr_addr;
    logic                  valid;
    
    always_ff @(posedge i_clk)
    begin
        if (i_rst) begin
            fifo_data    <= '{default: 0};
            fifo_rd_addr <= 'b0;
            fifo_wr_addr <= 'b0;
            valid        <= 0;
        end else begin
            // TODO: Need more useful valid signal
            valid <= 1;
            if (fifo_wr_addr < FIFO_DEPTH) begin
                fifo_data[fifo_wr_addr] <= i_in_feature;
                fifo_wr_addr <= fifo_wr_addr + 1;
            end
            if (fifo_wr_addr > 0 && i_rd_en) begin
                fifo_rd_addr <= fifo_rd_addr + 1;
            end
        end
    end
    
    assign o_feature_valid = valid;
    // Should this be registered or is it ok
    // since we process the data in conv in a sequential process
    assign o_out_feature   = fifo_data[fifo_rd_addr];

endmodule
