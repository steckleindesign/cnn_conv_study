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
    output logic               o_buffer_full
    );

    // Hardcode frame dimensions in local params
    localparam string WEIGHTS_FILE  = "weights.mem";
    localparam string BIASES_FILE   = "biases.mem";
    localparam        NUM_DSP48E1   = 90;
    localparam        DSP_PER_CH    = NUM_DSP48E1 / NUM_FILTERS;
    localparam        FILTER_SIZE   = 5; // 5x5 filters
    localparam        OFFSET_GRP_SZ = DSP_PER_CH / FILTER_SIZE;
    localparam        WEIGHT_ROM_DP = 5;
    localparam        INPUT_WIDTH   = 31;
    localparam        INPUT_HEIGHT  = 31;
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
    logic signed [15:0]
    weights [0:NUM_FILTERS-1][0:FILTER_SIZE-1]
            [0:OFFSET_GRP_SZ-1][0:WEIGHT_ROM_DP-1];
    initial $readmemb(WEIGHTS_FILE, weights);
    // Biases
    // (* rom_style = "block" *)
    logic signed [15:0] biases [0:NUM_FILTERS-1];
    initial $readmemb(BIASES_FILE, biases);
    
    // Make sure distributed RAMs are synthesized
    // These feature RAMs are essentially line buffers
    logic         [7:0] feature_rams [0:FILTER_SIZE-1][0:INPUT_WIDTH-1];
    
    // The actual feature window to be multiplied by the filter kernel
    logic         [7:0] feature_window [0:FILTER_SIZE-1][0:FILTER_SIZE-1];
    
    // We buffer the initial feature window of the next row
    // It loads during convolution operation of the preceeding row
    logic         [7:0] next_initial_feature_window [0:FILTER_SIZE-1][0:FILTER_SIZE-1];
    
    // Registers to hold temporary feature RAM data
    // as part of the input feature consumption logic
    logic signed [15:0] fram_swap_regs[0:NUM_FILTERS-2];
    
    // Signals holding the DSP48E1 operands, used for readability
    logic         [7:0] feature_operands[0:FILTER_SIZE-1][0:2];
    logic signed [15:0] weight_operands[0:NUM_FILTERS-1][0:FILTER_SIZE-1][0:OFFSET_GRP_SZ-1];
    
    // All 90 DSP48E1 outputs
    logic signed [15:0] mult_out[0:NUM_FILTERS-1][0:FILTER_SIZE*3-1];
    
    // Feature RAM location
    logic [$clog2(FILTER_SIZE)-1:0] fram_row_ctr;
    logic [$clog2(COL_END)-1:0]     fram_col_ctr;
    
    // Convolution Feature location
    logic [$clog2(ROW_END)-1:0] conv_row_ctr;
    logic [$clog2(COL_END)-1:0] conv_col_ctr;
    
    // Convolution FSM, controls DSP48E1 time multiplexing,
    // and convolution feature counters
    typedef enum logic [2:0] {
        ONE, TWO, THREE, FOUR, FIVE
    } state_t;
    state_t state, next_state;
    
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
    logic done_receiving;        // OK, unused
    
    // Flags
    always_comb begin
        // Should work, but is there a more optimal starting point?
        almost_done_consuming = fram_col_ctr == (COL_END-1);
        next_row              = conv_col_ctr == COL_END && state == FIVE;
        macc_ready            = fram_has_been_full;
    end
    
    // Control logic for feature consumption
    always_ff @(posedge i_clk)
        if (i_rst) begin
            consume_features <= 0;
            done_receiving   <= 0;
        end else begin
            if (next_row)
                consume_features <= 0;
            else if (i_feature_valid &&
                    ((conv_col_ctr == (COL_END-10) && state == FOUR)
                    || ~fram_has_been_full)) consume_features <= 1;
            
            if (conv_row_ctr == ROW_END)
                done_receiving <= 1;
        end
    
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
        if (i_rst) begin
            // Review: Do these feature windows need to be reset?
            feature_window              <= '{default: 0};
            next_initial_feature_window <= '{default: 0};
        end else if (next_row | macc_ready)
            feature_window <= next_initial_feature_window;
        else
            // Review: seems incorrect, should not be shifting every cycle
            // Maybe just shift during the states which conv col cnt is incr?
            for (int i = 0; i < FILTER_SIZE; i++)
                feature_window[i] <=
                    {feature_rams[i][conv_col_ctr],
                     feature_window[i][1:4]};
    
    
    // Takes 27*3=81 clock cycles for FRAM to become full
    // MACC enable set after 27*2=54 clock cycles
    // For logic simplicity, FRAM should become full
    // before MACC is enabled
    
    /*
    Consume the earlier column features after a certain number of 
    operations in the current convolution row, and consume the
    latter column features at the beginning of the next row features.
    So for the first several operations of the current convolution, the latter
    column features are being consumed
    
    Feature consumption logic should consume conv_row+1 features, so that next initial
    feature window can preload the necessary features before the next row operations begin
    
    Study the performance hit when using a fixed addition/subtraction on memory addressing
    
    */
    
    // TODO: Handle first row initial feature window
    // Next initial feature window data alignment
    always_ff @(posedge i_clk) begin
        // Input feature fans out to this preloading logic
        // as well as the feature RAM consumption logic
        if (fram_col_ctr <= (COL_START + FILTER_SIZE - 1))
            next_initial_feature_window[0][fram_col_ctr-2] <= i_feature;
        
        // Align data when the preload block is full
        if (fram_col_ctr == (COL_START + FILTER_SIZE)) begin
            // TODO: Is it possible to implement a column-wise
            //       shift operation to shorten this code?
            for (int i = 0; i < FILTER_SIZE; i++) begin
                for (int j = 0; j < FILTER_SIZE-1; j++)
                    next_initial_feature_window[j][i]
                        <= next_initial_feature_window[j+1][i];
                next_initial_feature_window[FILTER_SIZE-1][i]
                    <= next_initial_feature_window[0][i];
            end
        end
    end
    
