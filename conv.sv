`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
/*

    Study: Get outputs of DSP48s to carry chain resources efficiently
           Get feature and weight operands to DSPs efficiently
           Why is the DSP48E1 connectivity so unclean, all A pins connected to same LUT O6?

    Latency due to Design
        6 filters for conv1, 5x5 filter, 28x28 feature map
        = 6*(5*5)*(28*28) = 117600 multiplies / 90 DSPs = 1307 cycles
        
    State:         0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14
    
    Valid:         0,  0,  0,  0,  0,  0,  1,  1,  0,  1,  0,  1,  1,  0,  1
    
    adder 1-1:    15, 18,  9,  5,  3,  2,  1
    adder 2-1:         5, 18, 14,  7,  4,  2,  1
    adder 3-1:                10, 20, 10,  5,  3,  2,  1
    
    adder 1-2:                        15, 18,  9,  5,  3,  2,  1
    adder 2-2:                             5, 18, 14,  7,  4,  2,  1
    adder 3-2:                                    10, 20, 10,  5,  3,  2,  1
    
    feature_window, next_initial_feature_window, feature_distributed_ram, fram_swap_regs
    
    feature_window is 5x5
    feature_window is the data which feeds feature_operands,
    feature_window gets set with next_initial_feature_window,
        and then feature_rams_data is shifted into the
        right-most column throughout the feature row
    
    next_initial_feature_window is 5x5
    next_initial_feature_window is set with input features at the start,
        then throughout the convolutions gets shifted down, input features
        are shifted into the bottom row of next_initial_feature_window
    
    feature_distributed_ram
    feature_rams is 32x5
    feature_rams first two and last two columns are zero-padded, so non-zero
        data dimensions is 28x5, first two and last two feature map rows are zeros
    feature_rams is the data which feeds feature_window by shifting in data in each 5 rows
    feature_rams data is written directly by input features
    feature_rams data is shifted down via swap register logic
    
    
    DSP can perform 2 multiplies at once because we can fit multiple 8-bit operands on each input
    DSP input data muxes can be simpler if we utilize the 3 data bytes wide A input for features
    
    // Utilization
    // Weight ROMs
    // 90 distributed RAMs -> 1 per DSP48E1
    // 8-bit signed data x 6 filters x 5 rows x 3 columns x 5 deep
    // Overall there is 90x5 = 90 8x8-bit Distributed RAMs
    // One SLICEM can implement 4 8x8-bit Distruibuted RAMs
    // Hence, 23 slices (12 CLBs) will be used for the weight RAMs
    // Note - maybe no ROMs necessary, LUTs will be used instead
    
*/
//////////////////////////////////////////////////////////////////////////////////

module conv (
    input  logic              i_clk,
    input  logic              i_rst,
    
    input  logic              i_feature_valid,
    input  logic        [7:0] i_feature,
    
    output logic              o_feature_valid,
    output logic signed [7:0] o_features[0:5],
    
    output logic              o_ready_feature
);

    // Hardcode frame dimensions in local params
    localparam string WEIGHTS_FILE     = "weights.mem";
    localparam string BIASES_FILE      = "biases.mem";
    localparam        NUM_DSP48E1      = 90;
    localparam        NUM_FILTERS      = 6;
    localparam        FILTER_SIZE      = 5;
    localparam        WEIGHT_ROM_DEPTH = 5;
    localparam        DSP_PER_CH       = NUM_DSP48E1 / NUM_FILTERS;
    localparam        OFFSET_GRP_SZ    = DSP_PER_CH / FILTER_SIZE;
    localparam        INPUT_WIDTH      = 32;
    localparam        INPUT_HEIGHT     = 32;
    localparam        ROW_START        = 2;
    localparam        ROW_END          = 29;
    localparam        COL_START        = 2;
    localparam        COL_END          = 29;
    
    // Initialize trainable parameters
    (* rom_style = "distributed" *)
    logic signed [7:0] weights[0:NUM_FILTERS-1]       // 6
                              [0:FILTER_SIZE-1]       // 5
                              [0:OFFSET_GRP_SZ-1]     // 3
                              [0:WEIGHT_ROM_DEPTH-1]; // 5
    // integer raw_idx;
    initial begin
    //     $readmemb(WEIGHTS_FILE, raw_weights);
    //     raw_idx = 0;
    //     for (int i = 0; i < NUM_FILTERS; i++)
    //         for (int j = 0; j < FILTER_SIZE; j++)
    //             for (int k = 0; k < OFFSET_GRP_SZ; k++)
    //                 for (int l = 0; l < WEIGHT_ROM_DEPTH; l++) begin
    //                     weights[i][j][k][l] = raw_weights[raw_idx];
    //                     raw_idx = raw_idx + 1;
    //                 end
    // end
        // Not many weights/operands found in netlist,
        // something must be getting optimized out,
        // or the weights are simple enough that
        // LUTs can supply weight operands, hence
        // there is no need for weight distributed ROMs
        weights[0][0][0][0] = 8'b01111011;
        weights[0][0][0][1] = 8'b11010111;
        weights[0][0][0][2] = 8'b11100000;
        weights[0][0][0][3] = 8'b10101100;
        weights[0][0][0][4] = 8'b00101111;
        weights[0][0][1][0] = 8'b01011111;
        weights[0][0][1][1] = 8'b00011111;
        weights[0][0][1][2] = 8'b10001001;
        weights[0][0][1][3] = 8'b10111001;
        weights[0][0][1][4] = 8'b01100111;
        weights[0][0][2][0] = 8'b10111000;
        weights[0][0][2][1] = 8'b10001001;
        weights[0][0][2][2] = 8'b01110011;
        weights[0][0][2][3] = 8'b11111000;
        weights[0][0][2][4] = 8'b10110010;
        weights[0][1][0][0] = 8'b11101010;
        weights[0][1][0][1] = 8'b01101111;
        weights[0][1][0][2] = 8'b11000100;
        weights[0][1][0][3] = 8'b10010010;
        weights[0][1][0][4] = 8'b10001101;
        weights[0][1][1][0] = 8'b00000001;
        weights[0][1][1][1] = 8'b00010101;
        weights[0][1][1][2] = 8'b01000101;
        weights[0][1][1][3] = 8'b11101001;
        weights[0][1][1][4] = 8'b11000101;
        weights[0][1][2][0] = 8'b00110101;
        weights[0][1][2][1] = 8'b10100000;
        weights[0][1][2][2] = 8'b10010011;
        weights[0][1][2][3] = 8'b00101000;
        weights[0][1][2][4] = 8'b00001110;
        weights[0][2][0][0] = 8'b01101011;
        weights[0][2][0][1] = 8'b00001000;
        weights[0][2][0][2] = 8'b01101000;
        weights[0][2][0][3] = 8'b00010001;
        weights[0][2][0][4] = 8'b00010001;
        weights[0][2][1][0] = 8'b10111000;
        weights[0][2][1][1] = 8'b00111110;
        weights[0][2][1][2] = 8'b10000100;
        weights[0][2][1][3] = 8'b11000100;
        weights[0][2][1][4] = 8'b01100101;
        weights[0][2][2][0] = 8'b00100101;
        weights[0][2][2][1] = 8'b10100111;
        weights[0][2][2][2] = 8'b00111111;
        weights[0][2][2][3] = 8'b11110001;
        weights[0][2][2][4] = 8'b10110001;
        weights[0][3][0][0] = 8'b11001011;
        weights[0][3][0][1] = 8'b10001001;
        weights[0][3][0][2] = 8'b01011010;
        weights[0][3][0][3] = 8'b11101000;
        weights[0][3][0][4] = 8'b00110000;
        weights[0][3][1][0] = 8'b10100000;
        weights[0][3][1][1] = 8'b10110010;
        weights[0][3][1][2] = 8'b11010110;
        weights[0][3][1][3] = 8'b00110001;
        weights[0][3][1][4] = 8'b11011110;
        weights[0][3][2][0] = 8'b10010100;
        weights[0][3][2][1] = 8'b10110001;
        weights[0][3][2][2] = 8'b11111100;
        weights[0][3][2][3] = 8'b11001101;
        weights[0][3][2][4] = 8'b10111001;
        weights[0][4][0][0] = 8'b00011110;
        weights[0][4][0][1] = 8'b00011011;
        weights[0][4][0][2] = 8'b10111010;
        weights[0][4][0][3] = 8'b00010011;
        weights[0][4][0][4] = 8'b00111011;
        weights[0][4][1][0] = 8'b11000010;
        weights[0][4][1][1] = 8'b11100100;
        weights[0][4][1][2] = 8'b00100000;
        weights[0][4][1][3] = 8'b01010101;
        weights[0][4][1][4] = 8'b11000011;
        weights[0][4][2][0] = 8'b10100001;
        weights[0][4][2][1] = 8'b00011111;
        weights[0][4][2][2] = 8'b11000101;
        weights[0][4][2][3] = 8'b00001011;
        weights[0][4][2][4] = 8'b01110111;
        weights[1][0][0][0] = 8'b00111111;
        weights[1][0][0][1] = 8'b00010001;
        weights[1][0][0][2] = 8'b00101011;
        weights[1][0][0][3] = 8'b11101111;
        weights[1][0][0][4] = 8'b11001010;
        weights[1][0][1][0] = 8'b11111011;
        weights[1][0][1][1] = 8'b11000100;
        weights[1][0][1][2] = 8'b11110000;
        weights[1][0][1][3] = 8'b01111000;
        weights[1][0][1][4] = 8'b10101101;
        weights[1][0][2][0] = 8'b00110101;
        weights[1][0][2][1] = 8'b00111111;
        weights[1][0][2][2] = 8'b01010101;
        weights[1][0][2][3] = 8'b00010101;
        weights[1][0][2][4] = 8'b11111100;
        weights[1][1][0][0] = 8'b11101011;
        weights[1][1][0][1] = 8'b01101001;
        weights[1][1][0][2] = 8'b00010101;
        weights[1][1][0][3] = 8'b10100111;
        weights[1][1][0][4] = 8'b01101100;
        weights[1][1][1][0] = 8'b11100000;
        weights[1][1][1][1] = 8'b00001110;
        weights[1][1][1][2] = 8'b10001000;
        weights[1][1][1][3] = 8'b00011100;
        weights[1][1][1][4] = 8'b01011011;
        weights[1][1][2][0] = 8'b10110011;
        weights[1][1][2][1] = 8'b11000010;
        weights[1][1][2][2] = 8'b10100100;
        weights[1][1][2][3] = 8'b01011001;
        weights[1][1][2][4] = 8'b01110011;
        weights[1][2][0][0] = 8'b01010111;
        weights[1][2][0][1] = 8'b10001011;
        weights[1][2][0][2] = 8'b01000001;
        weights[1][2][0][3] = 8'b00010100;
        weights[1][2][0][4] = 8'b10100101;
        weights[1][2][1][0] = 8'b00000001;
        weights[1][2][1][1] = 8'b11011011;
        weights[1][2][1][2] = 8'b11011011;
        weights[1][2][1][3] = 8'b10000111;
        weights[1][2][1][4] = 8'b11110010;
        weights[1][2][2][0] = 8'b01110001;
        weights[1][2][2][1] = 8'b01000111;
        weights[1][2][2][2] = 8'b01010111;
        weights[1][2][2][3] = 8'b11001001;
        weights[1][2][2][4] = 8'b01000101;
        weights[1][3][0][0] = 8'b01100110;
        weights[1][3][0][1] = 8'b11110000;
        weights[1][3][0][2] = 8'b01101110;
        weights[1][3][0][3] = 8'b00110000;
        weights[1][3][0][4] = 8'b10110110;
        weights[1][3][1][0] = 8'b10010000;
        weights[1][3][1][1] = 8'b10110000;
        weights[1][3][1][2] = 8'b11110010;
        weights[1][3][1][3] = 8'b01110100;
        weights[1][3][1][4] = 8'b01000011;
        weights[1][3][2][0] = 8'b10011001;
        weights[1][3][2][1] = 8'b01001000;
        weights[1][3][2][2] = 8'b01110000;
        weights[1][3][2][3] = 8'b11010100;
        weights[1][3][2][4] = 8'b11111001;
        weights[1][4][0][0] = 8'b00011010;
        weights[1][4][0][1] = 8'b00001001;
        weights[1][4][0][2] = 8'b01100011;
        weights[1][4][0][3] = 8'b10001001;
        weights[1][4][0][4] = 8'b00100000;
        weights[1][4][1][0] = 8'b00010000;
        weights[1][4][1][1] = 8'b11001010;
        weights[1][4][1][2] = 8'b01111010;
        weights[1][4][1][3] = 8'b01100101;
        weights[1][4][1][4] = 8'b00010100;
        weights[1][4][2][0] = 8'b00100111;
        weights[1][4][2][1] = 8'b00100101;
        weights[1][4][2][2] = 8'b11100011;
        weights[1][4][2][3] = 8'b01011001;
        weights[1][4][2][4] = 8'b10000110;
        weights[2][0][0][0] = 8'b00101111;
        weights[2][0][0][1] = 8'b00101110;
        weights[2][0][0][2] = 8'b01101000;
        weights[2][0][0][3] = 8'b00111110;
        weights[2][0][0][4] = 8'b10000000;
        weights[2][0][1][0] = 8'b10101110;
        weights[2][0][1][1] = 8'b11011100;
        weights[2][0][1][2] = 8'b11001010;
        weights[2][0][1][3] = 8'b11100000;
        weights[2][0][1][4] = 8'b00011111;
        weights[2][0][2][0] = 8'b01000001;
        weights[2][0][2][1] = 8'b10100111;
        weights[2][0][2][2] = 8'b11001101;
        weights[2][0][2][3] = 8'b01011001;
        weights[2][0][2][4] = 8'b10110010;
        weights[2][1][0][0] = 8'b01001001;
        weights[2][1][0][1] = 8'b01101110;
        weights[2][1][0][2] = 8'b10000010;
        weights[2][1][0][3] = 8'b01000000;
        weights[2][1][0][4] = 8'b10111011;
        weights[2][1][1][0] = 8'b01010100;
        weights[2][1][1][1] = 8'b10001000;
        weights[2][1][1][2] = 8'b10001011;
        weights[2][1][1][3] = 8'b00011111;
        weights[2][1][1][4] = 8'b00001111;
        weights[2][1][2][0] = 8'b10100011;
        weights[2][1][2][1] = 8'b00000101;
        weights[2][1][2][2] = 8'b10111001;
        weights[2][1][2][3] = 8'b11000011;
        weights[2][1][2][4] = 8'b10011000;
        weights[2][2][0][0] = 8'b01011100;
        weights[2][2][0][1] = 8'b11010010;
        weights[2][2][0][2] = 8'b00101011;
        weights[2][2][0][3] = 8'b10000011;
        weights[2][2][0][4] = 8'b00010000;
        weights[2][2][1][0] = 8'b01100110;
        weights[2][2][1][1] = 8'b01011100;
        weights[2][2][1][2] = 8'b01000101;
        weights[2][2][1][3] = 8'b10011010;
        weights[2][2][1][4] = 8'b11001110;
        weights[2][2][2][0] = 8'b11101100;
        weights[2][2][2][1] = 8'b11101010;
        weights[2][2][2][2] = 8'b01101010;
        weights[2][2][2][3] = 8'b11011111;
        weights[2][2][2][4] = 8'b11010111;
        weights[2][3][0][0] = 8'b00010000;
        weights[2][3][0][1] = 8'b01101001;
        weights[2][3][0][2] = 8'b10110110;
        weights[2][3][0][3] = 8'b10111100;
        weights[2][3][0][4] = 8'b10010000;
        weights[2][3][1][0] = 8'b10000001;
        weights[2][3][1][1] = 8'b11111111;
        weights[2][3][1][2] = 8'b00000011;
        weights[2][3][1][3] = 8'b01000101;
        weights[2][3][1][4] = 8'b01101010;
        weights[2][3][2][0] = 8'b10000110;
        weights[2][3][2][1] = 8'b00101110;
        weights[2][3][2][2] = 8'b11010111;
        weights[2][3][2][3] = 8'b11001100;
        weights[2][3][2][4] = 8'b00110010;
        weights[2][4][0][0] = 8'b10010000;
        weights[2][4][0][1] = 8'b00001011;
        weights[2][4][0][2] = 8'b11111000;
        weights[2][4][0][3] = 8'b00110010;
        weights[2][4][0][4] = 8'b00111110;
        weights[2][4][1][0] = 8'b00000101;
        weights[2][4][1][1] = 8'b01100000;
        weights[2][4][1][2] = 8'b11110100;
        weights[2][4][1][3] = 8'b10001100;
        weights[2][4][1][4] = 8'b01101100;
        weights[2][4][2][0] = 8'b01111101;
        weights[2][4][2][1] = 8'b11010001;
        weights[2][4][2][2] = 8'b11011111;
        weights[2][4][2][3] = 8'b01001000;
        weights[2][4][2][4] = 8'b11101101;
        weights[3][0][0][0] = 8'b11001110;
        weights[3][0][0][1] = 8'b00110001;
        weights[3][0][0][2] = 8'b11111100;
        weights[3][0][0][3] = 8'b00011111;
        weights[3][0][0][4] = 8'b10100010;
        weights[3][0][1][0] = 8'b10110111;
        weights[3][0][1][1] = 8'b11100111;
        weights[3][0][1][2] = 8'b11101000;
        weights[3][0][1][3] = 8'b00011000;
        weights[3][0][1][4] = 8'b00110100;
        weights[3][0][2][0] = 8'b10001100;
        weights[3][0][2][1] = 8'b10001101;
        weights[3][0][2][2] = 8'b00010011;
        weights[3][0][2][3] = 8'b11100111;
        weights[3][0][2][4] = 8'b00110011;
        weights[3][1][0][0] = 8'b10000100;
        weights[3][1][0][1] = 8'b01010011;
        weights[3][1][0][2] = 8'b11110010;
        weights[3][1][0][3] = 8'b11001101;
        weights[3][1][0][4] = 8'b11101100;
        weights[3][1][1][0] = 8'b01111010;
        weights[3][1][1][1] = 8'b11100100;
        weights[3][1][1][2] = 8'b01100100;
        weights[3][1][1][3] = 8'b01011011;
        weights[3][1][1][4] = 8'b10110101;
        weights[3][1][2][0] = 8'b10010111;
        weights[3][1][2][1] = 8'b01000000;
        weights[3][1][2][2] = 8'b10001100;
        weights[3][1][2][3] = 8'b10111010;
        weights[3][1][2][4] = 8'b01000100;
        weights[3][2][0][0] = 8'b11101101;
        weights[3][2][0][1] = 8'b00001001;
        weights[3][2][0][2] = 8'b01000100;
        weights[3][2][0][3] = 8'b10110111;
        weights[3][2][0][4] = 8'b01100010;
        weights[3][2][1][0] = 8'b10100101;
        weights[3][2][1][1] = 8'b00111100;
        weights[3][2][1][2] = 8'b00101011;
        weights[3][2][1][3] = 8'b10010110;
        weights[3][2][1][4] = 8'b00001111;
        weights[3][2][2][0] = 8'b11101000;
        weights[3][2][2][1] = 8'b00011010;
        weights[3][2][2][2] = 8'b10111000;
        weights[3][2][2][3] = 8'b01001010;
        weights[3][2][2][4] = 8'b10000011;
        weights[3][3][0][0] = 8'b10110110;
        weights[3][3][0][1] = 8'b00100000;
        weights[3][3][0][2] = 8'b10110101;
        weights[3][3][0][3] = 8'b11010101;
        weights[3][3][0][4] = 8'b01010001;
        weights[3][3][1][0] = 8'b00110110;
        weights[3][3][1][1] = 8'b01000110;
        weights[3][3][1][2] = 8'b00001000;
        weights[3][3][1][3] = 8'b00111101;
        weights[3][3][1][4] = 8'b11001100;
        weights[3][3][2][0] = 8'b10101000;
        weights[3][3][2][1] = 8'b01111001;
        weights[3][3][2][2] = 8'b00000010;
        weights[3][3][2][3] = 8'b00101110;
        weights[3][3][2][4] = 8'b00011011;
        weights[3][4][0][0] = 8'b00001010;
        weights[3][4][0][1] = 8'b00010101;
        weights[3][4][0][2] = 8'b01001111;
        weights[3][4][0][3] = 8'b01111111;
        weights[3][4][0][4] = 8'b10011000;
        weights[3][4][1][0] = 8'b11000101;
        weights[3][4][1][1] = 8'b10101101;
        weights[3][4][1][2] = 8'b01101110;
        weights[3][4][1][3] = 8'b00111010;
        weights[3][4][1][4] = 8'b00101011;
        weights[3][4][2][0] = 8'b00100110;
        weights[3][4][2][1] = 8'b01000101;
        weights[3][4][2][2] = 8'b01001001;
        weights[3][4][2][3] = 8'b00111100;
        weights[3][4][2][4] = 8'b00100101;
        weights[4][0][0][0] = 8'b11001101;
        weights[4][0][0][1] = 8'b10010000;
        weights[4][0][0][2] = 8'b11101101;
        weights[4][0][0][3] = 8'b00010011;
        weights[4][0][0][4] = 8'b01011100;
        weights[4][0][1][0] = 8'b00100110;
        weights[4][0][1][1] = 8'b10010011;
        weights[4][0][1][2] = 8'b01001111;
        weights[4][0][1][3] = 8'b11111001;
        weights[4][0][1][4] = 8'b00100101;
        weights[4][0][2][0] = 8'b01000000;
        weights[4][0][2][1] = 8'b10010011;
        weights[4][0][2][2] = 8'b00111101;
        weights[4][0][2][3] = 8'b10100101;
        weights[4][0][2][4] = 8'b00101000;
        weights[4][1][0][0] = 8'b00010111;
        weights[4][1][0][1] = 8'b11100110;
        weights[4][1][0][2] = 8'b00011100;
        weights[4][1][0][3] = 8'b10010101;
        weights[4][1][0][4] = 8'b10100010;
        weights[4][1][1][0] = 8'b00001110;
        weights[4][1][1][1] = 8'b10101101;
        weights[4][1][1][2] = 8'b01100001;
        weights[4][1][1][3] = 8'b10110011;
        weights[4][1][1][4] = 8'b01011010;
        weights[4][1][2][0] = 8'b10011100;
        weights[4][1][2][1] = 8'b11000010;
        weights[4][1][2][2] = 8'b01000010;
        weights[4][1][2][3] = 8'b01110010;
        weights[4][1][2][4] = 8'b01101010;
        weights[4][2][0][0] = 8'b00110100;
        weights[4][2][0][1] = 8'b01101011;
        weights[4][2][0][2] = 8'b01110110;
        weights[4][2][0][3] = 8'b11101101;
        weights[4][2][0][4] = 8'b00001010;
        weights[4][2][1][0] = 8'b11001110;
        weights[4][2][1][1] = 8'b00101110;
        weights[4][2][1][2] = 8'b10110100;
        weights[4][2][1][3] = 8'b10101110;
        weights[4][2][1][4] = 8'b00111011;
        weights[4][2][2][0] = 8'b10010011;
        weights[4][2][2][1] = 8'b11111100;
        weights[4][2][2][2] = 8'b00111000;
        weights[4][2][2][3] = 8'b00100001;
        weights[4][2][2][4] = 8'b01001110;
        weights[4][3][0][0] = 8'b11011011;
        weights[4][3][0][1] = 8'b01010011;
        weights[4][3][0][2] = 8'b01101111;
        weights[4][3][0][3] = 8'b11001011;
        weights[4][3][0][4] = 8'b10010111;
        weights[4][3][1][0] = 8'b11010101;
        weights[4][3][1][1] = 8'b10010000;
        weights[4][3][1][2] = 8'b11010011;
        weights[4][3][1][3] = 8'b00001101;
        weights[4][3][1][4] = 8'b00011001;
        weights[4][3][2][0] = 8'b10000001;
        weights[4][3][2][1] = 8'b11110101;
        weights[4][3][2][2] = 8'b10011101;
        weights[4][3][2][3] = 8'b10110100;
        weights[4][3][2][4] = 8'b10100001;
        weights[4][4][0][0] = 8'b11000001;
        weights[4][4][0][1] = 8'b01110001;
        weights[4][4][0][2] = 8'b10111110;
        weights[4][4][0][3] = 8'b01000011;
        weights[4][4][0][4] = 8'b10000011;
        weights[4][4][1][0] = 8'b10010000;
        weights[4][4][1][1] = 8'b11110001;
        weights[4][4][1][2] = 8'b01011101;
        weights[4][4][1][3] = 8'b01011011;
        weights[4][4][1][4] = 8'b10101010;
        weights[4][4][2][0] = 8'b10001010;
        weights[4][4][2][1] = 8'b01100111;
        weights[4][4][2][2] = 8'b11101110;
        weights[4][4][2][3] = 8'b00101011;
        weights[4][4][2][4] = 8'b10111100;
        weights[5][0][0][0] = 8'b00000100;
        weights[5][0][0][1] = 8'b10111001;
        weights[5][0][0][2] = 8'b11110111;
        weights[5][0][0][3] = 8'b01111111;
        weights[5][0][0][4] = 8'b00010111;
        weights[5][0][1][0] = 8'b10110101;
        weights[5][0][1][1] = 8'b11101111;
        weights[5][0][1][2] = 8'b00111010;
        weights[5][0][1][3] = 8'b11010001;
        weights[5][0][1][4] = 8'b11001101;
        weights[5][0][2][0] = 8'b10000011;
        weights[5][0][2][1] = 8'b10100110;
        weights[5][0][2][2] = 8'b01001101;
        weights[5][0][2][3] = 8'b10111111;
        weights[5][0][2][4] = 8'b01000111;
        weights[5][1][0][0] = 8'b00010100;
        weights[5][1][0][1] = 8'b11000001;
        weights[5][1][0][2] = 8'b10001010;
        weights[5][1][0][3] = 8'b01001110;
        weights[5][1][0][4] = 8'b10011011;
        weights[5][1][1][0] = 8'b11101111;
        weights[5][1][1][1] = 8'b10010001;
        weights[5][1][1][2] = 8'b01101101;
        weights[5][1][1][3] = 8'b00100000;
        weights[5][1][1][4] = 8'b01011111;
        weights[5][1][2][0] = 8'b00101000;
        weights[5][1][2][1] = 8'b10110010;
        weights[5][1][2][2] = 8'b00100111;
        weights[5][1][2][3] = 8'b01101111;
        weights[5][1][2][4] = 8'b01010011;
        weights[5][2][0][0] = 8'b01001000;
        weights[5][2][0][1] = 8'b00010000;
        weights[5][2][0][2] = 8'b11001000;
        weights[5][2][0][3] = 8'b01011100;
        weights[5][2][0][4] = 8'b10000101;
        weights[5][2][1][0] = 8'b00010010;
        weights[5][2][1][1] = 8'b11100010;
        weights[5][2][1][2] = 8'b11010011;
        weights[5][2][1][3] = 8'b10110100;
        weights[5][2][1][4] = 8'b00010110;
        weights[5][2][2][0] = 8'b10011111;
        weights[5][2][2][1] = 8'b11011011;
        weights[5][2][2][2] = 8'b11100010;
        weights[5][2][2][3] = 8'b00011100;
        weights[5][2][2][4] = 8'b11010100;
        weights[5][3][0][0] = 8'b10011000;
        weights[5][3][0][1] = 8'b10100000;
        weights[5][3][0][2] = 8'b01110100;
        weights[5][3][0][3] = 8'b01011110;
        weights[5][3][0][4] = 8'b11101001;
        weights[5][3][1][0] = 8'b00011111;
        weights[5][3][1][1] = 8'b00001101;
        weights[5][3][1][2] = 8'b10000110;
        weights[5][3][1][3] = 8'b11110001;
        weights[5][3][1][4] = 8'b10010000;
        weights[5][3][2][0] = 8'b01011101;
        weights[5][3][2][1] = 8'b11010100;
        weights[5][3][2][2] = 8'b10010111;
        weights[5][3][2][3] = 8'b10101011;
        weights[5][3][2][4] = 8'b11010110;
        weights[5][4][0][0] = 8'b00011001;
        weights[5][4][0][1] = 8'b11100000;
        weights[5][4][0][2] = 8'b10101100;
        weights[5][4][0][3] = 8'b10011011;
        weights[5][4][0][4] = 8'b00110011;
        weights[5][4][1][0] = 8'b10001000;
        weights[5][4][1][1] = 8'b00110100;
        weights[5][4][1][2] = 8'b11000000;
        weights[5][4][1][3] = 8'b01000101;
        weights[5][4][1][4] = 8'b00000110;
        weights[5][4][2][0] = 8'b01111100;
        weights[5][4][2][1] = 8'b00001010;
        weights[5][4][2][2] = 8'b10111011;
        weights[5][4][2][3] = 8'b11010010;
        weights[5][4][2][4] = 8'b11101110;
    end
    
    // Biases
    logic signed [7:0] biases[0:NUM_FILTERS-1];
    initial $readmemb(BIASES_FILE, biases);
    
    // True dual-port distributed RAMs (ROMs)
    // TODO: Study the utilization of true dual port distributed RAM
    logic       feature_ram_we   [0:FILTER_SIZE-1];
    logic [7:0] feature_ram_din  [0:FILTER_SIZE-1];
    logic [4:0] feature_ram_addra[0:FILTER_SIZE-1];
    logic [4:0] feature_ram_addrb[0:FILTER_SIZE-1];
    logic [7:0] feature_ram_douta[0:FILTER_SIZE-1];
    logic [7:0] feature_ram_doutb[0:FILTER_SIZE-1];
    
    generate
    genvar i;
        for (i = 0; i < FILTER_SIZE; i++)
            feature_distributed_ram
                fram_inst (.clk (i_clk               ),
                           .we  (feature_ram_we   [i]),
                           .d   (feature_ram_din  [i]),
                           .a   (feature_ram_addra[i]),
                           .dpra(feature_ram_addrb[i]),
                           .spo (feature_ram_douta[i]),
                           .dpo (feature_ram_doutb[i]));
    endgenerate
    
    // The actual feature window to be multiplied by the filter kernel
    logic [7:0] feature_window[0:FILTER_SIZE-1][0:FILTER_SIZE-1];
    
    // We buffer the initial feature window of the next row
    // It loads during the convolution operation of the preceeding row
    logic [7:0] next_initial_feature_window[0:FILTER_SIZE-1][0:FILTER_SIZE-1] = '{default: 0};
    
    // Registers to hold temporary feature RAM data for input feature consumption logic
    logic signed [7:0] fram_swap_regs[0:FILTER_SIZE-2]; // 5 8-bit registers
    
    // Registers which feed the DSP48E1 operands
    logic signed [7:0] feature_operands[0:FILTER_SIZE-1][0:OFFSET_GRP_SZ-1];
    logic signed [7:0] weight_operands[0:NUM_FILTERS-1][0:FILTER_SIZE-1][0:OFFSET_GRP_SZ-1];
    
    // All 90 DSP48E1 registers (macro is fully pipelined)
    (* use_dsp = "yes" *) logic signed [7:0] dsp_a1[0:NUM_FILTERS-1][0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    (* use_dsp = "yes" *) logic signed [7:0] dsp_b1[0:NUM_FILTERS-1][0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    (* use_dsp = "yes" *) logic signed [7:0] dsp_a2[0:NUM_FILTERS-1][0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    (* use_dsp = "yes" *) logic signed [7:0] dsp_b2[0:NUM_FILTERS-1][0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    (* use_dsp = "yes" *) logic signed [7:0] dsp_m[0:NUM_FILTERS-1][0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    (* use_dsp = "yes" *) logic signed [7:0] dsp_p[0:NUM_FILTERS-1][0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    
    // Feature RAM location
    logic [$clog2(FILTER_SIZE)-1:0] fram_row_ctr;
    logic [$clog2(COL_END)    -1:0] fram_col_ctr;
    
    // Convolution output feature location
    logic [$clog2(ROW_END)-1:0] conv_row_ctr;
    logic [$clog2(COL_END)-1:0] conv_col_ctr;
    
    // Registered flags
    logic feature_consumption_during_processing;
    logic take_feature;
    logic fram_has_been_full;                    // Verify
    logic macc_en;                               // Optimize
    
    // Convolution FSM - controls DSP48E1 operand muxes and convolution feature counters
    typedef enum logic [2:0] {
        ONE, TWO, THREE, FOUR, FIVE
    } state_t;
    state_t state, next_state;
    
    // Adder Tree
    logic       [12:0] adder_tree_valid_sr[0:2];
    logic signed [7:0] adder1_stage1[0:NUM_FILTERS-1][0:14]; // 15 dsp outs
    logic signed [7:0] adder1_stage2[0:NUM_FILTERS-1][0:17]; // 8 adder outs from stage 1 + 10 dsp outs
    logic signed [7:0] adder1_stage3[0:NUM_FILTERS-1][0:8];  // 9 adder outs from stage 2
    logic signed [7:0] adder1_stage4[0:NUM_FILTERS-1][0:4];  // 5 adder outs from stage 3
    logic signed [7:0] adder1_stage5[0:NUM_FILTERS-1][0:2];  // 3 adder outs from stage 4
    logic signed [7:0] adder1_stage6[0:NUM_FILTERS-1][0:1];  // 2 adder outs from stage 5
    logic signed [7:0] adder1_result[0:NUM_FILTERS-1];       // adder tree 1 result
    logic signed [7:0] adder2_stage1[0:NUM_FILTERS-1][0:4];  // 5 dsp outs
    logic signed [7:0] adder2_stage2[0:NUM_FILTERS-1][0:17]; // 3 adder outs from stage 1 + 15 dsp outs
    logic signed [7:0] adder2_stage3[0:NUM_FILTERS-1][0:13]; // 9 adder outs from stage 2 + 5 dsp outs
    logic signed [7:0] adder2_stage4[0:NUM_FILTERS-1][0:6];  // 7 adder outs from stage 3
    logic signed [7:0] adder2_stage5[0:NUM_FILTERS-1][0:3];  // 4 adder outs from stage 4
    logic signed [7:0] adder2_stage6[0:NUM_FILTERS-1][0:1];  // 2 adder outs from stage 5
    logic signed [7:0] adder2_result[0:NUM_FILTERS-1];       // adder tree 2 result
    logic signed [7:0] adder3_stage1[0:NUM_FILTERS-1][0:9];  // 10 dsp outs
    logic signed [7:0] adder3_stage2[0:NUM_FILTERS-1][0:19]; // 5 adder outs from stage 1 + 15 dsp outs
    logic signed [7:0] adder3_stage3[0:NUM_FILTERS-1][0:9];  // 10 adder outs from stage 2
    logic signed [7:0] adder3_stage4[0:NUM_FILTERS-1][0:4];  // 5 adder outs from stage 3
    logic signed [7:0] adder3_stage5[0:NUM_FILTERS-1][0:2];  // 3 adder outs from stage 4
    logic signed [7:0] adder3_stage6[0:NUM_FILTERS-1][0:1];  // 2 adder outs from stage 5
    logic signed [7:0] adder3_result[0:NUM_FILTERS-1];       // adder tree 3 result
    logic signed [7:0] selected_tree_result[0:NUM_FILTERS-1];
    
    /* Processes
    
    next state
    
    feature RAM consumption, feature RAM address counters, feature RAM full flag, MACC enable flag
    
    next initial feature window loading, feature window loading, convolution counters
    
    registering DSP operands
    
    DSP48E1 pipelining
    
    adder tree
    
    register output signals
    
    */
    
    always_ff @(posedge i_clk)
        if (i_rst)
            state <= ONE;
        else
            state <= next_state;
    
    always_comb
        case(state)
            ONE: begin
                if (macc_en && (conv_col_ctr != COL_END))
                    next_state = TWO;
                else
                    next_state = ONE;
                // 15 -> adder tree 1
            end
            TWO: begin
                next_state = THREE;
                // 10 -> adder tree 1,
                // 5  -> adder tree 2
            end
            THREE: begin
                next_state = FOUR;
                // 15 -> adder tree 2
            end
            FOUR: begin
                next_state = FIVE;
                // 5  -> adder tree 2
                // 10 -> adder tree 3
            end
            FIVE: begin
                next_state = ONE;
                // 15 -> adder tree 3
            end
            default: begin
                next_state = ONE;
            end
        endcase
    
    always_ff @(posedge i_clk)
        if (i_rst) begin
            feature_consumption_during_processing <= 0;
            take_feature                          <= 0;
            fram_has_been_full                    <= 0;
            macc_en                               <= 0;
            fram_row_ctr                          <= ROW_START;
            fram_col_ctr                          <= COL_START;
        end else begin
            take_feature <= 0;
            feature_ram_we <= '{default: 0};
            // Fix start and stop count/state for feature_consumption_during_processing
            if (conv_col_ctr == (9) && state == THREE) feature_consumption_during_processing <= 0;
            else if (conv_col_ctr == (20) && state == ONE) feature_consumption_during_processing <= 1;
            if (i_feature_valid & ~fram_has_been_full) begin
                feature_ram_we   [fram_row_ctr] <= 1;
                feature_ram_addra[fram_row_ctr] <= fram_col_ctr;
                feature_ram_din  [fram_row_ctr] <= i_feature;
            end else if (feature_consumption_during_processing) begin
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_ram_we   [i] <= 1;
                    feature_ram_addra[i] <= fram_col_ctr;
                feature_ram_din <= {feature_ram_douta[3:0], i_feature};
            end
            if ((i_feature_valid & ~fram_has_been_full) | feature_consumption_during_processing) begin
                fram_col_ctr <= fram_col_ctr + 1;
                take_feature <= 1;
            end
            if (fram_col_ctr == COL_END) begin
                fram_col_ctr <= COL_START;
                if (fram_row_ctr == FILTER_SIZE-1) begin
                    if (i_feature_valid) fram_has_been_full <= 1;
                    macc_en <= 1;
                end else
                    fram_row_ctr <= fram_row_ctr + 1;
            end
        end
    
    always_ff @(posedge i_clk)
        if (i_rst) begin
            next_initial_feature_window <= '{default: 0};
            conv_row_ctr <= ROW_START;
            conv_col_ctr <= COL_START;
        end else begin
            if (fram_col_ctr < FILTER_SIZE)
                if (~fram_has_been_full)
                    next_initial_feature_window[fram_row_ctr][fram_col_ctr] <= i_feature;
                else begin
                    for (int i = 0; i < FILTER_SIZE-1; i++)
                        next_initial_feature_window[i][fram_col_ctr] <= next_initial_feature_window[i+1][fram_col_ctr];
                    next_initial_feature_window[FILTER_SIZE-1][fram_col_ctr] <= i_feature;
                end
            if ((macc_en && state == ONE) | state == THREE | state == FOUR) begin
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_ram_addrb[i] <= conv_col_ctr;
                conv_col_ctr <= conv_col_ctr + 1;
            end
            if (state == TWO | state == FOUR | state == FIVE)
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_window[i] <= {feature_ram_doutb[i], feature_window[i][1:4]};
            if (conv_col_ctr == COL_END && state == ONE) begin
                conv_row_ctr <= conv_row_ctr + 1;
                conv_col_ctr <= COL_START;
                feature_window <= next_initial_feature_window;
            end
            if (~fram_has_been_full && fram_col_ctr == COL_END && fram_row_ctr == ROW_END)
                feature_window <= next_initial_feature_window;
        end
    
    always_ff @(posedge i_clk) begin
        int feature_offsets[3];
        int weight_offsets[3];
        case(state)
            ONE: begin
                feature_offsets = '{-2,-1,0};
                weight_offsets  = '{0,1,2};
            end
            TWO: begin
                feature_offsets = '{1,2,-1};
                weight_offsets  = '{3,4,0};
            end
            THREE: begin
                feature_offsets = '{-1,0,1};
                weight_offsets  = '{1,2,3};
            end
            FOUR: begin
                feature_offsets = '{2,-1,0};
                weight_offsets  = '{4,0,1};
            end
            FIVE: begin
                feature_offsets = '{0,1,2};
                weight_offsets  = '{2,3,4};
            end
        endcase
        assign_feature_operands(feature_offsets);
        assign_weight_operands(weight_offsets);
    end
    
    task assign_feature_operands(input int offsets[3]);
        for (int i = 0; i < FILTER_SIZE; i++)
            for (int j = 0; j < OFFSET_GRP_SZ; j++)
                feature_operands[i][j] <= feature_window[i][offsets[j]+2];
    endtask
    
    task assign_weight_operands(input int offsets[3]);
        for (int i = 0; i < NUM_FILTERS; i++)
            for (int j = 0; j < FILTER_SIZE; j++)
                for (int k = 0; k < OFFSET_GRP_SZ; k++)
                    weight_operands[i][j][k] <= weights[i][j][k][offsets[k]];
    endtask
    
    always_ff @(posedge i_clk)
        for (int i = 0; i < NUM_FILTERS; i++)
            for (int j = 0; j < FILTER_SIZE; j++)
                for (int k = 0; k < OFFSET_GRP_SZ; k++)
                begin
                    dsp_a1[i][OFFSET_GRP_SZ*j+k] <= weight_operands[i][j][k];
                    dsp_b1[i][OFFSET_GRP_SZ*j+k] <= feature_operands[j][k];
                    dsp_a2[i][OFFSET_GRP_SZ*j+k] <= dsp_a1[i][OFFSET_GRP_SZ*j+k];
                    dsp_b2[i][OFFSET_GRP_SZ*j+k] <= dsp_b1[i][OFFSET_GRP_SZ*j+k];
                    dsp_m [i][OFFSET_GRP_SZ*j+k] <= dsp_a2[i][OFFSET_GRP_SZ*j+k] * dsp_b2[i][OFFSET_GRP_SZ*j+k];
                    dsp_p [i][OFFSET_GRP_SZ*j+k] <= dsp_m [i][OFFSET_GRP_SZ*j+k];
                end
    
//    TODO: Syntax simplify
//          for each adder tree
//              set constant where mult out index is for adder stage 1
//                  based on this value, set rest of adder tree mult out connections
//              compute and set adder stage x registers based on adder stage x-1 registers
    always_ff @(posedge i_clk) begin
        for (int i = 0; i < NUM_FILTERS; i++) begin
            // Adder tree structure 1
            adder1_stage1[i] <= dsp_p[i];
            
            adder1_stage2[i][17] <= adder1_stage1[i][14];
            adder1_stage2[i][0:9] <= dsp_p[i][0:9];
            for (int j = 0; j < 7; j++)
                adder1_stage2[i][10+j] <= adder1_stage1[i][j*2] + adder1_stage1[i][j*2+1];
            
            for (int j = 0; j < 9; j++)
                adder1_stage3[i][j] <= adder1_stage2[i][j*2] + adder1_stage2[i][j*2+1];
            
            adder1_stage4[i][4] <= adder1_stage3[i][8];
            for (int j = 0; j < 4; j++)
                adder1_stage4[i][j] <= adder1_stage3[i][j*2] + adder1_stage3[i][j*2+1];
            
            adder1_stage5[i][2] <= adder1_stage4[i][4];
            for (int j = 0; j < 2; j++)
                adder1_stage5[i][j] <= adder1_stage4[i][j*2] + adder1_stage4[i][j*2+1];
            
            adder1_stage6[i][1] <= adder1_stage5[i][2];
            adder1_stage6[i][0] <= adder1_stage5[i][0] + adder1_stage5[i][1];
            
            adder1_result[i] <= adder1_stage6[i][1] + adder1_stage6[i][0];
            
            // Adder tree structure 2
            adder2_stage1[i] <= dsp_p[i][10:14];
            
            adder2_stage2[i][17] <= adder2_stage1[i][4];
            adder2_stage2[i][0:14] <= dsp_p[i];
            for (int j = 0; j < 2; j++)
                adder2_stage2[i][j+15] <= adder2_stage1[i][j*2] + adder2_stage1[i][j*2+1];
            
            for (int j = 0; j < 9; j++)
                adder2_stage3[i][j+5] <= adder2_stage2[i][j*2] + adder2_stage2[i][j*2+1];
            adder2_stage3[i][0:4] <= dsp_p[i][0:4];
            
            for (int j = 0; j < 7; j++)
                adder2_stage4[i][j] <= adder2_stage3[i][j*2] + adder2_stage3[i][j*2+1];
            
            adder2_stage5[i][3] <= adder2_stage4[i][6];
            for (int j = 0; j < 3; j++)
                adder2_stage5[i][j] <= adder2_stage4[i][j*2] + adder2_stage4[i][j*2+1];
            
            for (int j = 0; j < 2; j++)
                adder2_stage6[i][j] <= adder2_stage5[i][j*2] + adder2_stage5[i][j*2+1];
            
            adder2_result[i] <= adder2_stage6[i][1] + adder2_stage6[i][0];
            
            // Adder tree structure 3
            adder3_stage1[i][0:9] <= dsp_p[i][5:14];
            
            for (int j = 0; j < 5; j++)
                adder3_stage2[i][j+15] <= adder3_stage1[i][j*2] + adder3_stage1[i][j*2+1];
            adder3_stage2[i][0:14] <= dsp_p[i];
            
            for (int j = 0; j < 10; j++)
                adder3_stage3[i][j] <= adder3_stage2[i][j*2] + adder3_stage2[i][j*2+1];
            
            for (int j = 0; j < 5; j++)
                adder3_stage4[i][j] <= adder3_stage3[i][j*2] + adder3_stage3[i][j*2+1];
            
            adder3_stage5[i][2] <= adder3_stage4[i][4];
            for (int j = 0; j < 2; j++)
                adder3_stage5[i][j] <= adder3_stage4[i][j*2] + adder3_stage4[i][j*2+1];
            
            adder3_stage6[i][1] <= adder3_stage5[i][2];
            adder3_stage6[i][0] <= adder3_stage5[i][0] + adder3_stage5[i][1];
            
            adder3_result[i] <= adder3_stage6[i][1] + adder3_stage6[i][0];
        end
        if (macc_en) begin
            adder_tree_valid_sr[0] <= {adder_tree_valid_sr[0][11:0], state == ONE ? 1'b1: 1'b0};
            adder_tree_valid_sr[1] <= {adder_tree_valid_sr[1][11:0], (state == TWO && conv_col_ctr != COL_END) ? 1'b1: 1'b0};
            adder_tree_valid_sr[2] <= {adder_tree_valid_sr[2][11:0], state == FOUR ? 1'b1: 1'b0};
        end
    end
    
    // 3:1 8-bit (8 LUTs, 2 slices, 1 CLB) mux to output data port register
    always_comb
        if (adder_tree_valid_sr[0][12])
            selected_tree_result = adder1_result;
        else if (adder_tree_valid_sr[1][12])
            selected_tree_result = adder2_result;
        else if (adder_tree_valid_sr[2][12])
            selected_tree_result = adder3_result;
        else
            selected_tree_result = adder3_result;
    
    always_ff @(posedge i_clk) begin
        o_feature_valid <= adder_tree_valid_sr[0][12] |
                           adder_tree_valid_sr[1][12] |
                           adder_tree_valid_sr[2][12];
        o_features      <= selected_tree_result;
        o_ready_feature <= take_feature;
    end
    
endmodule


/*
Possible convolution column count and state pairings
 1)   2: ONE    + 1
 2)   3: TWO
 3)   3: THREE  + 1
 4)   4: FOUR   + 1
 5)   5: FIVE
 6)   5: ONE    + 1
 7)   6: TWO
 8)   6: THREE  + 1
 9)   7: FOUR   + 1
10)   8: FIVE
11)   8: ONE    + 1
12)   9: TWO
13)   9: THREE  + 1
14)  10: FOUR   + 1
15)  11: FIVE
16)  11: ONE    + 1
17)  12: TWO
18)  12: THREE  + 1
19)  13: FOUR   + 1
20)  14: FIVE
21)  14: ONE    + 1
22)  15: TWO
23)  15: THREE  + 1
24)  16: FOUR   + 1
25)  17: FIVE
26)  17: ONE    + 1
27)  18: TWO
28)  18: THREE  + 1
29)  19: FOUR   + 1
30)  20: FIVE
31)  20: ONE    + 1
32)  21: TWO
33)  21: THREE  + 1
34)  22: FOUR   + 1
35)  23: FIVE
36)  23: ONE    + 1
37)  24: TWO
38)  24: THREE  + 1
39)  25: FOUR   + 1
40)  26: FIVE
41)  26: ONE    + 1
42)  27: TWO
43)  27: THREE  + 1
44)  28: FOUR   + 1
45)  29: FIVE
46)  29: ONE    ROLL-OVER

*/





