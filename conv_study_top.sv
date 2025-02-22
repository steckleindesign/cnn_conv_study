`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

/*
    Study:
        Study bit lopping
        
    TODO:
        MMCM PLL
        Testbenches
        - conv
        - post_processing
        
*/

//////////////////////////////////////////////////////////////////////////////////

module conv_study_top (
    input                clk,
    input                rst,
    input          [7:0] feature_in,
    output signed [15:0] feature_out,
    // LEDs for dev board
    output         [1:0] led,
    output               led_r, led_g, led_b
);

    localparam NUM_CONV_FILTERS = 6;

    logic               conv1_feat_in_valid;
    logic         [7:0] conv1_feature_in;
    logic               receive_feature;
    
    logic               output_features_valid;
    logic signed [15:0] output_features[NUM_CONV_FILTERS];
    logic               last_feature;
        
    feature_fwft feature_fwft_inst (.clk(clk),
                                    .rst(rst),
                                    .in_feature(feature_in),
                                    .rd_en(receive_feature),
                                    .feature_valid(conv1_feat_in_valid),
                                    .out_feature(conv1_feature_in));

    conv conv_inst (.i_clk(clk),
                    .i_rst(rst),
                    .i_feature_valid(conv1_feat_in_valid),
                    .i_feature(conv1_feature_in),
                    .o_feature_valid(output_features_valid),
                    .o_features(output_features),
                    .o_ready_feature(receive_feature),
                    .o_last_feature(last_feature));
    
    post_processing post_processing_inst (.clk(clk),
                                          .features_valid(output_features_valid),
                                          .features_in(output_features),
                                          .feature_out(feature_out));
    
    assign led   = {rst, last_feature};
    assign led_r = rst;
    assign led_g = last_feature;
    assign led_b = ~last_feature;

endmodule
