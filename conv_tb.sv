`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////


//////////////////////////////////////////////////////////////////////////////////

module conv_tb();

    // localparam NUM_FEATURE_MAPS = 6;
    localparam CLK_PERIOD = 5;
    
    // integer seed;
    
    // Inputs
    logic               clk;
    logic               rst;
    logic               valid_in;
    logic         [7:0] feature_in;
    
    // Outputs
    logic               valid_out;
    logic signed  [7:0] features_out[0:5];
    logic               ready_feature;
    
    // Debug
    logic [2:0] tb_debug_state;
    logic       tb_debug_feature_consumption_during_processing;
    logic       tb_debug_take_feature;
    logic       tb_debug_fram_has_been_full;
    logic       tb_debug_macc_en;
    logic [4:0] tb_debug_fram_row_ctr;
    logic [4:0] tb_debug_fram_col_ctr;
    logic [4:0] tb_debug_conv_row_ctr;
    logic [4:0] tb_debug_conv_col_ctr;
    
    
    conv
        UUT (.i_clk(clk),
             .i_rst(rst),
             .i_feature_valid(valid_in),
             .i_feature(feature_in),
             .o_feature_valid(valid_out),
             .o_features(features_out),
             .o_ready_feature(ready_feature),
             // Debug
             .debug_state(tb_debug_state),
             .debug_feature_consumption_during_processing(tb_debug_feature_consumption_during_processing),
             .debug_take_feature(tb_debug_take_feature),
             .debug_fram_has_been_full(tb_debug_fram_has_been_full),
             .debug_macc_en(tb_debug_macc_en),
             .debug_fram_row_ctr(tb_debug_fram_row_ctr),
             .debug_fram_col_ctr(tb_debug_fram_col_ctr),
             .debug_conv_row_ctr(tb_debug_conv_row_ctr),                          
             .debug_conv_col_ctr(tb_debug_conv_col_ctr));
    
    // Clocking
    initial begin
        clk = 0;
        forever #(CLK_PERIOD) clk = ~clk;
    end
    
    // Reset
    initial begin
        rst = 1;
        #20;
        rst = 0;
    end
    
    // Feature stimulus
    // for the first feature stimulus set valid high
    initial begin
        valid_in   = 0;
        feature_in = 0;
        #20;
        valid_in   = 1;
        feature_in = 14;
        #5000;
    end
    
//    initial begin
//        seed = 1234;
//        forever begin
//            @(posedge clk);
//            feature_in = $random(seed) & 8'hFF;
//        end
//    end

endmodule
