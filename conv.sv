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
TODO: Async reset? or sync and see if its used as 6th LUT input (1 sel, 2x 2:1 mux inputs)
      Understand clock gating vs. clock enables vs. if macc_en is treated as a logic variable
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
    localparam        NUM_DSP48E1   = 90;
    localparam        INPUT_WIDTH   = 31;
    localparam        INPUT_HEIGHT  = 31;
    localparam        FILTER_SIZE   = 5;
    localparam        ROW_START     = 2;
    localparam        ROW_END       = 29;
    localparam        COL_START     = 2;
    localparam        COL_END       = 29;
    
    // Weight ROMs
    // 90 distributed RAMs -> 1 per DSP48E1
    // 16-bit signed data x 6 filters x 5 rows x 3 columns x 5 deep
    // Overall there is 90x5 = 90 8x16-bit Distributed RAMs
    // One SLICEM can implement 2 8x16-bit Distruibuted RAMs
    // Hence, 45 slices will be used for the weight RAMs
    // Initialize trainable parameters
    // Weights
    // (* rom_style = "block" *)
    logic signed [15:0] weights [0:NUM_FILTERS-1][0:4][0:2][0:4];
    initial $readmemb(WEIGHTS_FILE, weights);
    // Biases
    // (* rom_style = "block" *)
    logic signed [15:0] biases [0:NUM_FILTERS-1];
    initial $readmemb(BIASES_FILE, biases);
    
    // Want to synth distributed RAMs for feature buffers,
    // These feature RAMs are essentially line buffers
    logic         [7:0] feature_rams [0:FILTER_SIZE-1][0:INPUT_WIDTH-1];
    // The actual feature window to be multiplied by the filter kernel
    logic         [7:0] feature_window [0:FILTER_SIZE-1][0:FILTER_SIZE-1];
    // We buffer the initial feature window of the next row
    // It loads during convolution operation of the preceeding row
    logic         [7:0] next_initial_feature_window [0:FILTER_SIZE-1][0:FILTER_SIZE-1];
    
    // FSM for preloading the initial feature window of the next row
    typedef enum logic [2:0] {
        IDLE, FILL, SHIFT
    } preload_state_t;
    preload_state_t preload_state, preload_next_state;
    // Column location of the preload operation, treated as the address to the feature RAMs
    // for the sake of filling the initial feauture window of the next row
    logic         [2:0] preload_col;
    
    // Signals holding the DSP48E1 operands, used for readability
    logic         [7:0] feature_operands[0:FILTER_SIZE-1][0:2];
    logic signed [15:0] weight_operands[0:NUM_FILTERS-1][0:FILTER_SIZE-1][0:2];
    // All 90 DSP48E1 outputs
    logic signed [15:0] mult_out[0:NUM_FILTERS-1][0:FILTER_SIZE*3-1];
    
    // Feature RAM location
    logic [$clog2(ROW_END)-1:0] fram_row_ctr;
    logic [$clog2(COL_END)-1:0] fram_col_ctr;
    // Convolution Feature location
    // Is conv row cnt needed?
    logic [$clog2(ROW_END)-1:0] conv_row_ctr;
    logic [$clog2(COL_END)-1:0] conv_col_ctr;
    
    // Flags
    logic macc_en;
    logic macc_ready;
    logic lb_full;
    logic next_row;
    logic consume_features;
    logic fill_next_start;
    
    // Adder Tree
    logic         [6:0] adder_tree_valid_sr[0:2];
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
    
    // Convolution FSM, controls DSP48E1 time multiplexing,
    // and convolution feature counters
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
    
    // Should we set next_row at macc_en rising edge?
    // So that the initial feature window of the first row is loaded in?
    always_ff @(posedge i_clk)
        if (i_rst) begin
            feature_window <= '{default: 0};
            next_initial_feature_window <= '{default: 0};
        end else if (next_row) begin
            feature_window <= next_initial_feature_window;
        end else begin
            for (int i = 0; i < FILTER_SIZE; i++)
                feature_window[i] <= {feature_rams[i][conv_col_ctr], feature_window[i][4:1]};
        end
    
    // Preload next initial feature window FSM
    always_ff @(posedge i_clk)
        if (i_rst)
            preload_state <= IDLE;
        else
            preload_state <= preload_next_state;
    
    always_comb
        case(preload_state)
            IDLE: begin
                if (fill_next_start) preload_next_state = FILL;
            end
            FILL: begin
                if (preload_col[2]) preload_next_state = SHIFT;
            end
            SHIFT: begin
                preload_next_state = IDLE;
            end
            default: preload_next_state = preload_next_state;
        endcase
    
    // Next initial feature window actual filling logic
    // Need to handle first row initial feature window
    always_ff @(posedge i_clk)
        case(preload_state)
            IDLE: begin
                preload_col <= 3'b0;
            end
            FILL: begin
                // Logic here depends on implementation of feature RAM filling
                // Will the data arriving into the feature RAMs fill the row 0 RAM?
                // Or will the RAM values be shifted as incoming data populates the RAM,
                // and therefore the features needed for the preload feature block will
                // Already be in the bottom row RAM, which is the correct order for the features
                // If the former, will need to make sure to shift up the values in RAM
                // before the next row of convolutions
                next_initial_feature_window[0][preload_col] <= feature_rams[FILTER_SIZE-1][preload_col];
                preload_col <= preload_col + 1;
            end
            SHIFT: begin
                // TODO: Is it possible to implement a column-wise shift operation to shorten this code?
                for (int i = 0; i < FILTER_SIZE; i++) begin
                    for (int j = 0; j < FILTER_SIZE-1; j++)
                        next_initial_feature_window[j][i] <= next_initial_feature_window[j+1][i];
                    next_initial_feature_window[FILTER_SIZE-1][i] <= next_initial_feature_window[0][i];
                end
            end
        endcase
    
    // TODO: Syntax simplify
    /*
    for each adder tree
        set constant where mult out index is for adder stage 1
            based on this value, set rest of adder tree mult out connections
        compute and set adder stage x registers based on adder stage x-1 registers
    */
    always_ff @(posedge i_clk) begin
        if (macc_en) begin
            for (int i = 0; i < NUM_FILTERS; i++) begin
                // Adder tree structure 1
                adder1_stage1[i]        <= mult_out[i];
                
                adder1_stage2[i][17]    <= adder1_stage1[i][15];
                for (int j = 0; j < 7; j++)
                    adder1_stage2[i][10+j] <= adder1_stage1[i][j*2] + adder1_stage1[i][j*2+1];
                adder1_stage2[i][0:9]   <= mult_out[i][0:9];
                
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
                adder2_stage2[i]        <= mult_out[i];
                
                for (int j = 0; j < 9; j++)
                    adder2_stage3[i][j+5] <= adder2_stage2[i][j*2] + adder2_stage2[i][j*2+1];
                adder2_stage3[i][0:4]   <= mult_out[i][0:4];
                
                for (int j = 0; j < 7; j++)
                    adder2_stage4[i][j+5] <= adder2_stage3[i][j*2] + adder2_stage3[i][j*2+1];
                
                adder2_stage5[i][3]     <= adder2_stage4[i][6];
                for (int j = 0; j < 3; j++)
                    adder2_stage5[i][j] <= adder2_stage4[i][j*2] + adder2_stage4[i][j*2+1];
                
                for (int j = 0; j < 2; j++)
                    adder2_stage6[i][j+5] <= adder2_stage5[i][j*2] + adder2_stage5[i][j*2+1];
                
                adder2_result[i]        <= adder2_stage6[i][1] + adder2_stage6[i][0];
                
                // Adder tree structure 3
                adder3_stage1[i][0:9]   <= mult_out[i][5:14];
                
                for (int j = 0; j < 5; j++)
                    adder3_stage2[i][j+15] <= adder3_stage1[i][j*2] + adder3_stage1[i][j*2+1];
                adder3_stage2[i]        <= mult_out[i];
                
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
    
    // Group adder tree valid bits into vector
    always_comb
        for (int i = 0; i < 3; i++)
            adder_tree_valid_bits[i] = adder_tree_valid_sr[i][6];
    
    // Set MACC Accumulate based on adder tree valid bit
    always_comb
        case(adder_tree_valid_bits)
            3'b100:  macc_acc = adder1_result;
            3'b010:  macc_acc = adder2_result;
            3'b001:  macc_acc = adder3_result;
            default: macc_acc = macc_acc;
        endcase
    
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
        endcase
        assign_feature_operands(feature_offsets);
        assign_weight_operands(weight_offsets);
    end
    
    task assign_feature_operands(input int offsets[3]);
        for (int i = 0; i < FILTER_SIZE; i++)
            for (int j = 0; j < 3; j++)
                feature_operands[i][j] = feature_window[i][conv_col_ctr+offsets[j]];
    endtask
    
    task assign_weight_operands(input int offsets[3]);
        for (int i = 0; i < NUM_FILTERS; i++)
            for (int j = 0; j < FILTER_SIZE; j++)
                for (int k = 0; k < NUM_DSP48E1 / NUM_FILTERS / FILTER_SIZE; k++)
                    for (int l = 0; l < 3; l++)
                        weight_operands[i][j][k][l] = weights[i][j][k][offsets[l]];
    endtask
    
    always_ff @(posedge i_clk)
        for (int i = 0; i < NUM_FILTERS; i++)
            for (int j = 0; j < 5; j++)
                for (int k = 0; k < 3; k++)
                    // Signed output only when both operands are signed
                    mult_out[i][k*5+j] <= weight_operands[i][j][k] * $signed(feature_operands[j][k]);
    
    always_ff @(posedge i_clk)
        if (macc_en)
            case(state)
                TWO:  conv_col_ctr <= conv_col_ctr + 1;
                FOUR: conv_col_ctr <= conv_col_ctr + 1;
                FIVE: conv_col_ctr <= conv_col_ctr + 1;
            endcase
    
    always_ff @(posedge i_clk) begin
        static state_t valid_states[3] = '{ONE, TWO, FOUR};
        if (macc_en)
            for (int i = 0; i < 3; i++)
                adder_tree_valid_sr[i] <= {adder_tree_valid_sr[i][5:0], state == valid_states[i]};
    end
     
    // Flags - TODO: Review
    always_comb begin
    
        next_row         = conv_col_ctr == COL_END-1 && state == FIVE;
        
        consume_features = conv_col_ctr == COL_START+10 && state == THREE;
        
        // Can start filling next preload block 5 cycles after new row
        // of features are consumed. It doesn't have to be exactly 5 cycles later,
        // but the next start values need to be preloaded before the next row of convolutions begin
        fill_next_start  = conv_col_ctr == COL_START+11 && state == THREE;
        
        // TODO: Review full flag, is it right to set the flag at an almost full state?
        lb_full          = fram_row_ctr == FILTER_SIZE && fram_col_ctr == COL_END-2;
        
        macc_ready       = fram_row_ctr == FILTER_SIZE-1 && fram_col_ctr == COL_START+FILTER_SIZE;
    end
    
    always_ff @(posedge i_clk)
        if (i_rst) begin
            macc_en             <= 0;
            conv_row_ctr        <= ROW_START;
            conv_col_ctr        <= COL_START;
            adder_tree_valid_sr <= '{default: 0};
        end else begin
            // Enable MACC operations when feature RAMs are full enough
            // for the first convolution window/kernel operation
            if (macc_ready)
                macc_en <= 1;
            if (next_row) begin
                conv_row_ctr <= conv_row_ctr + 1;
                conv_col_ctr <= COL_START;
            end
        end
    
    always_ff @(posedge i_clk)
        if (i_rst) begin
            fram_row_ctr <= ROW_START;
            fram_col_ctr <= COL_START;
        end else begin
            if (i_feature_valid) begin
                fram_col_ctr <= fram_col_ctr + 1;
                if (fram_col_ctr == COL_END-1) begin
                    fram_col_ctr <= COL_START;
                    fram_row_ctr <= fram_row_ctr + 1;
                end
                feature_window[fram_row_ctr][fram_col_ctr] <= i_feature;
            end else if (next_row) begin
                for (int i = 2; i < COL_END; i++)
                    for (int j = 0; j < FILTER_SIZE; j++)
                        feature_window[j][i] <= feature_window[j+1][i];
                fram_col_ctr <= COL_START;
            end
        end
    
    assign o_features      = macc_acc;
    assign o_buffer_full   = lb_full;
    assign o_feature_valid = |adder_tree_valid_bits;

endmodule