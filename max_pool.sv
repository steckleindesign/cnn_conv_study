`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////////

module max_pool #(
    parameter DATA_WIDTH   = 16,
    parameter NUM_CHANNELS = 6,
    parameter NUM_COLUMNS  = 28,
    parameter NUM_OUT_ROWS = 14
)(
    input  logic                         i_clk,
    input  logic                         i_start,
    input  logic signed [DATA_WIDTH-1:0] i_features[0:NUM_CHANNELS-1],
    output logic signed [DATA_WIDTH-1:0] o_features[0:NUM_CHANNELS-1],
    output logic                         o_nd
);
    
    logic [DATA_WIDTH-1:0] feature_buf[0:NUM_CHANNELS-1][0:NUM_COLUMNS-1];
    logic [$clog2(NUM_COLUMNS )-1:0] col_cnt;
    logic [$clog2(NUM_OUT_ROWS)-1:0] row_cnt;
    logic is_bottom_row;
    logic processing;
    logic nd_out;
    
    always_ff @(posedge i_clk)
    begin
        nd_out <= 0;
        if (~processing)
        begin
            col_cnt       <= 'b0;
            row_cnt       <= 'b0;
            is_bottom_row <= 0;
            if (i_start)
                processing <= 1;
        end
        else
        begin
            if (is_bottom_row)
            begin
                // [ -  - ]
                // [ x  x ]
                for (int i = 0; i < NUM_CHANNELS; i++)
                    if (i_features[i] > feature_buf[i][{col_cnt[$clog2(NUM_COLUMNS)-1:1], 1'b0}])
                        feature_buf[i][col_cnt-1] <= i_features[i];
                if (col_cnt[0])
                    nd_out <= 1;
            end
            else
                // [ x  x ]
                // [ -  - ]
                for (int i = 0; i < NUM_CHANNELS; i++)
                    feature_buf[i][col_cnt] <= i_features[i];
            col_cnt <= col_cnt + 1;
            if (col_cnt == NUM_COLUMNS-1)
            begin
                col_cnt <= 'b0;
                row_cnt <= row_cnt + 1;
            end
            for (int i = 0; i < NUM_CHANNELS; i++)
                o_features[i] <= feature_buf[i][col_cnt-1];
        end
    end
    
    assign o_nd = nd_out;
    
endmodule