`timescale 1ns / 1ps

module input_skewer_row #(
    parameter int N = 4,
    parameter int DATA_WIDTH = 8
)(
    input  logic clk,
    input  logic rst,
    input  logic input_valid,      
    input  logic [N*DATA_WIDTH-1:0] data_in_packed, 
    
    input  logic input_last,
    output logic output_last,

    output logic signed [DATA_WIDTH-1:0] stream_out [0:N-1],
    output logic valid_out
);

    // --- 1. Unpacking ---
    logic [DATA_WIDTH-1:0] data_in_unpacked [N];

    genvar m;
    generate
        for (m = 0; m < N; m++) begin : gen_unpack
            assign data_in_unpacked[m] = data_in_packed[(m+1)*DATA_WIDTH-1 : m*DATA_WIDTH];
        end
    endgenerate

    // --- 2. Control Signals (1-cycle delay) ---
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_out   <= 0;
            output_last <= 0;
        end else begin
            output_last <= input_last;
            valid_out   <= input_valid;
        end
    end

    // --- 3. Data Skewer (Shift Registers ακριβώς όπως στο Col) ---
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : delay_rows
            
            // Register depth = i + 1
            // Row 0: 1 reg, Row 1: 2 regs, etc.
            logic signed [DATA_WIDTH-1:0] shift_reg [0:i]; 
            integer k;

            always_ff @(posedge clk) begin
                if (rst) begin
                    for (k = 0; k <= i; k++) begin
                        shift_reg[k] <= '0; // Reset all
                    end
                end 
                else begin 
                    // 1. Load the first stage
                    // Zero padding όταν το input_valid είναι 0 για να μην μπαίνουν σκουπίδια
                    shift_reg[0] <= input_valid ? data_in_unpacked[i] : '0;
                    
                    // 2. Shift data to subsequent stages
                    for (k = 1; k <= i; k++) begin
                        shift_reg[k] <= shift_reg[k-1];
                    end
                end
            end
            
            // Assign το αποτέλεσμα από το τελευταίο στάδιο [i]
            assign stream_out[i] = shift_reg[i];

        end
    endgenerate

endmodule





/*


module input_skewer_row #(
    parameter int N = 4,
    parameter int DATA_WIDTH = 8
)(
    input  logic clk,
    input  logic rst,
    input  logic input_valid,      
    input  logic [N*DATA_WIDTH-1:0] data_in_packed, 
    
    input  logic input_last,
    output logic output_last,

    output logic signed [DATA_WIDTH-1:0] stream_out [0:N-1],
    output logic valid_out
);

    logic [DATA_WIDTH-1:0] data_in_unpacked [N];

    genvar i;
    generate
        for (i = 0; i < N; i++) begin : gen_unpack
            assign data_in_unpacked[i] = data_in_packed[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH];
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_out   <= 0;
            output_last <= 0;
        end else begin
            output_last <= input_last;
            valid_out   <= input_valid;
        end
    end

    // Memory: [Rows][Columns]
    logic [DATA_WIDTH-1:0] mem [0:N-1][0:N-1];

    // Write Pointer
    logic [$clog2(N)-1:0] wr_row_sel;

    // Read Pointers per row
    logic [$clog2(N)-1:0] rd_col_ptrs [0:N-1];
    
    // ΝΕΟ: Ανεξάρτητος μετρητής "ζωής" για ΚΑΘΕ γραμμή ξεχωριστά
    logic [$clog2(N):0] read_cnt [0:N-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_row_sel <= 0;

            for (int k=0; k<N; k++) begin
                for (int j=0; j<N; j++) mem[k][j] <= 0;
                rd_col_ptrs[k] <= 0;
                read_cnt[k]    <= 0; // Αρχικά καμία γραμμή δεν διαβάζει
            end
        end 
        else begin
            // ---------------------------------------------------------
            // 1. WRITE (LOAD ROW) - Ορίζουμε και ποιος "ξυπνάει"
            // ---------------------------------------------------------
            if (input_valid) begin
                for (int j=0; j<N; j++) begin
                    mem[wr_row_sel][j] <= data_in_packed[j*DATA_WIDTH +: DATA_WIDTH];
                end

                // Πάμε στην επόμενη γραμμή
                if (wr_row_sel == N-1) wr_row_sel <= 0;
                else                   wr_row_sel <= wr_row_sel + 1;
            end

            // ---------------------------------------------------------
            // 2. READ (Ανεξάρτητη Κίνηση Pointer για ΚΑΘΕ γραμμή)
            // ---------------------------------------------------------
            for (int k=0; k<N; k++) begin
                
                // Αν η γραμμή γράφτηκε ΑΥΤΟΝ τον κύκλο, την κάνουμε Reset και την Ξυπνάμε
                if (input_valid && (wr_row_sel == k)) begin
                    read_cnt[k]    <= N; // Δίνουμε "ζωή" N κύκλων στη γραμμή
                    rd_col_ptrs[k] <= 0; // Μηδενίζουμε τον pointer της για να ξεκινήσει σωστά
                end
                // Αν η γραμμή είναι "ξύπνια", κουνάμε τον pointer της
                else if (read_cnt[k] > 0) begin
                    read_cnt[k] <= read_cnt[k] - 1; // Μειώνουμε τη "ζωή" της
                    
                    if (rd_col_ptrs[k] == N-1) rd_col_ptrs[k] <= 0;
                    else                       rd_col_ptrs[k] <= rd_col_ptrs[k] + 1;
                end
                
            end
        end
    end

    // --- OUTPUT LOGIC ---
    always_comb begin
        for (int k=0; k<N; k++) begin
            // Αν η γραμμή είναι ενεργή (read_cnt > 0), βγάζει τα δεδομένα της.
            // Αλλιώς, βγάζει μηδενικά (Zero-Padding) για να μην περνάνε σκουπίδια στο Array.
            if (read_cnt[k] > 0)
                stream_out[k] = mem[k][rd_col_ptrs[k]];
            else
                stream_out[k] = '0; 
        end
    end

endmodule






*/




































/*


module input_skewer_row #(
    parameter int N = 4,
    parameter int DATA_WIDTH = 8
)(
    input  logic clk,
    input  logic rst,
    input  logic input_valid,      // New ROW arrives from memory
    input  logic [N*DATA_WIDTH-1:0] data_in_packed, // Entire row (A_i0, A_i1...)
    
    input  logic input_last,
    output logic output_last,

    // Output: Skewed column (A00, A1x, A2x...)
    output logic signed [DATA_WIDTH-1:0] stream_out [0:N-1],

    output logic valid_out
);
    /////////////////////////////////////////////////////////////////////////////////////////
    // Declaration of unpacked array (N elements, each of size DATA_WIDTH)
    logic [DATA_WIDTH-1:0] data_in_unpacked [N];

    genvar i;
    generate
        for (i = 0; i < N; i++) begin : gen_unpack
            assign data_in_unpacked[i] = data_in_packed[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH];
        end
    endgenerate








    // Memory: [Rows][Columns]
    // mem[0] = Buffer for the 1st row of matrix A
    // mem[1] = Buffer for the 2nd row of matrix A
    logic [DATA_WIDTH-1:0] mem [0:N-1][0:N-1];

    // Write Pointer: Selects ROW (Row Selector)
    logic [$clog2(N)-1:0] wr_row_sel;

    // Read Pointers: Select COLUMN (Column Selectors)
    logic [$clog2(N)-1:0] rd_col_ptrs [0:N-1];

    // Counter that fits the number N (e.g., 4)
    logic [$clog2(N):0] flush_counter;

    
    // LAST PIPELINE
    //logic [N-1:0] last_pipe;
    always_ff @(posedge clk) begin
    if (rst) begin
        valid_out <= 0;
        //last_pipe  <= 0;
        output_last  <= 0;
    end else begin
        //last_pipe  <= {last_pipe [N-2:0], input_last};
        output_last  <= input_last;
        valid_out <= input_valid;

    end
    end
    //assign output_last  = last_pipe [N-1];

    

  //  integer i, j;

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_row_sel <= 0;
            flush_counter <= 0;
            //valid_out <= 0;

            for (int i=0; i<N; i++) begin
                // Memory reset
                for (int j=0; j<N; j++) mem[i][j] <= 0;
                
                // Skew Initialization (As before)
                // Row 0 starts at col 0. Row 1 starts at col N-1 (for delay)...
                if (i == 0) rd_col_ptrs[i] <= 0;
                else        rd_col_ptrs[i] <= N - i;
            end
        end 
        else begin
        
            if (input_valid) begin
                // As long as data is arriving, keep the counter full (e.g., at 4)
                flush_counter <= N - 1;
                //valid_out <= 1'b1; 
            end
            else if (flush_counter > 0) begin
                // If data stops, decrement the counter
                flush_counter <= flush_counter - 1;
            end       
        
            if (input_valid) begin
                // ---------------------------------------------------------
                // 1. WRITE (LOAD ROW) - HORIZONTAL
                // ---------------------------------------------------------
                // Write the whole packet to the row indicated by wr_row_sel
                for (int j=0; j<N; j++) begin
                    mem[wr_row_sel][j] <= data_in_packed[j*DATA_WIDTH +: DATA_WIDTH];
                end

                // Move to the next row for the next write
                if (wr_row_sel == N-1) 
                    wr_row_sel <= 0;
                else 
                    wr_row_sel <= wr_row_sel + 1;
            end

            // -----------------------------------------------------
            // 3. READ (Pointer Movement)
            // -----------------------------------------------------
            // They move if we are writing (input_valid) 
            // Or if we have remainder in the counter (flush_counter > 0)
            if (input_valid || (flush_counter > 0)) begin
                //valid_out <= 1'b1;
                for (int i=0; i<N; i++) begin
                    if (rd_col_ptrs[i] == N-1)
                        rd_col_ptrs[i] <= 0;
                    else
                        rd_col_ptrs[i] <= rd_col_ptrs[i] + 1;
                end
            end
            //else begin
                //valid_out <= 1'b0;
            //end 
        end
    end

// --- OUTPUT (OUTPUT LOGIC) ---
    always_comb begin
        logic [$clog2(N)-1:0] idx; 

        for (int i=0; i<N; i++) begin
            // Safe calculation of ptr - 1
            if (rd_col_ptrs[i] == 0) 
                idx = N - 1;
            else 
                idx = rd_col_ptrs[i] - 1;

            stream_out[i] = mem[i][idx];
        end
    end

endmodule





*/