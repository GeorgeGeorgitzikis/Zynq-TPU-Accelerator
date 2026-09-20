`timescale 1ns / 1ps

module acc_ping_pong_wrapper #(
    parameter int N = 4,
    parameter int ACC_WIDTH = 32,
    parameter int ADDR_WIDTH = 10
)(
    input  logic clk,
    input  logic rst,

    // --- Control Signals ---
    input  logic swap_banks,         // Εναλλαγή Ping-Pong

    // ============================================================
    // HOT PATH: ACCUMULATOR (Direct Pipeline)
    // ============================================================
    input  logic                   acc_we,
    input  logic [ADDR_WIDTH-1:0]  acc_wr_addr,
    input  logic [N*ACC_WIDTH-1:0] acc_wr_data,
    
    input  logic                   acc_re,
    input  logic [ADDR_WIDTH-1:0]  acc_rd_addr,
    output logic [N*ACC_WIDTH-1:0] acc_rd_data,

    // ============================================================
    // COLD PATH: QUANTIZER READOUT (Streaming - No Backpressure)
    // ============================================================
    // Είσοδοι Ελέγχου
    input  logic                   start_readout,// Εντολή εκκίνησης
    input  logic [ADDR_WIDTH-1:0]  num_words,    

    // �?ξοδοι (Αφαι�?έσαμε το ready)
    output logic                   quant_valid,  // "Πά�?ε δεδομένα"
    output logic [N*ACC_WIDTH-1:0] quant_data    // Τα δεδομένα
);

    // ------------------------------------------------------------
    // 1. ΕΣΩΤΕΡΙ�?Α ΣΗ�?ΑΤΑ
    // ------------------------------------------------------------
    logic bank_sel; 

    logic [ADDR_WIDTH-1:0] current_limit;

    // Σήματα Muxing
    logic we_0, we_1;
    logic re_0, re_1;
    logic [ADDR_WIDTH-1:0]  addr_wr_0, addr_wr_1;
    logic [ADDR_WIDTH-1:0]  addr_rd_0, addr_rd_1;
    logic [N*ACC_WIDTH-1:0] din_0, din_1;
    logic [N*ACC_WIDTH-1:0] dout_0, dout_1;

    // Σήματα Controller Ανάγνωσης
    logic [ADDR_WIDTH-1:0]  q_read_ptr;
    logic [ADDR_WIDTH-1:0]  q_count;
    logic                   q_read_en;
    logic [N*ACC_WIDTH-1:0] raw_mem_data;

    // Ping-Pong Toggle
    always_ff @(posedge clk) begin
        if (rst) bank_sel <= 0;
        else if (swap_banks) bank_sel <= ~bank_sel;
    end

    // ------------------------------------------------------------
    // 2. MUX / DEMUX (�? "Τ�?οχον�?μος")
    // ------------------------------------------------------------
    always_comb begin
        // Default values
        we_0 = 0; we_1 = 0; re_0 = 0; re_1 = 0;
        addr_wr_0 = 0; addr_wr_1 = 0;
        addr_rd_0 = 0; addr_rd_1 = 0;
        din_0 = 0; din_1 = 0;

        // Επιλογή πηγής δεδομένων για τον Quantizer
        raw_mem_data = (bank_sel == 0) ? dout_1 : dout_0;

        if (bank_sel == 0) begin
            // Acc -> Bank 0 | Quant -> Bank 1
            we_0 = acc_we; addr_wr_0 = acc_wr_addr; din_0 = acc_wr_data;
            re_0 = acc_re; addr_rd_0 = acc_rd_addr;
            acc_rd_data = dout_0; 

            re_1 = q_read_en;
            addr_rd_1 = q_read_ptr;
        end else begin
            // Acc -> Bank 1 | Quant -> Bank 0
            we_1 = acc_we; addr_wr_1 = acc_wr_addr; din_1 = acc_wr_data;
            re_1 = acc_re; addr_rd_1 = acc_rd_addr;
            acc_rd_data = dout_1;

            re_0 = q_read_en;
            addr_rd_0 = q_read_ptr;
        end
    end

    // ------------------------------------------------------------
    // 3. READ CONTROLLER (Απλοποιημένος - Streaming)
    // ------------------------------------------------------------
    typedef enum logic {IDLE, READ} state_t;
    state_t state;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            q_read_ptr <= 0;
            q_count <= 0;
            q_read_en <= 0;
        end else begin
            case (state)
                IDLE: begin
                    q_read_ptr <= 0;
                    q_count <= 0;
                    q_read_en <= 0;
                    if (start_readout) begin
                        current_limit <= num_words; // Εδ�? γίνεται η "α�?παγή" της τιμής
                        state <= READ;
                    end
                end

                READ: begin
                    // Διαβάζουμε ασταμάτητα μέχ�?ι να τελει�?σουν οι λέξεις
                    if (q_count < current_limit) begin
                        q_read_en <= 1;
                        //q_read_ptr <= q_read_ptr + 1;   /////////////////////////////////////////////////////////////////////////////////////////
                        q_read_ptr <= q_count;
                        q_count <= q_count + 1;
                    end else begin
                        q_read_en <= 0;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    // ------------------------------------------------------------
    // 4. OUTPUT LOGIC (Pipeline Delay Match)
    // ------------------------------------------------------------
    // H BRAM έχει Latency 1 κ�?κλου.
    // Ά�?α αν ζητήσω δεδομένα (read_en) τ�?�?α, το valid θα π�?έπει να ανά�?ει στον επ�?μενο κ�?κλο.
    
    // always_ff @(posedge clk) begin   ///////////////////////////////////////////////////////////////////////////////////////////////
    //     if (rst) begin
    //         quant_valid <= 0;
    //         quant_data  <= 0;
    //     end else begin
    //         // Το Valid ακολουθεί το read_en με 1 κ�?κλο καθυστέ�?ηση
    //         quant_valid <= q_read_en;
            
    //         // Τα δεδομένα έ�?χονται απ�? τη μνήμη
    //         quant_data  <= raw_mem_data;
    //     end
    // end

    // ------------------------------------------------------------    ////////////////////////////////////////////////////////////////
    // 4. OUTPUT LOGIC (Pipeline Delay Match)
    // ------------------------------------------------------------
    
    logic q_read_en_delay; // <--- ΝΕΟ: Ενδιάμεσος καταχωρητής για καθυστέρηση

    always_ff @(posedge clk) begin
        if (rst) begin
            q_read_en_delay <= 0;
            quant_valid     <= 0;
            quant_data      <= 0;
        end else begin
            // Τα δεδομένα καθυστερούν 2 κύκλους (1 από τη BRAM + 1 από τον καταχωρητή quant_data)
            // Άρα δημιουργούμε μια αλυσίδα 2 κύκλων και για το valid!
            
            q_read_en_delay <= q_read_en;       // 1ος κύκλος καθυστέρησης
            quant_valid     <= q_read_en_delay; // 2ος κύκλος καθυστέρησης
            
            quant_data      <= raw_mem_data;    // Τα δεδομένα που μόλις βγήκαν από τη BRAM
        end
    end



    // ------------------------------------------------------------
    // 5. MEMORY INSTANTIATION
    // ------------------------------------------------------------
    acc_bram #(.N(N), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) bank0 (
        .clk(clk),
        .we_a(we_0), .addr_a(addr_wr_0), .din_a(din_0),
        .re_b(re_0), .addr_b(addr_rd_0), .dout_b(dout_0)
    );

    acc_bram #(.N(N), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) bank1 (
        .clk(clk),
        .we_a(we_1), .addr_a(addr_wr_1), .din_a(din_1),
        .re_b(re_1), .addr_b(addr_rd_1), .dout_b(dout_1)
    );

endmodule