`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////


//////////////////////////////////////////////////////////////////////////////////

module feature_buf (
    input        clk,
    input        rst,
    input  [7:0] feature_in,
    input        hold_data,
    output       feature_valid,
    output [7:0] feature_out
);

    logic       feature_valid_d;
    logic [7:0] feature_d;

    typedef enum logic [1:0] {
        IDLE,
        SEND,
        DONE
    } state_t;
    state_t state, next_state;
    
    always_ff @(posedge clk or negedge rst)
        if (~rst)
            state <= IDLE;
        else
            state <= next_state;

    always_comb
    begin
        case(state)
            IDLE: begin
                next_state = SEND;
            end
            SEND: begin
                if (hold_data)
                    next_state = DONE;
                else
                    next_state = SEND;
            end
            DONE: begin
                next_state = DONE;
            end
        endcase
    end
    
    always_ff @(posedge clk or negedge rst)
    begin
        if (~rst) begin
            feature_valid_d <= 0;
            feature_d       <= 8'b0;
        end else begin
            case(state)
                IDLE: begin
                    feature_valid_d <= 0;
                    feature_d       <= 8'b0;
                end
                SEND: begin
                    feature_valid_d <= 1;
                    feature_d       <= feature_in;
                end
                DONE: begin
                    feature_valid_d <= 0;
                    feature_d       <= 8'b0;
                end
            endcase
        end
    end
    
    assign feature_valid = feature_valid_d;
    assign feature_out   = feature_d;

endmodule