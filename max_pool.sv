`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////

// Conv1 data enters in parallel for 6 C1 maps and serially left to right, top to bottom per map

//////////////////////////////////////////////////////////////////////////////////

module max_pool (
    input  logic              i_clk,
    input  logic              i_rst,
    input  logic              i_feature_valid,
    input  logic signed [7:0] i_features[0:5],
    output logic              o_feature_valid,
    output logic signed [7:0] o_features[0:5]
);
    
    logic [$clog2(28)-1:0] col_cnt = 0;
    logic [$clog2(28)-1:0] row_cnt = 0;
    
    logic signed [7:0] feature_sr[0:5][0:13];
    
    logic signed [7:0] reg_0_0[0:5];
    logic signed [7:0] reg_0_1[0:5];
    logic signed [7:0] reg_0_c[0:5];
    logic signed [7:0] reg_1_0[0:5];
    logic signed [7:0] reg_1_1[0:5];
    logic signed [7:0] reg_1_c[0:5];
    
    always_ff @(posedge i_clk) begin
        if (i_rst) begin
            col_cnt <= 0;
            row_cnt <= 0;
            o_features      <= reg_1_c;
            o_feature_valid <= 0;
            for (int i = 0; i < 6; i++) begin
                reg_0_0[i] <= 0;
                reg_0_1[i] <= 0;
                reg_0_c[i] <= 0;
                reg_1_0[i] <= 0;
                reg_1_1[i] <= 0;
                reg_1_c[i] <= 0;
            end
        end else begin
            o_feature_valid <= 0;
            o_features <= reg_1_c;
            if (i_feature_valid) begin
                for (int i = 0; i < 6; i++) begin
                    // Conditional data flow - implemented as logic on D input or as CE?
                    if (col_cnt[0]) begin
                        feature_sr[i] <= {reg_0_c[i], feature_sr[i][0:12]};
                        reg_1_1[i] <= reg_1_c[i];
                    end else if (~col_cnt[0]) begin
                        reg_1_1[i] <= feature_sr[i][13];
                    end
                    // Continuous Data flow
                    reg_0_0[i] <= i_features[i];
                    reg_0_1[i] <= reg_0_0[i];
                    reg_0_c[i] <= (reg_0_1[i] > reg_0_0[i]) ? reg_0_1[i] : reg_0_0[i];
                    reg_1_0[i] <= i_features[i];
                    reg_1_c[i] <= (reg_1_1[i] > reg_1_0[i]) ? reg_1_1[i] : reg_1_0[i];
                end
                // Counters for control logic
                col_cnt <= col_cnt + 1;
                if (col_cnt == 27) begin
                    col_cnt <= 0;
                    row_cnt <= row_cnt + 1;
                end
                // Feature valid control logic
                o_feature_valid <= row_cnt[0] & col_cnt[0];
                // Send out registered feature
            end
        end
    end

endmodule
