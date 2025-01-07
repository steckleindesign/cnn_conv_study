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
      Async reset
      
*/

module conv #( parameter NUM_FILTERS = 6 ) (
    input  logic               i_clk,
    input  logic               i_rst,
    input  logic               i_feature_valid,
    input  logic         [7:0] i_feature,
    output logic               o_feature_valid,
    output logic signed [15:0] o_features[NUM_FILTERS-1:0],
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
    weights [NUM_FILTERS-1:0][FILTER_SIZE-1:0][FILTER_SIZE-1:0];
    initial $readmemb(WEIGHTS_FILE, weights);
    // Biases
    (* rom_style = "block" *) logic signed [15:0]
    biases [NUM_FILTERS-1:0];
    initial $readmemb(BIASES_FILE, biases);

    // For height=5 filter, we only need to store 4 rows of pixel data
    // For now we will starting MACC operations once line buffer is full
    // Also we will use a line buffer with FILTER_SIZE rows, 5 rows in our case
    // Again, we are not using the last 2 columns in this iteration (all 0's so its viable)
    // For first synthesis effort, using FILTER_SIZE+1 rows, no need for input feature
    // to be used in the logic, and for now we are not worried about memory
    logic         [7:0] line_buffer[FILTER_SIZE:0][INPUT_WIDTH-1:0];
    // Indexed features to be used for * operation
    logic         [7:0] feature_operands[FILTER_SIZE-1:0][2:0];
    logic signed  [7:0] weight_operands[NUM_FILTERS-1:0][FILTER_SIZE-1:0][2:0];
    
    // Line buffer location
    logic [$clog2(ROW_END)-1:0] lb_row_ctr;
    logic [$clog2(COL_END)-1:0] lb_col_ctr;
    // Feature conv location
    logic [$clog2(ROW_END)-1:0] feat_row_ctr;
    logic [$clog2(COL_END)-1:0] feat_col_ctr;
    
    logic               macc_en;
    logic               macc_ready;
    logic               lb_full;
    logic               next_row;
    logic         [6:0] adder_tree_valid_sr[2:0];
    logic signed [23:0] adder1_stage1[NUM_FILTERS-1:0][14:0]; // 15 dsp outs
    logic signed [23:0] adder1_stage2[NUM_FILTERS-1:0][17:0]; // 8 adder outs from stage 1 + 10 dsp outs
    logic signed [23:0] adder1_stage3[NUM_FILTERS-1:0][8:0];  // 9 adder outs from stage 2
    logic signed [23:0] adder1_stage4[NUM_FILTERS-1:0][4:0];  // 5 adder outs from stage 3
    logic signed [23:0] adder1_stage5[NUM_FILTERS-1:0][2:0];  // 3 adder outs from stage 4
    logic signed [23:0] adder1_stage6[NUM_FILTERS-1:0][1:0];  // 2 adder outs from stage 5
    logic signed [23:0] adder1_result[NUM_FILTERS-1:0];       // adder tree 1 result
    logic signed [23:0] adder2_stage1[NUM_FILTERS-1:0][4:0];  // 5 dsp outs
    logic signed [23:0] adder2_stage2[NUM_FILTERS-1:0][17:0]; // 3 adder outs from stage 1 + 15 dsp outs
    logic signed [23:0] adder2_stage3[NUM_FILTERS-1:0][13:0]; // 9 adder outs from stage 2 + 5 dsp outs
    logic signed [23:0] adder2_stage4[NUM_FILTERS-1:0][6:0];  // 7 adder outs from stage 3
    logic signed [23:0] adder2_stage5[NUM_FILTERS-1:0][3:0];  // 4 adder outs from stage 4
    logic signed [23:0] adder2_stage6[NUM_FILTERS-1:0][1:0];  // 2 adder outs from stage 5
    logic signed [23:0] adder2_result[NUM_FILTERS-1:0];       // adder tree 2 result
    logic signed [23:0] adder3_stage1[NUM_FILTERS-1:0][9:0];  // 10 dsp outs
    logic signed [23:0] adder3_stage2[NUM_FILTERS-1:0][19:0]; // 5 adder outs from stage 1 + 15 dsp outs
    logic signed [23:0] adder3_stage3[NUM_FILTERS-1:0][9:0];  // 10 adder outs from stage 2
    logic signed [23:0] adder3_stage4[NUM_FILTERS-1:0][4:0];  // 5 adder outs from stage 3
    logic signed [23:0] adder3_stage5[NUM_FILTERS-1:0][2:0];  // 3 adder outs from stage 4
    logic signed [23:0] adder3_stage6[NUM_FILTERS-1:0][1:0];  // 2 adder outs from stage 5
    logic signed [23:0] adder3_result[NUM_FILTERS-1:0];       // adder tree 3 result
    logic signed [23:0] macc_acc[NUM_FILTERS-1:0];
    
    // TODO: Flatten
    logic signed [23:0] mult_out[NUM_FILTERS-1:0][FILTER_SIZE*3-1:0];
    
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
    
    // TODO: try to really understand clock enables vs. gating vs. if the macc_en is just treated as a logic variable
    // Discover: Do we need to gate adder arithmetic?
    //           Or will having the valid out signal gate the adder logic
    //           and synthesize time multiplexing of carry chain logic?
    always_ff @(posedge i_clk) begin
        if (macc_en) begin
            for (int i = 0; i < NUM_FILTERS; i++) begin
                // Adder tree structure 1
                adder1_stage1[i][14:10] <= mult_out[i][14:10];
                adder1_stage1[i][9:5]   <= mult_out[i][9:5];
                adder1_stage1[i][4:0]   <= mult_out[i][4:0];
                
                adder1_stage2[i][17]    <= adder1_stage1[i][15];
                for (int j = 0; j < 7; j++)
                    adder1_stage2[i][10+j] <= adder1_stage1[i][j*2] + adder1_stage1[i][j*2+1];
                adder1_stage2[i][9:5]   <= mult_out[i][9:5];
                adder1_stage2[i][4:0]   <= mult_out[i][4:0];
                
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
                adder2_stage1[i]        <= mult_out[i][14:10];
                
                adder2_stage2[i][17]    <= adder2_stage1[i][4];
                for (int j = 0; j < 2; j++)
                    adder2_stage2[i][j] <= adder2_stage1[i][j*2] + adder2_stage1[i][j*2+1];
                adder2_stage2[i][14:10] <= mult_out[i][14:10];
                adder2_stage2[i][9:5]   <= mult_out[i][9:5];
                adder2_stage2[i][4:0]   <= mult_out[i][4:0];
                
                for (int j = 0; j < 9; j++)
                    adder2_stage3[i][j+5] <= adder2_stage2[i][j*2] + adder2_stage2[i][j*2+1];
                adder2_stage3[i][4:0]   <= mult_out[i][4:0];
                
                for (int j = 0; j < 7; j++)
                    adder2_stage4[i][j+5] <= adder2_stage3[i][j*2] + adder2_stage3[i][j*2+1];
                    
                adder2_stage5[i][3]     <= adder2_stage4[i][6];
                for (int j = 0; j < 3; j++)
                    adder2_stage5[i][j] <= adder2_stage4[i][j*2] + adder2_stage4[i][j*2+1];
                    
                for (int j = 0; j < 2; j++)
                    adder2_stage6[i][j+5] <= adder2_stage5[i][j*2] + adder2_stage5[i][j*2+1];
                
                adder2_result[i]        <= adder2_stage6[i][1] + adder2_stage6[i][0];
                
                // Adder tree structure 3
                adder3_stage1[i][9:5]   <= mult_out[i][14:10];
                adder3_stage1[i][4:0]   <= mult_out[i][9:5];
                
                for (int j = 0; j < 5; j++)
                    adder3_stage2[i][j+15] <= adder3_stage1[i][j*2] + adder3_stage1[i][j*2+1];
                adder3_stage2[i][14:10] <= mult_out[i][14:10];
                adder3_stage2[i][9:5]   <= mult_out[i][9:5];
                adder3_stage2[i][4:0]   <= mult_out[i][4:0];
                
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
    
    always_comb begin
        case(state)
            ONE: begin
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][0] = line_buffer[i][feat_col_ctr-2];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][0] = weights[i][0];
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][1] = line_buffer[i][feat_col_ctr-1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][1] = weights[i][1];              
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][2] = line_buffer[i][feat_col_ctr];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][2] = weights[i][2];
            end
            TWO: begin
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][0] = line_buffer[i][feat_col_ctr+1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][0] = weights[i][3];
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][1] = line_buffer[i][feat_col_ctr+2];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][1] = weights[i][4];
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][2] = line_buffer[i][feat_col_ctr-1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][2] = weights[i][0];
            end
            THREE: begin
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][0] = line_buffer[i][feat_col_ctr-1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][0] = weights[i][1];
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][1] = line_buffer[i][feat_col_ctr];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][1] = weights[i][2];
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][2] = line_buffer[i][feat_col_ctr+1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][2] = weights[i][3];
            end
            FOUR: begin
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][0] = line_buffer[i][feat_col_ctr+2];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][0] = weights[i][4];
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][1] = line_buffer[i][feat_col_ctr-1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][1] = weights[i][0];
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][2] = line_buffer[i][feat_col_ctr];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][2] = weights[i][1];
            end
            FIVE: begin
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][0] = line_buffer[i][feat_col_ctr];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][0] = weights[i][2];
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][1] = line_buffer[i][feat_col_ctr+1];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][1] = weights[i][3];
                for (int i = 0; i < FILTER_SIZE-1; i++)
                    feature_operands[i][2] = line_buffer[i][feat_col_ctr+2];
                for (int i = 0; i < NUM_FILTERS; i++)
                    weight_operands[i][2] = weights[i][4];
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
    
    /*
    Line buffer operation
    Details: Line buffer height is equal to filter size
             Buffer is filled on the fly
    
    fill lb enough to start macc operation
    
    once macc is enabled and the lb is totally full, start filling the first columns for future row
    the operation would be shifting the column up, and setting the bottom row of the column to the input feature
    
    once has completed row and feature counter is below 15, fill the last columns of the lb
    the operation would be shifting the column up, and setting the bottom row of the column to the input feature
    
    
    1   2   3   4   5
    6   7   8   9   10
    11  12  13  14  15
    
    
    16  17  18   4   5
    6   7   8   9   10
    11  12  13  14  15
    
    */
    
    always_comb begin
        next_row   = feat_col_ctr == COL_END-1 && state == FIVE;
        // TODO: Review full flag, is it right to set the flag at an almost full state?
        lb_full    = lb_row_ctr == FILTER_SIZE && lb_col_ctr == COL_END-2;
        macc_ready = lb_row_ctr == FILTER_SIZE-1 && lb_col_ctr == COL_START+FILTER_SIZE;
    end
    
    always_ff @(posedge i_clk)
        if (i_rst) begin
            macc_en             <= 0;
            feat_row_ctr        <= ROW_START;
            feat_col_ctr        <= COL_START;
            adder_tree_valid_sr <= '{default: 0};
            // line_buffer         <= '{default: 0};
        end else begin
            // Enable MACC operations when line buffer first fills.
            // Could lower latency with a line buffer full enough flag,
            // but that is not necessary for this study
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
    
    assign o_buffer_full   = lb_full;
    assign o_features      = macc_acc;
    assign o_feature_valid = adder_tree_valid_sr[0][6] ||
                             adder_tree_valid_sr[1][6] ||
                             adder_tree_valid_sr[2][6];

endmodule