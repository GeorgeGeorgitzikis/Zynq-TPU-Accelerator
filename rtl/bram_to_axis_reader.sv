`timescale 1ns / 1ps

module bram_to_axis_reader #(
    parameter int AXI_N       = 8,   
    parameter int BRAM_N      = 16,  
    parameter int DATA_WIDTH  = 8,   
    parameter int ADDR_WIDTH  = 12,  
    parameter int MATRIX_SIZE = 9,   
    parameter int FIFO_DEPTH  = 16   
)(
    input  logic clk,
    input  logic rst,

    input  logic start, 

    input  logic [MATRIX_SIZE-1:0]  cfg_cols,       
    input  logic [MATRIX_SIZE-1:0]  cfg_rows,       
    input  logic [ADDR_WIDTH-1:0]   cfg_start_addr, 
    input  logic                    cfg_valid, 
    output logic                    cfg_ready, 

    output logic done,
    output logic busy,

    output logic                         bram_en,
    output logic [ADDR_WIDTH-1:0]        bram_addr,
    input  logic [BRAM_N*DATA_WIDTH-1:0] bram_dout,

    output logic [AXI_N*DATA_WIDTH-1:0]  m_axis_tdata,
    output logic                         m_axis_tvalid,
    output logic                         m_axis_tlast,
    input  logic                         m_axis_tready
);

    localparam int AXI_W  = AXI_N * DATA_WIDTH;
    localparam int BRAM_W = BRAM_N * DATA_WIDTH;
    localparam int BRAM_N_LOG2 = $clog2(BRAM_N);
    localparam int FIFO_CMD_WIDTH = (MATRIX_SIZE * 2) + ADDR_WIDTH;

    logic [FIFO_CMD_WIDTH-1:0] fifo_din, fifo_dout;
    logic fifo_push, fifo_pop, fifo_full, fifo_empty;

    logic [MATRIX_SIZE-1:0] cmd_cols, cmd_rows;
    logic [ADDR_WIDTH-1:0]  cmd_start_addr;

    logic [ADDR_WIDTH:0]    cmd_num_lines; 
    logic [ADDR_WIDTH-1:0]  read_ptr;    
    logic [ADDR_WIDTH-1:0]  read_count;  

    logic stall;
    
    // --- ΞΕΚΑΘΑΡΑ ΣΗΜΑΤΑ ΑΝΑΓΝΩΣΗΣ ---
    logic [AXI_W-1:0] holding_reg;
    logic [AXI_W-1:0] current_chunk;
    
    logic       axis_fifo_wr;
    logic [4:0] axis_fifo_count;
    logic       axis_fifo_full, axis_fifo_empty;
    logic       axis_fifo_last_in;

    // --- ΤΟ BULLETPROOF FSM ---
    typedef enum logic [2:0] {IDLE, WAIT_FIRST_DATA, STREAM_LOWER, STREAM_UPPER, WAIT_NEXT_DATA} state_t;
    state_t state;

    assign fifo_din  = {cfg_cols, cfg_rows, cfg_start_addr};
    assign fifo_push = cfg_valid;
    assign cfg_ready = !fifo_full;

    simple_fifo #(.WIDTH(FIFO_CMD_WIDTH), .DEPTH(FIFO_DEPTH)) u_cmd_fifo (
        .clk(clk), .rst(rst),
        .push(fifo_push), .data_in(fifo_din),
        .pop(fifo_pop),   .data_out(fifo_dout),
        .full(fifo_full), .empty(fifo_empty)
    );

    assign cmd_start_addr = fifo_dout[ADDR_WIDTH-1:0];
    assign cmd_rows       = fifo_dout[ADDR_WIDTH + MATRIX_SIZE - 1 : ADDR_WIDTH];
    assign cmd_cols       = fifo_dout[FIFO_CMD_WIDTH - 1 : ADDR_WIDTH + MATRIX_SIZE];

    assign stall = (axis_fifo_count >= FIFO_DEPTH - 2); 

    always_ff @(posedge clk) begin
        if (rst) begin
            state             <= IDLE;
            read_ptr          <= 0;
            read_count        <= 0;
            bram_en           <= 0;
            bram_addr         <= 0;
            done              <= 0;
            fifo_pop          <= 0;
            axis_fifo_wr      <= 0;
            axis_fifo_last_in <= 0;
            current_chunk     <= 0;
            holding_reg       <= 0;
            cmd_num_lines     <= 0;
        end else begin
            done         <= 0;
            fifo_pop     <= 0;
            bram_en      <= 0;
            axis_fifo_wr <= 0; 

            case (state)
                IDLE: begin 
                    if (start && !fifo_empty) begin
                        read_ptr <= cmd_start_addr;
                        cmd_num_lines <= (cmd_rows * cmd_cols) << BRAM_N_LOG2;
                        read_count <= 0;
                        
                        bram_en   <= 1;
                        bram_addr <= cmd_start_addr;
                        read_ptr  <= cmd_start_addr + 1; 
                        
                        state    <= WAIT_FIRST_DATA;
                        fifo_pop <= 1; 
                    end
                end

                WAIT_FIRST_DATA: begin 
                    // ΑΠΑΡΑΙΤΗΤΟ: Περιμένουμε 1 κύκλο για να διαβάσει η BRAM
                    state <= STREAM_LOWER;
                end

                STREAM_LOWER: begin 
                    if (!stall) begin
                        // Τώρα τα δεδομένα είναι σίγουρα έγκυρα!
                        axis_fifo_wr      <= 1;
                        current_chunk     <= bram_dout[0 +: AXI_W];       // Γράφουμε το ΚΑΤΩ μισό
                        holding_reg       <= bram_dout[AXI_W +: AXI_W];   // Σώζουμε το ΠΑΝΩ μισό
                        axis_fifo_last_in <= 0; 
                        
                        state <= STREAM_UPPER;
                    end
                end

                STREAM_UPPER: begin
                    if (!stall) begin
                        axis_fifo_wr      <= 1;
                        current_chunk     <= holding_reg;                 // Γράφουμε το ΠΑΝΩ μισό
                        
                        read_count <= read_count + 1;

                        if (read_count == cmd_num_lines - 1) begin
                            axis_fifo_last_in <= 1;                       // TLAST ΠΑΝΤΑ ΣΤΟ ΤΕΛΕΥΤΑΙΟ ΚΟΜΜΑΤΙ
                            done  <= 1;
                            state <= IDLE;
                        end else begin
                            axis_fifo_last_in <= 0;
                            
                            // Ζητάμε την επόμενη λέξη
                            bram_en   <= 1;
                            bram_addr <= read_ptr;
                            read_ptr  <= read_ptr + 1;
                            
                            state <= WAIT_NEXT_DATA;
                        end
                    end
                end
                
                WAIT_NEXT_DATA: begin
                    // Περιμένουμε πάλι 1 κύκλο για τη νέα λέξη της BRAM
                    state <= STREAM_LOWER;
                end
            endcase
        end
    end

    fifo_axis #(
        .N(AXI_N), .DATA_WIDTH(DATA_WIDTH), .DEPTH(16)
    ) u_axis_fifo (
        .clk(clk), .rst(rst),
        .write_en(axis_fifo_wr),
        .data_in(current_chunk), 
        .last_in(axis_fifo_last_in),
        .full(axis_fifo_full),
        .read_en(m_axis_tready && !axis_fifo_empty),
        .data_out(m_axis_tdata),
        .last_out(m_axis_tlast),
        .empty(axis_fifo_empty),
        .count(axis_fifo_count)
    );

    assign m_axis_tvalid = !axis_fifo_empty;
    assign busy = (state != IDLE) || !fifo_empty;

endmodule






























/*

`timescale 1ns / 1ps

