`timescale 1ns / 1ps

module output_store_unit #(
    parameter int N = 4,             // Lanes
    parameter int OUT_WIDTH = 8,     // Output Width
    parameter int ADDR_WIDTH = 10,   // Buffer Depth
    
    // Νέες παράμετροι για σωστά μεγέθη
    parameter int MATRIX_SIZE = 9,   // Bits για Rows/Cols
    parameter int CMD_FIFO_DEPTH = 16
)(
    input  logic clk,
    input  logic rst,

    // Data Input
    input  logic                    quant_valid,
    input  logic [N*OUT_WIDTH-1:0]  quant_data,

    // Command Interface (SPLIT INPUTS για τη FIFO)
    input  logic [MATRIX_SIZE-1:0]  cmd_cols,
    input  logic [MATRIX_SIZE-1:0]  cmd_rows,
    input  logic [ADDR_WIDTH-1:0]   cmd_base_addr, 
    
    input  logic                    cmd_valid,     
    output logic                    cmd_ready,
    
    // Base Address (ΑΦΑΙΡΕΘΗΚΕ ΑΠΟ INPUT, ΕΓΙΝΕ ΕΣΩΤΕΡΙΚΟ)
    // input logic [ADDR_WIDTH-1:0] base_addr, 

    // Status
    output logic                    write_done,

    // Memory Interface
    output logic                    ub_we,
    output logic [ADDR_WIDTH-1:0]   ub_addr,
    output logic [N*OUT_WIDTH-1:0]  ub_wdata
);
    localparam int N_LOG2 = $clog2(N);
    // ============================================================
    // PARAMETER CALCULATIONS
    // ============================================================
    // Το CMD_WIDTH μεγαλώνει για να χωρέσει: Cols + Rows + Address
    localparam int CMD_WIDTH = (MATRIX_SIZE * 2) + ADDR_WIDTH;

    // ============================================================
    // INTERNAL SIGNALS
    // ============================================================
    // Εσωτερικό σήμα για το base_addr (που βγαίνει από τη FIFO)
    logic [ADDR_WIDTH-1:0] base_addr;

    // Προσάρμοσα τα πλάτη στο MATRIX_SIZE (αντί για CMD_WIDTH/2)
    logic [MATRIX_SIZE-1:0] row_c;      
    logic [MATRIX_SIZE-1:0] col_c;
    
    logic [MATRIX_SIZE-1:0] row_cnt;          
    logic [MATRIX_SIZE-1:0] tile_row_number;  
    logic [MATRIX_SIZE-1:0] tile_col_number;
    
    logic processing_batch;
    logic matrix_done;
    
    logic fifo_pop;
    logic fifo_empty, fifo_full;
    logic [CMD_WIDTH-1:0] fifo_data_out; // Το πλάτος ενημερώθηκε

    // Το stride είναι όσο το col_c
    logic [MATRIX_SIZE-1:0] stride;
    
    // Σήμα εισόδου για τη FIFO (Packing)
    logic [CMD_WIDTH-1:0] matrix_row_col; 

    // ============================================================
    // FIFO Instance
    // ============================================================
    assign cmd_ready = !fifo_full;
    
    // PACKING: Ενώνουμε τα inputs σε ένα bus για να μπουν στη FIFO
    assign matrix_row_col = {cmd_cols, cmd_rows, cmd_base_addr};

    simple_fifo #(.WIDTH(CMD_WIDTH), .DEPTH(CMD_FIFO_DEPTH)) u_cmd_fifo (
        .clk(clk), .rst(rst),
        .push(cmd_valid), .data_in(matrix_row_col), 
        .pop(fifo_pop), .data_out(fifo_data_out),
        .full(fifo_full), .empty(fifo_empty)
    );

    // ============================================================
    // Main Logic (Η ΛΟΓΙΚΗ ΠΑΡΕΜΕΙΝΕ ΑΘΙΚΤΗ)
    // ============================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            row_c           <= 0;
            col_c           <= 0;
            processing_batch<= 0;
            fifo_pop        <= 0;
            row_cnt         <= 0;
            tile_row_number <= 0;
            tile_col_number <= 0;
            matrix_done     <= 0;
            ub_we           <= 0;
            ub_addr         <= 0;
            ub_wdata        <= 0;
            write_done      <= 0;
            stride          <= 0;
            base_addr       <= 0;
        end else begin
            fifo_pop   <= 0;
            ub_we      <= 0;
            write_done <= 0;

            // 1. START COMMAND
            if (!processing_batch && !fifo_empty) begin
                // UNPACKING (Ξεπακετάρισμα από FIFO)
                
                // LSB -> Base Address
                base_addr <= fifo_data_out[ADDR_WIDTH-1:0];
                
                // Middle -> Rows
                row_c     <= fifo_data_out[ADDR_WIDTH + MATRIX_SIZE - 1 : ADDR_WIDTH];
                
                // MSB -> Cols
                col_c     <= fifo_data_out[CMD_WIDTH - 1 : ADDR_WIDTH + MATRIX_SIZE];
                
                // Stride is equal to Cols (Upper part)
                stride    <= fifo_data_out[CMD_WIDTH - 1 : ADDR_WIDTH + MATRIX_SIZE];

                row_cnt         <= 0;
                tile_row_number <= 0;
                tile_col_number <= 0;
                
                processing_batch <= 1;
                matrix_done      <= 0;
                fifo_pop         <= 1;
            end

            // 2. WRITE LOGIC
            else if (processing_batch && quant_valid) begin
                ub_we    <= 1;
                ub_wdata <= quant_data;

                // Address calculation (ΑΚΡΙΒΩΣ ΟΠΩΣ ΗΤΑΝ)
                ub_addr <= base_addr + ((tile_row_number * col_c )<< N_LOG2) + tile_col_number + (row_cnt * stride);

                // Counters (ΑΚΡΙΒΩΣ ΟΠΩΣ ΗΤΑΝ)
                
                // Loop 1: Inner
            if (row_cnt == N - 1) begin
                    row_cnt <= 0;
                    // Loop 2: Middle (ΤΩΡΑ ΕΙΝΑΙ ΤΑ COLUMNS)
                    if (tile_col_number == col_c - 1) begin
                        tile_col_number <= 0;
                        // Loop 3: Outer (ΤΩΡΑ ΕΙΝΑΙ ΤΑ ROWS)
                        if (tile_row_number == row_c - 1) begin
                            // ΤΕΛΟΣ
                            matrix_done      <= 1;
                            write_done       <= 1;
                            processing_batch <= 0;
                        end else begin
                            tile_row_number <= tile_row_number + 1;
                        end
                    end else begin
                        tile_col_number <= tile_col_number + 1;
                    end
                end else begin
                    row_cnt <= row_cnt + 1;
                end
            end
        end
    end

endmodule









/*

`timescale 1ns / 1ps

