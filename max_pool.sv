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
    input  logic signed [DATA_WIDTH-1:0] i_features,
    output logic signed [DATA_WIDTH-1:0] o_features
);
    
    logic [DATA_WIDTH-1:0] feature_buf[0:NUM_COLUMNS-1];
    logic [$clog2(NUM_COLUMNS)-1:0] col_cnt;
    logic [$clog2(NUM_OUT_ROWS)-1:0] row_cnt;
    logic is_bottom_row;
    logic processing;
    
    always_ff @(posedge i_clk)
    begin
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
                if (col_cnt[0])
                begin
                    //    [ -  - ]
                    //    [ -  x ]
                    if (i_features > feature_buf[col_cnt-1])
                        feature_buf[col_cnt-1] <= i_features;
                end
                else
                begin
                    //    [ -  - ]
                    //    [ x  - ]
                    if (i_features > feature_buf[col_cnt])
                        feature_buf[col_cnt] <= i_features;
                end
            end
            else
            begin
                if (col_cnt[0])
                begin
                    //    [ -  x ]
                    //    [ -  - ]
                    feature_buf[col_cnt] <= i_features;
                end
                else
                begin
                    //    [ x  - ]
                    //    [ -  - ]
                    feature_buf[col_cnt] <= i_features;
                end
            end
            col_cnt <= col_cnt + 1'b1;
            if (col_cnt == NUM_COLUMNS-1)
            begin
                col_cnt <= 'b0;
                row_cnt <= row_cnt + 1'b1;
            end
            o_features <= feature_buf[col_cnt-1];
        end
    end
    
endmodule