`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

// Theory of operation

// Data written from SPI interface synchronous to SPI clock
// Data read from system clock

// When read enable and write enable is set high
//  Shift data out of FIFO

// FIFO almost full flag for when there is enough data to begin CNN processing

// FIFO not-empty signal to tell convolutional layer that valid data is in FIFO

//////////////////////////////////////////////////////////////////////////////////

module pixel_fifo(
    input  logic       i_spi_clk,
    input  logic       i_sys_clk,
    input  logic       i_rst,
    input  logic       i_rd_en,
    input  logic       i_wr_en,
    input  logic [7:0] i_feature,
    output logic       o_feature_valid,
    output logic [7:0] o_feature
);

    logic fifo_full; // NC

    fifo_generator_0 fifo_0_inst (.rst   (i_rst),
                                  .wr_clk(i_spi_clk),
                                  .rd_clk(i_sys_clk),
                                  .wr_en (i_wr_en),
                                  .rd_en (i_rd_en),
                                  .din   (i_feature),
                                  .dout  (o_feature),
                                  .full  (fifo_full),
                                  .empty (~o_feature_valid));

endmodule