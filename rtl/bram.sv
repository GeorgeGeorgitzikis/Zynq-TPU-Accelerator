module bram #(
    parameter int N    = 4,    // Πλήθος στοιχείων (N)
    parameter int ELEM_WIDTH = 8,    // Πλάτος κάθε στοιχείου (π.χ. INT8)
    parameter int DEPTH      = 1024  // Πόσες λέξεις χωράει
)(
    input  logic clk,
    
    // Port A: Write-Only
    input  logic                     we_a,
    input  logic [$clog2(DEPTH)-1:0] addr_a,
    // Εδώ γίνεται ο υπολογισμός: 4 * 8 = 32 bits
    input  logic [N*ELEM_WIDTH-1:0] din_a,

    // Port B: Read-Only
    input  logic                     re_b,
    input  logic [$clog2(DEPTH)-1:0] addr_b,
    output logic [N*ELEM_WIDTH-1:0] dout_b
);

    // Υπολογισμός του συνολικού πλάτους της λέξης
    localparam TOTAL_WIDTH = N * ELEM_WIDTH;

    // Ορισμός της μνήμης (Array of 32-bit words)
    (* ram_style = "block" *) 
    logic [TOTAL_WIDTH-1:0] ram [0:DEPTH-1];
    
    // Register εξόδου
    logic [TOTAL_WIDTH-1:0] ram_data_b;

    // Port A: Write Operation
    always_ff @(posedge clk) begin
        if (we_a) begin
            ram[addr_a] <= din_a;
        end
    end

    // Port B: Read Operation
    always_ff @(posedge clk) begin
        if (re_b) begin
            ram_data_b <= ram[addr_b];
        end
    end

    assign dout_b = ram_data_b;

endmodule