`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

/*
TODO:
    Place reset in IOB?
    
    overclock DSP48E1, try different clocking techniques
        ([1x, 2x CLKOUT0/CLKOUT1],
        [1x, 2x CLKOUT0 w/ BUFGDIV],
        [1x w/ dual edge triggering],
        [2x w/ MCPs])
    
    change parallel IO to serial IO over SPI interface
    
    Testbenches for conv, pool, post_processing
    
    Takes 27*3=81 clock cycles for FRAM to become full
    MACC enable set after 27*2=54 clock cycles
    For logic simplicity, FRAM should become full before MACC is enabled
    
    For distributed RAM should we aim for sync or async reads?
    
    Study the performance hit when using a fixed addition/subtraction on memory addressing
*/

//////////////////////////////////////////////////////////////////////////////////

module conv_study_top (
    input  logic              top_i_clk,
    input  logic              top_i_rst,
    (* IOB = "TRUE" *)
    input  logic signed [7:0] top_i_feature_in,
    (* IOB = "TRUE" *)
    output logic signed [7:0] top_o_feature_out,
    // LEDs for dev board
    output logic        [1:0] top_o_led,
    output logic              top_o_led_r, top_o_led_g, top_o_led_b
);

    localparam NUM_CONV_FILTERS = 6;
    
    // MMCM
    logic clk50m;
    logic locked;
    
    logic              conv_feature_in_valid;
    logic signed [7:0] conv_feature_in;
    
    logic              conv_receive_feature;
    
    logic              pool_features_in_valid;
    logic signed [7:0] pool_features_in[0:5];
    
    logic              pool_features_out_valid;
    logic signed [7:0] pool_features_out[0:5];
    

    sys_mmcm_12m_to_50m sys_mmcm_inst (.clk(top_i_clk),
                                       .reset(top_i_rst),
                                       .clk50m(clk50m),
                                       .locked(locked));
    
    feature_fwft feature_fwft_inst (.i_clk(clk50m),
                                    .i_rst(top_i_rst),
                                    .i_in_feature(top_i_feature_in),
                                    .i_rd_en(conv_receive_feature),
                                    .o_feature_valid(conv_feature_in_valid),
                                    .o_out_feature(conv_feature_in));

    conv conv_inst (.i_clk(clk50m),
                    .i_rst(top_i_rst),
                    .i_feature_valid(conv_feature_in_valid),
                    .i_feature(conv_feature_in),
                    .o_ready_feature(conv_receive_feature),
                    .o_feature_valid(pool_features_in_valid),
                    .o_features(pool_features_in));
    
    max_pool max_pool_inst (.i_clk(clk50m),
                            .i_rst(top_i_rst),
                            .i_feature_valid(pool_features_in_valid),
                            .i_features(pool_features_in),
                            .o_feature_valid(pool_features_out_valid),
                            .o_features(pool_features_out));
    
    post_processing post_processing_inst (.i_clk(clk50m),
                                          .i_features_valid(pool_features_out_valid),
                                          .i_features_in(pool_features_out),
                                          .o_feature_out(top_o_feature_out));
    
    assign top_o_led   = {1'b0, 1'b0};
    assign top_o_led_r = 0;
    assign top_o_led_g = 1;
    assign top_o_led_b = 0;

endmodule
