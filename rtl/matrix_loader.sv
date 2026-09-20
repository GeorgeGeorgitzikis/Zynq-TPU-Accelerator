`timescale 1ns / 1ps

module matrix_loader #(
    parameter int ADDR_WIDTH = 10,
    parameter int DATA_WIDTH = 8, 
    parameter int N          = 4,     
    parameter int MATRIX_SIZE = 9,    
    parameter int FIFO_DEPTH = 16     
)(
    input  logic clk,
    input  logic rst,

    // --- Control ---
    input  logic start,
    //input  logic load_next_col_en, // Trigger

    // --- Config ---
    input  logic [ADDR_WIDTH-1:0]   cfg_start_addr, 
    input  logic [MATRIX_SIZE-1:0]  cfg_num_tile_rows,
    input  logic [MATRIX_SIZE-1:0]  cfg_num_tile_cols,
    input  logic [MATRIX_SIZE-1:0]  cfg_weight_rows,   
    
    input  logic                    cfg_valid,
    output logic                    cfg_ready,

    // --- Status ---
    //output logic loader_busy,
    output logic loader_done,

    // --- BRAM ---
    output logic [ADDR_WIDTH-1:0]   bram_addr,
    output logic                    bram_en,
    input  logic [N*DATA_WIDTH-1:0] bram_dout,

    // --- Array Output ---
    output logic [N*DATA_WIDTH-1:0] m_axis_data,
    output logic                    m_axis_valid,
    output logic                    m_axis_last,

    output logic                    swap_enable,
    output logic                    load_next_weights_enable 
);

    // ============================================================
    // 1. SIGNALS
    // ============================================================
    localparam int N_LOG2 = $clog2(N);
    
    localparam int FIFO_CMD_WIDTH = (MATRIX_SIZE * 3) + ADDR_WIDTH;

    logic [FIFO_CMD_WIDTH-1:0] fifo_din, fifo_dout;
    logic fifo_push, fifo_pop, fifo_full, fifo_empty;

    logic [ADDR_WIDTH-1:0]  base_addr;
    logic [MATRIX_SIZE-1:0] max_tile_rows, max_tile_cols, num_repeats, stride;
    logic [MATRIX_SIZE-1:0] current_tile_row, line_cnt, repeat_cnt, current_tile_col;

    // State Machine
    typedef enum logic [1:0] {IDLE, WAIT_COL_TRIGGER, LOAD_DATA, DONE_STATE} state_t;
    state_t state;

    // Pipeline Registers
    logic valid_d1;
    logic last_d1;
    logic last;
    logic swap;
    logic swap_d1;
    logic swap_d2;
    
    //logic initial_swap;
    //logic initial_swap_d1;
    //logic initial_swap_d2;
    //logic initial_swap_d3;
    
    logic first_column_run; 
    
    logic [7:0] wait_cnt;
    logic       internal_load_trigger;

    // ============================================================
    // 2. FIFO
    // ============================================================
    assign fifo_din  = {cfg_weight_rows, cfg_num_tile_cols, cfg_num_tile_rows, cfg_start_addr};
    assign fifo_push = cfg_valid;
    assign cfg_ready = !fifo_full;

    simple_fifo #(.WIDTH(FIFO_CMD_WIDTH), .DEPTH(FIFO_DEPTH)) u_cmd_fifo (
        .clk(clk), .rst(rst), .push(fifo_push), .data_in(fifo_din),
        .pop(fifo_pop), .data_out(fifo_dout), .full(fifo_full), .empty(fifo_empty)
    );

    // ============================================================
    // 3. MAIN FSM
    // ============================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            state            <= IDLE;
            bram_en          <= 0; 
            bram_addr        <= 0;
            current_tile_row <= 0; 
            line_cnt         <= 0; 
            repeat_cnt       <= 0; 
            current_tile_col <= 0;
            fifo_pop         <= 0; 
            //loader_done      <= 0; 
            //loader_busy      <= 0;
            //initial_swap     <= 0;
            first_column_run <= 0;
            swap             <= 0;
            last             <= 0;
        end else begin
            fifo_pop    <= 0; 
            //loader_done <= 0;

            case (state)
                IDLE: begin
                    bram_en      <= 0; 
                    //loader_busy <= 0;
                    if (start && !fifo_empty) begin
                        // Unpacking
                        base_addr     <= fifo_dout[ADDR_WIDTH-1:0];
                        max_tile_rows <= fifo_dout[ADDR_WIDTH + MATRIX_SIZE - 1 : ADDR_WIDTH];
                        max_tile_cols <= fifo_dout[ADDR_WIDTH + 2*MATRIX_SIZE - 1 : ADDR_WIDTH + MATRIX_SIZE];
                        stride        <= fifo_dout[ADDR_WIDTH + 2*MATRIX_SIZE - 1 : ADDR_WIDTH + MATRIX_SIZE]; 
                        num_repeats   <= fifo_dout[FIFO_CMD_WIDTH - 1 : ADDR_WIDTH + 2*MATRIX_SIZE];

                        // Init
                        current_tile_row <= 0;
                        line_cnt         <= 0;
                        repeat_cnt       <= 0;
                        current_tile_col <= 0;
                        
                        fifo_pop     <= 1; 
                        //loader_busy  <= 1;
                        //initial_swap <= 1; // Set flag HIGH
                        swap         <= 0;
                        
                        // Note: First column runs initially
                        first_column_run <= 1; 
                        
                        state <= WAIT_COL_TRIGGER; 
                    end
                end

                WAIT_COL_TRIGGER: begin
                    //loader_busy  <= 1;
                    bram_en      <= 0; 
                    // initial_swap remains 1 during initialization
                    
                    if (internal_load_trigger || first_column_run) begin
                        state            <= LOAD_DATA;
                        first_column_run <= 0; 
                        swap <= 1;
                        
                    end
                end


/*
                LOAD_DATA: begin
                    //loader_busy  <= 1;
                    bram_en      <= 1;
                    //initial_swap <= 0; // Clear flag when execution starts
                    swap <= 0;
                    
                    bram_addr <= base_addr + ((current_tile_row * max_tile_cols )<< N_LOG2) + current_tile_col + (line_cnt * stride);

                    if (line_cnt == N - 1) begin
                        line_cnt <= 0;
                        
                        if (current_tile_row == max_tile_rows - 1) begin
                            current_tile_row <= 0;
                            
                            // Check END or NEXT COL/REPEAT
                            if (current_tile_col == max_tile_cols - 1) begin
                                if (repeat_cnt == num_repeats - 1) begin
                                    // Done
                                    current_tile_col <= 0;
                                    repeat_cnt       <= 0;
                                    bram_en          <= 0;
                                    state            <= DONE_STATE;
                                end else begin
                                    // Next Repeat -> WAIT
                                    current_tile_col <= 0;
                                    repeat_cnt       <= repeat_cnt + 1;
                                    state            <= WAIT_COL_TRIGGER; 
                                end
                            end else begin
                                // Next Column -> WAIT
                                current_tile_col <= current_tile_col + 1;
                                state            <= WAIT_COL_TRIGGER;
                            end

                        end else begin
                            // Next Row (Same Column) -> CONTINUE
                            current_tile_row <= current_tile_row + 1;
                        end
                    end else begin
                        line_cnt <= line_cnt + 1;
                    end
                end
*/                


                LOAD_DATA: begin
                    bram_en   <= 1; // Enable is 1 throughout the execution
                    swap      <= 0;
                    last             <= 0;
                    bram_addr <= base_addr + ((current_tile_row * max_tile_cols) << N_LOG2) + current_tile_col + (line_cnt * stride);

                    if (line_cnt == N - 1) begin
                        line_cnt <= 0;
                        //bram_en  <= 0;
                        // Caution: Changing state, but bram_en will remain 1 for this cycle
                        // Because of Non-Blocking (<=). In the next clock cycle it goes to WAIT, 
                        // and bram_en will become 0 in the WAIT_COL_TRIGGER state.
                        
                        if (current_tile_row == max_tile_rows - 1) begin
                            current_tile_row <= 0;
                            if (current_tile_col == max_tile_cols - 1) begin
                                if (repeat_cnt == num_repeats - 1) begin
                                    //current_tile_col <= 0;
                                    //repeat_cnt       <= 0;
                                    //bram_en          <= 0;
                                    state <= DONE_STATE;
                                    last             <= 1;
                                end
                                else begin
                                    repeat_cnt <= repeat_cnt + 1;
                                    current_tile_col <= 0;
                                    state <= WAIT_COL_TRIGGER;
                                end
                            end else begin
                                current_tile_col <= current_tile_col + 1;
                                state <= WAIT_COL_TRIGGER;
                            end
                        end else begin
                            current_tile_row <= current_tile_row + 1;
                            //state <= WAIT_COL_TRIGGER;
                        end
                    end else begin
                        line_cnt <= line_cnt + 1;
                    end
                end












                DONE_STATE: begin
                    //loader_done <= 1;
                    //loader_busy <= 1;
                    state       <= IDLE;
                    bram_en          <= 0;
                    last             <= 0;
                end
            endcase
        end
    end

   // assign loader_done = (state == DONE_STATE);

    //(load_next_col_en || first_column_run || internal_load_trigger)
    // Delay block for the next trigger


    always_ff @(posedge clk) begin
        if (rst) begin
            wait_cnt              <= 0;
            internal_load_trigger <= 0;
        end else begin
            // Counting only in WAIT state (when it's not the first column run)
            if (state == WAIT_COL_TRIGGER && !first_column_run) begin
                
                if (max_tile_rows == 1) begin
                    // 1 row dimension: wait for N cycles===================================
                    if (wait_cnt == N - 1) begin
                        internal_load_trigger <= 1;
                        wait_cnt              <= 0;
                    end else begin
                        internal_load_trigger <= 0;
                        wait_cnt              <= wait_cnt + 1;
                    end
                end else begin
                    // Multiple rows dimension: direct trigger
                    internal_load_trigger <= 1;
                    wait_cnt              <= 0;
                end

            end else begin
                // Reset for all other states
                internal_load_trigger <= 0;
                wait_cnt              <= 0;
            end
        end
    end

//////////////////////////////////////////////////////////////////////////////////////////////


    // ============================================================
    // 4. PIPELINE OUTPUTS
    // ============================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_d1        <= 0;
            last_d1         <= 0;           
            swap_d1         <= 0;
            swap_d2         <= 0;
            loader_done     <= 0;

        end else begin
            last_d1         <= last; 
            loader_done <= (state == DONE_STATE);
            valid_d1        <= bram_en;  //////////////////////////////////////////////////////////////////
            //valid_d1 <= (state == LOAD_DATA);
                       
            swap_d1         <= swap;
            swap_d2         <= swap_d1;
                 
            // LAST: at the end of each Tile
            //if (state == LOAD_DATA && line_cnt == N - 1) begin
                //last_d1 <= 1;
           // end else begin   ///////////////////////////////////////////////////////////////////////////////////
            //end else if (valid_d1)begin // If valid drops, last must drop
                
               // last_d1 <= 0;
            //end
       end
    end
  
   

   
   
   

    assign m_axis_data  = bram_dout;
    assign m_axis_valid = valid_d1;
    assign m_axis_last  = last_d1;
    
    // Using d2 so the initial swap drops along with the data
    assign swap_enable  = swap_d2 ;
    assign load_next_weights_enable = swap ;

endmodule











