`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

/*
    Study:
        Study bit lopping
        
    TODO:
        Testbenches
        - feature_buf
        - conv
        - post_processing
        
*/

//////////////////////////////////////////////////////////////////////////////////

localparam CONV_FILTERS = 6;

module conv_study_top (
    input                clk,
    input                rst,
    input          [7:0] feature_in,
    output signed [15:0] feature_out,
    
    output [1:0] led,
    output led_r, led_g, led_b
);

    logic               line_buf_full;
    logic               conv1_feat_in_valid;
    logic         [7:0] conv1_feature_in;
    
    logic               output_features_valid;
    logic signed [15:0] output_features[CONV_FILTERS];
    
    // logic        [15:0] feature_stream_out[CONV_FILTERS-1];
    
    feature_fwft feature_fwft_inst (.clk(clk),
                                    .rst(rst),
                                    .feature_in(feature_in),
                                    .rd_en(line_buf_full),
                                    .feature_valid(conv1_feat_in_valid),
                                    .feature_out(conv1_feature_in));

    conv #(.NUM_FILTERS(CONV_FILTERS))
            conv_inst (.i_clk(clk),
                       .i_rst(rst),
                       .i_feature_valid(conv1_feat_in_valid),
                       .i_feature(conv1_feature_in),
                       .o_feature_valid(output_features_valid),
                       .o_features(output_features),
                       .o_buffer_full(line_buf_full));
    
    post_processing #(.FEATURE_WIDTH(16),
                      .FEATURES_DEPTH(CONV_FILTERS))
                       post_processing_inst (.clk(clk),
                                             .features_valid(output_features_valid),
                                             .features_in(output_features),
                                             .feature_out(feature_out));
    
    assign led = 2'b11;
    assign led_r = 1;
    assign led_g = 0;
    assign led_b = 0;

endmodule
