`timescale 1ns / 1ps

module weight_loader #(
    parameter int ADDR_WIDTH = 10,
    parameter int DATA_WIDTH = 8, 
    parameter int N          = 4,    
    parameter int MATRIX_SIZE = 9,
    parameter int FIFO_DEPTH = 16   // Internal FIFO depth
)(
    input  logic clk,
    input  logic rst,

    // --- Control / Trigger ---
    input  logic start, // Enable signal (checks if FIFO has data)
    // --- OUTPUT: Delayed Start Signal ---
    output logic matrix_loader_start,

    // --- Configuration Interface (PUSH to Internal FIFO) ---
    input  logic [ADDR_WIDTH-1:0]   cfg_start_addr, 
    input  logic [MATRIX_SIZE-1:0]  cfg_num_tile_rows, 
    input  logic [MATRIX_SIZE-1:0]  cfg_num_tile_cols, 
    //input  logic                    start,
    //input  logic [MATRIX_SIZE-1:0]  cfg_matrix_tile_rows,
    
    input  logic                    cfg_valid, // PUSH signal
    output logic                    cfg_ready, // !FULL signal
    
    // --- Handshake ---
    input  logic load_next_en, // Signal from Array for the next Tile
    //output logic matrix_load_enable,


    //output logic loader_busy,  // High when the loader module is busy
    output logic weights_done, 
    input logic matrix_loader_done,

    // --- BRAM Interface ---
    output logic [ADDR_WIDTH-1:0]   bram_addr,
    output logic                    bram_en,
    input  logic [N*DATA_WIDTH-1:0] bram_dout,

    // --- Array Interface ---
    output logic [N*DATA_WIDTH-1:0] weight_data,
    output logic                    weight_valid,
    output logic                    weight_last
);

    // ============================================================
    // 1. WIDTH CALCULATIONS
    // ============================================================
    localparam int N_LOG2 = $clog2(N);
    
    localparam int FIFO_CMD_WIDTH = (MATRIX_SIZE * 2) + ADDR_WIDTH ;

    typedef enum logic [1:0] {IDLE, WAIT_TRIGGER, LOAD_TILE, DONE_STATE} state_t;
    state_t state;

    // ============================================================
    // START SIGNAL DELAY LINE (N + 1 Cycles)
    // ============================================================
    // // Start signal delay
    // localparam int START_DELAY = N + 2;
    
    // // // Shift Register pipeline
    // logic [START_DELAY-1:0] start_delay_pipe;

    // always_ff @(posedge clk) begin
    //     if (rst) begin
    //         start_delay_pipe <= '0;
    //     end else begin
    //         // Shift left: start signal enters from LSB and shifts towards MSB
    //         start_delay_pipe <= (start_delay_pipe << 1) | internal_start_pulse;
    //     end
    // end

    // // // The output is the MSB (the bit delayed by N+2 cycles)
    // assign matrix_loader_start = start_delay_pipe[START_DELAY-1];



// Internal signals for state transitions
    logic state_idle_trigger;
    logic state_to_idle_cond;

    // Trigger and Reset for Delay FSM (Global Reset or completed Tile)
    assign state_idle_trigger = ((state == DONE_STATE && load_next_en) || rst);
    
    // Condition to return to IDLE (if main FSM is IDLE, wait)
    assign state_to_idle_cond = (state == IDLE);

    // --- Delay FSM Definitions ---
    typedef enum logic [1:0] {
        D_TO_IDLE,  // Waiting for reset state
        D_IDLE,     // Idle state
        D_COUNT,    // Counting state (N stages)
        D_ENABLE    // Enable state (Output = 1)
    } delay_state_t;

    delay_state_t d_state;
    
    // Counter to delay for "N cycles" through N states
    localparam int DELAY_TARGET = N + 1; // We need N+2 cycles as before (start_delay), we achieve it with N and states.
    logic [31:0] delay_cnt;

    always_ff @(posedge clk) begin
        // 1. Trigger detected: jump to TO_IDLE
        if (state_idle_trigger) begin
            d_state   <= D_TO_IDLE;
            delay_cnt <= 0;
        end else begin
            case (d_state)
                // State 1: TO_IDLE - Wait to return to idle condition
                D_TO_IDLE: begin
                    if (state_to_idle_cond) begin
                        d_state <= D_IDLE;
                    end
                end

                // State 2: IDLE - Wait until the main FSM starts
                D_IDLE: begin
                    if (!state_to_idle_cond) begin // Main FSM started (not 0)
                        d_state   <= D_COUNT;
                        delay_cnt <= 0;
                    end
                end

                // State 3: COUNT - Wait for the "pipeline to fill" (N cycles)
                D_COUNT: begin
                    if (delay_cnt == DELAY_TARGET - 1) begin
                        d_state <= D_ENABLE;
                    end else begin
                        delay_cnt <= delay_cnt + 1;
                    end
                end

                // State 4: ENABLE - Activate output
                D_ENABLE: begin
                    // Stays here until state_idle_trigger becomes 1 (outer if)
                end
            endcase
        end
    end

    // Output is 1 only in the enable state
    assign matrix_loader_start = (d_state == D_ENABLE);






    // ============================================================
    // 2. INTERNAL SIGNALS & FIFO WIRING
    // ============================================================
    // FIFO Signals
    logic [FIFO_CMD_WIDTH-1:0] fifo_din;
    logic [FIFO_CMD_WIDTH-1:0] fifo_dout;
    logic fifo_push, fifo_pop;
    logic fifo_full, fifo_empty;

    // Internal Registers (Latched from FIFO)
    logic [ADDR_WIDTH-1:0]  start_addr_reg; 
    logic [MATRIX_SIZE-1:0] max_tile_rows;
    logic [MATRIX_SIZE-1:0] max_tile_cols;
    logic [ADDR_WIDTH-1:0]  stride; 
    
    // --- Deadlock Fix Flag ---
    logic first_tile; 
    // -------------------------

    // Counters
    logic [MATRIX_SIZE-1:0] current_tile_row;
    logic [MATRIX_SIZE-1:0] current_tile_col;
    //logic [MATRIX_SIZE-1:0] matrix_row;
    logic [MATRIX_SIZE-1:0] line_cnt;

    logic valid_d1;
    logic last_d1;
    logic last;

    // ============================================================
    // 3. INTERNAL FIFO INSTANCE
    // ============================================================
    assign fifo_din  = {cfg_num_tile_cols, cfg_num_tile_rows, cfg_start_addr};
    assign fifo_push = cfg_valid;
    assign cfg_ready = !fifo_full;

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

    assign stride  = max_tile_cols;

    logic internal_start_pulse;
    assign internal_start_pulse = (state == IDLE)  && !fifo_empty && start;

    // logic state_idle;
    // logic state_to_idle
    // assign state_idle = ((state == DONE_STATE && load_next_en) || rst);
    // assign state_to_idle = (state == IDLE);

    // ============================================================
    // 4. MAIN LOGIC (FSM)
    // ============================================================

    always_ff @(posedge clk) begin
        if (rst) begin
            state            <= IDLE;
            bram_addr        <= 0;
            bram_en          <= 0;
            current_tile_row <= 0;
            current_tile_col <= 0;
            line_cnt         <= N - 1;
            //line_cnt         <= 0;
            //weights_done     <= 0;
            //loader_busy      <= 0;
            max_tile_rows    <= 0;
            max_tile_cols    <= 0;
            start_addr_reg   <= 0;
            //stride           <= 0;
            fifo_pop         <= 0;
            first_tile       <= 0; 
            //matrix_row       <= 0;
            last             <= 0;
        end else begin
            //weights_done <= 0;
            fifo_pop     <= 0; 

            case (state)
                IDLE: begin
                    last <= 0;
                    //loader_busy <= 0;
                    
                    if (!fifo_empty && start) begin
                        // 1. Unpacking
                        start_addr_reg <= fifo_dout[ADDR_WIDTH-1:0];
                        max_tile_rows  <= fifo_dout[ADDR_WIDTH + MATRIX_SIZE - 1 : ADDR_WIDTH];
                        max_tile_cols  <= fifo_dout[ADDR_WIDTH + 2*MATRIX_SIZE - 1 : ADDR_WIDTH + MATRIX_SIZE];
                        //stride         <= fifo_dout[ADDR_WIDTH + 2*MATRIX_SIZE - 1 : ADDR_WIDTH + MATRIX_SIZE]; 
                        //matrix_row     <= fifo_dout[FIFO_CMD_WIDTH - 1 : ADDR_WIDTH + 2*MATRIX_SIZE];
                        
                        // 2. Reset Counters
                        current_tile_row <= 0;
                        current_tile_col <= 0;
                        
                        // --- Phase 1: Initialize counter (N-1) ---
                        line_cnt         <= N - 1; 
                        //line_cnt   <= 0;
                        
                        // --- Deadlock Fix ---
                        first_tile <= 1; 

                        // 3. Consume & Move
                        fifo_pop    <= 1;
                        //loader_busy <= 1; 
                        state       <= WAIT_TRIGGER;

                    end
                end

                WAIT_TRIGGER: begin
                    //loader_busy <= 1; 
                    bram_en     <= 0; // Ensure BRAM disabled while waiting
                    last        <= 0;

                    // --- Deadlock Fix: Check First Tile ---
                    if (load_next_en || first_tile) begin //////////////////////////////////////////
                        state      <= LOAD_TILE;
                        
                        // --- Phase 2: Reset counter (N-1) ---
                        line_cnt   <= N - 1; 
                        //line_cnt   <= 0;

                        first_tile <= 0; 
                    end
                end


/*
                LOAD_TILE: begin
                    
                    
                    // Calculate address (old logic)
                    //bram_addr <= start_addr_reg +  (current_tile_row << N_LOG2) + current_tile_col +  (line_cnt * stride);
                    bram_addr <= start_addr_reg +  ((current_tile_row * max_tile_cols )<< N_LOG2) + current_tile_col +  (line_cnt * stride);
                    // --- Phase 3: Update counters when reaching 0 ---
                    if (line_cnt == 0) begin
                        // Final read (Index 0)
                        bram_en  <= 0;       // Stop reading
                        line_cnt <= N - 1;   // Reset for the next time
                        
                        // --- Navigation Logic ---
                        if (current_tile_row == max_tile_rows - 1) begin
                            current_tile_row <= 0;
                            
                            if (current_tile_col == max_tile_cols - 1) begin
                                state <= DONE_STATE;
                            end else begin
                                current_tile_col <= current_tile_col + 1;
                                state <= WAIT_TRIGGER;
                            end
                            
                        end else begin
                            current_tile_row <= current_tile_row + 1;
                            state <= WAIT_TRIGGER; 
                        end
                       

                    end else begin
                        // Normal read (N-1 -> 1)
                        bram_en  <= 1;
                        line_cnt <= line_cnt - 1; // Decrement
                    end
                end

                
*/
                LOAD_TILE: begin ////////////////////////////////////////////////////////
                    bram_en   <= 1; 
                    last      <= 0; // Set last signal when line_cnt is 0
                    bram_addr <= start_addr_reg + ((current_tile_row * max_tile_cols) << N_LOG2) + current_tile_col + (line_cnt * stride);

                    if (line_cnt == 0) begin
                        line_cnt <= N - 1; 
                    //if (line_cnt == N - 1) begin
                    //    line_cnt <= 0; 
                        
                        if (current_tile_row == max_tile_rows - 1) begin
                            current_tile_row <= 0;
                            if (current_tile_col == max_tile_cols - 1) begin
                                state   <= DONE_STATE;
                                last      <= 1;
                                //bram_en <= 0;
                            end else begin
                                current_tile_col <= current_tile_col + 1;
                                state            <= WAIT_TRIGGER;
                                last      <= 1;
                                //bram_en          <= 0;
                            end
                        end else begin
                            current_tile_row <= current_tile_row + 1;
                            state            <= WAIT_TRIGGER; 
                            last      <= 1;
                            //bram_en          <= 0;
                        end
                    end else begin
                        line_cnt <= line_cnt - 1;
                        //line_cnt <= line_cnt + 1;

                    end
                end





                DONE_STATE: begin
                    //weights_done <= 1;
                    //loader_busy  <= 1;
                    bram_en <= 0;
                    last      <= 0;
                    //if (matrix_loader_done) begin 
                    if (load_next_en) begin 
                    state        <= IDLE; 
                    
                    end
                end
            endcase
        end
    end

    //assign weights_done = (state == DONE_STATE);

    // ============================================================
    // PIPELINE OUTPUTS
    // ============================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_d1 <= 0;
            last_d1  <= 0;
            weights_done <= 0;
        end else begin
            valid_d1 <= bram_en; //////////////////////////////////////////////////////////////////////////////
            weights_done <= (state == DONE_STATE);
            last_d1 <= last;
            //valid_d1 <= (state == LOAD_TILE);
            
            
            
            // --- Phase 4: Last becomes true when line_cnt is 0 ---
            // Because of the Pipeline, the 'last' signal needs to be triggered 
            // exactly at the moment when reading index '0'.
            //if (state == LOAD_TILE && line_cnt == 0) 
                ///last_d1 <= 1;

            //else /////////////////////////////////////////////////////////////////////////////////////////
            //else if (valid_d1)

                //last_d1 <= 0;
        end
    end

    assign weight_data  = bram_dout;
    assign weight_valid = valid_d1;
    assign weight_last  = last_d1;

endmodule






















/*


`timescale 1ns / 1ps

