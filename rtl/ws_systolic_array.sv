module ws_systolic_array #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int N          = 4
)(
    input  logic clk,
    input  logic rst,

    // --- Control Signals (Valid Path) ---
    input  logic valid_in,
    output logic valid_out,

    // Status output
    output logic weights_loaded,

    // --- Swap Control (Wavefront) ---
    input  logic swap_in_left   [0:N-1], 
    input  logic swap_in_top    [0:N-1],
    output logic swap_out_right [0:N-1],
    output logic swap_out_down  [0:N-1],

    // --- Load Control (Row Broadcast) ---
    // ΑΛΛΑΓΗ: ??να bit για κάθε γ??αμμή. Ελέγχει ??λη τη γ??αμμή ταυτ??χ??ονα.
    input  logic [N-1:0] load_in_cols,
    input  logic [N-1:0] last_in_cols, 

    // --- Data Inputs ---
    input  logic signed [DATA_WIDTH-1:0] row_in [0:N-1], // A
    input  logic signed [DATA_WIDTH-1:0] col_in [0:N-1], // W
    input  logic signed [ACC_WIDTH-1:0]  sum_in [0:N-1], // C

    // --- Data Outputs ---
    output logic signed [DATA_WIDTH-1:0] row_out [0:N-1], 
    output logic signed [DATA_WIDTH-1:0] col_out [0:N-1], 
    output logic signed [ACC_WIDTH-1:0]  sum_out [0:N-1] 
);

    // Εσωτε??ικά ??αλ??δια
    logic h_swap [0:N-1][0:N]; 
    logic v_swap [0:N][0:N-1];

    logic signed [DATA_WIDTH-1:0] h_a [0:N-1][0:N];
    logic signed [DATA_WIDTH-1:0] v_w [0:N][0:N-1];
    logic signed [ACC_WIDTH-1:0]  v_c [0:N][0:N-1];

    // Valid Pipeline Logic (ίδια με π??ιν)
    logic [N-1:0] valid_pipe;
    always_ff @(posedge clk) begin
        if (rst) valid_pipe <= '0;
        else     valid_pipe <= (valid_pipe << 1) | valid_in;
    end
    assign valid_out = valid_pipe[N-1];

    genvar i, j;
    generate
        // ---------------------------------------------------------
        // 1. Boundary Setup
        // ---------------------------------------------------------
        for (i = 0; i < N; i++) begin : boundaries
            assign h_a[i][0]     = row_in[i];      
            assign v_w[0][i]     = col_in[i]; 
            //assign v_w[0][i]     = col_in[N - 1 - i];     
            assign v_c[0][i]     = sum_in[i];      
            
            assign h_swap[i][0]  = swap_in_left[i];
            assign v_swap[0][i]  = swap_in_top[i];

            assign row_out[i]        = h_a[i][N];       
            assign col_out[i]        = v_w[N][i];       
            assign sum_out[i]        = v_c[N][i];       
            assign swap_out_right[i] = h_swap[i][N];
            assign swap_out_down[i]  = v_swap[N][i];
        end

        // ---------------------------------------------------------
        // 2. Grid Instantiation
        // ---------------------------------------------------------
        for (i = 0; i < N; i++) begin : rows
            for (j = 0; j < N; j++) begin : cols
                ws_systolic_pe #(
                    .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
                ) pe_inst (
                    .clk(clk), .rst(rst),

                    // --- Swap (Systolic) ---
                    .swap_in_left   (h_swap[i][j]),
                    .swap_in_top    (v_swap[i][j]),
                    .swap_out_right (h_swap[i][j+1]),
                    .swap_out_down  (v_swap[i+1][j]),

                    // --- Load (Row Broadcast) ---
                    // ΑΛΛΑΓΗ: ??λα τα PE της στήλης j παί??νουν το ίδιο σήμα
                    .load_in_top       (last_in_cols[j]), 
                    //.load_in_top       (last_in_cols[N - 1 - j]),

                    // --- Data Flow ---
                    .a_in           (h_a[i][j]),
                    .a_out          (h_a[i][j+1]),
                    .w_in           (v_w[i][j]),
                    .w_out          (v_w[i+1][j]),
                    .c_in           (v_c[i][j]),
                    .c_out          (v_c[i+1][j])
                );
            end
        end
    endgenerate

    // ---------------------------------------------------------
    // WEIGHTS LOADED LOGIC 
    // ---------------------------------------------------------
    
    logic  load_delay;

    always_ff @(posedge clk) begin
        if (rst) begin
            load_delay <= 1'b0;
        end else begin
            // Shift left: Το νέο bit μπαίνει στο LSB
            load_delay <=  last_in_cols[N-1]; /////////////////////////////////////////////////////////////////////////////////////
        end
    end

    // Η έξοδος λαμβάνεται απ?? το MSB (Index N-1), δηλαδή μετά απ?? N κ??κλους.
    assign weights_loaded = load_delay;

endmodule