module output_store_unit #(
    parameter int N = 4,             // Lanes
    parameter int OUT_WIDTH = 8,     // Output Width
    parameter int ADDR_WIDTH = 10,   // Buffer Depth
    
    // Νέες παράμετροι για σωστά μεγέθη
    parameter int MATRIX_SIZE = 9,   // Bits για Rows/Cols
    parameter int CMD_FIFO_DEPTH = 16
)(
    input  logic clk,
    input  logic rst,

    // Data Input
    input  logic                    quant_valid,
    input  logic [N*OUT_WIDTH-1:0]  quant_data,

    // Command Interface (SPLIT INPUTS για τη FIFO)
    input  logic [MATRIX_SIZE-1:0]  cmd_cols,
    input  logic [MATRIX_SIZE-1:0]  cmd_rows,
    input  logic [ADDR_WIDTH-1:0]   cmd_base_addr, 
    
    input  logic                    cmd_valid,     
    output logic                    cmd_ready,
    
    // Base Address (ΑΦΑΙΡΕΘΗΚΕ ΑΠΟ INPUT, ΕΓΙΝΕ ΕΣΩΤΕΡΙΚΟ)
    // input logic [ADDR_WIDTH-1:0] base_addr, 

    // Status
    output logic                    write_done,

    // Memory Interface
    output logic                    ub_we,
    output logic [ADDR_WIDTH-1:0]   ub_addr,
    output logic [N*OUT_WIDTH-1:0]  ub_wdata
);
    localparam int N_LOG2 = $clog2(N);
    // ============================================================
    // PARAMETER CALCULATIONS
    // ============================================================
    // Το CMD_WIDTH μεγαλώνει για να χωρέσει: Cols + Rows + Address
    localparam int CMD_WIDTH = (MATRIX_SIZE * 2) + ADDR_WIDTH;

    // ============================================================
    // INTERNAL SIGNALS
    // ============================================================
    // Εσωτερικό σήμα για το base_addr (που βγαίνει από τη FIFO)
    logic [ADDR_WIDTH-1:0] base_addr;

    // Προσάρμοσα τα πλάτη στο MATRIX_SIZE (αντί για CMD_WIDTH/2)
    logic [MATRIX_SIZE-1:0] row_c;      
    logic [MATRIX_SIZE-1:0] col_c;
    
    logic [MATRIX_SIZE-1:0] row_cnt;          
    logic [MATRIX_SIZE-1:0] tile_row_number;  
    logic [MATRIX_SIZE-1:0] tile_col_number;
    
    logic processing_batch;
    logic matrix_done;
    
    logic fifo_pop;
    logic fifo_empty, fifo_full;
    logic [CMD_WIDTH-1:0] fifo_data_out; // Το πλάτος ενημερώθηκε

    // Το stride είναι όσο το col_c
    logic [MATRIX_SIZE-1:0] stride;
    
    // Σήμα εισόδου για τη FIFO (Packing)
    logic [CMD_WIDTH-1:0] matrix_row_col; 

    // ============================================================
    // FIFO Instance
    // ============================================================
    assign cmd_ready = !fifo_full;
    
    // PACKING: Ενώνουμε τα inputs σε ένα bus για να μπουν στη FIFO
    assign matrix_row_col = {cmd_cols, cmd_rows, cmd_base_addr};

    simple_fifo #(.WIDTH(CMD_WIDTH), .DEPTH(CMD_FIFO_DEPTH)) u_cmd_fifo (
        .clk(clk), .rst(rst),
        .push(cmd_valid), .data_in(matrix_row_col), 
        .pop(fifo_pop), .data_out(fifo_data_out),
        .full(fifo_full), .empty(fifo_empty)
    );

    // ============================================================
    // Main Logic (Η ΛΟΓΙΚΗ ΠΑΡΕΜΕΙΝΕ ΑΘΙΚΤΗ)
    // ============================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            row_c           <= 0;
            col_c           <= 0;
            processing_batch<= 0;
            fifo_pop        <= 0;
            row_cnt         <= 0;
            tile_row_number <= 0;
            tile_col_number <= 0;
            matrix_done     <= 0;
            ub_we           <= 0;
            ub_addr         <= 0;
            ub_wdata        <= 0;
            write_done      <= 0;
            stride          <= 0;
            base_addr       <= 0;
        end else begin
            fifo_pop   <= 0;
            ub_we      <= 0;
            write_done <= 0;

            // 1. START COMMAND
            if (!processing_batch && !fifo_empty) begin
                // UNPACKING (Ξεπακετάρισμα από FIFO)
                
                // LSB -> Base Address
                base_addr <= fifo_data_out[ADDR_WIDTH-1:0];
                
                // Middle -> Rows
                row_c     <= fifo_data_out[ADDR_WIDTH + MATRIX_SIZE - 1 : ADDR_WIDTH];
                
                // MSB -> Cols
                col_c     <= fifo_data_out[CMD_WIDTH - 1 : ADDR_WIDTH + MATRIX_SIZE];
                
                // Stride is equal to Cols (Upper part)
                stride    <= fifo_data_out[CMD_WIDTH - 1 : ADDR_WIDTH + MATRIX_SIZE];

                row_cnt         <= 0;
                tile_row_number <= 0;
                tile_col_number <= 0;
                
                processing_batch <= 1;
                matrix_done      <= 0;
                fifo_pop         <= 1;
            end

            // 2. WRITE LOGIC
            else if (processing_batch && quant_valid) begin
                ub_we    <= 1;
                ub_wdata <= quant_data;

                // Address calculation (ΑΚΡΙΒΩΣ ΟΠΩΣ ΗΤΑΝ)
                ub_addr <= base_addr + ((tile_row_number * col_c )<< N_LOG2) + tile_col_number + (row_cnt * stride);

                // Counters (ΑΚΡΙΒΩΣ ΟΠΩΣ ΗΤΑΝ)
                
                // Loop 1: Inner
                if (row_cnt == N - 1) begin
                    row_cnt <= 0; 
                    
                    // Loop 2: Middle
                    if (tile_row_number == row_c - 1) begin
                        tile_row_number <= 0; 

                        // Loop 3: Outer
                        if (tile_col_number == col_c - 1) begin
                            // ΤΕΛΟΣ
                            matrix_done      <= 1;
                            write_done       <= 1;
                            processing_batch <= 0; 
                        end else begin
                            tile_col_number <= tile_col_number + 1;
                        end

                    end else begin
                        tile_row_number <= tile_row_number + 1;
                    end

                end else begin
                    row_cnt <= row_cnt + 1;
                end
            end
        end
    end

