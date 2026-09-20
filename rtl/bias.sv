`timescale 1ns / 1ps

module bias_adder #(
    parameter int N           = 4,      // Lanes
    parameter int DATA_WIDTH  = 32,     // Input Width
    parameter int ADDR_WIDTH  = 10,     // Bias Memory Depth
    parameter int MATRIX_SIZE = 9,      // Counter Bits
    parameter int FIFO_DEPTH  = 4       // Command Queue Depth
)(
    input  logic clk,
    input  logic rst,

    // --- Configuration (FIFO Input) ---
    input  logic [ADDR_WIDTH-1:0]   cfg_bias_base_addr, 
    input  logic [MATRIX_SIZE-1:0]  cfg_num_tile_rows,  
    input  logic [MATRIX_SIZE-1:0]  cfg_num_tile_cols,
    input  logic                    cfg_enable,
    
    input  logic                    cfg_valid, 
    output logic                    cfg_ready, 

    // --- Status ---
    output logic busy, 
    output logic done, 

    // --- Data Path ---
    input  logic [N*DATA_WIDTH-1:0] data_in_packed,
    input  logic                    valid_in,

    // --- BRAM Interface ---
    output logic [ADDR_WIDTH-1:0]   bram_addr,
    output logic                    bram_en,
    input  logic [DATA_WIDTH-1:0]             bram_dout, 

    // --- Output ---
    output logic [N*DATA_WIDTH-1:0] data_out_packed,
    output logic                    valid_out,
    output logic                    last_out // <-- ΝΕΟ ΣΗΜΑ
);

    // --- Internal Signals ---
    localparam int FIFO_WIDTH = ADDR_WIDTH + 2*MATRIX_SIZE + 1;
    
    logic [FIFO_WIDTH-1:0] fifo_din, fifo_dout;
    logic fifo_push, fifo_pop, fifo_empty, fifo_full;

    // Active Config
    logic [ADDR_WIDTH-1:0]  current_base_addr;
    logic [MATRIX_SIZE-1:0] current_num_tile_rows;
    logic [MATRIX_SIZE-1:0] current_num_tile_cols;
    logic                   current_enable; 

    // Counters
    logic [ADDR_WIDTH-1:0]  cnt_vertical; 
    logic [ADDR_WIDTH-1:0]  total_vertical_lines;
    logic [MATRIX_SIZE-1:0] cnt_tile_cols;

    // Pipeline Logic
    logic signed [DATA_WIDTH-1:0] lane_data [0:N-1];
    logic signed [DATA_WIDTH-1:0] result_data [0:N-1];
    
    // Stage 1 Registers
    logic signed [DATA_WIDTH-1:0] data_d1 [0:N-1];
    logic                         valid_d1;
    logic                         last_d1; // <-- Pipeline Register για το Last

    // Last Input Detection Signal
    logic                         is_last_input; 

    typedef enum logic {IDLE, ACTIVE} state_t;
    state_t state;

    // --- FIFO Instance ---
    assign fifo_din  = {cfg_enable, cfg_num_tile_cols, cfg_num_tile_rows, cfg_bias_base_addr};
    assign fifo_push = cfg_valid;
    assign cfg_ready = !fifo_full;

    simple_fifo #(.WIDTH(FIFO_WIDTH), .DEPTH(FIFO_DEPTH)) u_config_fifo (
        .clk(clk), .rst(rst),
        .push(fifo_push), .data_in(fifo_din),
        .pop(fifo_pop), .data_out(fifo_dout),
        .full(fifo_full), .empty(fifo_empty)
    );

    // Unpack Input
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : gen_unpack
             assign lane_data[i] = data_in_packed[i*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    assign total_vertical_lines = current_num_tile_rows * N;

    // --- Combinational Logic ---
    always_comb begin
        // Address Calc
        bram_addr = current_base_addr + cnt_vertical[ADDR_WIDTH-1:0];

        // Enable Logic
        if ((state == ACTIVE) && valid_in && current_enable) 
            bram_en = 1'b1;
        else 
            bram_en = 1'b0;

        // Last Input Detection (Combinational)
        // Είναι το τελευταίο αν έχουμε valid input ΚΑΙ οι counters είναι στα μέγιστα
        if ((state == ACTIVE) && valid_in && 
            (cnt_vertical == total_vertical_lines - 1) && 
            (cnt_tile_cols == current_num_tile_cols - 1)) begin
            is_last_input = 1'b1;
        end else begin
            is_last_input = 1'b0;
        end
    end

    // --- Sequential Logic ---
    always_ff @(posedge clk) begin
        if (rst) begin
            state               <= IDLE;
            fifo_pop            <= 0;
            cnt_vertical        <= 0;
            cnt_tile_cols       <= 0;
            done                <= 0;
            busy                <= 0;
            current_enable      <= 0;
            
            // Reset Pipeline
            valid_d1            <= 0;
            last_d1             <= 0; // Reset last flag
            for (int k=0; k<N; k++) data_d1[k] <= 0;
            
        end else begin
            fifo_pop <= 0;
            done     <= 0;

            case (state)
                IDLE: begin
                    if (!fifo_empty) begin
                        current_base_addr     <= fifo_dout[ADDR_WIDTH-1:0];
                        current_num_tile_rows <= fifo_dout[ADDR_WIDTH + MATRIX_SIZE - 1 : ADDR_WIDTH];
                        current_num_tile_cols <= fifo_dout[ADDR_WIDTH + 2*MATRIX_SIZE - 1 : ADDR_WIDTH + MATRIX_SIZE];
                        current_enable        <= fifo_dout[FIFO_WIDTH-1]; 
                        
                        fifo_pop      <= 1; 
                        cnt_vertical  <= 0;
                        cnt_tile_cols <= 0;
                        state         <= ACTIVE;
                        busy          <= 1;
                    end else begin
                        busy <= 0;
                    end
                end

                ACTIVE: begin
                    busy <= 1;
                    if (valid_in) begin
                        if (cnt_vertical == total_vertical_lines - 1) begin
                            cnt_vertical <= 0; 
                            if (cnt_tile_cols == current_num_tile_cols - 1) begin
                                cnt_tile_cols <= 0;
                                done          <= 1;
                                state         <= IDLE;
                            end else begin
                                cnt_tile_cols <= cnt_tile_cols + 1;
                            end
                        end else begin
                            cnt_vertical <= cnt_vertical + 1;
                        end
                    end 
                end
            endcase

            // --- Pipeline Stage 1 ---
            // Data & Valid
            valid_d1 <= valid_in;
            for (int k=0; k<N; k++) begin
                data_d1[k] <= lane_data[k];
            end
            
            // Περνάμε το last signal στο επόμενο στάδιο
            last_d1 <= is_last_input;
        end
    end

    // --- Pipeline Stage 2 (Addition & Output) ---
    logic signed [31:0] bias_val;
    assign bias_val = (current_enable) ? $signed(bram_dout) : 32'd0;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_out <= 0;
            last_out  <= 0; // Reset Output
        end else begin
            valid_out <= valid_d1;
            last_out  <= last_d1; // Το last_out ακολουθεί ακριβώς το valid_out
            
            for (int k=0; k<N; k++) begin
                if (valid_d1)
                    result_data[k] <= data_d1[k] + bias_val;
                else
                    result_data[k] <= 0;
            end
        end
    end

    // Pack Output
    generate
        for (i = 0; i < N; i++) begin : gen_pack
             assign data_out_packed[i*DATA_WIDTH +: DATA_WIDTH] = result_data[i];
        end
    endgenerate

endmodule