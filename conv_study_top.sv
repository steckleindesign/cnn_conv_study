`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

/*
TODO:
    Place reset in IOB?
        If we can fit a 2FF synchronizer in the IOB then sure
        otherwise, just synchronize in fabric FFs
    
    change parallel IO to serial IO over SPI interface
    
    overclock DSP48E1, try different clocking techniques
        ([1x, 2x CLKOUT0/CLKOUT1],
        [1x, 2x CLKOUT0 w/ BUFGDIV],
        [1x w/ dual edge triggering],
        [2x w/ MCPs])
    
    
    Testbenches for conv, pool, post_processing
    
    Takes 27*3=81 clock cycles for FRAM to become full
    MACC enable set after 27*2=54 clock cycles
    For logic simplicity, FRAM should become full before MACC is enabled
    
    For distributed RAM should we aim for sync or async reads?
    
    Study the performance hit when using a fixed addition/subtraction on memory addressing
*/

//////////////////////////////////////////////////////////////////////////////////

module conv_study_top (
                       input  logic              top_i_clk,
                       input  logic              top_i_rst,
    (* IOB = "TRUE" *) input  logic              top_i_feature_valid,
    (* IOB = "TRUE" *) input  logic signed [7:0] top_i_feature_in,
    (* IOB = "TRUE" *) output logic              top_o_feature_valid,
    (* IOB = "TRUE" *) output logic signed [7:0] top_o_feature_out,
    // LEDs for dev board
                       output logic        [1:0] top_o_led,
                       output logic              top_o_led_r, top_o_led_g, top_o_led_b
);

    // MMCM
    logic clk200m;
    logic locked;
    
    // External data sent into FPGA and registered into IOBs
    logic              pixel_in_valid;
    logic signed [7:0] pixel_in;
    
    // Convolutional layer is ready for data to be sent from pixel FIFO
    logic              conv_receive_feature;
    
    // Data out of pixel FIFO and into convolutional layer
    logic              conv_feature_in_valid;
    logic signed [7:0] conv_feature_in;
    
    // Data out of convolutional layer and into max pooling layer
    logic              pool_features_in_valid;
    logic signed [7:0] pool_features_in[0:5];
    
    // Data out of max pooling layer and into post-processing logic
    logic              pool_features_out_valid;
    logic signed [7:0] pool_features_out[0:5];
    
    sys_mmcm_12m_to_50m sys_mmcm_inst (.clk(top_i_clk),
                                       .reset(top_i_rst),
                                       .clk200m(clk200m),
                                       .locked(locked));
    
    // Top level device input data registered in IOB then sent directly to FIFO
    always_ff @(posedge clk200m) begin
        pixel_in_valid <= top_i_feature_valid;
        pixel_in       <= top_i_feature_in;
    end
    
    pixel_fifo pixel_fifo_inst (.i_spi_clk       (clk200m),
                                .i_sys_clk       (clk200m),
                                .i_rst           (top_i_rst),
                                .i_rd_en         (conv_receive_feature), // Slave ready - similar to AXI
                                .i_wr_en         (pixel_in_valid),
                                .i_feature       (pixel_in),
                                .o_feature_valid (conv_feature_in_valid),
                                .o_feature       (conv_feature_in));

    conv conv_inst (.i_clk(clk200m),
                    .i_rst(top_i_rst),
                    .i_feature_valid(conv_feature_in_valid),
                    .i_feature(conv_feature_in),
                    .o_ready_feature(conv_receive_feature),
                    .o_feature_valid(pool_features_in_valid),
                    .o_features(pool_features_in));
    
    max_pool max_pool_inst (.i_clk(clk200m),
                            .i_rst(top_i_rst),
                            .i_feature_valid(pool_features_in_valid),
                            .i_features(pool_features_in),
                            .o_feature_valid(pool_features_out_valid),
                            .o_features(pool_features_out));
    
    post_processing post_processing_inst (.i_clk(clk200m),
                                          .i_features_valid(pool_features_out_valid),
                                          .i_features_in(pool_features_out),
                                          .o_feature_out(top_o_feature_out));
    
    assign top_o_led   = {1'b0, 1'b0};
    assign top_o_led_r = 0;
    assign top_o_led_g = 1;
    assign top_o_led_b = 0;

endmodule
