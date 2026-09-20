`timescale 1ns / 1ps

module fifo_axis #(
    parameter int N          = 8,   // AXI Lanes (e.g., 8)
    parameter int DATA_WIDTH = 8,   // Width per Lane
    parameter int DEPTH      = 16   // FIFO Depth
)(
    input  logic clk,
    input  logic rst,

    // --- Write Interface (From Unpacker) ---
    input  logic write_en,
    input  logic [N*DATA_WIDTH-1:0] data_in, 
    input  logic last_in,                    
    output logic full,

    // --- Read Interface (To AXI Stream Master) ---
    input  logic read_en,
    output logic [N*DATA_WIDTH-1:0] data_out,
    output logic last_out,                   
    output logic empty,

    // --- Status ---
    output logic [$clog2(DEPTH):0] count
);

    localparam int TOTAL_W = N * DATA_WIDTH;

    // Memory: Data bits + 1 bit for TLAST at the MSB
    logic [TOTAL_W:0] mem [0:DEPTH-1]; 
    
    logic [$clog2(DEPTH)-1:0] wr_ptr;
    logic [$clog2(DEPTH)-1:0] rd_ptr;
    logic [$clog2(DEPTH):0]   fifo_cnt;

    assign full  = (fifo_cnt == DEPTH);
    assign empty = (fifo_cnt == 0);
    assign count = fifo_cnt;
    
    assign data_out = mem[rd_ptr][TOTAL_W-1:0];
    assign last_out = mem[rd_ptr][TOTAL_W];

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr   <= 0;
            rd_ptr   <= 0;
            fifo_cnt <= 0;
        end else begin
            if (write_en && !full) begin
                mem[wr_ptr] <= {last_in, data_in}; 
                wr_ptr      <= (wr_ptr == DEPTH-1) ? 0 : wr_ptr + 1;
            end

            if (read_en && !empty) begin
                rd_ptr <= (rd_ptr == DEPTH-1) ? 0 : rd_ptr + 1;
            end

            if (write_en && !full && !(read_en && !empty))
                fifo_cnt <= fifo_cnt + 1;
            else if (read_en && !empty && !(write_en && !full))
                fifo_cnt <= fifo_cnt - 1;
        end
    end

endmodule



/*

`timescale 1ns / 1ps

module fifo_axis #(
    parameter int N          = 4,   // Α�?ιθμ�?ς Lanes (Pixels)
    parameter int DATA_WIDTH = 8,   // Πλάτος κάθε Lane
    parameter int DEPTH      = 16   // Βάθος FIFO
)(
    input  logic clk,
    input  logic rst,

    // --- Write Interface (Απ�? BRAM Reader) ---
    input  logic write_en,
    input  logic [N*DATA_WIDTH-1:0] data_in, // Αυτ�?ματος υπολογισμ�?ς πλάτους
    input  logic last_in,                    // TLAST bit
    output logic full,

    // --- Read Interface (Π�?ος AXI Stream) ---
    input  logic read_en,
    output logic [N*DATA_WIDTH-1:0] data_out,
    output logic last_out,                   // TLAST bit
    output logic empty,

    // --- Status ---
    output logic [$clog2(DEPTH):0] count
);

    // 1. Υπολογισμ�?ς Συνολικο�? Πλάτους Δεδομένων
    localparam int TOTAL_W = N * DATA_WIDTH;

    // 2. Η �?νήμη: Πλάτος = Data + 1 bit για το TLAST
    //    Bit [TOTAL_W]   -> TLAST
    //    Bits [TOTAL_W-1:0] -> DATA
    logic [TOTAL_W:0] mem [0:DEPTH-1]; 
    
    // Pointers
    logic [$clog2(DEPTH)-1:0] wr_ptr;
    logic [$clog2(DEPTH)-1:0] rd_ptr;
    logic [$clog2(DEPTH):0]   fifo_cnt;

    // 3. Logic
    assign full     = (fifo_cnt == DEPTH);
    assign empty    = (fifo_cnt == 0);
    assign count    = fifo_cnt;
    
    // Διάσπαση εξ�?δου (Data & Last)
    assign data_out = mem[rd_ptr][TOTAL_W-1:0];
    assign last_out = mem[rd_ptr][TOTAL_W];

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr   <= 0;
            rd_ptr   <= 0;
            fifo_cnt <= 0;
        end else begin
            // --- Write ---
            if (write_en && !full) begin
                // "�?ολλάμε" το last bit πάνω απ�? τα δεδομένα
                mem[wr_ptr] <= {last_in, data_in}; 
                wr_ptr      <= (wr_ptr == DEPTH-1) ? 0 : wr_ptr + 1;
            end

            // --- Read ---
            if (read_en && !empty) begin
                rd_ptr <= (rd_ptr == DEPTH-1) ? 0 : rd_ptr + 1;
            end

            // --- Count Update ---
            if (write_en && !full && !(read_en && !empty))
                fifo_cnt <= fifo_cnt + 1;
            else if (read_en && !empty && !(write_en && !full))
                fifo_cnt <= fifo_cnt - 1;
        end
    end

endmodule


*/