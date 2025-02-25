`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////


//////////////////////////////////////////////////////////////////////////////////

module conv_tb();

    // localparam NUM_FEATURE_MAPS = 6;
    integer seed;
    
    // Inputs
    logic               clk;
    logic               rst;
    logic               valid_in;
    logic         [7:0] feature_in;
    // Outputs
    logic               pull_in_feature;
    logic               valid_out;
    logic signed [15:0] features_out[0:5];
    logic               last_feature;
    
    // Debug
    logic [10:0] conv_col;
    logic [10:0] conv_row;
    logic  [2:0] state;
    logic        macc_en;
    
    conv DUT (.i_clk(clk),
              .i_rst(rst),
              .i_feature_valid(valid_in),
              .i_feature(feature_in),
              .o_feature_valid(valid_out),
              .o_features(features_out),
              .o_ready_feature(pull_in_feature),
              .o_last_feature(last_feature),
              // Debug
              .debug_conv_col(conv_col),
              .debug_conv_row(conv_row),
              .debug_state(state),
              .debug_macc_en(macc_en));
    
    // Clocking
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // Reset
    initial begin
        rst = 1;
        #20
        rst = 0;
    end
    
    // Feature stimulus
    // for the first feature stimulus set valid high
    initial begin
        valid_in   = 0;
        feature_in = 0;
        #20
        valid_in   = 1;
        feature_in = 40;
        #1000
        feature_in = 41;
    end
    
    initial begin
        seed = 1234;
        forever begin
            @(posedge clk);
            feature_in = $random(seed) & 8'hFF;
        end
    end

endmodule
