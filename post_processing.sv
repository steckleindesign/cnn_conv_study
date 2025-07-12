`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

// Take features from pool layer, and process down so we can fit on pins

//////////////////////////////////////////////////////////////////////////////////

module post_processing (
    input  logic              i_clk,
    input  logic              i_features_valid,
    input  logic signed [7:0] i_features_in[0:5],
    output logic signed [7:0] o_feature_out
);
    
    // Post processing stages
    logic signed [7:0] stage0[0:5];
    logic signed [7:0] stage1[0:2];
    logic signed [7:0] stage2[0:1];
    logic signed [7:0] processed_feature;
    
    always_ff @(posedge i_clk)
    begin
        if (i_features_valid)
            stage0 <= i_features_in;
        
        for (int i = 0; i < 3; i++)
            stage1[i] <= stage0[i*2] + stage0[i*2+1];
        
        stage2[1] <= stage1[2];
        stage2[0] <= stage1[1] - stage1[0];
        
        processed_feature <= stage2[1] + stage2[0];
    end
    
    assign o_feature_out = processed_feature;
    
endmodule
