`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////////

module feature_fwft_tb();
    // inputs
    logic       clk;
    logic       rst;
    logic       rd_en;
    logic [7:0] in_feature;
    // output
    logic       feature_valid;
    logic [7:0] out_feature;
    
    feature_fwft DUT (.clk(clk),
                      .rst(rst),
                      .rd_en(rd_en),
                      .in_feature(in_feature),
                      .feature_valid(feature_valid),
                      .out_feature(out_feature));

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    initial begin
        rst = 1;
        #21
        rst = 0;
    end
    
    initial begin
        rd_en = 0;
        forever begin
            #(10 * 10) rd_en = 1;
            #(5  * 10) rd_en = 0;
        end
    end
    
    initial begin
        in_feature = 8'h00;
        repeat (4*256) begin
            @(negedge clk);
            if (~rst)
                in_feature = in_feature == 8'hFF ? 8'h00 : in_feature + 1;
        end
        $finish;
    end

endmodule