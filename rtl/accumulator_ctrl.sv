`timescale 1ns / 1ps

module accumulator_ctrl #(
    parameter int N = 4,                // Μέγεθος Array
    parameter int ACC_WIDTH = 32,       // Πλάτος Δεδομένων (32-bit)
    parameter int ADDR_WIDTH = 10       // Βάθος Μνήμης
)(
    input  logic clk,
    input  logic rst,

    // --- Interface με το Deskewer (Είσοδος Νέων Δεδομένων) ---
    input  logic signed [N*ACC_WIDTH-1:0] new_sums_packed, // Τα 4 αποτελέσματα μαζί
    input  logic valid_in,                                 // Έγκυρα δεδομένα εισόδου
    input  logic last_in,                                  

    // --- Control Signals (Από τον Controller) ---
    input  logic accumulate_en,         // 0: Overwrite (1ο Tile), 1: Add (Επόμενα Tiles)
    input  logic [ADDR_WIDTH-1:0] start_addr, 

    output logic done_tick,             // Ολοκληρώθηκε η εγγραφή του Batch
    output logic busy,                  // Το pipeline έχει ενεργά δεδομένα

    // --- Interface με την Accumulator BRAM (Dual Port Logic) ---
    // Port A: WRITE ONLY
    output logic [ADDR_WIDTH-1:0] mem_wr_addr,
    output logic [N*ACC_WIDTH-1:0] mem_din,
    output logic mem_we,
    
    // Port B: READ ONLY
    output logic [ADDR_WIDTH-1:0] mem_rd_addr,
    output logic mem_rd_en,
    input  logic [N*ACC_WIDTH-1:0] mem_dout // Η παλιά τιμή από τη μνήμη
);

    // --- Εσωτερικά Σήματα Pipeline ---
    
    // Stage 1 (Καταχώρηση εισόδων & Αίτηση ανάγνωσης)
    logic [ADDR_WIDTH-1:0] addr_d1;
    logic valid_d1, last_d1;
    logic accum_mode_d1;
    logic signed [N*ACC_WIDTH-1:0] new_data_d1; 

    // Stage 2 (Αναμονή δεδομένων BRAM - Latency)
    logic [ADDR_WIDTH-1:0] addr_d2;
    logic valid_d2, last_d2;
    logic accum_mode_d2;
    logic signed [N*ACC_WIDTH-1:0] new_data_d2;

    // Unpacked μορφή για τις πράξεις
    logic signed [ACC_WIDTH-1:0] old_values [0:N-1];
    logic signed [ACC_WIDTH-1:0] new_values [0:N-1];
    logic signed [ACC_WIDTH-1:0] result_values [0:N-1];


    // Το busy ενημερώνεται ώστε να περιλαμβάνει και το νέο _d2 stage
    assign busy = valid_in | valid_d1 | valid_d2 | mem_we;

    // ----------------------------------------------------------------
    // Stage 1: Address Generation & Read Request
    // ----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_rd_en     <= 0;
            last_d1       <= 0;
            valid_d1      <= 0;
            addr_d1       <= 0;
            new_data_d1   <= 0;
            accum_mode_d1 <= 0;
        end else begin
            if (valid_in) begin
                mem_rd_addr <= start_addr;
                mem_rd_en   <= 1; // Ενεργοποιήθηκε η ανάγνωση!

                new_data_d1   <= new_sums_packed;
                accum_mode_d1 <= accumulate_en;
                addr_d1       <= start_addr;
                valid_d1      <= 1;
                last_d1       <= last_in; 
            end else begin
                mem_rd_en <= 0;
                valid_d1  <= 0;
                last_d1   <= 0;
            end
        end
    end

    // ----------------------------------------------------------------
    // Stage 2: Pipeline Delay (Περιμένουμε 1 κύκλο τη BRAM)
    // ----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_d2      <= 0;
            last_d2       <= 0;
            addr_d2       <= 0;
            accum_mode_d2 <= 0;
            new_data_d2   <= 0;
        end else begin
            valid_d2      <= valid_d1;
            last_d2       <= last_d1;
            addr_d2       <= addr_d1;
            accum_mode_d2 <= accum_mode_d1;
            new_data_d2   <= new_data_d1;
        end
    end

    // ----------------------------------------------------------------
    // Stage 3: Arithmetic Logic (Add or Overwrite)
    // ----------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : adder_loop
            // Χρησιμοποιούμε τα σήματα του Stage 2 (_d2) που είναι συγχρονισμένα με το mem_dout
            assign old_values[i] = mem_dout[i*ACC_WIDTH +: ACC_WIDTH];
            assign new_values[i] = new_data_d2[i*ACC_WIDTH +: ACC_WIDTH];

            always_comb begin
                if (accum_mode_d2) begin
                    // MODE: ADD (Προσθέτουμε στο υπάρχον)
                    result_values[i] = old_values[i] + new_values[i];
                end else begin
                    // MODE: OVERWRITE (Γράφουμε το καινούργιο πάνω στο παλιό)
                    result_values[i] = new_values[i];
                end
            end
        end
    endgenerate

    // ----------------------------------------------------------------
    // Stage 4: Write Back
    // ----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_we      <= 0;
            mem_wr_addr <= 0;
            mem_din     <= 0;
            done_tick   <= 0;
        end else begin
            // Αν το προηγούμενο στάδιο (_d2) είχε έγκυρα δεδομένα, γράφουμε
            if (valid_d2) begin
                mem_we      <= 1;
                mem_wr_addr <= addr_d2; 
                
                // Pack results back to wide vector
                for (int k=0; k<N; k++) begin
                    mem_din[k*ACC_WIDTH +: ACC_WIDTH] <= result_values[k];
                end

                // Status Logic: Αν αυτό που γράφουμε τώρα ήταν το "last", τότε τελειώσαμε
                if (last_d2) begin
                    done_tick <= 1;
                end else begin
                    done_tick <= 0;
                end

            end else begin
                mem_we    <= 0;
                done_tick <= 0;
            end
        end
    end

endmodule









/*


module accumulator_ctrl #(
    parameter int N = 4,                // ??έγεθος Array
    parameter int ACC_WIDTH = 32,       // Πλάτος Δεδομένων (32-bit)
    parameter int ADDR_WIDTH = 10       // Βάθος ??νήμης
)(
    input  logic clk,
    input  logic rst,

    // --- Interface με το Deskewer (Είσοδος ??έων Δεδομένων) ---
    input  logic signed [N*ACC_WIDTH-1:0] new_sums_packed, // Τα 4 αποτελέσματα μαζί
    input  logic valid_in,                            // ??γκυ??α δεδομένα εισ??δου
    input  logic last_in,                                 

    // --- Control Signals (Απ?? τον Controller) ---
    input  logic accumulate_en,         // 0: Overwrite (1ο Tile), 1: Add (Επ??μενα Tiles)
    input  logic [ADDR_WIDTH-1:0] start_addr, 

    output logic done_tick,             // <--- NEW: ??λοκλη????θηκε η εγγ??αφή του Batch
    output logic busy,                  // <--- NEW: Το pipeline έχει ενε??γά δεδομένα

    // --- Interface με την Accumulator BRAM (Dual Port Logic) ---
    // Port A: WRITE ONLY
    output logic [ADDR_WIDTH-1:0] mem_wr_addr,
    output logic [N*ACC_WIDTH-1:0] mem_din,
    output logic mem_we,
    
    // Port B: READ ONLY
    output logic [ADDR_WIDTH-1:0] mem_rd_addr,
    output logic mem_rd_en,
    input  logic [N*ACC_WIDTH-1:0] mem_dout // Η παλιά τιμή απ?? τη μνήμη
);

    // --- Εσωτε??ικά Σήματα Pipeline ---
    
    // ??ετ??ητής διε??θυνσης για το διάβασμα
    //logic [ADDR_WIDTH-1:0] current_rd_addr;
    
    // ??αθυστε??ημένα σήματα (για να ται??ιάξουν με το Latency της μνήμης)
    logic [ADDR_WIDTH-1:0] addr_d1, addr_d2;
    logic valid_d1, last_d1;
    logic accum_mode_d1;
    
    logic signed [N*ACC_WIDTH-1:0] new_data_d1; // Buffer για τα δεδομένα εισ??δου

    // Unpacked μο??φή για τις π??άξεις
    logic signed [ACC_WIDTH-1:0] old_values [0:N-1];
    logic signed [ACC_WIDTH-1:0] new_values [0:N-1];
    logic signed [ACC_WIDTH-1:0] result_values [0:N-1];


    assign busy = valid_in | valid_d1  | mem_we;

    // ----------------------------------------------------------------
    // Stage 1: Address Generation & Read Request
    // ----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            //current_rd_addr <= 0;
            mem_rd_en <= 0;
            // Reset Pipeline registers

            last_d1         <= 0;

            valid_d1 <= 0;
            addr_d1  <= 0;
            new_data_d1 <= 0;
            accum_mode_d1 <= 0;
        end else begin
            // Αν έ??χονται έγκυ??α δεδομένα απ?? το Array (μέσω Deskewer)
            if (valid_in) begin
                // 1. Δίνουμε διε??θυνση ανάγνωσης
                mem_rd_addr <= start_addr;

                //mem_rd_addr <= start_addr + current_rd_addr;
                mem_rd_en   <= 1; ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

                // 2. Αυξάνουμε τον μετ??ητή για το επ??μενο
                //current_rd_addr <= current_rd_addr + 1;

                // 3. Αποθηκε??ουμε τα δεδομένα εισ??δου και το control για το επ??μενο στάδιο
                new_data_d1   <= new_sums_packed;
                accum_mode_d1 <= accumulate_en;
                //addr_d1       <= start_addr + current_rd_addr; // ????ατάμε ποια διε??θυνση διαβάσαμε
                addr_d1       <= start_addr;
                valid_d1      <= 1;

                last_d1         <= last_in; // Π??ο??θηση της σημαίας "last"

            end else begin
                mem_rd_en <= 0;
                valid_d1  <= 0;
                // Reset counter ??ταν σταματήσει το valid (για το επ??μενο batch)
                //current_rd_addr <= 0; 
                last_d1         <= 0;
            end
        end
    end

    // ----------------------------------------------------------------
    // Stage 2: Arithmetic Logic (Add or Overwrite)
    // ----------------------------------------------------------------
    // Εδ?? φτάνουν τα δεδομένα απ?? τη μνήμη (mem_dout) μετά απ?? 1 κ??κλο latency
    
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : adder_loop
            // Unpack τα wide vectors
            assign old_values[i] = mem_dout[i*ACC_WIDTH +: ACC_WIDTH];
            assign new_values[i] = new_data_d1[i*ACC_WIDTH +: ACC_WIDTH];

            always_comb begin
                if (accum_mode_d1) begin
                    // MODE: ADD (Π??οσθέτουμε στο υπά??χον)
                    result_values[i] = old_values[i] + new_values[i];
                end else begin
                    // MODE: OVERWRITE (Γ??άφουμε το καινο????γιο πάνω στο παλι??)
                    // Αυτ?? συμβαίνει στο π????το tile του υπολογισμο??
                    result_values[i] = new_values[i];
                end
            end
        end
    endgenerate

    // ----------------------------------------------------------------
    // Stage 3: Write Back
    // ----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_we <= 0;
            mem_wr_addr <= 0;
            mem_din <= 0;
            done_tick   <= 0;
        end else begin
            // Αν το π??οηγο??μενο στάδιο είχε έγκυ??α δεδομένα, γ??άφουμε
            if (valid_d1) begin
                mem_we      <= 1;
                mem_wr_addr <= addr_d1; 
                //addr_d1 <= mem_wr_addr;
                
                // Pack results back to wide vector
                for (int k=0; k<N; k++) begin
                    mem_din[k*ACC_WIDTH +: ACC_WIDTH] <= result_values[k];
                end

                // Status Logic:
                // Αν αυτ?? που γ??άφουμε τ????α ήταν το "last", τ??τε τελει??σαμε.
                if (last_d1) begin
                    done_tick <= 1;
                end else begin
                    done_tick <= 0;
                end


            end else begin
                mem_we <= 0;
                done_tick <= 0;
            end
        end
    end

endmodule











*/