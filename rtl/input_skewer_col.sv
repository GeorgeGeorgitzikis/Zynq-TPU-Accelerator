// =============================================================================
// Module: input_skewer_col
// Description:
//   Column-wise input skewing unit for systolic array alignment.
//
// Operation:
//   Introduces an incremental pipeline register delay (depth = i + 1) for
//   each column index i (from 0 to N-1). This aligns input vectors along a
//   diagonal wave-front matching the internal data arrival times of the 2D grid.
//   Synchronously propagates data along with valid and last control markers.
// =============================================================================

module input_skewer_col #(
    parameter int N          = 4, // Matrix dimension
    parameter int DATA_WIDTH = 8  // Element bit width
)(
    input  logic clk,
    input  logic rst,

    input  logic input_valid,
    input  logic input_last,

    output logic [N-1:0] output_valid,
    output logic [N-1:0] output_last,

    input  logic [N*DATA_WIDTH-1:0]      data_in_packed,
    output logic signed [DATA_WIDTH-1:0] skewed_data_out [0:N-1]
);

    genvar i;
    generate
        for (i = 0; i < N; i++) begin : delay_columns
            // Packet contains {Last, Valid, Data}
            localparam int PKT_WIDTH = DATA_WIDTH + 2;

            // Shift register of depth (i + 1)
            logic [PKT_WIDTH-1:0] shift_reg [0:i];
            integer k;

            always_ff @(posedge clk) begin
                if (rst) begin
                    for (k = 0; k <= i; k++) begin
                        shift_reg[k] <= '0;
                    end
                end else begin
                    // Stage 0: Load data with zero-padding when invalid
                    shift_reg[0] <= {
                        input_last,
                        input_valid,
                        input_valid ? data_in_packed[i*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}}
                    };

                    // Delay shift line
                    for (k = 1; k <= i; k++) begin
                        shift_reg[k] <= shift_reg[k-1];
                    end
                end
            end

            // Unpack delayed stage outputs
            assign output_last[i]     = shift_reg[i][PKT_WIDTH-1];
            assign output_valid[i]    = shift_reg[i][PKT_WIDTH-2];
            assign skewed_data_out[i] = shift_reg[i][DATA_WIDTH-1:0];
        end
    endgenerate

endmodule