module bram_to_axis_reader #(
    parameter int AXI_N       = 8,   // Lanes to AXI (e.g., 8 for 64-bit bus)
    parameter int BRAM_N      = 16,  // Lanes from BRAM (e.g., 16 for 128-bit array)
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

    // --- BRAM Interface (Read Port) ---
    output logic                         bram_en,
    output logic [ADDR_WIDTH-1:0]        bram_addr,
    input  logic [BRAM_N*DATA_WIDTH-1:0] bram_dout,

    // --- AXI Stream Interface (Master) ---
    output logic [AXI_N*DATA_WIDTH-1:0]  m_axis_tdata,
    output logic                         m_axis_tvalid,
    output logic                         m_axis_tlast,
    input  logic                         m_axis_tready
);

    // ============================================================
    // 1. DYNAMIC WIDTH & SCALING CALCULATIONS
    // ============================================================
    localparam int AXI_W  = AXI_N * DATA_WIDTH;
    localparam int BRAM_W = BRAM_N * DATA_WIDTH;
    
    // How many AXI packets are extracted from one BRAM word?
    localparam int RATIO  = BRAM_N / AXI_N; 
    
    // Dynamic bit-width for the unpacker counter (prevents resource waste)
    localparam int WORD_CNT_W  = (RATIO > 1) ? $clog2(RATIO) : 1; 
    
    // Log2 of BRAM dimension for total reads calculation
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

    // FSM & Control Variables
    logic [ADDR_WIDTH:0]  cmd_total_bram_reads; 
    logic [ADDR_WIDTH-1:0]  read_ptr;   
    logic [ADDR_WIDTH-1:0]  read_count; 
    logic                   stall;

    // --- UNPACKER SIGNALS ---
    logic [BRAM_W-1:0]     holding_reg;   // Stores BRAM output to slice over multiple cycles
    logic [WORD_CNT_W-1:0] word_cnt;      // Fully parameterized counter (0 to RATIO-1)
    logic [AXI_W-1:0]      current_chunk; // Combinational extracted slice
    logic                  is_last_chunk; // TLAST detection flag

    // Axis FIFO Control
    logic       axis_fifo_wr;
    logic [4:0] axis_fifo_count;
    logic       axis_fifo_full, axis_fifo_empty;
    logic       axis_fifo_last_in;

    // FSM Definition
    typedef enum logic [1:0] {IDLE, WAIT_DATA, STREAM} state_t;
    state_t state;

    // ============================================================
    // 3. INTERNAL COMMAND FIFO
    // ============================================================
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

    assign cmd_start_addr = fifo_dout[ADDR_WIDTH-1:0];
    assign cmd_rows       = fifo_dout[ADDR_WIDTH + MATRIX_SIZE - 1 : ADDR_WIDTH];
    assign cmd_cols       = fifo_dout[FIFO_CMD_WIDTH - 1 : ADDR_WIDTH + MATRIX_SIZE];

    // ============================================================
    // 4. COMBINATIONAL UNPACKER LOGIC
    // ============================================================
    // Protect against pipeline stalls (stop reading if output FIFO is almost full)
    assign stall = (axis_fifo_count >= FIFO_DEPTH - 2); 

    // Extract the correct AXI-width slice from the wide BRAM word
    always_comb begin
        if (word_cnt == 0) begin
            // First chunk comes directly from BRAM output (0-latency bypass)
            current_chunk = bram_dout[0 +: AXI_W];
            //current_chunk = bram_dout[(RATIO - 1) * AXI_W +: AXI_W];
        end else begin
            // Subsequent chunks come from the holding register
            current_chunk = holding_reg[word_cnt * AXI_W +: AXI_W];
            //current_chunk = holding_reg[(RATIO - 1 - word_cnt) * AXI_W +: AXI_W];

        end
    end

    // Detect the absolute last chunk of the entire matrix transfer
    assign is_last_chunk = (read_count == cmd_total_bram_reads - 1) && (word_cnt == RATIO - 1);

    // ============================================================
    // 5. READ CONTROLLER (FSM)
    // ============================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            state                 <= IDLE;
            read_ptr              <= 0;
            read_count            <= 0;
            word_cnt              <= 0;
            bram_en               <= 0;
            bram_addr             <= 0;
            done                  <= 0;
            fifo_pop              <= 0;
            axis_fifo_wr          <= 0;
            cmd_total_bram_reads  <= 0;
            holding_reg           <= 0;
            axis_fifo_last_in     <= 0;
        end else begin
            // Default Pulses
            done         <= 0;
            fifo_pop     <= 0;
            bram_en      <= 0;
            axis_fifo_wr <= 0;

            case (state)
                // --- STATE 0: IDLE ---
                IDLE: begin 
                    if (start && !fifo_empty) begin
                        read_ptr <= cmd_start_addr;
                        
                        // Total BRAM reads calculation (Tiles * BRAM_N)
                        cmd_total_bram_reads <= (cmd_rows * cmd_cols) << BRAM_N_LOG2;
                        
                        read_count <= 0;
                        word_cnt   <= 0;
                        
                        // Issue the first read immediately
                        bram_en   <= 1;
                        bram_addr <= cmd_start_addr;
                        read_ptr  <= cmd_start_addr + 1; // Increment for next read
                        
                        state    <= WAIT_DATA;
                        fifo_pop <= 1; 
                    end
                end

                // --- STATE 1: WAIT_DATA ---
                // Wait 1 clock cycle for the BRAM read latency
                WAIT_DATA: begin 
                    state <= STREAM;
                end

                // --- STATE 2: STREAM & UNPACK ---
                STREAM: begin 
                    if (!stall) begin
                        // 1. Write current chunk to AXIS FIFO
                        axis_fifo_wr      <= 1;
                        axis_fifo_last_in <= is_last_chunk;

                        // 2. Latch the BRAM output into the holding register on chunk 0
                        if (word_cnt == 0) begin
                            holding_reg <= bram_dout;
                        end

                        // 3. Counter Logic
                        if (word_cnt == RATIO - 1) begin
                            word_cnt   <= 0;
                            read_count <= read_count + 1;

                            // Check for completion
                            if (read_count == cmd_total_bram_reads - 1) begin
                                state <= IDLE;
                                done  <= 1;
                            end
                        end else begin
                            word_cnt <= word_cnt + 1;
                        end

                        // 4. PIPELINE PREFETCH
                        // Request the next BRAM word exactly when we are processing the last chunk
                        // of the current word. It will arrive perfectly when word_cnt rolls over to 0.
                        if ((word_cnt == RATIO - 1) && (read_count < cmd_total_bram_reads - 1)) begin
                            bram_en   <= 1;
                            bram_addr <= read_ptr;
                            read_ptr  <= read_ptr + 1;
                        end
                    end
                end
            endcase
        end
    end

    // ============================================================
    // 6. AXIS OUTPUT FIFO
    // ============================================================
    fifo_axis #(
        .N(AXI_N), .DATA_WIDTH(DATA_WIDTH), .DEPTH(16)
    ) u_axis_fifo (
        .clk(clk), .rst(rst),
        .write_en(axis_fifo_wr),
        .data_in(current_chunk), // Using the combinational slice
        .last_in(axis_fifo_last_in),
        .full(axis_fifo_full),
        .read_en(m_axis_tready && !axis_fifo_empty),
        .data_out(m_axis_tdata),
        .last_out(m_axis_tlast),
        .empty(axis_fifo_empty),
        .count(axis_fifo_count)
    );

    assign m_axis_tvalid = !axis_fifo_empty;
    assign busy = (state != IDLE) || !fifo_empty;

endmodule












*/