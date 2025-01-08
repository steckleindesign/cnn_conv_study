`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////


//////////////////////////////////////////////////////////////////////////////////

module feature_map_stream #(
    parameter FEATURE_WIDTH = 16,
    parameter FEATURE_DEPTH = 6
)(
    input clk,
    input features_valid,
    input  logic signed [FEATURE_WIDTH-1:0] features_in[FEATURE_DEPTH-1:0],
    output logic signed [FEATURE_WIDTH-1:0] features_out[FEATURE_DEPTH-1:0]
);

    always_ff @(posedge clk)
        if (features_valid)
            features_out <= features_in;

endmodule