endmodule



*/










/*

`timescale 1ns / 1ps

module output_store_unit #(
    parameter int N = 4,             // Lanes
    parameter int OUT_WIDTH = 8,     // Output Width (e.g. INT8)
    parameter int ADDR_WIDTH = 10    // Buffer Depth
)(
    input  logic clk,
    input  logic rst,

    // --- Inputs from Quantizer ---
    input  logic                   quant_valid,
    input  logic [N*OUT_WIDTH-1:0] quant_data,
    
    // --- Control ---
    input  logic                   store_en,
    input  logic [ADDR_WIDTH-1:0]  base_addr, // Πού ξεκινάει το Tile (πάνω αριστερά γωνία)
    input  logic [ADDR_WIDTH-1:0]  num_words, // Πόσες γραμμές έχει το Tile (συνήθως N)
    input  logic [ADDR_WIDTH-1:0]  stride,    // <--- ΝΕΟ: Πόσο πρέπει να πηδάω για την επόμενη γραμμή
    output logic                   write_done,

    // --- Output to Unified Buffer ---
    output logic                   ub_we,
    output logic [ADDR_WIDTH-1:0]  ub_addr,
    output logic [N*OUT_WIDTH-1:0] ub_wdata
);

    logic [ADDR_WIDTH-1:0] current_addr;  // Τρέχουσα διεύθυνση εγγραφής
    logic [ADDR_WIDTH-1:0] words_written; // Μετρητής

    always_ff @(posedge clk) begin
        if (!rst) begin
            ub_we         <= 0;
            ub_addr       <= 0;
            ub_wdata      <= 0;
            write_done    <= 0;
            current_addr  <= 0;
            words_written <= 0;
        end else begin
            
            // Default pulse low
            write_done <= 0;

            if (store_en) begin
                // Αν ο Quantizer στέλνει δεδομένα
                if (quant_valid) begin
                    // 1. Γράφουμε στη Μνήμη
                    ub_we    <= 1;
                    ub_wdata <= quant_data;
                    ub_addr  <= current_addr; // Γράφουμε εκεί που δείχνει ο pointer

                    // 2. Ενημερώνουμε για τον επόμενο κύκλο
                    // Πηδάμε όσο λέει το stride (π.χ. μια ολόκληρη γραμμή εικόνας)
                    current_addr <= current_addr + stride;
                    
                    // 3. Ελέγχουμε αν τελειώσαμε
                    if (words_written == num_words - 1) begin
                        write_done    <= 1;
                        words_written <= 0;         // Reset για το επόμενο Tile
                        // Το current_addr θα γίνει reset εξωτερικά με νέο base_addr
                        // ή μπορούμε να το αφήσουμε εδώ, εξαρτάται από τον controller.
                    end else begin
                        words_written <= words_written + 1;
                    end

                end else begin
                    // Αν έχουμε store_en αλλά όχι valid δεδομένα, περιμένουμε
                    ub_we <= 0;
                end
            end else begin
                // IDLE / RESET STATE (Όταν το store_en είναι 0)
                // Εδώ "οπλίζουμε" το module για το επόμενο Tile
                current_addr  <= base_addr; 
                words_written <= 0;
                ub_we         <= 0;
            end
        end
    end

endmodule

*/