// =============================================================================
// Module: ws_output_deskewer
// Description:
//   Output deskewing unit for systolic array result realignment.
//
// Operation:
//   In a 2D systolic array, column outputs exit at staggered clock cycles
//   (column 0 finishes first, column N-1 finishes last).
//   This module introduces a complementary triangular delay:
//     Delay for column i = (N - 1) - i
//   This realigns staggered columns back into parallel matrix rows (flattened_out)
//   and provides latency-compensated valid_out and last_out signals.
// =============================================================================

module ws_output_deskewer #(
    parameter int N         = 4,
    parameter int ACC_WIDTH = 32
)(
    input  logic clk,
    input  logic rst,

    // Staggered skewed inputs from the systolic grid
    input  logic signed [ACC_WIDTH-1:0] skewed_in [0:N-1],

    // Synchronously deskewed parallel row outputs
    output logic signed [ACC_WIDTH-1:0] flattened_out [0:N-1],

    // Control Path (Latency Matching)
    input  logic valid_in,
    output logic valid_out,
    output logic last_out
);

    genvar i;
    generate
        for (i = 0; i < N; i++) begin : deskew_logic
            localparam int DELAY = (N - 1) - i;

            if (DELAY == 0) begin
                assign flattened_out[i] = skewed_in[i];
            end else begin
                logic signed [ACC_WIDTH-1:0] shift_reg [0:DELAY-1];

                always_ff @(posedge clk) begin
                    if (rst) begin
                        for (int k = 0; k < DELAY; k++) shift_reg[k] <= '0;
                    end else begin
                        shift_reg[0] <= skewed_in[i];
                        for (int k = 1; k < DELAY; k++) begin
                            shift_reg[k] <= shift_reg[k-1];
                        end
                    end
                end

                assign flattened_out[i] = shift_reg[DELAY-1];
            end
        end
    endgenerate

    // Pipeline Latency Compensation for valid signal
    localparam int TOTAL_LATENCY = N - 1;

    logic [TOTAL_LATENCY-1:0] valid_pipe;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_pipe <= '0;
        end else begin
            valid_pipe <= {valid_pipe[TOTAL_LATENCY-2:0], valid_in};
        end
    end

    assign valid_out = valid_pipe[TOTAL_LATENCY-1];

    // Word counter for asserting last_out
    logic [$clog2(N)-1:0] count;

    always_ff @(posedge clk) begin
        if (rst) begin
            count <= '0;
        end else if (valid_out) begin
            if (count == N - 1) begin
                count <= '0;
            end else begin
                count <= count + 1'b1;
            end
        end
    end

    assign last_out = (valid_out && (count == N - 1));

endmodule