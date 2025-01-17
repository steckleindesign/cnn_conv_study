`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
/*

    Architecture:
        Overview:
            Utilize 90 DSPs for convolution
            Complete 3 convolutions in 5 clock cycles
            We will skip the last convolution (output feature) for each row
            There will be 27 convolutions (output features) in each row
            This will take (27/3)*5 = 45 clock cycles per row
            We will sequentially execute convolution operation on 27 rows
            For each row, convolve left to right, from output feature 0-26
        Start
            Wait until line buffer is full to enable convolution operation
        End of row (After each row convolution operation if finished):
            Increment feature row count
            Shift line buffer down
            reset the line buffer full flag
        
        90 DSPs, 50 BRAMS (36Kb each)
        6 filters for conv1, 5x5 filter (25 * ops), 27x27 conv ops (730)
        = 6*(5*5)*(27*27) = 109350 * ops / 90 DSPs = 1215 cycs theoretically
        
        Study how to get outputs of DSP48s to carry chain resources efficiently
        
        State:        0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14
        
        adder 1-1:    15, 18,  9,  5,  3,  2,  1
        adder 2-1:        5,  18, 14,  7,  4,  2,  1
        adder 3-1:                10, 20, 10,  5,  3,  2,  1
        
        adder 1-2:                        15, 18,  9,  5,  3,  2,  1
        adder 2-2:                            5,  18, 14,  7,  4,  2,  1
        adder 3-2:                                    10, 20, 10,  5,  3,  2,  1
*/
//////////////////////////////////////////////////////////////////////////////////

/*
TODO: Determine proper bitwidths for adder stages, keeping data to 16 bits
      Async reset? or sync and see if its used as 6th LUT input (1 sel, 2x 2:1 mux inputs)
*/

module conv #( parameter NUM_FILTERS = 6 ) (
    input  logic               i_clk,
    input  logic               i_rst,
    input  logic               i_feature_valid,
    input  logic         [7:0] i_feature,
    output logic               o_feature_valid,
    output logic signed [15:0] o_features[0:NUM_FILTERS-1],
    output logic               o_buffer_full
);

    // Hardcode frame dimensions in local params
    localparam string WEIGHTS_FILE  = "weights.mem";
    localparam string BIASES_FILE   = "biases.mem";
    localparam        INPUT_WIDTH   = 31;
    localparam        INPUT_HEIGHT  = 31;
    localparam        FILTER_SIZE   = 5;
    localparam        OUTPUT_HEIGHT = 27;
    localparam        OUTPUT_WIDTH  = 27;
    localparam        ROW_START     = 2;
    localparam        ROW_END       = 29;
    localparam        COL_START     = 2;
    localparam        COL_END       = 29;
    
    // Initialize trainable parameters
    // Weights
    (* rom_style = "block" *) logic signed [15:0]
    weights [0:NUM_FILTERS-1][0:FILTER_SIZE-1][0:FILTER_SIZE-1];
    initial $readmemb(WEIGHTS_FILE, weights);
    // Biases
    (* rom_style = "block" *) logic signed [15:0]
    biases [0:NUM_FILTERS-1];
    initial $readmemb(BIASES_FILE, biases);
    
    // Weight ROMs
    // 90 distributed RAMs -> 1 per DSP48E1
    // 16-bit signed data x 6 filters x 5 rows x 3 columns x 5 deep
    // Overall there is 90x5 = 90 8x16-bit Distributed RAMs
    // 1 SLICEM can implement 2 8x16-bit Distruibuted RAMs
    // Hence, 45 slices will be used for the weight RAMs
    // Which syntax is standard/better/preferred?
    // logic signed [15:0] weights [0:5][0:4][0:2][0:4];
    logic signed [15:0] weights [NUM_FILTERS][5][3][5];
    
    logic         [7:0] feature_rams [FILTER_SIZE][INPUT_WIDTH];
        
    logic         [7:0] feature_window [5][5];
    logic         [7:0] next_row_features [5][5];
    
    typedef enum logic [2:0] {
        IDLE, FILL, SHIFT
    } preload_state_t;
    preload_state_t preload_state, preload_next_state;
    
    logic         [2:0] preload_addr;
        
    logic         [7:0] line_buffer[0:FILTER_SIZE][0:INPUT_WIDTH-1];
    logic         [7:0] feature_operands[0:FILTER_SIZE-1][0:2];
    logic signed [15:0] weight_operands[0:NUM_FILTERS-1][0:FILTER_SIZE-1][0:2];
    
    // Line buffer location
    logic [$clog2(ROW_END)-1:0] lb_row_ctr;
    logic [$clog2(COL_END)-1:0] lb_col_ctr;
    // Feature conv location
    logic [$clog2(ROW_END)-1:0] feat_row_ctr;
    logic [$clog2(COL_END)-1:0] feat_col_ctr;
    
    // Flags
    logic macc_en;
    logic macc_ready;
    logic lb_full;
    logic next_row;
    logic consume_features;
    logic fill_next_start;
    
    // Adder Tree
    logic         [6:0] adder_tree_valid_sr[2:0];
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
    
    // TODO: Flatten
    logic signed [15:0] mult_out[0:NUM_FILTERS-1][0:FILTER_SIZE*3-1];
    
    typedef enum logic [2:0] {
        ONE, TWO, THREE, FOUR, FIVE
    } state_t;
    state_t state, next_state;
    
    always_ff @(posedge i_clk)
        if (i_rst)
            state <= ONE;
        else
            state <= next_state;
    
    always_comb
        if (macc_en)
            case(state)
                ONE:
                    next_state = TWO;
                    // 15 -> adder tree 1
                TWO:
                    next_state = THREE;
                    // 10 -> adder tree 1,
                    // 5  -> adder tree 2
                THREE:
                    next_state = FOUR;
                    // 15 -> adder tree 2
                FOUR:
                    next_state = FIVE;
                    // 5  -> adder tree 2
                    // 10 -> adder tree 3
                FIVE:
                    next_state = ONE;
                    // 15 -> adder tree 3
               default: next_state = next_state;
            endcase
        else
            next_state = ONE;
    
    always_ff @(posedge i_clk)
    begin
        // Check synthesis/implementation and verify reset is a free signal here
        // regarding the 2:1 mux LUTs, I expect its the 6th input to the LUTs
        if (i_rst) begin
            for (int i = 0; i < FILTER_SIZE; i++) begin
                for (int j = 0; j < FILTER_SIZE; j++) begin
                    feature_window[i][j]    <= 0;
                    next_row_features[i][j] <= 0;
                end
            end
        end else if (next_row) begin
            for (int i = 0; i < FILTER_SIZE; i++) begin
                for (int j = 0; j < FILTER_SIZE; j++) begin
                    feature_window[i][j] <= next_row_features[i][j] <= 0;
                end
            end
        end else begin
            for (int i = 0; i < FILTER_SIZE; i++) begin
                for (int j = 0; j < FILTER_SIZE-1; j++) begin
                    feature_window[i][j] <= feature_window[i][j+1];
                end
                feature_window[i][FILTER_SIZE-1] <= feature_rams[i][feat_col_ctr];
            end
        end
    end
    
    always_ff @(posedge i_clk)
        if (i_rst)
            preload_state <= IDLE;
        else
            preload_state <= preload_next_state;
    
    always_comb begin
        case(preload_state)
            IDLE: begin
                if (fill_next_start) preload_next_state = FILL;
            end
            FILL: begin
                if (preload_addr[2]) preload_next_state = SHIFT;
            end
            SHIFT: begin
                preload_next_state = IDLE;
            end
        endcase
    end
    
    /*
    5x5 Feature window
    
    [x]  [x]  [x]  [x]  [x]
    [x]  [x]  [x]  [x]  [x]
    [x]  [x]  [x]  [x]  [x]
    [x]  [x]  [x]  [x]  [x]
    [x]  [x]  [x]  [x]  [x]
    
    Input of each value "x" is output of 16-bit wide 2:1 MUX
    
    The inputs of the 2:1 MUX for the first 4 columns:
        1. output of register in next column
        2. output of corresponding feature in next_row_features block
    
    The inputs of the 2:1 MUX for the last column:
        1. output of feature RAM
        2. output of corresponding feature in next_row_features block
    */
    
    always_ff @(posedge i_clk)
    begin
        case(preload_state)
            IDLE: begin
                preload_addr <= 3'b0;
            end
            FILL: begin
                // Logic here depends on implementation of feature RAM filling
                // Will the data arriving into the feature RAMs fill the row 0 RAM?
                // Or will the RAM values be shifted as incoming data populates the RAM,
                // and therefore the features needed for the preload feature block will
                // Already be in the bottom row RAM, which is the correct order for the features
                // If the former, will need to make sure to shift up the values in RAM
                // before the next row of convolutions
                next_row_features[0][preload_addr] <= feature_rams[FILTER_SIZE-1][preload_addr];
                preload_addr <= preload_addr + 1;
            end
            SHIFT: begin
                for (int i = 0; i < FILTER_SIZE; i++) begin
                    for (int j = 0; j < FILTER_SIZE-1; j++) begin
                        next_row_features[j][i] <= next_row_features[j+1][i];
                    end
                    next_row_features[FILTER_SIZE-1][i] <= next_row_features[0][i];
                end
            end
            // Do we need a default if we don't use all cases?
        endcase
    end
    
    // TODO: try to really understand clock enables vs. gating vs. if the macc_en is just treated as a logic variable
    // Discover: Do we need to gate adder arithmetic?
    //           Or will having the valid out signal gate the adder logic
    //           and synthesize time multiplexing of carry chain logic?
    // Use function and/or task to simplify this logic, its especially long
    // for the full LeNet-5 implementation amongst other larger adder trees
    always_ff @(posedge i_clk) begin
        if (macc_en) begin
            for (int i = 0; i < NUM_FILTERS; i++) begin
                // Adder tree structure 1
                adder1_stage1[i][10:14] <= mult_out[i][10:14];
                adder1_stage1[i][5:9]   <= mult_out[i][5:9];
                adder1_stage1[i][0:4]   <= mult_out[i][0:4];
                
                adder1_stage2[i][17]    <= adder1_stage1[i][15];
                for (int j = 0; j < 7; j++)
                    adder1_stage2[i][10+j] <= adder1_stage1[i][j*2] + adder1_stage1[i][j*2+1];
                adder1_stage2[i][5:9]   <= mult_out[i][5:9];
                adder1_stage2[i][0:4]   <= mult_out[i][0:4];
                
                for (int j = 0; j < 9; j++)
                    adder1_stage3[i][j] <= adder1_stage2[i][j*2] + adder1_stage2[i][j*2+1];
                
                // Can stage 4 5th reg just directly be connected to stage 6 1st reg?
                adder1_stage4[i][4]     <= adder1_stage3[i][8];
                for (int j = 0; j < 4; j++)
                    adder1_stage4[i][j] <= adder1_stage3[i][j*2] + adder1_stage3[i][j*2+1];
                
                adder1_stage5[i][2]     <= adder1_stage4[i][4];
                for (int j = 0; j < 2; j++)
                    adder1_stage5[i][j] <= adder1_stage4[i][j*2] + adder1_stage4[i][j*2+1];
                
                adder1_stage6[i][1]     <= adder1_stage5[i][2];
                adder1_stage6[i][0]     <= adder1_stage5[i][0] + adder1_stage5[i][1];
                
                adder1_result[i]        <= adder1_stage6[i][1] + adder1_stage6[i][0];
                
                // Adder tree structure 2
                adder2_stage1[i]        <= mult_out[i][10:14];
                
                adder2_stage2[i][17]    <= adder2_stage1[i][4];
                for (int j = 0; j < 2; j++)
                    adder2_stage2[i][j] <= adder2_stage1[i][j*2] + adder2_stage1[i][j*2+1];
                adder2_stage2[i][14:10] <= mult_out[i][10:14];
                adder2_stage2[i][9:5]   <= mult_out[i][5:9];
                adder2_stage2[i][4:0]   <= mult_out[i][0:4];
                
                for (int j = 0; j < 9; j++)
                    adder2_stage3[i][j+5] <= adder2_stage2[i][j*2] + adder2_stage2[i][j*2+1];
                adder2_stage3[i][4:0]   <= mult_out[i][0:4];
                
                for (int j = 0; j < 7; j++)
                    adder2_stage4[i][j+5] <= adder2_stage3[i][j*2] + adder2_stage3[i][j*2+1];
                
                adder2_stage5[i][3]     <= adder2_stage4[i][6];
                for (int j = 0; j < 3; j++)
                    adder2_stage5[i][j] <= adder2_stage4[i][j*2] + adder2_stage4[i][j*2+1];
                
                for (int j = 0; j < 2; j++)
                    adder2_stage6[i][j+5] <= adder2_stage5[i][j*2] + adder2_stage5[i][j*2+1];
                
                adder2_result[i]        <= adder2_stage6[i][1] + adder2_stage6[i][0];
                
                // Adder tree structure 3
                adder3_stage1[i][9:5]   <= mult_out[i][10:14];
                adder3_stage1[i][4:0]   <= mult_out[i][5:9];
                
                for (int j = 0; j < 5; j++)
                    adder3_stage2[i][j+15] <= adder3_stage1[i][j*2] + adder3_stage1[i][j*2+1];
                adder3_stage2[i][14:10] <= mult_out[i][10:14];
                adder3_stage2[i][9:5]   <= mult_out[i][5:9];
                adder3_stage2[i][4:0]   <= mult_out[i][0:4];
                
                for (int j = 0; j < 10; j++)
                    adder3_stage3[i][j] <= adder3_stage2[i][j*2] + adder3_stage2[i][j*2+1];
                
                for (int j = 0; j < 5; j++)
                    adder3_stage4[i][j] <= adder3_stage3[i][j*2] + adder3_stage3[i][j*2+1];
                
                adder3_stage5[i][2] <= adder3_stage4[i][4];
                for (int j = 0; j < 2; j++)
                    adder3_stage5[i][j] <= adder3_stage4[i][j*2] + adder3_stage4[i][j*2+1];
                
                adder3_stage6[i][1]     <= adder3_stage5[i][2];
                adder3_stage6[i][0]     <= adder3_stage5[i][0] + adder3_stage5[i][1];
                
                adder3_result[i]        <= adder3_stage6[i][1] + adder3_stage6[i][0];
            end
        end
    end
    
    always_comb
        // Would casex block be better here?
        if (adder_tree_valid_sr[0][6])
            macc_acc = adder1_result;
        else if (adder_tree_valid_sr[1][6])
            macc_acc = adder2_result;
        else if (adder_tree_valid_sr[2][6])
            macc_acc = adder3_result;
        else
            macc_acc = macc_acc;
    
    always_ff @(posedge i_clk)
        for (int i = 0; i < NUM_FILTERS; i++)
            for (int j = 0; j < 5; j++)
                for (int k = 0; k < 3; k++)
                    mult_out[i][k*5+j] <= weight_operands[i][j][k] * feature_operands[j][k];
    
    // DSP48E1 operands - simplify this
    always_comb begin
        case(state)
            ONE: begin
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][0] = line_buffer[i][feat_col_ctr-2];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][0] = weights[i][j][0];
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][1] = line_buffer[i][feat_col_ctr-1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][1] = weights[i][j][1];
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][2] = line_buffer[i][feat_col_ctr];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][2] = weights[i][j][2];
            end
            TWO: begin
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][0] = line_buffer[i][feat_col_ctr+1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][0] = weights[i][j][3];
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][1] = line_buffer[i][feat_col_ctr+2];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][1] = weights[i][j][4];
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][2] = line_buffer[i][feat_col_ctr-1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][2] = weights[i][j][0];
            end
            THREE: begin
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][0] = line_buffer[i][feat_col_ctr-1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][0] = weights[i][j][1];
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][1] = line_buffer[i][feat_col_ctr];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][1] = weights[i][j][2];
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][2] = line_buffer[i][feat_col_ctr+1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][2] = weights[i][j][3];
            end
            FOUR: begin
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][0] = line_buffer[i][feat_col_ctr+2];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][0] = weights[i][j][4];
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][1] = line_buffer[i][feat_col_ctr-1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][1] = weights[i][j][0];
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][2] = line_buffer[i][feat_col_ctr];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][2] = weights[i][j][1];
            end
            FIVE: begin
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][0] = line_buffer[i][feat_col_ctr];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][0] = weights[i][j][2];
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][1] = line_buffer[i][feat_col_ctr+1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][1] = weights[i][j][3];
                for (int i = 0; i < FILTER_SIZE; i++)
                    feature_operands[i][2] = line_buffer[i][feat_col_ctr+2];
                for (int i = 0; i < NUM_FILTERS; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        weight_operands[i][j][2] = weights[i][j][4];
            end
        endcase
    end
    
    always_ff @(posedge i_clk)
        if (macc_en) begin
            case(state)
                ONE: begin
                    // 15 -> adder tree 1
                end
                TWO: begin
                    // 10 -> adder tree 1,
                    // 5  -> adder tree 2
                    feat_col_ctr <= feat_col_ctr + 1;
                end
                THREE: begin
                    // 15 -> adder tree 2
                end
                FOUR: begin
                    // 5  -> adder tree 2
                    // 10 -> adder tree 3
                    feat_col_ctr <= feat_col_ctr + 1;
                end
                FIVE: begin
                    // 15 -> adder tree 3
                    feat_col_ctr <= feat_col_ctr + 1;
                end
            endcase
            adder_tree_valid_sr[0] <= { adder_tree_valid_sr[0][5:0], state == ONE  };
            adder_tree_valid_sr[1] <= { adder_tree_valid_sr[1][5:0], state == TWO  };
            adder_tree_valid_sr[2] <= { adder_tree_valid_sr[2][5:0], state == FOUR };
        end
     
    // Flags
    always_comb begin
        next_row         = feat_col_ctr == COL_END-1 && state == FIVE;
        consume_features = feat_col_ctr == COL_START+10 && state == THREE;
        // Can start filling next preload block 5 cycles after new row
        // of features are consumed. It doesn't have to be exactly 5 cycles later,
        // but the next start values need to be preloaded before the next row of convolutions begin
        fill_next_start  = feat_col_ctr == COL_START+11 && state == THREE;
        // TODO: Review full flag, is it right to set the flag at an almost full state?
        lb_full          = lb_row_ctr == FILTER_SIZE && lb_col_ctr == COL_END-2;
        macc_ready       = lb_row_ctr == FILTER_SIZE-1 && lb_col_ctr == COL_START+FILTER_SIZE;
    end
    
    always_ff @(posedge i_clk)
        if (i_rst) begin
            macc_en             <= 0;
            feat_row_ctr        <= ROW_START;
            feat_col_ctr        <= COL_START;
            adder_tree_valid_sr <= '{default: 0};
        end else begin
            // Enable MACC operations when feature RAMs are full enough
            // for the first convolution window/kernel operation
            if (macc_ready)
                macc_en <= 1;
            if (next_row) begin
                feat_row_ctr <= feat_row_ctr + 1;
                feat_col_ctr <= COL_START;
            end
        end
    
    always_ff @(posedge i_clk)
        if (i_rst) begin
            lb_row_ctr <= ROW_START;
            lb_col_ctr <= COL_START;
        end else
            if (i_feature_valid) begin
                lb_col_ctr <= lb_col_ctr + 1;
                if (lb_col_ctr == COL_END-1) begin
                    lb_col_ctr <= COL_START;
                    lb_row_ctr <= lb_row_ctr + 1;
                end
                line_buffer[lb_row_ctr][lb_col_ctr] <= i_feature;
            end else if (next_row) begin
                for (int i = 2; i < COL_END; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        line_buffer[j][i] <= line_buffer[j+1][i];
                lb_col_ctr <= COL_START;
            end
    
    always_comb
        for (int i = 0; i < NUM_FILTERS; i++)
            o_features[i] = macc_acc[i];
    
    assign o_buffer_full   = lb_full;
    assign o_feature_valid = adder_tree_valid_sr[0][6] ||
                             adder_tree_valid_sr[1][6] ||
                             adder_tree_valid_sr[2][6];

endmodule