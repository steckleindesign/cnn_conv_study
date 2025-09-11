`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////////

module pixel_fifo_tb();

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
    
    pixel_fifo
        pixel_fifo_uut (.i_spi_clk(clk),
                        .i_sys_clk(clk),
                        .i_rst(rst),
                        .i_rd_en(ready_feature),
                        .i_wr_en(pixel_valid),
                        .i_feature(pixel_in),
                        .o_feature_valid(feature_in_valid),
                        .o_feature(feature_in));
    
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
        rst         = 0;
        ready_feature = 0;
        #100;
        rst         = 1;
        #100;
        rst         = 0;
        #100;
        pixel_valid = 1;
        while (i < (28*28)) begin
            pixel_in = i;
            i = i + 1;
            @(posedge clk);
        end
        pixel_valid = 0;
    end
    
    initial begin
        wait (pixel_valid == 1);
        repeat (10) @(posedge clk);
        forever begin
            ready_feature = 1;
            #100;
            ready_feature = 0;
            #100;
        end
    
    end
    
    
//    initial begin
//        seed = 1234;
//        forever begin
//            @(posedge clk);
//            feature_in = $random(seed) & 8'hFF;
//        end
//    end

endmodule
