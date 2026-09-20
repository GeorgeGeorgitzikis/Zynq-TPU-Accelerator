module ping_pong_memory #(
    parameter int N   = 4,    // Πλήθος στοιχείων (Lanes)
    parameter int ELEM_WIDTH = 8,    // Πλάτος κάθε στοιχείου (INT8)
    parameter int DEPTH      = 1024  // Βάθος κάθε Bank
)(
    input  logic clk,
    input  logic rst,

    // --- Control Signal ---
    input  logic swap_buffers,       // 0->1 ή 1->0: Αλλαγή Ρόλων

    // ============================================================
    // SIDE A: HOST / DMA INTERFACE (Server Side)
    // ============================================================
    // Ο Host γράφει Inputs και διαβάζει Outputs
    input  logic                     dma_we,
    input  logic [$clog2(DEPTH)-1:0] dma_wr_addr,
    input  logic [N*ELEM_WIDTH-1:0] dma_wdata,

    input  logic                     dma_re,
    input  logic [$clog2(DEPTH)-1:0] dma_rd_addr,
    output logic [N*ELEM_WIDTH-1:0] dma_rdata,

    // ============================================================
    // SIDE B: TPU CORE INTERFACE (Accelerator Side)
    // ============================================================
    // H TPU διαβάζει Inputs και γράφει Outputs
    input  logic                     tpu_we,        // Από Output Store Unit
    input  logic [$clog2(DEPTH)-1:0] tpu_wr_addr,
    input  logic [N*ELEM_WIDTH-1:0] tpu_wdata,

    input  logic                     tpu_re,        // Από Data Loader
    input  logic [$clog2(DEPTH)-1:0] tpu_rd_addr,
    output logic [N*ELEM_WIDTH-1:0] tpu_rdata
);

    // ------------------------------------------------------------
    // 1. ΕΣΩΤΕΡΙΚΑ ΣΗΜΑΤΑ
    // ------------------------------------------------------------
    logic bank_sel; // 0: DMA->Bank0 / TPU->Bank1,  1: DMA->Bank1 / TPU->Bank0
    logic swap_d;
    // Σήματα προς τα Banks (Physical Signals)
    // we_0: Write Enable για Bank 0, κτλ.
    logic we_0, we_1;
    logic re_0, re_1;
    logic [$clog2(DEPTH)-1:0] addr_a_0, addr_a_1; // Write Addresses
    logic [$clog2(DEPTH)-1:0] addr_b_0, addr_b_1; // Read Addresses
    logic [N*ELEM_WIDTH-1:0] din_0, din_1;
    logic [N*ELEM_WIDTH-1:0] dout_0, dout_1;

    // ------------------------------------------------------------
    // 2. BANK SELECTION LOGIC (Toggle)
    // ------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            bank_sel <= 0;
            swap_d   <= 0;
        end else begin
            swap_d <= swap_buffers;
            if (swap_buffers && !swap_d) begin
                bank_sel <= ~bank_sel;
            end

        end
    end

    // ------------------------------------------------------------
    // 3. MUX / DEMUX (Routing Logic)
    // ------------------------------------------------------------
    // Θυμήσου: Η BRAM μας έχει Port A = Write, Port B = Read.
    // Πρέπει να δρομολογήσουμε τα Write σήματα (we, din) στο Port A
    // και τα Read σήματα (re, addr) στο Port B.

    always_comb begin
        // --- Output Routing (Data Out Mux) ---
        // Ποιο Bank διαβάζει το DMA και ποιο η TPU;
        if (bank_sel == 0) begin
            dma_rdata = dout_0; // DMA διαβάζει Bank 0
            tpu_rdata = dout_1; // TPU διαβάζει Bank 1
        end else begin
            dma_rdata = dout_1; // DMA διαβάζει Bank 1
            tpu_rdata = dout_0; // TPU διαβάζει Bank 0
        end

        // --- Input Routing (Control Signals Mux) ---
        if (bank_sel == 0) begin
            // STATE 0: DMA <-> Bank 0, TPU <-> Bank 1
            
            // BANK 0 (Συνδεδεμένο στο DMA)
            we_0     = dma_we;
            addr_a_0 = dma_wr_addr;
            din_0    = dma_wdata;
            
            re_0     = dma_re;
            addr_b_0 = dma_rd_addr;

            // BANK 1 (Συνδεδεμένο στην TPU)
            we_1     = tpu_we;        // Η TPU γράφει τα Outputs εδώ
            addr_a_1 = tpu_wr_addr;
            din_1    = tpu_wdata;
            
            re_1     = tpu_re;        // Η TPU διαβάζει τα Inputs από εδώ
            addr_b_1 = tpu_rd_addr;

        end else begin
            // STATE 1: DMA <-> Bank 1, TPU <-> Bank 0
            
            // BANK 0 (Συνδεδεμένο στην TPU)
            we_0     = tpu_we;
            addr_a_0 = tpu_wr_addr;
            din_0    = tpu_wdata;
            
            re_0     = tpu_re;
            addr_b_0 = tpu_rd_addr;

            // BANK 1 (Συνδεδεμένο στο DMA)
            we_1     = dma_we;
            addr_a_1 = dma_wr_addr;
            din_1    = dma_wdata;
            
            re_1     = dma_re;
            addr_b_1 = dma_rd_addr;
        end
    end

    // ------------------------------------------------------------
    // 4. MEMORY INSTANTIATION
    // ------------------------------------------------------------
    // Χρησιμοποιούμε το BRAM module που ορίσαμε πριν
    bram #(
        .N(N), 
        .ELEM_WIDTH(ELEM_WIDTH), 
        .DEPTH(DEPTH)
    ) bank_0 (
        .clk(clk),
        // Port A (Write)
        .we_a(we_0), 
        .addr_a(addr_a_0), 
        .din_a(din_0),
        // Port B (Read)
        .re_b(re_0), 
        .addr_b(addr_b_0), 
        .dout_b(dout_0)
    );

    bram #(
        .N(N), 
        .ELEM_WIDTH(ELEM_WIDTH), 
        .DEPTH(DEPTH)
    ) bank_1 (
        .clk(clk),
        // Port A (Write)
        .we_a(we_1), 
        .addr_a(addr_a_1), 
        .din_a(din_1),
        // Port B (Read)
        .re_b(re_1), 
        .addr_b(addr_b_1), 
        .dout_b(dout_1)
    );

endmodule