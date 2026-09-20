module acc_bram #(
    parameter int N = 4,            // Πόσα PEs έχεις στη σειρά
    parameter int ACC_WIDTH = 32,   // Πλάτος αποτελέσματος (INT32)
    parameter int ADDR_WIDTH = 10   // Βάθος μνήμης (1024 θέσεις)
)(
    input  logic clk,

    // ============================================================
    // PORT A: WRITE ONLY (Χρησιμοποιείται για την εγγραφή των Sums)
    // Συνδέεται στο: mem_we, mem_wr_addr, mem_din του accumulator_ctrl
    // ============================================================
    input  logic we_a,
    input  logic [ADDR_WIDTH-1:0] addr_a,
    input  logic [N*ACC_WIDTH-1:0] din_a,  // 128-bit Input

    // ============================================================
    // PORT B: READ ONLY (Χρησιμοποιείται για ανάγνωση Sums)
    // Συνδέεται στο: mem_re, mem_rd_addr, mem_dout του accumulator_ctrl
    // ΚΑΙ αργότερα στον Quantizer
    // ============================================================
    input  logic re_b,
    input  logic [ADDR_WIDTH-1:0] addr_b,
    output logic [N*ACC_WIDTH-1:0] dout_b  // 128-bit Output
);

    // 1. Υπολογισμός συνολικού πλάτους (π.χ. 4 * 32 = 128 bits)
    localparam TOTAL_WIDTH = N * ACC_WIDTH;

    // 2. Ορισμός της Μνήμης (Array of Registers)
    // Το Vivado θα το αναγνωρίσει αυτόματα ως Block RAM (BRAM)
    (* ram_style = "block" *) 
    logic [TOTAL_WIDTH-1:0] ram [0:(2**ADDR_WIDTH)-1];

    // 3. Λογική Μνήμης (Synchronous Read/Write)
    always_ff @(posedge clk) begin
        // --- Port A (Write) ---
        if (we_a) begin
            ram[addr_a] <= din_a;
        end

        // --- Port B (Read) ---
        if (re_b) begin
            dout_b <= ram[addr_b];
        end
    end

endmodule