module weight_loader #(
    parameter int ADDR_WIDTH = 10,
    parameter int DATA_WIDTH = 8, 
    parameter int N          = 4,    
    parameter int MATRIX_SIZE = 9,
    parameter int FIFO_DEPTH = 16   // ????? ?????????? FIFO
)(
    input  logic clk,
    input  logic rst,

    // --- Control / Trigger ---
    input  logic start, // ?????? Enable (???????? ?? ? FIFO ???? ????????)
    // --- OUTPUT: Delayed Start Signal ---
    output logic matrix_loader_start,

    // --- Configuration Interface (PUSH to Internal FIFO) ---
    input  logic [ADDR_WIDTH-1:0]   cfg_start_addr, 
    input  logic [MATRIX_SIZE-1:0]  cfg_num_tile_rows, 
    input  logic [MATRIX_SIZE-1:0]  cfg_num_tile_cols, 
    //input  logic                    start,
    //input  logic [MATRIX_SIZE-1:0]  cfg_matrix_tile_rows,
    
    input  logic                    cfg_valid, // PUSH signal
    output logic                    cfg_ready, // !FULL signal
    
    // --- Handshake ---
    input  logic load_next_en, // ???? ??? ?? Array ??? ?? ??????? Tile
    //output logic matrix_load_enable,


    //output logic loader_busy,  // High ??? ?? ?????? ??? ????????? ????? ?? ?????????
    output logic weights_done, 
    input logic matrix_loader_done,

    // --- BRAM Interface ---
    output logic [ADDR_WIDTH-1:0]   bram_addr,
    output logic                    bram_en,
    input  logic [N*DATA_WIDTH-1:0] bram_dout,

    // --- Array Interface ---
    output logic [N*DATA_WIDTH-1:0] weight_data,
    output logic                    weight_valid,
    output logic                    weight_last
);

    // ============================================================
    // 1. WIDTH CALCULATIONS
    // ============================================================
    localparam int N_LOG2 = $clog2(N);
    
    localparam int FIFO_CMD_WIDTH = (MATRIX_SIZE * 2) + ADDR_WIDTH ;

    typedef enum logic [1:0] {IDLE, WAIT_TRIGGER, LOAD_TILE, DONE_STATE} state_t;
    state_t state;

    // ============================================================
    // START SIGNAL DELAY LINE (N + 1 Cycles)
    // ============================================================
    // ???????? ?? ????? ??? ????????????
    // localparam int START_DELAY = N + 2;
    
    // // ??????????? ????????? (Shift Register)
    // logic [START_DELAY-1:0] start_delay_pipe;

    // always_ff @(posedge clk) begin
    //     if (rst) begin
    //         start_delay_pipe <= '0;
    //     end else begin
    //         // Shift left: ?? start ??????? ??? LSB ??? ????????? ???? ?? MSB
    //         start_delay_pipe <= (start_delay_pipe << 1) | internal_start_pulse;
    //     end
    // end

    // // ? ?????? ????? ?? MSB (?? bit ??? ???? ???????????? N+2 ???????)
    // assign matrix_loader_start = start_delay_pipe[START_DELAY-1];