/*


module ws_systolic_array #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int N          = 4
)(
    input  logic clk,
    input  logic rst,



    // --- Control Signals (Valid Path) ---
    // ??Ε??: Pipeline N κ??κλων για να ται??ιάζει με το βάθος του array
    input  logic valid_in,
    output logic valid_out,

    output logic weights_loaded,


    // --- Control Vectors (SWAP Wavefront) ---
    // ΑΛΛΑΓΗ: Πλέον είναι διαν??σματα για να συνδέονται με τα διπλανά Arrays
    input  logic swap_in_left   [0:N-1], 
    input  logic swap_in_top    [0:N-1],
    
    output logic swap_out_right [0:N-1],
    output logic swap_out_down  [0:N-1],

    // --- Control Vectors (LOAD Wavefront) ---
    input  logic load_in_left   [0:N-1], 
    input  logic load_in_top    [0:N-1],
    
    output logic load_out_right [0:N-1],
    output logic load_out_down  [0:N-1],

    // --- Data Inputs ---
    input  logic signed [DATA_WIDTH-1:0] row_in [0:N-1], // A
    input  logic signed [DATA_WIDTH-1:0] col_in [0:N-1], // W
    input  logic signed [ACC_WIDTH-1:0]  sum_in [0:N-1], // C

    // --- Data Outputs ---
    output logic signed [DATA_WIDTH-1:0] row_out [0:N-1], 
    output logic signed [DATA_WIDTH-1:0] col_out [0:N-1], 
    output logic signed [ACC_WIDTH-1:0]  sum_out [0:N-1] 
);

    // Εσωτε??ικά ??αλ??δια
    // [N][N+1] για τα ο??ιζ??ντια, [N+1][N] για τα κάθετα
    logic h_swap [0:N-1][0:N]; 
    logic v_swap [0:N][0:N-1];

    logic h_load [0:N-1][0:N];
    logic v_load [0:N][0:N-1];

    logic signed [DATA_WIDTH-1:0] h_a [0:N-1][0:N];
    logic signed [DATA_WIDTH-1:0] v_w [0:N][0:N-1];
    logic signed [ACC_WIDTH-1:0]  v_c [0:N][0:N-1];





    // ---------------------------------------------------------
    // 0. Valid Signal Latency Pipeline (Depth = N)
    // ---------------------------------------------------------
    // Δημιου??γο??με καθυστέ??ηση N κ??κλων για το valid signal
    // ??στε να βγει μαζί με το π????το sum_out[0].
    logic [N-1:0] valid_pipe;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_pipe <= '0;
        end else begin
            // Shift Register: (??λίσθηση π??ος τα α??ιστε??ά)
            // Αυτ??ς ο τ????πος γ??αφής είναι ασφαλής για κάθε N >= 1
            valid_pipe <= (valid_pipe << 1) | valid_in;
        end
    end

    // Η έξοδος είναι το MSB (bit N-1) που έχει καθυστε??ήσει N κ??κλους
    assign valid_out = valid_pipe[N-1];

    // ---------------------------------------------------------




    genvar i, j;
    generate
        // ---------------------------------------------------------
        // 1. Boundary Setup (Routing)
        // ---------------------------------------------------------
        for (i = 0; i < N; i++) begin : boundaries
            // Inputs: Συνδέουμε τα ports στα εσωτε??ικά καλ??δια (index 0)
            assign h_a[i][0]    = row_in[i];      
            assign v_w[0][i]    = col_in[i];      
            assign v_c[0][i]    = sum_in[i];      
            
            assign h_load[i][0] = load_in_left[i]; 
            assign v_load[0][i] = load_in_top[i]; 

            // --- ??Ε??: Swap Inputs (ίδια λογική με τα Load) ---
            assign h_swap[i][0] = swap_in_left[i];
            assign v_swap[0][i] = swap_in_top[i];

            // Outputs: Συνδέουμε τα εσωτε??ικά καλ??δια (index N) στα ports
            assign row_out[i]        = h_a[i][N];       
            assign col_out[i]        = v_w[N][i];       
            assign sum_out[i]        = v_c[N][i];       
            
            assign load_out_right[i] = h_load[i][N];    
            assign load_out_down[i]  = v_load[N][i];    

            // --- ??Ε??: Swap Outputs (ίδια λογική με τα Load) ---
            assign swap_out_right[i] = h_swap[i][N];
            assign swap_out_down[i]  = v_swap[N][i];
        end

        // ---------------------------------------------------------
        // 2. Grid Instantiation
        // ---------------------------------------------------------
        for (i = 0; i < N; i++) begin : rows
            for (j = 0; j < N; j++) begin : cols
                ws_systolic_pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH(ACC_WIDTH)
                ) pe_inst (
                    .clk(clk),
                    .rst(rst),

                    // --- Swap Wavefront ---
                    .swap_in_left   (h_swap[i][j]),
                    .swap_in_top    (v_swap[i][j]),
                    .swap_out_right (h_swap[i][j+1]),
                    .swap_out_down  (v_swap[i+1][j]),

                    // --- Load Wavefront ---
                    .load_in_left   (h_load[i][j]),
                    .load_in_top    (v_load[i][j]),
                    .load_out_right (h_load[i][j+1]),
                    .load_out_down  (v_load[i+1][j]),

                    // --- Data Flow ---
                    .a_in           (h_a[i][j]),
                    .a_out          (h_a[i][j+1]),
                    .w_in           (v_w[i][j]),
                    .w_out          (v_w[i+1][j]),
                    .c_in           (v_c[i][j]),
                    .c_out          (v_c[i+1][j])
                );
            end
        end
    endgenerate


    // ---------------------------------------------------------
    // WEIGHTS LOADED LOGIC (NEW)
    // ---------------------------------------------------------
    // always_ff @(posedge clk) begin
    //     if (rst) begin
    //         weights_loaded <= 0;
    //     end else begin
    //         // h_load[N-1][0] είναι το σήμα LOAD που μπαίνει στο 
    //         // ??άτω (N-1) Α??ιστε??ά (0) PE.
    //         weights_loaded <= v_load[N-1][0] | h_load[N-1][0]; 
    //     end
    // end

endmodule


*/