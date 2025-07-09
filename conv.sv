`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
/*

    Latency due to Design
        6 filters for conv1, 5x5 filter (25 * ops), 27x27 conv ops (730)
        = 6*(5*5)*(27*27) = 109350 * ops / 90 DSPs = 1215 cycs theoretically
        
    State:         0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14
    
    adder 1-1:    15, 18,  9,  5,  3,  2,  1
    adder 2-1:         5, 18, 14,  7,  4,  2,  1
    adder 3-1:                10, 20, 10,  5,  3,  2,  1
    
    adder 1-2:                        15, 18,  9,  5,  3,  2,  1
    adder 2-2:                             5, 18, 14,  7,  4,  2,  1
    adder 3-2:                                    10, 20, 10,  5,  3,  2,  1
    
    TODO: Get outputs of DSP48s to carry chain resources efficiently
          Should we implement some of the adder tree in the DSPs?
    
    
    
    
    Verify control logic
    
    Registering vs combinatorial naming of
    - feature_operands/weight_operands
    Logic mapping
    - feature_rams, feature_window, next_initial_feature_window, fram_swap_regs
    
    feature_window is 5x5
    feature_window is the data which feeds feature_operands,
    feature_window gets set with next_initial_feature_window,
        and then feature_rams_data is shifted into the
        right-most column throughout the feature row
    
    next_initial_feature_window is 5x5
    next_initial_feature_window is set with input features at the start,
        then throughout the convolutions gets shifted down, input features
        are shifted into the bottom row of next_initial_feature_window
    
    feature_rams is 32x5
    feature_rams first two and last two columns are zero-padded so non-zero
        data dimensions is 28x5, first two and last two feature map rows are zeros
    feature_rams is the data which feeds feature_window by shifting in data in each 5 rows
    feature_rams data is written directly by input features
    feature_rams data is shifted down via swap register logic
    Read/Write logic currently
        - Read for 3 out of 5 states by feature_window
        - Read for 28/46 cycles by swap registers
        - Write for 28/46 cycles by swap registers or input feature
            (bottom row is written by input feature, top 4 rows
                written by swap registers. For until the feature RAMs
                    have been full, all locations are written by input features)
        The question is, can we combine the 2 reads into a single read?
            If so, we can synthesize distributed RAM
            
            We can't do this simply with distributed RAM as the reads are not
                from the same addresses, so we need to get creative.
                
                Option 1: Use 2x clock domain for reads so we can read twice per
                    system clock tick
                Option 2: Use BRAM with wide data bus so we can effectively read multiple
                    values within a single clock cycle. This might mean we need to arrange
                        the data so that data is stored in columns, or maybe in wider groups
                            like groups of 5 or 6 features or something. It might make sense to store
                                the data as 32 5x8 feature columns. 
    
    
    
    Why is the DSP48E1 connectivity so unclean, all A pins connected to same LUT O6?
    
    Could try some hacky tricks with DSP operands like using 3 input bytes for 
        the DSPs, and for MSBytes just shift output back to correct value
    
    Also may need to get hacky with the feature RAMs and have wider outputs so we can
        effectively read 2 bytes per read cycle
            The way to do it, is to not just inhale features every cycle for 28 cycles
                straight, but to consume an input feature on the same states as
                    when feature RAM data is read and shifted into feature_window.
                        Then we would have a read/write happening each of the
                            3 out of 5 states. The read fans out to feature_window
                                and swap registers. The write data is routed from
                                    swap registers for 4 of the rows and input
                                        feature for 1 row.
                        

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
    
    // Weight ROMs
    // 90 distributed RAMs -> 1 per DSP48E1
    // 8-bit signed data x 6 filters x 5 rows x 3 columns x 5 deep
    // Overall there is 90x5 = 90 8x8-bit Distributed RAMs
    // One SLICEM can implement 4 8x8-bit Distruibuted RAMs
    // Hence, 23 slices (12 CLBs) will be used for the weight RAMs
    
    // Initialize trainable parameters
    // Weights
    // (* rom_style = "distributed" *)
    // logic signed [7:0] raw_weights [0:NUM_DSP48E1*WEIGHT_ROM_DEPTH-1];
    // initial $readmemb(WEIGHTS_FILE, raw_weights);
    
    (* ram_style = "distributed" *) logic signed [7:0] weights[0:NUM_FILTERS-1][0:FILTER_SIZE-1][0:OFFSET_GRP_SZ-1][0:WEIGHT_ROM_DEPTH-1];
    
    // integer raw_idx;
    // initial begin
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

    // Hardcoded initialization of Distributed RAM weights
    initial begin
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
    
    // Feature RAM line buffers -> try to synthesize block RAMs
    logic [7:0] feature_rams[0:FILTER_SIZE-1][0:INPUT_WIDTH-1]                = '{default: 0};
    
    // The actual feature window to be multiplied by the filter kernel
    logic [7:0] feature_window[0:FILTER_SIZE-1][0:FILTER_SIZE-1]              = '{default: 0};
    
    // We buffer the initial feature window of the next row
    // It loads during convolution operation of the preceeding row
    logic [7:0] next_initial_feature_window[0:FILTER_SIZE-1][0:FILTER_SIZE-1] = '{default: 0};
    
    // Registers to hold temporary feature RAM data
    // as part of the input feature consumption logic
    logic signed [7:0] fram_swap_regs[0:FILTER_SIZE-2]                        = '{default: 0};
    
    // Signals holding the DSP48E1 operands, used for readability
    logic signed [7:0] feature_operands[0:FILTER_SIZE-1][0:OFFSET_GRP_SZ-1];
    logic signed [7:0] weight_operands[0:NUM_FILTERS-1][0:FILTER_SIZE-1][0:OFFSET_GRP_SZ-1];
    
    // All 90 DSP48E1 registers (macro is fully pipelined)
    (* use_dsp = "yes" *)
    logic signed [7:0] dsp_a1[0:NUM_FILTERS-1][0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    (* use_dsp = "yes" *)
    logic signed [7:0] dsp_b1[0:NUM_FILTERS-1][0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    (* use_dsp = "yes" *)
    logic signed [7:0] dsp_a2[0:NUM_FILTERS-1][0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    (* use_dsp = "yes" *)
    logic signed [7:0] dsp_b2[0:NUM_FILTERS-1][0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    (* use_dsp = "yes" *)
    logic signed [7:0] dsp_m[0:NUM_FILTERS-1][0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    (* use_dsp = "yes" *)
    logic signed [7:0] dsp_p[0:NUM_FILTERS-1][0:FILTER_SIZE*OFFSET_GRP_SZ-1];
    
    // Feature RAM location
    logic [$clog2(FILTER_SIZE)-1:0] fram_row_ctr;
    logic [$clog2(COL_END)-1:0]     fram_col_ctr;
    
    // Convolution Feature location
    logic [$clog2(ROW_END)-1:0] conv_row_ctr;
    logic [$clog2(COL_END)-1:0] conv_col_ctr;
    
    // Registered flags
    logic macc_en;               // can enable sooner?
    logic consume_features;      // OK
    logic fram_has_been_full;    // OK
    logic take_feature_d0, take_feature_d1;
    
    // Convolution FSM, controls DSP48E1 time multiplexing,
    // and convolution feature counters
    typedef enum logic [2:0] {
        ONE, TWO, THREE, FOUR, FIVE
    } state_t;
    state_t state, next_state;
    
    // Adder Tree
    logic [7:0] adder_tree_valid_sr[0:2];
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
    
    // Control logic for feature consumption
    always_ff @(posedge i_clk)
        if (i_rst) begin
            consume_features <= 0;
        end else begin
            if (conv_col_ctr == (9) && state == FOUR)
                consume_features <= 0;
            else if (i_feature_valid &&
                    (
                        (conv_col_ctr == (19) && state == FIVE) ||
                        ~fram_has_been_full
                    ))
            begin
                consume_features <= 1;
            end
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
    end
    
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
                begin
                    dsp_a1[i][OFFSET_GRP_SZ*j+k] <= weight_operands[i][j][k];
                    dsp_b1[i][OFFSET_GRP_SZ*j+k] <= feature_operands[j][k];
                    dsp_a2[i][OFFSET_GRP_SZ*j+k] <= dsp_a1[i][OFFSET_GRP_SZ*j+k];
                    dsp_b2[i][OFFSET_GRP_SZ*j+k] <= dsp_b1[i][OFFSET_GRP_SZ*j+k];
                    dsp_m [i][OFFSET_GRP_SZ*j+k] <= dsp_a2[i][OFFSET_GRP_SZ*j+k] * dsp_b2[i][OFFSET_GRP_SZ*j+k];
                    dsp_p [i][OFFSET_GRP_SZ*j+k] <= dsp_m [i][OFFSET_GRP_SZ*j+k];
                end
    
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
            macc_en        <= 0;
            conv_row_ctr   <= ROW_START;
            conv_col_ctr   <= COL_START;
        end else begin
            // Start MACC operations when ready
            if (fram_has_been_full)
                macc_en <= 1;
            
            // Update convolution column counter and shift feature window on predetermined states,
            // this is a column-wise shift, the entire right-most column shifts in feature_rams data
            if (state == TWO | state == FOUR | state == FIVE)
            begin
                conv_col_ctr <= conv_col_ctr + 1;
                // Shift to the right, but logically this is a left-shift
                // Perform the shift for all 5 rows of feature_window
                // [a,b,c,d,e] << [f,g,h...] = [b,c,d,e,f] 
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_window[i] <= {feature_rams[i][conv_col_ctr], feature_window[i][1:4]};
            end
            
            // Update convolution row count
            // Reset column count to column 2
            if (conv_col_ctr == COL_END && state == FIVE) begin
                conv_row_ctr <= conv_row_ctr + 1;
                conv_col_ctr <= COL_START;
            end
            
            // Review: We have 2 ports for the feature RAM (read port and write port)
            //         Does this make it impossible to synthesize distributed RAM?
            if ((conv_col_ctr == COL_END && state == FIVE) | (fram_has_been_full & ~macc_en))
                feature_window <= next_initial_feature_window;
        end
    end
    
    // Next initial feature window curation
    // TODO: Really need to study the hardware implementation of this logic
    //       Seems to be come bugs with the way next_initial_feature_window is initially set
    always_ff @(posedge i_clk)
        if (i_rst)
            // TODO: Not all values need to be reset, but for simplicity we'll keep the reset on all 5x5 values
            next_initial_feature_window <= '{default: 0};
        else
            if (fram_has_been_full) begin
                // Input feature fans out to this preloading logic
                // as well as the feature RAM consumption logic
                if (fram_col_ctr <= (COL_START + FILTER_SIZE - 1))
                    next_initial_feature_window[0][fram_col_ctr-2] <= i_feature;
                
                // Align data when the preload block is full
                if (fram_col_ctr == (COL_START + FILTER_SIZE))
                    // Is it possible to implement a column-wise shift operation to shorten this code?
                    for (int i = 0; i < FILTER_SIZE; i++) begin
                        for (int j = 0; j < FILTER_SIZE-1; j++)
                            next_initial_feature_window[j][i] <= next_initial_feature_window[j+1][i];
                        next_initial_feature_window[FILTER_SIZE-1][i] <= next_initial_feature_window[0][i];
                    end
            end else
                if (fram_col_ctr <= (COL_START + FILTER_SIZE - 1))
                    next_initial_feature_window[fram_row_ctr][fram_col_ctr-2] <= i_feature;
    
    always_ff @(posedge i_clk)
        if (i_rst) begin
            take_feature_d0    <= 0;
            fram_has_been_full <= 0;
            fram_row_ctr       <= ROW_START;
            fram_col_ctr       <= COL_START;
        end else begin
            take_feature_d1 <= take_feature_d0;
            
            if (consume_features) begin
                // Feature consumption control signal
                // sent to FWFT FIFO read enable port
                take_feature_d0 <= 1;
                
                if ((conv_col_ctr == (9) && state == THREE) | (conv_col_ctr == (9) && state == FOUR))
                    take_feature_d0 <= 0;
                
                // Feature RAM filling logic
                if (fram_has_been_full) begin
                    for (int i = 0; i < FILTER_SIZE-1; i++) begin
                        if (take_feature_d0)
                            fram_swap_regs[i] <= feature_rams[i+1][fram_col_ctr];
                            
                        if (take_feature_d1)
                            feature_rams[i][fram_col_ctr] <= fram_swap_regs[i];
                    end
                
                // feature RAM is set with 2 different values at potentially different
                // addresses in the same clock cycle? So this already uses 2 true dual
                // ports. If there is another read in the same cycle then this data
                // cant be used in BRAM or distributed RAM, and probably will cause
                // fabric FFs to be inferred
                
                // Consume input feature from input image pixel data FIFO
                if (take_feature_d1)
                    feature_rams[fram_row_ctr][fram_col_ctr] <= i_feature;
                
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
    
    // 3:1 8-bit mux for conv block output data port register
    always_ff @(posedge i_clk)
        if (adder_tree_valid_sr[0][7])
            selected_tree_result <= adder1_result;
        else if (adder_tree_valid_sr[1][7])
            selected_tree_result <= adder2_result;
        else if (adder_tree_valid_sr[2][7])
            selected_tree_result <= adder3_result;
    
    // Registering output data/control signals
    always_comb
    begin
        o_feature_valid <= adder_tree_valid_sr[0][7] |
                           adder_tree_valid_sr[1][7] |
                           adder_tree_valid_sr[2][7];
        o_features      <= selected_tree_result;
        o_ready_feature <= take_feature_d0;
    end
    
endmodule