// ??????? ??????? ??????? ???? ?? ???????
    logic state_idle_trigger;
    logic state_to_idle_cond;

    // Trigger ??? Reset ??? Delay FSM (Global Reset ? ???????????? ??? ??? Tile)
    assign state_idle_trigger = ((state == DONE_STATE && load_next_en) || rst);
    
    // ??????? ????????? ??? IDLE (??? ? ???????? FSM ????? IDLE, ???????????)
    assign state_to_idle_cond = (state == IDLE);

    // --- Delay FSM Definitions ---
    typedef enum logic [1:0] {
        D_TO_IDLE,  // ?????????? ?????? reset
        D_IDLE,     // ?????? ????????
        D_COUNT,    // ?????? ???????????? (N stages)
        D_ENABLE    // ?????? ?????? (Output = 1)
    } delay_state_t;

    delay_state_t d_state;
    
    // ???????? ??? ?? ???????????? ?? "N ??????" ????? ?? ???????? N states
    localparam int DELAY_TARGET = N + 1; // ??????????? N+2 ???? ???? ????? ?????? (start_delay), ?????? ?? ?? N ?? ???.
    logic [31:0] delay_cnt;

    always_ff @(posedge clk) begin
        // 1. ??????? ?????????????: ????????? ??? TO_IDLE
        if (state_idle_trigger) begin
            d_state   <= D_TO_IDLE;
            delay_cnt <= 0;
        end else begin
            case (d_state)
                // ?????? 1: TO_IDLE - ??????????? ?? ??????????????
                D_TO_IDLE: begin
                    if (state_to_idle_cond) begin
                        d_state <= D_IDLE;
                    end
                end

                // ?????? 2: IDLE - ??????? ??? ??? ? ???????? FSM ????????
                D_IDLE: begin
                    if (!state_to_idle_cond) begin // ????? ? main FSM ???????? (????? 0)
                        d_state   <= D_COUNT;
                        delay_cnt <= 0;
                    end
                end

                // ?????? 3: COUNT - ????????? "??? ?????? ?? ??????" (N ??????)
                D_COUNT: begin
                    if (delay_cnt == DELAY_TARGET - 1) begin
                        d_state <= D_ENABLE;
                    end else begin
                        delay_cnt <= delay_cnt + 1;
                    end
                end

                // ?????? 4: ENABLE - ???????????? ??????
                D_ENABLE: begin
                    // ????????? ??? ????? ?? ????? ?? state_idle_trigger 1 (??????? if)
                end
            endcase
        end
    end

    // ? ?????? ??????? 1 ???? ??? ?????? ??????
    assign matrix_loader_start = (d_state == D_ENABLE);






    // ============================================================
    // 2. INTERNAL SIGNALS & FIFO WIRING
    // ============================================================
    // FIFO Signals
    logic [FIFO_CMD_WIDTH-1:0] fifo_din;
    logic [FIFO_CMD_WIDTH-1:0] fifo_dout;
    logic fifo_push, fifo_pop;
    logic fifo_full, fifo_empty;

    // Internal Registers (Latched from FIFO)
    logic [ADDR_WIDTH-1:0]  start_addr_reg; 
    logic [MATRIX_SIZE-1:0] max_tile_rows;
    logic [MATRIX_SIZE-1:0] max_tile_cols;
    logic [ADDR_WIDTH-1:0]  stride; 
    
    // --- Deadlock Fix Flag ---
    logic first_tile; 
    // -------------------------

    // Counters
    logic [MATRIX_SIZE-1:0] current_tile_row;
    logic [MATRIX_SIZE-1:0] current_tile_col;
    //logic [MATRIX_SIZE-1:0] matrix_row;
    logic [MATRIX_SIZE-1:0] line_cnt;

    logic valid_d1;
    logic last_d1;

    // ============================================================
    // 3. INTERNAL FIFO INSTANCE
    // ============================================================
    assign fifo_din  = {cfg_num_tile_cols, cfg_num_tile_rows, cfg_start_addr};
    assign fifo_push = cfg_valid;
    assign cfg_ready = !fifo_full;

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

    assign stride  = max_tile_cols;

    logic internal_start_pulse;
    assign internal_start_pulse = (state == IDLE)  && !fifo_empty && start;

    // logic state_idle;
    // logic state_to_idle
    // assign state_idle = ((state == DONE_STATE && load_next_en) || rst);
    // assign state_to_idle = (state == IDLE);

    // ============================================================
    // 4. MAIN LOGIC (FSM)
    // ============================================================

    always_ff @(posedge clk) begin
        if (rst) begin
            state            <= IDLE;
            bram_addr        <= 0;
            bram_en          <= 0;
            current_tile_row <= 0;
            current_tile_col <= 0;
            line_cnt         <= 0;
            //weights_done     <= 0;
            //loader_busy      <= 0;
            max_tile_rows    <= 0;
            max_tile_cols    <= 0;
            start_addr_reg   <= 0;
            //stride           <= 0;
            fifo_pop         <= 0;
            first_tile       <= 0; 
            //matrix_row       <= 0;
        end else begin
            //weights_done <= 0;
            fifo_pop     <= 0; 

            case (state)
                IDLE: begin
                    //loader_busy <= 0;
                    
                    if (!fifo_empty && start) begin
                        // 1. Unpacking
                        start_addr_reg <= fifo_dout[ADDR_WIDTH-1:0];
                        max_tile_rows  <= fifo_dout[ADDR_WIDTH + MATRIX_SIZE - 1 : ADDR_WIDTH];
                        max_tile_cols  <= fifo_dout[ADDR_WIDTH + 2*MATRIX_SIZE - 1 : ADDR_WIDTH + MATRIX_SIZE];
                        //stride         <= fifo_dout[ADDR_WIDTH + 2*MATRIX_SIZE - 1 : ADDR_WIDTH + MATRIX_SIZE]; 
                        //matrix_row     <= fifo_dout[FIFO_CMD_WIDTH - 1 : ADDR_WIDTH + 2*MATRIX_SIZE];
                        
                        // 2. Reset Counters
                        current_tile_row <= 0;
                        current_tile_col <= 0;
                        
                        // --- ?????? 1: ???????????? ??? ????? (N-1) ---
                        line_cnt         <= N - 1; 
                        
                        // --- Deadlock Fix ---
                        first_tile <= 1; 

                        // 3. Consume & Move
                        fifo_pop    <= 1;
                        //loader_busy <= 1; 
                        state       <= WAIT_TRIGGER;

                    end
                end

                WAIT_TRIGGER: begin
                    //loader_busy <= 1; 
                    bram_en     <= 0; // Ensure BRAM disabled while waiting

                    // --- Deadlock Fix: Check First Tile ---
                    if (load_next_en || first_tile) begin //////////////////////////////////////////
                        state      <= LOAD_TILE;
                        
                        // --- ?????? 2: Reset ??? ????? (N-1) ---
                        line_cnt   <= N - 1; 
                        first_tile <= 0; 
                    end
                end

