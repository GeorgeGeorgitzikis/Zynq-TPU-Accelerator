// =============================================================================
// Module: ws_systolic_pe
// Description:
//   Weight-Stationary Systolic Processing Element (PE) with dual-buffer
//   (active/shadow) weight registers and DSP48-targeted Multiply-Accumulate (MAC).
//
// Features:
//   - Weight-Stationary Operation: Weights are stationary in local registers while
//     activations flow left-to-right and partial sums accumulate top-to-bottom.
//   - Double-Buffering (Ping-Pong): Shadow weight register allows pre-loading the
//     next tile's weights concurrently while the active weights are computing.
//   - Systolic Swap Control: Swap handshake propagates systolically across the array.
// =============================================================================

(* use_dsp = "yes" *)
module ws_systolic_pe #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
)(
    input  logic clk,
    input  logic rst,

    // Systolic Swap Control (Wavefront propagation)
    input  logic swap_in_left,
    input  logic swap_in_top,
    output logic swap_out_right,
    output logic swap_out_down,

    // Weight Load Control
    input  logic load_in_top,

    // Activation Data Path (Horizontal propagation: West -> East)
    input  logic signed [DATA_WIDTH-1:0] a_in,
    output logic signed [DATA_WIDTH-1:0] a_out,

    // Partial Sum Accumulation Path (Vertical propagation: North -> South)
    input  logic signed [ACC_WIDTH-1:0]  c_in,
    output logic signed [ACC_WIDTH-1:0]  c_out,

    // Weight Data Path (Vertical propagation during pre-loading)
    input  logic signed [DATA_WIDTH-1:0] w_in,
    output logic signed [DATA_WIDTH-1:0] w_out
);

    // Internal Dual-Buffer Registers for Weights
    logic signed [DATA_WIDTH-1:0] w_active;  // Currently active weight used in MAC
    logic signed [DATA_WIDTH-1:0] w_shadow;  // Shadow weight loaded in background

    logic active_load;
    logic active_swap;

    assign active_load = load_in_top;
    assign active_swap = swap_in_left | swap_in_top;

    always_ff @(posedge clk) begin
        if (rst) begin
            a_out          <= '0;
            w_out          <= '0;
            c_out          <= '0;
            w_active       <= '0;
            w_shadow       <= '0;
            swap_out_right <= 1'b0;
            swap_out_down  <= 1'b0;
        end else begin
            // 1. Forward Activations & Weights (Pipelined Data Flow)
            a_out <= a_in;
            w_out <= w_in;

            // 2. Systolic Propagation of Swap Control Signal
            swap_out_right <= active_swap;
            swap_out_down  <= active_swap;

            // 3. Multiply-Accumulate (MAC): c_out = c_in + (a_in * w_active)
            c_out <= c_in + (a_in * w_active);

            // 4. Background Shadow Weight Pre-Loading
            if (active_load) begin
                w_shadow <= w_in;
            end

            // 5. Weight Buffer Swap: Promote shadow weights to active computation
            if (active_swap) begin
                w_active <= w_shadow;
            end
        end
    end

endmodule