//    TODO: Syntax simplify
//          for each adder tree
//              set constant where mult out index is for adder stage 1
//                  based on this value, set rest of adder tree mult out connections
//              compute and set adder stage x registers based on adder stage x-1 registers
    always_ff @(posedge i_clk) begin
        if (macc_en) begin
            for (int i = 0; i < NUM_FILTERS; i++) begin
                // Adder tree structure 1
                adder1_stage1[i] <= mult_out[i];
                
                adder1_stage2[i][17] <= adder1_stage1[i][15];
                for (int j = 0; j < 7; j++)
                    adder1_stage2[i][10+j] <= adder1_stage1[i][j*2] + adder1_stage1[i][j*2+1];
                adder1_stage2[i][0:9]   <= mult_out[i][0:9];
                
                for (int j = 0; j < 9; j++)
                    adder1_stage3[i][j] <= adder1_stage2[i][j*2] + adder1_stage2[i][j*2+1];
                
                // Can stage 4 5th reg just directly be connected to stage 6 1st reg?
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
                for (int j = 0; j < 2; j++)
                    adder2_stage2[i][j] <= adder2_stage1[i][j*2] + adder2_stage1[i][j*2+1];
                adder2_stage2[i][0:14] <= mult_out[i];
                
                for (int j = 0; j < 9; j++)
                    adder2_stage3[i][j+5] <= adder2_stage2[i][j*2] + adder2_stage2[i][j*2+1];
                adder2_stage3[i][0:4] <= mult_out[i][0:4];
                
                for (int j = 0; j < 7; j++)
                    adder2_stage4[i][j+5] <= adder2_stage3[i][j*2] + adder2_stage3[i][j*2+1];
                
                adder2_stage5[i][3] <= adder2_stage4[i][6];
                for (int j = 0; j < 3; j++)
                    adder2_stage5[i][j] <= adder2_stage4[i][j*2] + adder2_stage4[i][j*2+1];
                
                for (int j = 0; j < 2; j++)
                    adder2_stage6[i][j+5] <= adder2_stage5[i][j*2] + adder2_stage5[i][j*2+1];
                
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
    
    // Review: Logically incorrect -> conv_col_ctr+offsets[j]
    task assign_feature_operands(input int offsets[3]);
        for (int i = 0; i < FILTER_SIZE; i++)
            for (int j = 0; j < 3; j++)
                feature_operands[i][j] = feature_window[i][offsets[j]];
    endtask
    
    task assign_weight_operands(input int offsets[3]);
        for (int i = 0; i < NUM_FILTERS; i++)
            for (int j = 0; j < FILTER_SIZE; j++)
                for (int k = 0; k < OFFSET_GRP_SZ; k++)
                    weight_operands[i][j][k] = weights[i][j][k][offsets[k]];
    endtask
    
    always_ff @(posedge i_clk)
        for (int i = 0; i < NUM_FILTERS; i++)
            for (int j = 0; j < FILTER_SIZE; j++)
                for (int k = 0; k < OFFSET_GRP_SZ; k++)
                    mult_out[i][k*5+j] <= weight_operands[i][j][k]
                                            * $signed(feature_operands[j][k]);
    
    // Increment convolution column location on specific states
    always_ff @(posedge i_clk)
        if (macc_en && (state == TWO | state == FOUR | state == FIVE))
            conv_col_ctr <= conv_col_ctr + 1;
    
    // Shift adder tree valid signal shift register
    always_ff @(posedge i_clk) begin
        static state_t valid_states[3] = '{ONE, TWO, FOUR};
        for (int i = 0; i < 3; i++)
            adder_tree_valid_sr[i] <=
                {adder_tree_valid_sr[i][5:0],
                 macc_en ? state == valid_states[i]: 1'b0};
    end
    
    always_ff @(posedge i_clk)
        if (i_rst) begin
            macc_en      <= 0;
            conv_row_ctr <= ROW_START;
            conv_col_ctr <= COL_START;
        end else begin
            if (macc_ready)
                macc_en <= 1;
            if (next_row) begin
                conv_row_ctr <= conv_row_ctr + 1;
                conv_col_ctr <= COL_START;
            end
        end
    
    // TODO: On power-up, need to set feature RAM "zero ring"
    always_ff @(posedge i_clk)
        if (i_rst) begin
            fram_has_been_full <= 0;
            fram_row_ctr       <= ROW_START;
            fram_col_ctr       <= COL_START;
        end else begin
            process_feature <= take_feature;
            if (consume_features) begin
                // Feature consumption control signal sent
                // to FWFT FIFO read enable port
                take_feature <= 1;
                if (almost_done_consuming)
                    take_feature <= 0;
                
                // Feature RAM filling logic
                if (fram_has_been_full)
                begin
                    if (take_feature)
                        for (int i = 0; i < FILTER_SIZE-1; i++)
                            fram_swap_regs[i] <= feature_rams[i+1][fram_col_ctr];
                    if (process_feature)
                        for (int i = 0; i < FILTER_SIZE-1; i++)
                            feature_rams[i][fram_col_ctr] <= fram_swap_regs[i];
                end
                
                // Consume input feature from FWFT FIFO
                if (process_feature)
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
    
    assign o_feature_valid = |adder_tree_valid_bits;
    assign o_features      = macc_acc;
    assign o_buffer_full   = take_feature;

endmodule