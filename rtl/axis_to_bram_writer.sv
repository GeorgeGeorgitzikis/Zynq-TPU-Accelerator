`timescale 1ns / 1ps

module axis_to_bram_writer #(
    parameter int AXI_N       = 8,   // Lanes from AXI (e.g., 8 for 64-bit bus)
    parameter int BRAM_N      = 16,  // Lanes to BRAM (e.g., 16 for 128-bit array)
    parameter int DATA_WIDTH  = 8,   // Bit-width per Lane (e.g., INT8 = 8 bits)
    parameter int ADDR_WIDTH  = 12,  // Memory Depth Address Width
    parameter int MATRIX_SIZE = 9,   // Bits required for Rows/Cols counters
    parameter int FIFO_DEPTH  = 16   // Internal Command FIFO Depth
)(
    input  logic clk,
    input  logic rst,

    // --- Control / Trigger ---
    input  logic start, // Global enable to consume commands from FIFO

    // --- Configuration Interface (PUSH to Internal FIFO) ---
    input  logic [MATRIX_SIZE-1:0]  cfg_cols,       
    input  logic [MATRIX_SIZE-1:0]  cfg_rows,       
    input  logic [ADDR_WIDTH-1:0]   cfg_start_addr, 
    input  logic                    cfg_valid, // Push signal
    output logic                    cfg_ready, // !Full signal

    // --- Status ---
    output logic done,
    output logic busy,

    // --- AXI Stream Interface (Slave) ---
    input  logic [AXI_N*DATA_WIDTH-1:0]  s_axis_tdata,
    input  logic                         s_axis_tvalid,
    input  logic                         s_axis_tlast, 
    output logic                         s_axis_tready,

    // --- BRAM Interface (Write Port) ---
    output logic                         bram_we,
    output logic [ADDR_WIDTH-1:0]        bram_addr,
    output logic [BRAM_N*DATA_WIDTH-1:0] bram_wdata
);

    // ============================================================
    // 1. DYNAMIC WIDTH & SCALING CALCULATIONS
    // ============================================================
    localparam int AXI_W  = AXI_N * DATA_WIDTH;
    localparam int BRAM_W = BRAM_N * DATA_WIDTH;
    
    // How many AXI packets are required to fill one BRAM word?
    localparam int RATIO  = BRAM_N / AXI_N; 
    
    // Dynamic bit-width for the packer counter (prevents resource waste)
    localparam int WORD_CNT_W  = (RATIO > 1) ? $clog2(RATIO) : 1; 
    
    // Log2 of BRAM dimension for total writes calculation
    localparam int BRAM_N_LOG2 = $clog2(BRAM_N);

    // Command FIFO width calculation
    localparam int FIFO_CMD_WIDTH = (MATRIX_SIZE * 2) + ADDR_WIDTH;

    // ============================================================
    // 2. INTERNAL SIGNALS & FIFO WIRING
    // ============================================================
    logic [FIFO_CMD_WIDTH-1:0] fifo_din, fifo_dout;
    logic fifo_push, fifo_pop, fifo_full, fifo_empty;

    // Decoded Command Variables
    logic [MATRIX_SIZE-1:0] cmd_cols;
    logic [MATRIX_SIZE-1:0] cmd_rows;
    logic [ADDR_WIDTH-1:0]  cmd_start_addr;

    // FSM Control Variables
    logic [ADDR_WIDTH:0]  cmd_total_bram_writes; 
    logic [ADDR_WIDTH-1:0]  write_ptr;   
    logic [ADDR_WIDTH-1:0]  write_count; 

    logic writing_active; 
    logic handshake;

    // --- PACKER SIGNALS ---
    logic [BRAM_W-1:0]     pack_reg;       // Holding register for incoming AXI chunks
    logic [WORD_CNT_W-1:0] word_cnt;       // Fully parameterized counter (0 to RATIO-1)
    logic [BRAM_W-1:0]     full_bram_word; // Combinational output merging pack_reg and active tdata

    // ============================================================
    // 3. INTERNAL COMMAND FIFO
    // ============================================================
    // PACKING: MSB -> [Cols] [Rows] [Addr] <- LSB
    assign fifo_din  = {cfg_cols, cfg_rows, cfg_start_addr};
    assign fifo_push = cfg_valid;
    assign cfg_ready = !fifo_full; 

    simple_fifo #(
        .WIDTH(FIFO_CMD_WIDTH), .DEPTH(FIFO_DEPTH)
    ) u_cmd_fifo (
        .clk(clk), .rst(rst),
        .push(fifo_push), .data_in(fifo_din),
        .pop(fifo_pop),   .data_out(fifo_dout),
        .full(fifo_full), .empty(fifo_empty)
    );

    // UNPACKING
    assign cmd_start_addr = fifo_dout[ADDR_WIDTH-1:0];
    assign cmd_rows       = fifo_dout[ADDR_WIDTH + MATRIX_SIZE - 1 : ADDR_WIDTH];
    assign cmd_cols       = fifo_dout[FIFO_CMD_WIDTH - 1 : ADDR_WIDTH + MATRIX_SIZE];

    // ============================================================
    // 4. COMBINATIONAL PACKER LOGIC
    // ============================================================
    assign s_axis_tready = writing_active; 
    assign handshake     = s_axis_tvalid && s_axis_tready;

    // Dynamically insert the incoming AXI word into the correct slice of the BRAM word
    // SystemVerilog variable part-select [offset +: width] is highly efficient for ASICs.
    always_comb begin
        full_bram_word = pack_reg;
        full_bram_word[word_cnt * AXI_W +: AXI_W] = s_axis_tdata;
        //full_bram_word[(RATIO - 1 - word_cnt) * AXI_W +: AXI_W] = s_axis_tdata;
    end

    // ============================================================
    // 5. WRITE CONTROLLER (FSM)
    // ============================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            writing_active        <= 0;
            write_ptr             <= 0;
            write_count           <= 0;
            word_cnt              <= 0;
            pack_reg              <= 0;
            done                  <= 0;
            fifo_pop              <= 0; 
            cmd_total_bram_writes <= 0;
        end else begin
            // Default pulse signals
            done     <= 0;
            fifo_pop <= 0; 

            case (writing_active)
                // --- STATE 0: IDLE ---
                0: begin
                    if (start && !fifo_empty) begin
                        write_ptr <= cmd_start_addr;

                        // Calculate total target writes to the BRAM (NOT AXI packets)
                        cmd_total_bram_writes <= (cmd_rows * cmd_cols) << BRAM_N_LOG2;
                        
                        write_count    <= 0;
                        word_cnt       <= 0;
                        writing_active <= 1;
                        fifo_pop       <= 1; // Dequeue the command
                    end
                end

                // --- STATE 1: WRITING ---
                1: begin
                    if (handshake) begin
                        // 1. Latch the current AXI chunk into the correct slice of the holding register
                        pack_reg[word_cnt * AXI_W +: AXI_W] <= s_axis_tdata;
                        //pack_reg[(RATIO - 1 - word_cnt) * AXI_W +: AXI_W] <= s_axis_tdata;

                        // 2. Check if we have gathered enough chunks to form a complete BRAM word
                        if (word_cnt == RATIO - 1) begin
                            word_cnt    <= 0;
                            write_ptr   <= write_ptr + 1; // Linear stride = 1 for BRAM address
                            write_count <= write_count + 1;

                            // 3. Check for matrix completion
                            if (write_count == cmd_total_bram_writes - 1) begin
                                writing_active <= 0;
                                done           <= 1;
                            end
                        end else begin
                            word_cnt <= word_cnt + 1;
                        end
                    end
                end
            endcase
        end
    end

    // ============================================================
    // 6. OUTPUT ASSIGNMENTS
    // ============================================================
    // Trigger BRAM write ONLY when the last chunk of the ratio is received
    assign bram_we    = handshake && (word_cnt == RATIO - 1); 
    assign bram_addr  = write_ptr; 
    assign bram_wdata = full_bram_word;

    // Module is busy if writing is active or there are pending commands in the FIFO
    assign busy = writing_active || !fifo_empty;

endmodule











/*




`timescale 1ns / 1ps

