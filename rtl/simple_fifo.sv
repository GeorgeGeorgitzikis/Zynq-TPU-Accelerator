
// ============================================================
// SIMPLE FIFO MODULE
// ============================================================
module simple_fifo #(
    parameter int WIDTH = 16,
    parameter int DEPTH = 16
)(
    input  logic clk, rst,
    input  logic push, pop,
    input  logic [WIDTH-1:0] data_in,
    output logic [WIDTH-1:0] data_out,
    output logic full, empty
);
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [$clog2(DEPTH):0] count; 
    logic [$clog2(DEPTH)-1:0] wr_ptr, rd_ptr;

    assign full  = (count == DEPTH);
    assign empty = (count == 0);
    // FWFT: Τα δεδομένα είναι διαθέσιμα στην έξοδο πριν το pop
    assign data_out = mem[rd_ptr]; 

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0; rd_ptr <= 0; count <= 0;
        end else begin
            if (push && !full) begin
                mem[wr_ptr] <= data_in;
                wr_ptr <= wr_ptr + 1;
            end
            if (pop && !empty) begin
                rd_ptr <= rd_ptr + 1;
            end
            
            // Count Update Logic
            if (push && !pop && !full) 
                count <= count + 1;
            else if (pop && !push && !empty) 
                count <= count - 1;
        end
    end
endmodule