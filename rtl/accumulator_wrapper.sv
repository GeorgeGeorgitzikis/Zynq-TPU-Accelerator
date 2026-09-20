`timescale 1ns / 1ps

module accumulator_wrapper #(
    parameter int N = 4,
    parameter int ACC_WIDTH = 32,
    parameter int ADDR_WIDTH = 10,

    parameter int MATRIX_SIZE = 9,    // Bits για διαστάσεις
    parameter int FIFO_DEPTH = 16     // Βάθος εσωτερικής FIFO
)(
    input  logic clk,
    input  logic rst,

    // Command Interface
    input  logic [MATRIX_SIZE-1:0]  cmd_num_tile_rows, // Πόσα Tiles ύψος έχει ο Πίνακας
    input  logic [MATRIX_SIZE-1:0]  cmd_num_tile_cols, // Πόσα Tiles πλάτος (Stride)
    input  logic [MATRIX_SIZE-1:0]  cmd_num_tile_k,
    input  logic                 cmd_accumulate_mode, // 1=Αθροίζει, 0=Επανεγγράφει
    input  logic                 cmd_keep_in_bram,      // 1=Κρατάει τα δεδομένα στη BRAM μετά το batch
    input  logic                 cmd_valid,     
    output logic                 cmd_ready,

    // Data Input
    input  logic signed [N*ACC_WIDTH-1:0] new_sums_packed,
    input  logic valid_in,
    input  logic last_in, 

    // Readout & Status
    //input  logic [ADDR_WIDTH-1:0] num_words_readout, 
    output logic quant_valid,
    output logic [N*ACC_WIDTH-1:0] quant_data,
    
    output logic batch_done_tick, 
    output logic busy
);

    localparam int FIFO_CMD_WIDTH = (MATRIX_SIZE * 3) + 2 ;
    localparam int N_LOG2 = $clog2(N);

    // Internal Signals
    // Το μισό πλάτος της εντολής για Rows και Cols
    logic [MATRIX_SIZE-1:0] rows_c; 
    logic [MATRIX_SIZE-1:0] cols_c; 
    logic [MATRIX_SIZE-1:0] k_c;

    // Counters (Πρέπει να έχουν το ίδιο πλάτος με τα rows_c/cols_c)
    logic [MATRIX_SIZE-1:0] tile_row_ptr;        // Loop 1
    logic [MATRIX_SIZE-1:0] batch_count;     // Loop 2
    logic [MATRIX_SIZE-1:0] c_colums_done;   // Loop 3
    logic [$clog2(N)-1:0] line_cnt; // Μετρητής γραμμών (0 έως N-1)

    // State Flags
    logic processing_batch;
    logic swap_enabled;
    
    // FIFO Signals
    logic fifo_full, fifo_empty;
    logic fifo_pop;
    logic [FIFO_CMD_WIDTH-1:0] fifo_data_out; 

    // Controls
    logic ctrl_accumulate_en;
    logic ctrl_swap_banks;
    logic ctrl_start_readout;
    
    // Submodules
    logic sub_done_tick; 
    logic sub_busy;
    
    // Loopback wires
    logic we_int, re_int;
    logic [ADDR_WIDTH-1:0] wr_addr_int, rd_addr_int;
    logic [N*ACC_WIDTH-1:0] wdata_int, rdata_int;

    logic cfg_accumulate_mode;
    logic cfg_keep_in_bram;


     logic [FIFO_CMD_WIDTH-1:0] fifo_din;
     //assign fifo_din  = {cmd_keep_in_bram, cmd_accumulate_mode, cmd_num_tile_cols, cmd_num_tile_rows};
    assign fifo_din  = {cmd_keep_in_bram, cmd_accumulate_mode, cmd_num_tile_k, cmd_num_tile_cols, cmd_num_tile_rows};

    // FIFO Instance
    assign cmd_ready = !fifo_full;
    
        simple_fifo #(
        .WIDTH(FIFO_CMD_WIDTH), 
        .DEPTH(FIFO_DEPTH)
    ) u_cmd_fifo (
        .clk(clk), .rst(rst),
        .push(cmd_valid), 
        .data_in(fifo_din),
        .pop(fifo_pop), 
        .data_out(fifo_data_out),
        .full(fifo_full), 
        .empty(fifo_empty)
    );


    // ============================================================
    // THE CONTROLLER LOGIC
    // ============================================================
    
    always_ff @(posedge clk) begin
        if (rst) begin
            rows_c           <= 0;
            cols_c           <= 0;
            k_c              <= 0;
            tile_row_ptr         <= 0;
            batch_count      <= 0; 
            c_colums_done    <= 0;
            ctrl_swap_banks  <= 0;
            ctrl_start_readout <= 0;
            batch_done_tick  <= 0;
            swap_enabled     <= 0;
            processing_batch <= 0;
            fifo_pop         <= 0;
            line_cnt <= 0;
        end else begin
            // Defaults
            ctrl_swap_banks    <= 0;
            ctrl_start_readout <= 0;
            batch_done_tick    <= 0;
            fifo_pop           <= 0; 

            // A. START COMMAND
            if (!processing_batch && !fifo_empty) begin
                // Δυναμικό Slicing ανάλογα με το CMD_WIDTH
                //cols_c           <= fifo_data_out[FIFO_CMD_WIDTH-3 : MATRIX_SIZE];
                //rows_c           <= fifo_data_out[MATRIX_SIZE-1 : 0];
                k_c              <= fifo_data_out[FIFO_CMD_WIDTH-3 : 2*MATRIX_SIZE];
                cols_c           <= fifo_data_out[2*MATRIX_SIZE-1 : MATRIX_SIZE];
                rows_c           <= fifo_data_out[MATRIX_SIZE-1 : 0];
                cfg_accumulate_mode <= fifo_data_out[FIFO_CMD_WIDTH-2];
                cfg_keep_in_bram    <= fifo_data_out[FIFO_CMD_WIDTH-1];
                
                tile_row_ptr         <= 0;
                batch_count      <= 0;
                c_colums_done    <= 0;
                
                swap_enabled     <= 0;
                processing_batch <= 1;
                fifo_pop         <= 1;
            end

            // B. INPUT LOGIC (Triple Loop)
        if (processing_batch && valid_in) begin
            // Κάθε valid_in αυξάνει τον line_cnt
            if (line_cnt == N - 1) begin
                line_cnt <= 0;
                               
                if (tile_row_ptr == rows_c - 1) begin
                    tile_row_ptr <= 0;
                    
                    if (batch_count == k_c - 1) begin
                        batch_count <= 0;
                        
                        if (c_colums_done == cols_c - 1) begin
                            swap_enabled  <= 1;
                            c_colums_done <= 0;
                        end else begin
                            c_colums_done <= c_colums_done + 1;
                        end
                    end else begin
                        batch_count <= batch_count + 1;
                    end
                end else begin
                    tile_row_ptr <= tile_row_ptr + 1;
                end
            end else begin
                line_cnt <= line_cnt + 1;
            end
        end





            // C. OUTPUT LOGIC (Swap & Pop)
            if (processing_batch && sub_done_tick && swap_enabled) begin

                batch_done_tick    <= 1;
                swap_enabled       <= 0;
                processing_batch   <= 0;
                //fifo_pop           <= 1; 

            if (!cfg_keep_in_bram) begin
                ctrl_swap_banks    <= 1;
                ctrl_start_readout <= 1;
            end

            end
        end
    end


    // LOGIC: ACCUMULATE ENABLE
    assign ctrl_accumulate_en = (batch_count != 0)|| cfg_accumulate_mode;




    logic [ADDR_WIDTH-1:0] current_rd_addr;
    //assign current_rd_addr =  (line_cnt + tile_row_ptr) << N_LOG2 + (c_colums_done * rows_c) << N_LOG2 ;
    assign current_rd_addr =  ((tile_row_ptr *  cols_c ) << N_LOG2 ) + (c_colums_done << N_LOG2)   + line_cnt ;
    
    // INSTANTIATIONS
    accumulator_ctrl #(.N(N), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) u_ctrl (
        .clk(clk), .rst(rst),
        .new_sums_packed(new_sums_packed), .valid_in(valid_in), .last_in(last_in), 
        .accumulate_en(ctrl_accumulate_en), 
        .start_addr(current_rd_addr), // Tile ptr controls address
        .done_tick(sub_done_tick), .busy(sub_busy),
        .mem_we(we_int), .mem_wr_addr(wr_addr_int), .mem_din(wdata_int),
        .mem_rd_en(re_int), .mem_rd_addr(rd_addr_int), .mem_dout(rdata_int)
    );

    logic [ADDR_WIDTH-1:0] num_words_readout;
    assign num_words_readout = (rows_c * cols_c) << N_LOG2 ; // Υπολογισμός

    acc_ping_pong_wrapper #(.N(N), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) u_mem (
        .clk(clk), .rst(rst),
        .swap_banks(ctrl_swap_banks), 
        .acc_we(we_int), .acc_wr_addr(wr_addr_int), .acc_wr_data(wdata_int),
        .acc_re(re_int), .acc_rd_addr(rd_addr_int), .acc_rd_data(rdata_int),
        .start_readout(ctrl_start_readout), .num_words(num_words_readout),
        .quant_valid(quant_valid), .quant_data(quant_data)
    );
    
    assign busy = processing_batch || sub_busy || !fifo_empty;

endmodule





