module axis_to_bram_writer #(
    parameter int N          = 4,   // Lanes
    parameter int DATA_WIDTH = 8,   // Width per Lane
    parameter int ADDR_WIDTH = 10,  // Memory Depth
    parameter int MATRIX_SIZE = 9,  // Bits for Rows/Cols
    parameter int FIFO_DEPTH  = 16  // Βάθος εσωτερικής FIFO
)(
    input  logic clk,
    input  logic rst,

    // --- Control / Trigger ---
    input  logic start, // Γενικό Enable για να ξεκινήσει η κατανάλωση από τη FIFO

    // --- Configuration Interface (PUSH to Internal FIFO) ---
    // Αυτά τα σήματα έρχονται από τον CPU/Controller για να φορτώσουν εντολές
    input  logic [MATRIX_SIZE-1:0]  cfg_cols,       
    input  logic [MATRIX_SIZE-1:0]  cfg_rows,       
    input  logic [ADDR_WIDTH-1:0]   cfg_start_addr, 
    input  logic                    cfg_valid, // PUSH signal
    output logic                    cfg_ready, // !FULL signal

    // --- Status ---
    output logic done,
    output logic busy,

    // --- AXI Stream Interface (Slave) ---
    input  logic [N*DATA_WIDTH-1:0] s_axis_tdata,
    input  logic                    s_axis_tvalid,
    input  logic                    s_axis_tlast, 
    output logic                    s_axis_tready,

    // --- BRAM Interface (Write Port) ---
    output logic                    bram_we,
    output logic [ADDR_WIDTH-1:0]   bram_addr,
    output logic [N*DATA_WIDTH-1:0] bram_wdata
);

    // ============================================================
    // 1. WIDTH CALCULATIONS
    // ============================================================
    // Το πλάτος της FIFO: [Cols] + [Rows] + [Addr]
    localparam int FIFO_CMD_WIDTH = (MATRIX_SIZE * 2) + ADDR_WIDTH;

    // Το πλάτος του Counter για το γινόμενο (Rows*Cols*N)
    //localparam int CTR_WIDTH = (MATRIX_SIZE * 2) + $clog2(N);

    localparam int N_LOG2 = $clog2(N);

    // ============================================================
    // 2. INTERNAL SIGNALS & FIFO WIRING
    // ============================================================
    // FIFO Signals
    logic [FIFO_CMD_WIDTH-1:0] fifo_din;
    logic [FIFO_CMD_WIDTH-1:0] fifo_dout;
    logic fifo_push, fifo_pop;
    logic fifo_full, fifo_empty;

    // Decoded Signals from FIFO Output
    logic [MATRIX_SIZE-1:0] cmd_cols;
    logic [MATRIX_SIZE-1:0] cmd_rows;
    logic [ADDR_WIDTH-1:0]  cmd_start_addr;

    // FSM Signals
    logic [ADDR_WIDTH-1:0]  cmd_total_writes; 
    logic [MATRIX_SIZE-1:0] cmd_stride;       
    logic [ADDR_WIDTH-1:0] write_ptr;   
    logic [ADDR_WIDTH-1:0]  write_count; 

    logic writing_active; 
    logic handshake;

    // ============================================================
    // 3. INTERNAL FIFO INSTANCE
    // ============================================================
    
    // PACKING: Ενώνουμε τα inputs σε ένα bus
    // MSB -> [Cols] [Rows] [Addr] <- LSB
    assign fifo_din = {cfg_cols, cfg_rows, cfg_start_addr};
    assign fifo_push = cfg_valid;
    assign cfg_ready = !fifo_full; // Λέμε έξω ότι είμαστε έτοιμοι αν η FIFO δεν είναι γεμάτη

    simple_fifo #(
        .WIDTH(FIFO_CMD_WIDTH), 
        .DEPTH(FIFO_DEPTH)
    ) u_cmd_fifo (
        .clk(clk), .rst(rst),
        .push(fifo_push), 
        .data_in(fifo_din),
        .pop(fifo_pop), 
        .data_out(fifo_dout),
        .full(fifo_full), 
        .empty(fifo_empty)
    );

    // UNPACKING: Σπάμε το output της FIFO στα εσωτερικά σήματα
    assign cmd_start_addr = fifo_dout[ADDR_WIDTH-1:0];
    assign cmd_rows       = fifo_dout[ADDR_WIDTH + MATRIX_SIZE - 1 : ADDR_WIDTH];
    assign cmd_cols       = fifo_dout[FIFO_CMD_WIDTH - 1 : ADDR_WIDTH + MATRIX_SIZE];

    // ============================================================
    // 4. WRITE CONTROLLER (FSM)
    // ============================================================
    assign s_axis_tready = writing_active; 
    assign handshake     = s_axis_tvalid && s_axis_tready;

    always_ff @(posedge clk) begin
        if (rst) begin
            writing_active   <= 0;
            write_ptr        <= 0;
            write_count      <= 0;
            done             <= 0;
            fifo_pop         <= 0; 
            cmd_total_writes <= 0;
            cmd_stride       <= 0;
        end else begin
            // Defaults
            done     <= 0;
            fifo_pop <= 0; // Pulse reset

            case (writing_active)
                // --- STATE: IDLE ---
                0: begin
                    // Αν έχουμε Start trigger ΚΑΙ η εσωτερική FIFO έχει δεδομένα
                    if (start && !fifo_empty) begin
                        
                        // 1. LATCH from FIFO Output
                        write_ptr <= cmd_start_addr;

                        // Total Writes calculation
                        cmd_total_writes <= (cmd_rows * cmd_cols) << N_LOG2;
                        
                        // 2. Stride = 1
                        cmd_stride       <= 1;

                        // 3. Init Writing
                        write_count      <= 0;
                        writing_active   <= 1;
                        
                        // 4. POP Internal FIFO (Διώχνουμε την εντολή αφού τη διαβάσαμε)
                        fifo_pop         <= 1; 
                    end
                end

                // --- STATE: WRITING ---
                1: begin
                    if (handshake) begin
                        write_ptr   <= write_ptr + cmd_stride;
                        write_count <= write_count + 1;

                        if (write_count == cmd_total_writes - 1) begin
                            writing_active <= 0;
                            done           <= 1;
                        end
                    end
                end
            endcase
        end
    end

    // ============================================================
    // 5. OUTPUTS
    // ============================================================
    assign bram_we    = handshake; 
    assign bram_addr  = write_ptr; 
    assign bram_wdata = s_axis_tdata;

    // Busy αν γράφουμε ή αν η FIFO έχει κι άλλα πράγματα να κάνει
    assign busy = writing_active || !fifo_empty;

endmodule







*/