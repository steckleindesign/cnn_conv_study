`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////////

module post_processing #(
    localparam FEATURE_WIDTH  = 16,
    localparam FEATURES_DEPTH = 6
)(
    input  logic clk,
    input  logic features_valid,
    // Take features from conv layer, and process down so we can fit on pins
    input  logic signed [FEATURE_WIDTH-1:0] features_in[0:FEATURES_DEPTH-1],
    output logic signed [FEATURE_WIDTH-1:0] feature_out
);
    
    // Post processing stages
    logic signed [FEATURE_WIDTH-1:0] stage0 [0:FEATURES_DEPTH-1];     // 6 features
    logic signed [FEATURE_WIDTH-1:0] stage1 [0:FEATURES_DEPTH/2-1];   // 3 features
    logic signed [FEATURE_WIDTH-1:0] stage2 [0:1];      // 2 features
    logic signed [FEATURE_WIDTH-1:0] processed_feature; // Final processed feature
    
    always_ff @(posedge clk)
    begin
        if (features_valid)
            stage0 <= features_in;
        
        for (int i = 0; i < FEATURES_DEPTH/2; i++)
            stage1[i] <= stage0[i*2] + stage0[i*2+1];
        
        stage2[1] <= stage1[2];
        stage2[0] <= stage1[1] - stage1[0];
        
        processed_feature <= stage2[1] + stage2[0];
    end
    
    assign feature_out = processed_feature;
    
endmodule
