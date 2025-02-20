`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
/*
    Theory of Operation:
        Overview:
            Utilize 90 DSPs for convolution.
            Complete 3 convolution kernels in 5 clock cycles.
            We will skip the last convolution (output feature)
            for each row for simplicity.
            There will be 27 convolutions (output features) in each row
            which will take (27/3)*5 = 45 clock cycles per row.
            We will sequentially execute convolution operations on 27 rows.
            For each row, convolve left to right, from output feature 0-26.
        Start
            Wait until feature RAMs are full to enable convolution operation.
            Start when there is just enough data in the feature RAMs in the future,
            but for now we wait until the feature RAMs are full for simplicity.
        
        Artix7-35 Resources
            90 DSPs, 50 BRAMS (36Kb each)
        Required Resources by Design
        
        Latency due to Design
            6 filters for conv1, 5x5 filter (25 * ops), 27x27 conv ops (730)
            = 6*(5*5)*(27*27) = 109350 * ops / 90 DSPs = 1215 cycs theoretically
        
        Study how to get outputs of DSP48s to carry chain resources efficiently
        
        State:         0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14
        
        adder 1-1:    15, 18,  9,  5,  3,  2,  1
        adder 2-1:         5, 18, 14,  7,  4,  2,  1
        adder 3-1:                10, 20, 10,  5,  3,  2,  1
        
        adder 1-2:                        15, 18,  9,  5,  3,  2,  1
        adder 2-2:                             5, 18, 14,  7,  4,  2,  1
        adder 3-2:                                    10, 20, 10,  5,  3,  2,  1
*/
//////////////////////////////////////////////////////////////////////////////////


    // Takes 27*3=81 clock cycles for FRAM to become full
    // MACC enable set after 27*2=54 clock cycles
    // For logic simplicity, FRAM should become full
    // before MACC is enabled
    
    // For distributed RAM should we aim for sync or async reads?
    
    // Study the performance hit when using a fixed addition/subtraction on memory addressing

module conv
    #(
    localparam NUM_FILTERS = 6
    )(
    input  logic               i_clk,
    input  logic               i_rst,
    input  logic               i_feature_valid,
    input  logic         [7:0] i_feature,
    output logic               o_feature_valid,
    output logic signed [15:0] o_features[0:NUM_FILTERS-1],
    output logic               o_ready_feature
    );

    // Hardcode frame dimensions in local params
    localparam string WEIGHTS_FILE     = "weights.mem";
    localparam string BIASES_FILE      = "biases.mem";
    localparam        NUM_DSP48E1      = 90;
    localparam        DSP_PER_CH       = NUM_DSP48E1 / NUM_FILTERS;
    localparam        FILTER_SIZE      = 5; // 5x5 filters
    localparam        OFFSET_GRP_SZ    = DSP_PER_CH / FILTER_SIZE;
    localparam        WEIGHT_ROM_DEPTH = 5;
    localparam        INPUT_WIDTH      = 31;
    localparam        INPUT_HEIGHT     = 31;
    localparam        ROW_START        = 2;
    localparam        ROW_END          = 29;
    localparam        COL_START        = 2;
    localparam        COL_END          = 29;
    
    // Weight ROMs
    // 90 distributed RAMs -> 1 per DSP48E1
    // 16-bit signed data x 6 filters x 5 rows x 3 columns x 5 deep
    // Overall there is 90x5 = 90 8x16-bit Distributed RAMs
    // One SLICEM can implement 2 8x16-bit Distruibuted RAMs
    // Hence, 45 slices will be used for the weight RAMs
    // Initialize trainable parameters
    // Weights
    // (* rom_style = "block" *)
    // logic signed [15:0] raw_weights [0:NUM_DSP48E1*WEIGHT_ROM_DEPTH-1];
    // initial $readmemb(WEIGHTS_FILE, raw_weights);
    // (* ram_style = "distributed" *)
    logic signed [15:0]
    weights [0:NUM_FILTERS-1][0:FILTER_SIZE-1]
            [0:OFFSET_GRP_SZ-1][0:WEIGHT_ROM_DEPTH-1];
//    integer raw_idx;
//    initial begin
//        $readmemb(WEIGHTS_FILE, raw_weights);
//        raw_idx = 0;
//        for (int i = 0; i < NUM_FILTERS; i++)
//            for (int j = 0; j < FILTER_SIZE; j++)
//                for (int k = 0; k < OFFSET_GRP_SZ; k++)
//                    for (int l = 0; l < WEIGHT_ROM_DEPTH; l++) begin
//                        weights[i][j][k][l] = raw_weights[raw_idx];
//                        raw_idx = raw_idx + 1;
//                    end
//    end
    // Hardcoded initialization of Distributed RAM weights
    initial begin
        weights[0][0][0][0] = 16'b0111101101100110;
        weights[0][0][0][1] = 16'b1101011110010100;
        weights[0][0][0][2] = 16'b1110000000101011;
        weights[0][0][0][3] = 16'b1010110001101101;
        weights[0][0][0][4] = 16'b0010111111100110;
        weights[0][0][1][0] = 16'b0101111100110111;
        weights[0][0][1][1] = 16'b0001111100001110;
        weights[0][0][1][2] = 16'b1000100100000001;
        weights[0][0][1][3] = 16'b1011100110101110;
        weights[0][0][1][4] = 16'b0110011100001110;
        weights[0][0][2][0] = 16'b1011100000100011;
        weights[0][0][2][1] = 16'b1000100111011001;
        weights[0][0][2][2] = 16'b0111001101110100;
        weights[0][0][2][3] = 16'b1111100001001111;
        weights[0][0][2][4] = 16'b1011001000101001;
        weights[0][1][0][0] = 16'b1110101000000001;
        weights[0][1][0][1] = 16'b0110111101100010;
        weights[0][1][0][2] = 16'b1100010011110101;
        weights[0][1][0][3] = 16'b1001001000101011;
        weights[0][1][0][4] = 16'b1000110101010110;
        weights[0][1][1][0] = 16'b0000000110100111;
        weights[0][1][1][1] = 16'b0001010111101011;
        weights[0][1][1][2] = 16'b0100010110100110;
        weights[0][1][1][3] = 16'b1110100110100001;
        weights[0][1][1][4] = 16'b1100010111101000;
        weights[0][1][2][0] = 16'b0011010100101000;
        weights[0][1][2][1] = 16'b1010000010100101;
        weights[0][1][2][2] = 16'b1001001110001001;
        weights[0][1][2][3] = 16'b0010100011011001;
        weights[0][1][2][4] = 16'b0000111011011101;
        weights[0][2][0][0] = 16'b0110101110011010;
        weights[0][2][0][1] = 16'b0000100011000010;
        weights[0][2][0][2] = 16'b0110100010000011;
        weights[0][2][0][3] = 16'b0001000110110100;
        weights[0][2][0][4] = 16'b0001000111101110;
        weights[0][2][1][0] = 16'b1011100001110101;
        weights[0][2][1][1] = 16'b0011111010100011;
        weights[0][2][1][2] = 16'b1000010001111010;
        weights[0][2][1][3] = 16'b1100010001000100;
        weights[0][2][1][4] = 16'b0110010110000011;
        weights[0][2][2][0] = 16'b0010010110011110;
        weights[0][2][2][1] = 16'b1010011100000000;
        weights[0][2][2][2] = 16'b0011111110101011;
        weights[0][2][2][3] = 16'b1111000100111011;
        weights[0][2][2][4] = 16'b1011000111110010;
        weights[0][3][0][0] = 16'b1100101100100000;
        weights[0][3][0][1] = 16'b1000100100101111;
        weights[0][3][0][2] = 16'b0101101001000111;
        weights[0][3][0][3] = 16'b1110100011010101;
        weights[0][3][0][4] = 16'b0011000000000110;
        weights[0][3][1][0] = 16'b1010000001100110;
        weights[0][3][1][1] = 16'b1011001001011111;
        weights[0][3][1][2] = 16'b1101011010110111;
        weights[0][3][1][3] = 16'b0011000101111001;
        weights[0][3][1][4] = 16'b1101111001110100;
        weights[0][3][2][0] = 16'b1001010011101001;
        weights[0][3][2][1] = 16'b1011000100110100;
        weights[0][3][2][2] = 16'b1111110010101100;
        weights[0][3][2][3] = 16'b1100110100011001;
        weights[0][3][2][4] = 16'b1011100100110100;
        weights[0][4][0][0] = 16'b0001111011101001;
        weights[0][4][0][1] = 16'b0001101100110101;
        weights[0][4][0][2] = 16'b1011101011101100;
        weights[0][4][0][3] = 16'b0001001101001100;
        weights[0][4][0][4] = 16'b0011101111111101;
        weights[0][4][1][0] = 16'b1100001001011110;
        weights[0][4][1][1] = 16'b1110010011011010;
        weights[0][4][1][2] = 16'b0010000011110010;
        weights[0][4][1][3] = 16'b0101010101011101;
        weights[0][4][1][4] = 16'b1100001100001010;
        weights[0][4][2][0] = 16'b1010000100000011;
        weights[0][4][2][1] = 16'b0001111100000001;
        weights[0][4][2][2] = 16'b1100010111111010;
        weights[0][4][2][3] = 16'b0000101110010000;
        weights[0][4][2][4] = 16'b0111011100000100;
        weights[1][0][0][0] = 16'b0011111101101000;
        weights[1][0][0][1] = 16'b0001000101111100;
        weights[1][0][0][2] = 16'b0010101111000011;
        weights[1][0][0][3] = 16'b1110111100100101;
        weights[1][0][0][4] = 16'b1100101000101000;
        weights[1][0][1][0] = 16'b1111101100011011;
        weights[1][0][1][1] = 16'b1100010000100010;
        weights[1][0][1][2] = 16'b1111000011010101;
        weights[1][0][1][3] = 16'b0111100011111001;
        weights[1][0][1][4] = 16'b1010110111111010;
        weights[1][0][2][0] = 16'b0011010111000010;
        weights[1][0][2][1] = 16'b0011111110111001;
        weights[1][0][2][2] = 16'b0101010111100111;
        weights[1][0][2][3] = 16'b0001010110000000;
        weights[1][0][2][4] = 16'b1111110011011110;
        weights[1][1][0][0] = 16'b1110101111011101;
        weights[1][1][0][1] = 16'b0110100110011011;
        weights[1][1][0][2] = 16'b0001010101110101;
        weights[1][1][0][3] = 16'b1010011101000101;
        weights[1][1][0][4] = 16'b0110110011011010;
        weights[1][1][1][0] = 16'b1110000010001100;
        weights[1][1][1][1] = 16'b0000111011111111;
        weights[1][1][1][2] = 16'b1000100010111100;
        weights[1][1][1][3] = 16'b0001110011010000;
        weights[1][1][1][4] = 16'b0101101111001111;
        weights[1][1][2][0] = 16'b1011001101001000;
        weights[1][1][2][1] = 16'b1100001011000000;
        weights[1][1][2][2] = 16'b1010010001110011;
        weights[1][1][2][3] = 16'b0101100101001001;
        weights[1][1][2][4] = 16'b0111001101001101;
        weights[1][2][0][0] = 16'b0101011111010101;
        weights[1][2][0][1] = 16'b1000101101100101;
        weights[1][2][0][2] = 16'b0100000100100000;
        weights[1][2][0][3] = 16'b0000000001011000;
        weights[1][2][0][4] = 16'b1010010101010110;
        weights[1][2][1][0] = 16'b0000000101011001;
        weights[1][2][1][1] = 16'b1101101110110100;
        weights[1][2][1][2] = 16'b1101101111111100;
        weights[1][2][1][3] = 16'b1000011101001110;
        weights[1][2][1][4] = 16'b1111001000010111;
        weights[1][2][2][0] = 16'b0111000111111101;
        weights[1][2][2][1] = 16'b0100011100011011;
        weights[1][2][2][2] = 16'b0101011100111111;
        weights[1][2][2][3] = 16'b1100100111111010;
        weights[1][2][2][4] = 16'b0100010111101100;
        weights[1][3][0][0] = 16'b0110011001010011;
        weights[1][3][0][1] = 16'b1111000011110101;
        weights[1][3][0][2] = 16'b0110111000111001;
        weights[1][3][0][3] = 16'b0011000000111110;
        weights[1][3][0][4] = 16'b1011011010001111;
        weights[1][3][1][0] = 16'b1001000001101100;
        weights[1][3][1][1] = 16'b1011000010010111;
        weights[1][3][1][2] = 16'b1111001011101001;
        weights[1][3][1][3] = 16'b0111010000000001;
        weights[1][3][1][4] = 16'b0100001110001111;
        weights[1][3][2][0] = 16'b1001100110111001;
        weights[1][3][2][1] = 16'b0100100011010100;
        weights[1][3][2][2] = 16'b0111000001101110;
        weights[1][3][2][3] = 16'b1101010010000110;
        weights[1][3][2][4] = 16'b1111100110110111;
        weights[1][4][0][0] = 16'b0001101001100111;
        weights[1][4][0][1] = 16'b0000100101100101;
        weights[1][4][0][2] = 16'b0110001100011111;
        weights[1][4][0][3] = 16'b1000100101101111;
        weights[1][4][0][4] = 16'b0010000000010011;
        weights[1][4][1][0] = 16'b0001000010110000;
        weights[1][4][1][1] = 16'b1100101001000111;
        weights[1][4][1][2] = 16'b0111101011110011;
        weights[1][4][1][3] = 16'b0110010101100101;
        weights[1][4][1][4] = 16'b0001010011011001;
        weights[1][4][2][0] = 16'b0010011110110000;
        weights[1][4][2][1] = 16'b0010010101111101;
        weights[1][4][2][2] = 16'b1110001110011001;
        weights[1][4][2][3] = 16'b0101100100001101;
        weights[1][4][2][4] = 16'b1000011011100010;
        weights[2][0][0][0] = 16'b0010111111011001;
        weights[2][0][0][1] = 16'b0010111010111101;
        weights[2][0][0][2] = 16'b0110100001001011;
        weights[2][0][0][3] = 16'b0011111001111111;
        weights[2][0][0][4] = 16'b1000000010001001;
        weights[2][0][1][0] = 16'b1010111011100111;
        weights[2][0][1][1] = 16'b1101110010000101;
        weights[2][0][1][2] = 16'b1100101001100001;
        weights[2][0][1][3] = 16'b1110000000010101;
        weights[2][0][1][4] = 16'b0001111111100001;
        weights[2][0][2][0] = 16'b0100000110000101;
        weights[2][0][2][1] = 16'b1010011110001110;
        weights[2][0][2][2] = 16'b1100110110000000;
        weights[2][0][2][3] = 16'b0101100110111000;
        weights[2][0][2][4] = 16'b1011001001111000;
        weights[2][1][0][0] = 16'b0100100111001100;
        weights[2][1][0][1] = 16'b0110111010111010;
        weights[2][1][0][2] = 16'b1000001011010010;
        weights[2][1][0][3] = 16'b0100000011000011;
        weights[2][1][0][4] = 16'b1011101100110110;
        weights[2][1][1][0] = 16'b0101010001110001;
        weights[2][1][1][1] = 16'b1000100010100001;
        weights[2][1][1][2] = 16'b1000101101000110;
        weights[2][1][1][3] = 16'b0001111110110100;
        weights[2][1][1][4] = 16'b0000111101100001;
        weights[2][1][2][0] = 16'b1010001110110100;
        weights[2][1][2][1] = 16'b0000010101001000;
        weights[2][1][2][2] = 16'b1011100101010101;
        weights[2][1][2][3] = 16'b1100001111010001;
        weights[2][1][2][4] = 16'b1001100000100011;
        weights[2][2][0][0] = 16'b0101110010010101;
        weights[2][2][0][1] = 16'b1101001011111001;
        weights[2][2][0][2] = 16'b0010101100010010;
        weights[2][2][0][3] = 16'b1000001101011110;
        weights[2][2][0][4] = 16'b0001000011001111;
        weights[2][2][1][0] = 16'b0110011001001100;
        weights[2][2][1][1] = 16'b0101110010101110;
        weights[2][2][1][2] = 16'b0100010100011110;
        weights[2][2][1][3] = 16'b1001101010000101;
        weights[2][2][1][4] = 16'b1100111000001000;
        weights[2][2][2][0] = 16'b1110110001010111;
        weights[2][2][2][1] = 16'b1110101011011000;
        weights[2][2][2][2] = 16'b0110101001001010;
        weights[2][2][2][3] = 16'b1101111111110110;
        weights[2][2][2][4] = 16'b1101011101000110;
        weights[2][3][0][0] = 16'b0001000010000010;
        weights[2][3][0][1] = 16'b0110100100010001;
        weights[2][3][0][2] = 16'b1011011010010110;
        weights[2][3][0][3] = 16'b1011110001110110;
        weights[2][3][0][4] = 16'b1001000010010110;
        weights[2][3][1][0] = 16'b1000000110000100;
        weights[2][3][1][1] = 16'b1111111101101011;
        weights[2][3][1][2] = 16'b0000001100001011;
        weights[2][3][1][3] = 16'b0100010101111101;
        weights[2][3][1][4] = 16'b0110101010100000;
        weights[2][3][2][0] = 16'b1000011000010011;
        weights[2][3][2][1] = 16'b0010111001000001;
        weights[2][3][2][2] = 16'b1101011100011111;
        weights[2][3][2][3] = 16'b1100110010001000;
        weights[2][3][2][4] = 16'b0011001010011110;
        weights[2][4][0][0] = 16'b1001000001001001;
        weights[2][4][0][1] = 16'b0000101101001100;
        weights[2][4][0][2] = 16'b1111100011010001;
        weights[2][4][0][3] = 16'b0011001010011100;
        weights[2][4][0][4] = 16'b0011111011101001;
        weights[2][4][1][0] = 16'b0000010100101001;
        weights[2][4][1][1] = 16'b0110000001000101;
        weights[2][4][1][2] = 16'b1111010010011111;
        weights[2][4][1][3] = 16'b1000110000111000;
        weights[2][4][1][4] = 16'b0110110010101111;
        weights[2][4][2][0] = 16'b0111110100010111;
        weights[2][4][2][1] = 16'b1101000111001000;
        weights[2][4][2][2] = 16'b1101111110101101;
        weights[2][4][2][3] = 16'b0100100010100101;
        weights[2][4][2][4] = 16'b1110110111000000;
        weights[3][0][0][0] = 16'b1100111000100101;
        weights[3][0][0][1] = 16'b0011000110101010;
        weights[3][0][0][2] = 16'b1111110011110001;
        weights[3][0][0][3] = 16'b0001111111000000;
        weights[3][0][0][4] = 16'b1010001001001110;
        weights[3][0][1][0] = 16'b1011011111010011;
        weights[3][0][1][1] = 16'b1110011111001111;
        weights[3][0][1][2] = 16'b1110100011111110;
        weights[3][0][1][3] = 16'b0001100000011000;
        weights[3][0][1][4] = 16'b0011010000101100;
        weights[3][0][2][0] = 16'b1000110000101001;
        weights[3][0][2][1] = 16'b1000110111111001;
        weights[3][0][2][2] = 16'b0001001100001111;
        weights[3][0][2][3] = 16'b1110011111110100;
        weights[3][0][2][4] = 16'b0011001100001111;
        weights[3][1][0][0] = 16'b1000010001011111;
        weights[3][1][0][1] = 16'b0101001100101101;
        weights[3][1][0][2] = 16'b1111001001011111;
        weights[3][1][0][3] = 16'b1100110101011111;
        weights[3][1][0][4] = 16'b1110110000100111;
        weights[3][1][1][0] = 16'b0111101011100100;
        weights[3][1][1][1] = 16'b1110010010101011;
        weights[3][1][1][2] = 16'b0110010001001101;
        weights[3][1][1][3] = 16'b0101101101000000;
        weights[3][1][1][4] = 16'b1011010101101000;
        weights[3][1][2][0] = 16'b1001011110110010;
        weights[3][1][2][1] = 16'b0100000000101110;
        weights[3][1][2][2] = 16'b1000110011111000;
        weights[3][1][2][3] = 16'b1011101011100001;
        weights[3][1][2][4] = 16'b0100010011000100;
        weights[3][2][0][0] = 16'b1110110100000001;
        weights[3][2][0][1] = 16'b0000100101001100;
        weights[3][2][0][2] = 16'b0100010011010111;
        weights[3][2][0][3] = 16'b1011011101110101;
        weights[3][2][0][4] = 16'b0110001010101100;
        weights[3][2][1][0] = 16'b1010010101100001;
        weights[3][2][1][1] = 16'b0011110001100011;
        weights[3][2][1][2] = 16'b0010101101011111;
        weights[3][2][1][3] = 16'b1001011000010110;
        weights[3][2][1][4] = 16'b0000111100011101;
        weights[3][2][2][0] = 16'b1110100011111110;
        weights[3][2][2][1] = 16'b0001101000000001;
        weights[3][2][2][2] = 16'b1011100011100010;
        weights[3][2][2][3] = 16'b0100101010110000;
        weights[3][2][2][4] = 16'b1000001100001000;
        weights[3][3][0][0] = 16'b1011011000101101;
        weights[3][3][0][1] = 16'b0010000011000111;
        weights[3][3][0][2] = 16'b1011010101000110;
        weights[3][3][0][3] = 16'b1101010111111000;
        weights[3][3][0][4] = 16'b0101000110100110;
        weights[3][3][1][0] = 16'b0011011011001110;
        weights[3][3][1][1] = 16'b0100011001011000;
        weights[3][3][1][2] = 16'b0000100000101101;
        weights[3][3][1][3] = 16'b0011110111110000;
        weights[3][3][1][4] = 16'b1100110001011010;
        weights[3][3][2][0] = 16'b1010100011000111;
        weights[3][3][2][1] = 16'b0111100110110000;
        weights[3][3][2][2] = 16'b0000001000001010;
        weights[3][3][2][3] = 16'b0010111001100100;
        weights[3][3][2][4] = 16'b0001101110110001;
        weights[3][4][0][0] = 16'b0000101011110011;
        weights[3][4][0][1] = 16'b0001010111101010;
        weights[3][4][0][2] = 16'b0100111110010101;
        weights[3][4][0][3] = 16'b0111111111000101;
        weights[3][4][0][4] = 16'b1001100011000000;
        weights[3][4][1][0] = 16'b1100010101110100;
        weights[3][4][1][1] = 16'b1010110101100010;
        weights[3][4][1][2] = 16'b0110111010010010;
        weights[3][4][1][3] = 16'b0011101010011011;
        weights[3][4][1][4] = 16'b0010101111110100;
        weights[3][4][2][0] = 16'b0010011011001100;
        weights[3][4][2][1] = 16'b0100010111110111;
        weights[3][4][2][2] = 16'b0100100100000101;
        weights[3][4][2][3] = 16'b0011110000010100;
        weights[3][4][2][4] = 16'b0010010110110111;
        weights[4][0][0][0] = 16'b1100110100001110;
        weights[4][0][0][1] = 16'b1001000010100010;
        weights[4][0][0][2] = 16'b1110110111111101;
        weights[4][0][0][3] = 16'b0001001101001011;
        weights[4][0][0][4] = 16'b0101110001010001;
        weights[4][0][1][0] = 16'b0010011011000110;
        weights[4][0][1][1] = 16'b1001001101100010;
        weights[4][0][1][2] = 16'b0100111111000100;
        weights[4][0][1][3] = 16'b1111100100111000;
        weights[4][0][1][4] = 16'b0010010110100000;
        weights[4][0][2][0] = 16'b0000000000000100;
        weights[4][0][2][1] = 16'b1001001100000010;
        weights[4][0][2][2] = 16'b0011110110001110;
        weights[4][0][2][3] = 16'b1010010111001100;
        weights[4][0][2][4] = 16'b0010100000010101;
        weights[4][1][0][0] = 16'b0001011110001000;
        weights[4][1][0][1] = 16'b1110011001100001;
        weights[4][1][0][2] = 16'b0001110000100110;
        weights[4][1][0][3] = 16'b1001010101101010;
        weights[4][1][0][4] = 16'b1010001000101100;
        weights[4][1][1][0] = 16'b0000111011111101;
        weights[4][1][1][1] = 16'b1010110101100010;
        weights[4][1][1][2] = 16'b0110000101000011;
        weights[4][1][1][3] = 16'b1011001100011111;
        weights[4][1][1][4] = 16'b0101101010000111;
        weights[4][1][2][0] = 16'b1001110010100110;
        weights[4][1][2][1] = 16'b1100001011001011;
        weights[4][1][2][2] = 16'b0100001010100001;
        weights[4][1][2][3] = 16'b0111001000011101;
        weights[4][1][2][4] = 16'b0110101000001111;
        weights[4][2][0][0] = 16'b0011010010111100;
        weights[4][2][0][1] = 16'b0110101111110100;
        weights[4][2][0][2] = 16'b0111011011110100;
        weights[4][2][0][3] = 16'b1110110101001011;
        weights[4][2][0][4] = 16'b0000101010110101;
        weights[4][2][1][0] = 16'b1100111011001010;
        weights[4][2][1][1] = 16'b0010111011111011;
        weights[4][2][1][2] = 16'b1011010011011001;
        weights[4][2][1][3] = 16'b1010111001100101;
        weights[4][2][1][4] = 16'b0011101110000001;
        weights[4][2][2][0] = 16'b1001001110000111;
        weights[4][2][2][1] = 16'b1111110010011111;
        weights[4][2][2][2] = 16'b0011100000101100;
        weights[4][2][2][3] = 16'b0010000100001001;
        weights[4][2][2][4] = 16'b0100111010000010;
        weights[4][3][0][0] = 16'b1101101100111000;
        weights[4][3][0][1] = 16'b0101001100001110;
        weights[4][3][0][2] = 16'b0110111111101011;
        weights[4][3][0][3] = 16'b1100101101100010;
        weights[4][3][0][4] = 16'b1001011101001010;
        weights[4][3][1][0] = 16'b1101010101100010;
        weights[4][3][1][1] = 16'b1001000010100000;
        weights[4][3][1][2] = 16'b1101001110001011;
        weights[4][3][1][3] = 16'b0000110100001110;
        weights[4][3][1][4] = 16'b0001100111101000;
        weights[4][3][2][0] = 16'b1000000110000000;
        weights[4][3][2][1] = 16'b1111010100101110;
        weights[4][3][2][2] = 16'b1001110110011010;
        weights[4][3][2][3] = 16'b1011010011010100;
        weights[4][3][2][4] = 16'b1010000111011111;
        weights[4][4][0][0] = 16'b1100000110001111;
        weights[4][4][0][1] = 16'b0111000111000011;
        weights[4][4][0][2] = 16'b1011111011011010;
        weights[4][4][0][3] = 16'b0100001101011011;
        weights[4][4][0][4] = 16'b1000001100111011;
        weights[4][4][1][0] = 16'b1001000011111100;
        weights[4][4][1][1] = 16'b1111000111001111;
        weights[4][4][1][2] = 16'b0101110100011010;
        weights[4][4][1][3] = 16'b0101101111000001;
        weights[4][4][1][4] = 16'b1010101010111111;
        weights[4][4][2][0] = 16'b1000101011101100;
        weights[4][4][2][1] = 16'b0110011101111010;
        weights[4][4][2][2] = 16'b1110111000001100;
        weights[4][4][2][3] = 16'b0010101110101001;
        weights[4][4][2][4] = 16'b1011110001001101;
        weights[5][0][0][0] = 16'b0000010000101100;
        weights[5][0][0][1] = 16'b1011100100101101;
        weights[5][0][0][2] = 16'b1111011101100010;
        weights[5][0][0][3] = 16'b0111111110000000;
        weights[5][0][0][4] = 16'b0001011111000000;
        weights[5][0][1][0] = 16'b1011010110001000;
        weights[5][0][1][1] = 16'b1110111101000100;
        weights[5][0][1][2] = 16'b0011101001101011;
        weights[5][0][1][3] = 16'b1101000111101010;
        weights[5][0][1][4] = 16'b1100110110111111;
        weights[5][0][2][0] = 16'b1000001101010010;
        weights[5][0][2][1] = 16'b1010011010101000;
        weights[5][0][2][2] = 16'b0100110110000010;
        weights[5][0][2][3] = 16'b1011111100001001;
        weights[5][0][2][4] = 16'b0100011111011110;
        weights[5][1][0][0] = 16'b0001010010100011;
        weights[5][1][0][1] = 16'b1100000101011001;
        weights[5][1][0][2] = 16'b1000101010101010;
        weights[5][1][0][3] = 16'b0100111011110001;
        weights[5][1][0][4] = 16'b1001101110110011;
        weights[5][1][1][0] = 16'b1110111100001010;
        weights[5][1][1][1] = 16'b1001000111100111;
        weights[5][1][1][2] = 16'b0110110100011001;
        weights[5][1][1][3] = 16'b0010000000101101;
        weights[5][1][1][4] = 16'b0101111100101111;
        weights[5][1][2][0] = 16'b0010100011010100;
        weights[5][1][2][1] = 16'b1011001000000010;
        weights[5][1][2][2] = 16'b0010011101111001;
        weights[5][1][2][3] = 16'b0110111111011000;
        weights[5][1][2][4] = 16'b0101001110011110;
        weights[5][2][0][0] = 16'b0100100011110010;
        weights[5][2][0][1] = 16'b0001000000100101;
        weights[5][2][0][2] = 16'b1100100010100101;
        weights[5][2][0][3] = 16'b0101110000011101;
        weights[5][2][0][4] = 16'b1000010100001011;
        weights[5][2][1][0] = 16'b0001001011111110;
        weights[5][2][1][1] = 16'b1110001001001111;
        weights[5][2][1][2] = 16'b1101001101010000;
        weights[5][2][1][3] = 16'b1011010001000100;
        weights[5][2][1][4] = 16'b0001011001000011;
        weights[5][2][2][0] = 16'b1001111100000111;
        weights[5][2][2][1] = 16'b1101101111110110;
        weights[5][2][2][2] = 16'b1110001001011010;
        weights[5][2][2][3] = 16'b0001110001101001;
        weights[5][2][2][4] = 16'b1101010000110001;
        weights[5][3][0][0] = 16'b1001100011100101;
        weights[5][3][0][1] = 16'b1010000010000010;
        weights[5][3][0][2] = 16'b0111010001000000;
        weights[5][3][0][3] = 16'b0101111011101001;
        weights[5][3][0][4] = 16'b1110100100001010;
        weights[5][3][1][0] = 16'b0001111110011111;
        weights[5][3][1][1] = 16'b0000110100010010;
        weights[5][3][1][2] = 16'b1000011011010010;
        weights[5][3][1][3] = 16'b1111000111010010;
        weights[5][3][1][4] = 16'b1001000011101001;
        weights[5][3][2][0] = 16'b0101110100111010;
        weights[5][3][2][1] = 16'b1101010000110100;
        weights[5][3][2][2] = 16'b1001011111111110;
        weights[5][3][2][3] = 16'b1010101101010101;
        weights[5][3][2][4] = 16'b1101011001001100;
        weights[5][4][0][0] = 16'b0001100110011111;
        weights[5][4][0][1] = 16'b1110000010101111;
        weights[5][4][0][2] = 16'b1010110011110011;
        weights[5][4][0][3] = 16'b1001101100101101;
        weights[5][4][0][4] = 16'b0011001101010010;
        weights[5][4][1][0] = 16'b1000100000100010;
        weights[5][4][1][1] = 16'b0011010001011010;
        weights[5][4][1][2] = 16'b1100000001101101;
        weights[5][4][1][3] = 16'b0100010101011011;
        weights[5][4][1][4] = 16'b0000011011110100;
        weights[5][4][2][0] = 16'b0111110000111000;
        weights[5][4][2][1] = 16'b0000101010011010;
        weights[5][4][2][2] = 16'b1011101110100110;
        weights[5][4][2][3] = 16'b1101001010001110;
        weights[5][4][2][4] = 16'b1110111001100010;
    end
    
    // Biases
    // (* rom_style = "block" *)
    logic signed [15:0] biases [0:NUM_FILTERS-1];
    initial $readmemb(BIASES_FILE, biases);
    
    // Make sure distributed RAMs are synthesized
    // These feature RAMs are essentially line buffers
    // (* ram_style = "distributed" *)
    logic [7:0] feature_rams [0:FILTER_SIZE-1][0:INPUT_WIDTH-1];
    // initial feature_rams = '{default: 0};
    initial begin
        for (int i = 0; i < FILTER_SIZE; i++) begin
            for (int j = 0; j < INPUT_WIDTH; j++) begin
                feature_rams[i][j] = 0;
            end
        end
    end 
    
    // The actual feature window to be multiplied by the filter kernel
    logic [7:0] feature_window [0:FILTER_SIZE-1][0:FILTER_SIZE-1];
    
    // We buffer the initial feature window of the next row
    // It loads during convolution operation of the preceeding row
    logic [7:0] next_initial_feature_window[0:FILTER_SIZE-1]
                                           [0:FILTER_SIZE-1];
    
    // Registers to hold temporary feature RAM data
    // as part of the input feature consumption logic
    logic signed [15:0] fram_swap_regs[0:NUM_FILTERS-2];
    
    // Signals holding the DSP48E1 operands, used for readability
    logic         [7:0] feature_operands[0:FILTER_SIZE-1][0:2];
    logic signed [15:0] weight_operands[0:NUM_FILTERS-1]
                                       [0:FILTER_SIZE-1]
                                       [0:OFFSET_GRP_SZ-1];
    
    // All 90 DSP48E1 outputs
    logic signed [15:0] mult_out[0:NUM_FILTERS-1]
                                [0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    
    // Feature RAM location
    logic [$clog2(FILTER_SIZE)-1:0] fram_row_ctr;
    logic [$clog2(COL_END)-1:0]     fram_col_ctr;
    
    // Convolution Feature location
    // logic [$clog2(ROW_END)-1:0] conv_row_ctr; // unused
    logic [$clog2(COL_END)-1:0] conv_col_ctr;
    
    // Convolution FSM, controls DSP48E1 time multiplexing,
    // and convolution feature counters
    typedef enum logic [2:0] {
        ONE, TWO, THREE, FOUR, FIVE
    } state_t;
    state_t state, next_state;
    
    // Adder Tree
    logic         [7:0] adder_tree_valid_sr[0:2];
    logic         [2:0] adder_tree_valid_bits;
    logic signed [15:0] adder1_stage1[0:NUM_FILTERS-1][0:14]; // 15 dsp outs
    logic signed [15:0] adder1_stage2[0:NUM_FILTERS-1][0:17]; // 8 adder outs from stage 1 + 10 dsp outs
    logic signed [15:0] adder1_stage3[0:NUM_FILTERS-1][0:8];  // 9 adder outs from stage 2
    logic signed [15:0] adder1_stage4[0:NUM_FILTERS-1][0:4];  // 5 adder outs from stage 3
    logic signed [15:0] adder1_stage5[0:NUM_FILTERS-1][0:2];  // 3 adder outs from stage 4
    logic signed [15:0] adder1_stage6[0:NUM_FILTERS-1][0:1];  // 2 adder outs from stage 5
    logic signed [15:0] adder1_result[0:NUM_FILTERS-1];       // adder tree 1 result
    logic signed [15:0] adder2_stage1[0:NUM_FILTERS-1][0:4];  // 5 dsp outs
    logic signed [15:0] adder2_stage2[0:NUM_FILTERS-1][0:17]; // 3 adder outs from stage 1 + 15 dsp outs
    logic signed [15:0] adder2_stage3[0:NUM_FILTERS-1][0:13]; // 9 adder outs from stage 2 + 5 dsp outs
    logic signed [15:0] adder2_stage4[0:NUM_FILTERS-1][0:6];  // 7 adder outs from stage 3
    logic signed [15:0] adder2_stage5[0:NUM_FILTERS-1][0:3];  // 4 adder outs from stage 4
    logic signed [15:0] adder2_stage6[0:NUM_FILTERS-1][0:1];  // 2 adder outs from stage 5
    logic signed [15:0] adder2_result[0:NUM_FILTERS-1];       // adder tree 2 result
    logic signed [15:0] adder3_stage1[0:NUM_FILTERS-1][0:9];  // 10 dsp outs
    logic signed [15:0] adder3_stage2[0:NUM_FILTERS-1][0:19]; // 5 adder outs from stage 1 + 15 dsp outs
    logic signed [15:0] adder3_stage3[0:NUM_FILTERS-1][0:9];  // 10 adder outs from stage 2
    logic signed [15:0] adder3_stage4[0:NUM_FILTERS-1][0:4];  // 5 adder outs from stage 3
    logic signed [15:0] adder3_stage5[0:NUM_FILTERS-1][0:2];  // 3 adder outs from stage 4
    logic signed [15:0] adder3_stage6[0:NUM_FILTERS-1][0:1];  // 2 adder outs from stage 5
    logic signed [15:0] adder3_result[0:NUM_FILTERS-1];       // adder tree 3 result
    logic signed [15:0] macc_acc[0:NUM_FILTERS-1];
    
    // Flags
    
    // Wires driven by combinatorial logic
    logic macc_en;               // OK
    logic macc_ready;            // OK
    logic next_row;              // OK
    logic consume_features;      // OK
    logic almost_done_consuming; // OK
    
    // Registers set in sequential processes
    logic take_feature;          // OK
    logic process_feature;       // OK
    logic fram_has_been_full;    // OK
    // logic done_receiving;        // unused
    
    // Flags
    always_comb begin
        // Should work, but is there a more optimal starting point?
        almost_done_consuming = fram_col_ctr == (COL_END-1);
        next_row = conv_col_ctr == COL_END && state == FIVE;
        macc_ready = fram_has_been_full;
    end
    
    // Control logic for feature consumption
    always_ff @(posedge i_clk)
        if (i_rst) begin
            consume_features <= 0;
            // done_receiving   <= 0;
        end else begin
            if (next_row)
                consume_features <= 0;
            else if (i_feature_valid &&
                    ((conv_col_ctr == (COL_END-10) && state == FOUR)
                    || ~fram_has_been_full)) consume_features <= 1;
            
            // if (conv_row_ctr == ROW_END) done_receiving <= 1;
        end
    
    always_ff @(posedge i_clk)
        if (i_rst)
            state <= ONE;
        else
            state <= next_state;
    
    always_comb
        case(state)
            ONE: begin
                if (macc_en)
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
    
//    TODO: Syntax simplify
//          for each adder tree
//              set constant where mult out index is for adder stage 1
//                  based on this value, set rest of adder tree mult out connections
//              compute and set adder stage x registers based on adder stage x-1 registers
    // Review: Do we need a reset?
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            adder1_stage1 <= '{default: 0}; 
            adder1_stage2 <= '{default: 0}; 
            adder1_stage3 <= '{default: 0};
            adder1_stage4 <= '{default: 0};
            adder1_stage5 <= '{default: 0};
            adder1_stage6 <= '{default: 0};
            adder1_result <= '{default: 0};
            adder2_stage1 <= '{default: 0};
            adder2_stage2 <= '{default: 0}; 
            adder2_stage3 <= '{default: 0}; 
            adder2_stage4 <= '{default: 0};
            adder2_stage5 <= '{default: 0};
            adder2_stage6 <= '{default: 0};
            adder2_result <= '{default: 0};
            adder3_stage1 <= '{default: 0};
            adder3_stage2 <= '{default: 0}; 
            adder3_stage3 <= '{default: 0};
            adder3_stage4 <= '{default: 0};
            adder3_stage5 <= '{default: 0};
            adder3_stage6 <= '{default: 0};
            adder3_result <= '{default: 0};
        end else begin
            for (int i = 0; i < NUM_FILTERS; i++) begin
                // Adder tree structure 1
                adder1_stage1[i] <= mult_out[i];
                
                adder1_stage2[i][17] <= adder1_stage1[i][14];
                adder1_stage2[i][0:9] <= mult_out[i][0:9];
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
                adder2_stage1[i] <= mult_out[i][10:14];
                
                adder2_stage2[i][17] <= adder2_stage1[i][4];
                adder2_stage2[i][0:14] <= mult_out[i];
                for (int j = 0; j < 2; j++)
                    adder2_stage2[i][j+15] <= adder2_stage1[i][j*2] + adder2_stage1[i][j*2+1];
                
                for (int j = 0; j < 9; j++)
                    adder2_stage3[i][j+5] <= adder2_stage2[i][j*2] + adder2_stage2[i][j*2+1];
                adder2_stage3[i][0:4] <= mult_out[i][0:4];
                
                for (int j = 0; j < 7; j++)
                    adder2_stage4[i][j] <= adder2_stage3[i][j*2] + adder2_stage3[i][j*2+1];
                
                adder2_stage5[i][3] <= adder2_stage4[i][6];
                for (int j = 0; j < 3; j++)
                    adder2_stage5[i][j] <= adder2_stage4[i][j*2] + adder2_stage4[i][j*2+1];
                
                for (int j = 0; j < 2; j++)
                    adder2_stage6[i][j] <= adder2_stage5[i][j*2] + adder2_stage5[i][j*2+1];
                
                adder2_result[i] <= adder2_stage6[i][1] + adder2_stage6[i][0];
                
                // Adder tree structure 3
                adder3_stage1[i][0:9] <= mult_out[i][5:14];
                
                for (int j = 0; j < 5; j++)
                    adder3_stage2[i][j+15] <= adder3_stage1[i][j*2] + adder3_stage1[i][j*2+1];
                adder3_stage2[i][0:14] <= mult_out[i];
                
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
        end
    end
    
    // Group adder tree valid bits into vector
//    always_comb
//        for (int i = 0; i < 3; i++)
//            adder_tree_valid_bits[i] = adder_tree_valid_sr[i][7];
    
    // Set MACC Accumulate based on adder tree valid bit
//    always_comb
//        case(adder_tree_valid_bits)
//            3'b100:  macc_acc = adder1_result;
//            3'b010:  macc_acc = adder2_result;
//            3'b001:  macc_acc = adder3_result;
//            default: macc_acc = adder1_result;
//        endcase
    
    always_comb
        if (adder_tree_valid_sr[0][7])
            macc_acc = adder1_result;
        else if (adder_tree_valid_sr[1][7])
            macc_acc = adder2_result;
        else if (adder_tree_valid_sr[2][7])
            macc_acc = adder3_result;
        else
            macc_acc = adder1_result; // '{default: 0};
    
    // DSP48E1 operands
    always_comb begin
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
            default: begin
                feature_offsets = '{0,0,0};
                weight_offsets  = '{0,0,0};
            end
        endcase
        assign_feature_operands(feature_offsets);
        assign_weight_operands(weight_offsets);
    end
    
    task assign_feature_operands(input int offsets[3]);
        for (int i = 0; i < FILTER_SIZE; i++)
            for (int j = 0; j < 3; j++)
                feature_operands[i][j]
                    = feature_window[i][offsets[j]+2];
    endtask
    
    task assign_weight_operands(input int offsets[3]);
        for (int i = 0; i < NUM_FILTERS; i++)
            for (int j = 0; j < FILTER_SIZE; j++)
                for (int k = 0; k < OFFSET_GRP_SZ; k++)
                    weight_operands[i][j][k]
                        = weights[i][j][k][offsets[k]];
    endtask
    
    always_ff @(posedge i_clk)
        for (int i = 0; i < NUM_FILTERS; i++)
            for (int j = 0; j < FILTER_SIZE; j++)
                for (int k = 0; k < OFFSET_GRP_SZ; k++)
                    mult_out[i][k*5+j]
                        <= weight_operands[i][j][k]
                            * $signed(feature_operands[j][k]);
    
    // Shift adder tree valid signal shift register
    always_ff @(posedge i_clk) begin
        static state_t valid_states[3] = '{ONE, TWO, FOUR};
        for (int i = 0; i < 3; i++)
            adder_tree_valid_sr[i] <=
                {adder_tree_valid_sr[i][6:0],
                 macc_en ? state == valid_states[i]: 1'b0};
    end
    
    
    // Convolution control, counters and enable
    always_ff @(posedge i_clk)
    begin
        if (i_rst) begin
            macc_en      <= 0;
            // conv_row_ctr <= ROW_START;
            conv_col_ctr <= COL_START;
        end else begin
            // Start MACC operations when ready
            if (macc_ready)
                macc_en <= 1;
            
            // Update convolution column counter and
            // shift feature window on predetermined states
            if (state == TWO | state == FOUR | state == FIVE)
            begin
                conv_col_ctr <= conv_col_ctr + 1;
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_window[i] <=
                        {feature_rams[i][conv_col_ctr],
                         feature_window[i][1:4]};
            end
            
            // Update convolution row count
            // Reset column count to column 2
            if (next_row) begin
                // conv_row_ctr <= conv_row_ctr + 1;
                conv_col_ctr <= COL_START;
            end
            
            // Review: We have 2 ports for the feature RAM
            //         (read port and write port)
            //         Does this make it impossible
            //         to synthesize distributed RAM?
            if (next_row | macc_ready)
                feature_window <= next_initial_feature_window;
        end
    end
    
    // Next initial feature window curation
    always_ff @(posedge i_clk)
        if (i_rst)
            next_initial_feature_window <= '{default: 0};
        else
            if (fram_has_been_full)
            begin
                // Input feature fans out to this preloading logic
                // as well as the feature RAM consumption logic
                if (fram_col_ctr <= (COL_START + FILTER_SIZE - 1))
                    next_initial_feature_window[0][fram_col_ctr-2]
                        <= i_feature;
                
                // Align data when the preload block is full
                if (fram_col_ctr == (COL_START + FILTER_SIZE))
                    // Is it possible to implement a column-wise shift operation to shorten this code?
                    for (int i = 0; i < FILTER_SIZE; i++)
                    begin
                        for (int j = 0; j < FILTER_SIZE-1; j++)
                            next_initial_feature_window[j][i]
                                <= next_initial_feature_window[j+1][i];
                        next_initial_feature_window[FILTER_SIZE-1][i]
                            <= next_initial_feature_window[0][i];
                    end
            end
            else
                if (fram_col_ctr <= (COL_START + FILTER_SIZE - 1))
                    next_initial_feature_window
                        [fram_row_ctr][fram_col_ctr-2]
                            <= i_feature;
    
    always_ff @(posedge i_clk)
        if (i_rst) begin
            take_feature       <= 0;
            fram_has_been_full <= 0;
            fram_row_ctr       <= ROW_START;
            fram_col_ctr       <= COL_START;
        end else begin
            process_feature <= take_feature;
            if (consume_features) begin
                // Feature consumption control signal
                // sent to FWFT FIFO read enable port
                take_feature <= 1;
                if (almost_done_consuming)
                    take_feature <= 0;
                
                // Feature RAM filling logic
                if (fram_has_been_full)
                begin
                    if (take_feature)
                        for (int i = 0; i < FILTER_SIZE-1; i++)
                            fram_swap_regs[i]
                                <= feature_rams[i+1][fram_col_ctr];
                    if (process_feature)
                        for (int i = 0; i < FILTER_SIZE-1; i++)
                            feature_rams[i][fram_col_ctr]
                                <= fram_swap_regs[i];
                end
                
                // Consume input feature from FWFT FIFO
                if (process_feature)
                    feature_rams[fram_row_ctr][fram_col_ctr]
                        <= i_feature;
                
                // Feature RAM addr control logic
                fram_col_ctr <= fram_col_ctr + 1;
                if (fram_col_ctr == COL_END) begin
                    fram_col_ctr <= COL_START;
                    if (fram_row_ctr == FILTER_SIZE-1)
                        fram_has_been_full <= 1;
                    else
                        fram_row_ctr <= fram_row_ctr+1;
                end
            end
        end
    
    // assign o_feature_valid = |adder_tree_valid_bits;
    assign o_feature_valid = macc_en &
                             (adder_tree_valid_sr[0][7] |
                              adder_tree_valid_sr[1][7] |
                              adder_tree_valid_sr[2][7]);
    
    assign o_features      = macc_acc;
    assign o_ready_feature = take_feature;

endmodule