*/
/*
                LOAD_TILE: begin
                    
                    
                    // ??????????? ?????????? (? ????? ??? ???????)
                    //bram_addr <= start_addr_reg +  (current_tile_row << N_LOG2) + current_tile_col +  (line_cnt * stride);
                    bram_addr <= start_addr_reg +  ((current_tile_row * max_tile_cols )<< N_LOG2) + current_tile_col +  (line_cnt * stride);
                    // --- ?????? 3: ?????????? ??????? ?? ?????? ??? 0 ---
                    if (line_cnt == 0) begin
                        // ????????? ???????? (Index 0)
                        bram_en  <= 0;       // Stop reading
                        line_cnt <= N - 1;   // Reset ??? ??? ??????? ????
                        
                        // --- Navigation Logic ---
                        if (current_tile_row == max_tile_rows - 1) begin
                            current_tile_row <= 0;
                            
                            if (current_tile_col == max_tile_cols - 1) begin
                                state <= DONE_STATE;
                            end else begin
                                current_tile_col <= current_tile_col + 1;
                                state <= WAIT_TRIGGER;
                            end
                            
                        end else begin
                            current_tile_row <= current_tile_row + 1;
                            state <= WAIT_TRIGGER; 
                        end
                       

                    end else begin
                        // ????????? ???????? (N-1 -> 1)
                        bram_en  <= 1;
                        line_cnt <= line_cnt - 1; // Decrement
                    end
                end

                
*/
/*
                LOAD_TILE: begin ////////////////////////////////////////////////////////
                    bram_en   <= 1; 
                    bram_addr <= start_addr_reg + ((current_tile_row * max_tile_cols) << N_LOG2) + current_tile_col + (line_cnt * stride);

                    if (line_cnt == 0) begin
                        line_cnt <= N - 1; 
                        
                        if (current_tile_row == max_tile_rows - 1) begin
                            current_tile_row <= 0;
                            if (current_tile_col == max_tile_cols - 1) begin
                                state   <= DONE_STATE;
                                //bram_en <= 0;
                            end else begin
                                current_tile_col <= current_tile_col + 1;
                                state            <= WAIT_TRIGGER;
                                //bram_en          <= 0;
                            end
                        end else begin
                            current_tile_row <= current_tile_row + 1;
                            state            <= WAIT_TRIGGER; 
                            //bram_en          <= 0;
                        end
                    end else begin
                        line_cnt <= line_cnt - 1;
                    end
                end





                DONE_STATE: begin
                    //weights_done <= 1;
                    //loader_busy  <= 1;
                    bram_en <= 0;
                    //if (matrix_loader_done) begin 
                    if (load_next_en) begin 
                    state        <= IDLE; 
                    
                    end
                end
            endcase
        end
    end

    assign weights_done = (state == DONE_STATE);

    // ============================================================
    // PIPELINE OUTPUTS
    // ============================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_d1 <= 0;
            last_d1  <= 0;
        end else begin
            valid_d1 <= bram_en; //////////////////////////////////////////////////////////////////////////////
            //valid_d1 <= (state == LOAD_TILE);
            
            
            
            // --- ?????? 4: ?? Last ??????? ???? ?? line_cnt ????? 0 ---
            // ?????? ????? Pipeline, ?? ???? 'last' ?????? ?? ???? 
            // ???? ???? ????? ??? ???????? ?? ???????? ??? ?????????? '0'.
            if (state == LOAD_TILE && line_cnt == 0) 
                last_d1 <= 1;
            else /////////////////////////////////////////////////////////////////////////////////////////
            //else if (valid_d1)
                last_d1 <= 0;
        end
    end

    assign weight_data  = bram_dout;
    assign weight_valid = valid_d1;
    assign weight_last  = last_d1;

endmodule



*/

























