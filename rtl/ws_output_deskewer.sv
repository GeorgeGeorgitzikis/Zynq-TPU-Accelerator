module ws_output_deskewer #(
    parameter int N = 4,
    parameter int ACC_WIDTH = 32
)(
    input  logic clk,
    input  logic rst,
    
    // Είσοδος: Τα αποτελέσματα όπως βγαίνουν από το Grid (Skewed)
    // skewed_in[0] φτάνει πρώτο, skewed_in[N-1] φτάνει τελευταίο
    input  logic signed [ACC_WIDTH-1:0] skewed_in [0:N-1],
    
    // Έξοδος: Ευθυγραμμισμένη γραμμή αποτελεσμάτων
    output logic signed [ACC_WIDTH-1:0] flattened_out [0:N-1],

    // --- Control Path (Latency Matching) ---
    input  logic valid_in, 
    output logic valid_out,

    output logic last_out
);

    genvar i;
    generate
        for (i = 0; i < N; i++) begin : deskew_logic
            // Υπολογισμός καθυστέρησης:
            // Η στήλη 0 βγαίνει νωρίς -> θέλει μεγάλη καθυστέρηση (N-1).
            // Η στήλη N-1 βγαίνει αργά -> θέλει 0 καθυστέρηση.
            localparam int DELAY = (N - 1) - i;

            if (DELAY == 0) begin
                // Η τελευταία στήλη περνάει απευθείας (δεν χρειάζεται delay)
                assign flattened_out[i] = skewed_in[i];
            end 
            else begin
                // Shift Register για καθυστέρηση
                logic signed [ACC_WIDTH-1:0] shift_reg [0:DELAY-1];
                
                always_ff @(posedge clk) begin
                    if (rst) begin
                        for (int k = 0; k < DELAY; k++) shift_reg[k] <= '0;
                    end else begin
                        // Είσοδος στο πρώτο στάδιο
                        shift_reg[0] <= skewed_in[i];
                        
                        // Shift στα υπόλοιπα
                        for (int k = 1; k < DELAY; k++) begin
                            shift_reg[k] <= shift_reg[k-1];
                        end
                    end
                end
                
                // Η έξοδος είναι το τελευταίο στάδιο του shift register
                assign flattened_out[i] = shift_reg[DELAY-1];
            end
        end
    endgenerate





    // 2. VALID SIGNAL LATENCY COMPENSATION

    localparam int TOTAL_LATENCY = N - 1;
    
    logic [TOTAL_LATENCY-1:0] valid_pipe;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_pipe <= 0;
        end else begin
            // Shift Register: Ολίσθηση του valid signal
            // Το valid_in μπαίνει στο LSB
            valid_pipe <= {valid_pipe[TOTAL_LATENCY-2:0], valid_in};
        end
    end

    // Η έξοδος είναι το MSB του shift register
    assign valid_out = valid_pipe[TOTAL_LATENCY-1];




    // Ο μετρητής
    logic [$clog2(N)-1:0] count;

    always_ff @(posedge clk) begin
        if (rst) begin
            count <= '0;
        end else if (valid_out) begin
            if (count == N - 1) begin
                count <= '0; // Μηδενίζει για να είναι έτοιμο για το επόμενο batch
            end else begin
                count <= count + 1;
            end
        end
    end

    // ΣΥΝΔΥΑΣΤΙΚΗ ΛΟΓΙΚΗ: 
    // Το last_out θα γίνει 1 ΑΚΡΙΒΩΣ τη στιγμή που:
    // 1. Το valid_out είναι 1
    // 2. Ο μετρητής έχει φτάσει στο N-1 (π.χ. στο 3 για N=4)
    assign last_out = (valid_out && (count == N - 1));


endmodule
