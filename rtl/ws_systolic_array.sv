// =============================================================================
// Module: ws_systolic_array
// Description:
//   2D Weight-Stationary (WS) Systolic Array of size N x N.
//
// Operation & Data Flow:
//   - Activations (Matrix A) enter from the West boundary (row_in) and stream East.
//   - Weights (Matrix B) enter from the North boundary (col_in) during pre-loading.
//   - Partial Sums (Matrix C) stream Southward (sum_in -> sum_out), accumulating
//     products at each clock cycle across all PEs.
//   - Swap control signals propagate systolically across rows and columns.
// =============================================================================

module ws_systolic_array #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int N          = 4
)(
    input  logic clk,
    input  logic rst,

    // Control Signals (Valid Path)
    input  logic valid_in,
    output logic valid_out,

    // Status Output
    output logic weights_loaded,

    // Systolic Swap Control (Wavefront propagation)
    input  logic swap_in_left   [0:N-1],
    input  logic swap_in_top    [0:N-1],
    output logic swap_out_right [0:N-1],
    output logic swap_out_down  [0:N-1],

    // Weight Load Control (Column strobes)
    input  logic [N-1:0] load_in_cols,
    input  logic [N-1:0] last_in_cols,

    // Data Inputs
    input  logic signed [DATA_WIDTH-1:0] row_in [0:N-1], // Activation inputs (A)
    input  logic signed [DATA_WIDTH-1:0] col_in [0:N-1], // Weight inputs (W)
    input  logic signed [ACC_WIDTH-1:0]  sum_in [0:N-1], // Partial sum inputs (C)

    // Data Outputs
    output logic signed [DATA_WIDTH-1:0] row_out [0:N-1], // Activation passthrough
    output logic signed [DATA_WIDTH-1:0] col_out [0:N-1], // Weight passthrough
    output logic signed [ACC_WIDTH-1:0]  sum_out [0:N-1]  // Final accumulated results
);

    // Internal Grid Interconnect Routing
    logic h_swap [0:N-1][0:N];
    logic v_swap [0:N][0:N-1];

    logic signed [DATA_WIDTH-1:0] h_a [0:N-1][0:N];
    logic signed [DATA_WIDTH-1:0] v_w [0:N][0:N-1];
    logic signed [ACC_WIDTH-1:0]  v_c [0:N][0:N-1];

    // Pipeline Valid Tracking
    logic [N-1:0] valid_pipe;
    always_ff @(posedge clk) begin
        if (rst) valid_pipe <= '0;
        else     valid_pipe <= (valid_pipe << 1) | valid_in;
    end
    assign valid_out = valid_pipe[N-1];

    genvar i, j;
    generate
        // ---------------------------------------------------------
        // 1. Boundary Connections
        // ---------------------------------------------------------
        for (i = 0; i < N; i++) begin : boundaries
            assign h_a[i][0]     = row_in[i];
            assign v_w[0][i]     = col_in[i];
            assign v_c[0][i]     = sum_in[i];

            assign h_swap[i][0]  = swap_in_left[i];
            assign v_swap[0][i]  = swap_in_top[i];

            assign row_out[i]        = h_a[i][N];
            assign col_out[i]        = v_w[N][i];
            assign sum_out[i]        = v_c[N][i];
            assign swap_out_right[i] = h_swap[i][N];
            assign swap_out_down[i]  = v_swap[N][i];
        end

        // ---------------------------------------------------------
        // 2. 2D N x N PE Grid Instantiation
        // ---------------------------------------------------------
        for (i = 0; i < N; i++) begin : rows
            for (j = 0; j < N; j++) begin : cols
                ws_systolic_pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH(ACC_WIDTH)
                ) pe_inst (
                    .clk(clk),
                    .rst(rst),

                    // Systolic Swap Routing
                    .swap_in_left   (h_swap[i][j]),
                    .swap_in_top    (v_swap[i][j]),
                    .swap_out_right (h_swap[i][j+1]),
                    .swap_out_down  (v_swap[i+1][j]),

                    // Load Control
                    .load_in_top    (last_in_cols[j]),

                    // Data Routing
                    .a_in           (h_a[i][j]),
                    .a_out          (h_a[i][j+1]),
                    .w_in           (v_w[i][j]),
                    .w_out          (v_w[i+1][j]),
                    .c_in           (v_c[i][j]),
                    .c_out          (v_c[i+1][j])
                );
            end
        end
    endgenerate

    // ---------------------------------------------------------
    // 3. Weight Load Status Logic
    // ---------------------------------------------------------
    logic load_delay;

    always_ff @(posedge clk) begin
        if (rst) begin
            load_delay <= 1'b0;
        end else begin
            load_delay <= last_in_cols[N-1];
        end
    end

    assign weights_loaded = load_delay;

endmodule