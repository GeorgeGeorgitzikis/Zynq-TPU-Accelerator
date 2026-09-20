(* use_dsp = "yes" *)

module ws_systolic_pe #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH = 32
)(
    input  logic clk,
    input  logic rst,
    
    // --- ΠΑΛΙΟ: Global Swap ---
    // input  logic weight_swap,  <-- ΔΙΑΓΡΑΦΗ ΑΥΤΟΥ

    // --- ΝΕΟ: Systolic Swap Control ---
    input  logic swap_in_left,  // Έρχεται από αριστερά
    input  logic swap_in_top,   // Έρχεται από πάνω
    
    output logic swap_out_right, // Φεύγει δεξιά
    output logic swap_out_down,  // Φεύγει κάτω

    // ... (Τα υπόλοιπα signals παραμένουν ίδια: load_in, a_in, etc.) ...
    //input  logic load_in_left,
    input  logic load_in_top,
    //output logic load_out_right,
    //output logic load_out_down,

    input  logic signed [DATA_WIDTH-1:0] a_in,  
    output logic signed [DATA_WIDTH-1:0] a_out, 
    
    input  logic signed [ACC_WIDTH-1:0]  c_in,  
    output logic signed [ACC_WIDTH-1:0]  c_out, 
    
    input  logic signed [DATA_WIDTH-1:0] w_in,  
    output logic signed [DATA_WIDTH-1:0] w_out  
);

    logic signed [DATA_WIDTH-1:0] w_active; 
    logic signed [DATA_WIDTH-1:0] w_shadow; 
    
    //logic active_load;
    logic active_swap; // Εσωτερικό σήμα ενεργοποίησης swap

    // Η λογική ενεργοποίησης είναι OR: Αν έρθει σήμα από αριστερά Ή από πάνω
    //assign active_load = load_in_left | load_in_top;
    assign active_load =  load_in_top;

    assign active_swap = swap_in_left | swap_in_top;

    always_ff @(posedge clk) begin
        if (rst) begin
            a_out          <= 0;
            w_out          <= 0;
            c_out          <= 0;
            w_active       <= 0;
            w_shadow       <= 0;
            //load_out_right <= 0;
            //load_out_down  <= 0;
            
            // Reset και στα Swap outputs
            swap_out_right <= 0;
            swap_out_down  <= 0;
        end else begin
            // 1. Προώθηση Δεδομένων & Load Signals
            a_out <= a_in;
            w_out <= w_in;
            //load_out_right <= active_load;
            //load_out_down  <= active_load;

            // 2. Προώθηση SWAP Signal (Systolic Propagation)
            // Το σήμα περνάει στους επόμενους στον επόμενο κύκλο
            swap_out_right <= active_swap;
            swap_out_down  <= active_swap;

            // 3. Υπολογισμός MAC
            c_out <= c_in + (a_in * w_active); 
            
            // 4. Shadow Loading
            if (active_load) begin
                w_shadow <= w_in;
            end

            // 5. Weight Swap (Ping-Pong)
            // Τώρα γίνεται τοπικά, όταν φτάσει το κύμα "active_swap"
            if (active_swap) begin
                w_active <= w_shadow;
            end
        end
    end
endmodule




/*

module ws_systolic_pe #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH = 32
)(
    input  logic clk,
    input  logic rst,
    
    // --- ΠΑΛΙΟ: Global Swap ---
    // input  logic weight_swap,  <-- ΔΙΑΓΡΑΦΗ ΑΥΤΟΥ

    // --- ΝΕΟ: Systolic Swap Control ---
    input  logic swap_in_left,  // Έρχεται από αριστερά
    input  logic swap_in_top,   // Έρχεται από πάνω
    
    output logic swap_out_right, // Φεύγει δεξιά
    output logic swap_out_down,  // Φεύγει κάτω

    // ... (Τα υπόλοιπα signals παραμένουν ίδια: load_in, a_in, etc.) ...
    input  logic load_in_left,
    input  logic load_in_top,
    output logic load_out_right,
    output logic load_out_down,

    input  logic signed [DATA_WIDTH-1:0] a_in,  
    output logic signed [DATA_WIDTH-1:0] a_out, 
    
    input  logic signed [ACC_WIDTH-1:0]  c_in,  
    output logic signed [ACC_WIDTH-1:0]  c_out, 
    
    input  logic signed [DATA_WIDTH-1:0] w_in,  
    output logic signed [DATA_WIDTH-1:0] w_out  
);

    logic signed [DATA_WIDTH-1:0] w_active; 
    logic signed [DATA_WIDTH-1:0] w_shadow; 
    
    logic active_load;
    logic active_swap; // Εσωτερικό σήμα ενεργοποίησης swap

    // Η λογική ενεργοποίησης είναι OR: Αν έρθει σήμα από αριστερά Ή από πάνω
    assign active_load = load_in_left | load_in_top;
    assign active_swap = swap_in_left | swap_in_top;

    always_ff @(posedge clk) begin
        if (rst) begin
            a_out          <= 0;
            w_out          <= 0;
            c_out          <= 0;
            w_active       <= 0;
            w_shadow       <= 0;
            load_out_right <= 0;
            load_out_down  <= 0;
            
            // Reset και στα Swap outputs
            swap_out_right <= 0;
            swap_out_down  <= 0;
        end else begin
            // 1. Προώθηση Δεδομένων & Load Signals
            a_out <= a_in;
            w_out <= w_in;
            load_out_right <= active_load;
            load_out_down  <= active_load;

            // 2. Προώθηση SWAP Signal (Systolic Propagation)
            // Το σήμα περνάει στους επόμενους στον επόμενο κύκλο
            swap_out_right <= active_swap;
            swap_out_down  <= active_swap;

            // 3. Υπολογισμός MAC
            c_out <= c_in + (a_in * w_active); 
            
            // 4. Shadow Loading
            if (active_load) begin
                w_shadow <= w_in;
            end

            // 5. Weight Swap (Ping-Pong)
            // Τώρα γίνεται τοπικά, όταν φτάσει το κύμα "active_swap"
            if (active_swap) begin
                w_active <= w_shadow;
            end
        end
    end
endmodule

*/