`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////////

module pixel_fifo_conv_pool_tb();

    localparam CLK_PERIOD = 10;
    
    // integer seed;
    
    // Clock/Reset
    logic               clk;
    logic               rst;
    
    // Pixel FIFO Inputs
    logic         [7:0] pixel_in;
    logic               pixel_valid;
    
    // Pixel FIFO Outputs/Convolutional block Inputs
    logic               feature_in_valid;
    logic         [7:0] feature_in;
    
    // Pixel FIFO Inputs/Convolutional block Outputs
    logic               ready_feature;
    
    // Convolutional block Outputs
    logic               feature_out_valid;
    logic signed  [7:0] features_out[0:5];
    
    // Max Pooling Outputs
    logic               pool_features_out_valid;
    logic signed  [7:0] pool_features_out[0:5];
    
    // Debug
    logic              tb_debug_take_feature;
    logic              tb_debug_feature_consumption_during_processing;
    logic              tb_debug_fram_has_been_full;
    logic              tb_debug_macc_en;
    logic        [2:0] tb_debug_state;
    logic        [4:0] tb_debug_fram_row_ctr;
    logic        [4:0] tb_debug_fram_col_ctr;
    logic        [4:0] tb_debug_conv_row_ctr;
    logic        [4:0] tb_debug_conv_col_ctr;
    logic              tb_debug_next_row;
    logic        [7:0] tb_debug_adder1_result;
    logic        [7:0] tb_debug_adder2_result;
    logic        [7:0] tb_debug_adder3_result;
    logic signed [7:0] tb_debug_weight_operands[0:5][0:4][0:2];
    logic signed [7:0] tb_debug_feature_operands[0:4][0:2];
    logic        [7:0] tb_debug_feature_window[0:4][0:4];
    logic        [7:0] tb_debug_next_initial_feature_window[0:4][0:4];
    logic              tb_debug_feature_ram_we[0:4];
    logic        [7:0] tb_debug_feature_ram_din[0:4];
    logic        [4:0] tb_debug_feature_ram_addra[0:4];
    logic        [4:0] tb_debug_feature_ram_addrb[0:4];
    logic        [7:0] tb_debug_feature_ram_douta[0:4];
    logic        [7:0] tb_debug_feature_ram_doutb[0:4];
    
    
    pixel_fifo
        pixel_fifo_uut (.i_spi_clk(clk),
                        .i_sys_clk(clk),
                        .i_rst(rst),
                        .i_rd_en(ready_feature),
                        .i_wr_en(pixel_valid),
                        .i_feature(pixel_in),
                        .o_feature_valid(feature_in_valid),
                        .o_feature(feature_in));
    
    conv
        conv_uut (.i_clk(clk),
                  .i_rst(rst),
                  .i_feature_valid(feature_in_valid),
                  .i_feature(feature_in),
                  .o_feature_valid(feature_out_valid),
                  .o_features(features_out),
                  .o_ready_feature(ready_feature),
                  // Debug
                  .debug_state(tb_debug_state),
                  .debug_feature_consumption_during_processing(tb_debug_feature_consumption_during_processing),
                  .debug_take_feature(tb_debug_take_feature),
                  .debug_fram_has_been_full(tb_debug_fram_has_been_full),
                  .debug_macc_en(tb_debug_macc_en),
                  .debug_fram_row_ctr(tb_debug_fram_row_ctr),
                  .debug_fram_col_ctr(tb_debug_fram_col_ctr),
                  .debug_conv_row_ctr(tb_debug_conv_row_ctr),                          
                  .debug_conv_col_ctr(tb_debug_conv_col_ctr),
                  .debug_next_row(tb_debug_next_row),
                  .debug_adder1_result(tb_debug_adder1_result),
                  .debug_adder2_result(tb_debug_adder2_result),
                  .debug_adder3_result(tb_debug_adder3_result),
                  .debug_weight_operands(tb_debug_weight_operands),
                  .debug_feature_operands(tb_debug_feature_operands),
                  .debug_feature_window(tb_debug_feature_window),
                  .debug_next_initial_feature_window(tb_debug_next_initial_feature_window),
                  .debug_feature_ram_we(tb_debug_feature_ram_we),
                  .debug_feature_ram_din(tb_debug_feature_ram_din),
                  .debug_feature_ram_addra(tb_debug_feature_ram_addra),
                  .debug_feature_ram_addrb(tb_debug_feature_ram_addrb),
                  .debug_feature_ram_douta(tb_debug_feature_ram_douta),
                  .debug_feature_ram_doutb(tb_debug_feature_ram_doutb));
    
    
    max_pool
        max_pool_uut (.i_clk(clk),
                      .i_rst(rst),
                      .i_feature_valid(feature_out_valid),
                      .i_features(features_out),
                      .o_feature_valid(pool_features_out_valid),
                      .o_features(pool_features_out));
    
    // Clocking
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // Reset
    initial begin
    end
    
    // Input pixel stimulus
    initial begin
        automatic int i = 0;
        pixel_valid = 0;
        pixel_in    = 0;
        rst         = 1;
        #200;
        rst         = 0;
        #100;
        pixel_valid = 1;
        while (i < (28*28)) begin
            pixel_in = i;
            //if (ready_feature) begin
                i = i + 1;
            //end
            @(posedge clk);
        end
        pixel_valid = 0;
    end
    
//    initial begin
//        seed = 1234;
//        forever begin
//            @(posedge clk);
//            feature_in = $random(seed) & 8'hFF;
//        end
//    end

endmodule
