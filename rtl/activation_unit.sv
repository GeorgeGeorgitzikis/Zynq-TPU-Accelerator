`timescale 1ns / 1ps

module activation_unit #(
    parameter int N          = 4,
    parameter int DATA_WIDTH = 32,
    parameter int TABLE_AW   = 10,
    parameter int FIFO_DEPTH = 4,
    parameter  GELU_FILE = "gelu_table.mem",
    parameter  SIGM_FILE = "sigmoid_table.mem"
)(
    input  logic clk,
    input  logic rst,

    // Config
    input  logic [1:0] cfg_act_mode, 
    input  logic       cfg_valid,
    output logic       cfg_ready,

    // Data
    input  logic [N*DATA_WIDTH-1:0] data_in_packed,
    input  logic                    valid_in,
    input  logic                    last_in,      
    
    output logic [N*DATA_WIDTH-1:0] data_out_packed,
    output logic                    valid_out,
    output logic                    last_out    
);

    // --- FIFO ---
    localparam int FIFO_CMD_WIDTH = 2;

    logic [1:0] fifo_dout;
    logic       fifo_empty, fifo_pop, fifo_full;
    
    assign cfg_ready = !fifo_full;
    
    simple_fifo #(.WIDTH(FIFO_CMD_WIDTH), .DEPTH(FIFO_DEPTH)) u_cfg_fifo (
        .clk(clk), .rst(rst),
        .push(cfg_valid), .data_in(cfg_act_mode), 
        .pop(fifo_pop), .data_out(fifo_dout),.full(fifo_full), .empty(fifo_empty)
    );
 

    // --- FSM (2-State Optimized) ---
    logic [1:0] active_mode; 
    typedef enum logic {IDLE, BUSY} state_t; 
    state_t state;

    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= IDLE;
            active_mode <= 0;
            fifo_pop    <= 0;
        end else begin
            fifo_pop <= 0;

            case (state)
                IDLE: begin
                    if (!fifo_empty) begin
                        active_mode <= fifo_dout;
                        fifo_pop    <= 1;
                        state       <= BUSY;
                    end
                end

                BUSY: begin
                    //if (valid_in && last_in) begin
                    if (last_in) begin
                        state <= IDLE; 
                    end
                end
            endcase
        end
    end

    // --- Memories ---
    logic signed [DATA_WIDTH-1:0] gelu_mem [0:(1<<TABLE_AW)-1];
    logic signed [DATA_WIDTH-1:0] sigm_mem [0:(1<<TABLE_AW)-1];

    initial begin
        $readmemh(GELU_FILE, gelu_mem);
        $readmemh(SIGM_FILE, sigm_mem);
    end

    // --- Data Pipeline ---
    logic signed [DATA_WIDTH-1:0] lane_in    [0:N-1];
    logic signed [DATA_WIDTH-1:0] lane_in_d1 [0:N-1]; // Ξ”Ξ®Ξ»Ο‰ΟƒΞ· Ξ•Ξ?Ξ© Ξ±Ο€Ο? Ο„ΞΏ generate
    logic signed [DATA_WIDTH-1:0] lane_out   [0:N-1];
    
    // Control Pipeline Registers
    logic valid_d1, last_d1;
    logic [1:0] mode_d1; 

    genvar i;
    generate
        for (i = 0; i < N; i++) begin : lanes
            // Unpack
            assign lane_in[i] = data_in_packed[i*DATA_WIDTH +: DATA_WIDTH];
            
            logic [TABLE_AW-1:0] addr_reg;
            
            always_ff @(posedge clk) begin
                // --- Stage 1: Capture Address & Delay Data for Bypass ---
                if (valid_in) begin
                    addr_reg      <= lane_in[i] + (1 << (TABLE_AW-1));
                    lane_in_d1[i] <= lane_in[i]; // Ξ‘Ο€ΞΏΞΈΞ®ΞΊΞµΟ…ΟƒΞ· Ξ³ΞΉΞ± ΟƒΟ…Ξ³Ο‡Ο?ΞΏΞ½ΞΉΟƒΞΌΟ? (Balancing)
                end

                // --- Stage 2: Memory Read OR Bypass ---
                case (mode_d1)
                    2'b01:   lane_out[i] <= gelu_mem[addr_reg];
                    2'b10:   lane_out[i] <= sigm_mem[addr_reg];
                    default: lane_out[i] <= lane_in_d1[i]; // Ξ§Ο?Ξ®ΟƒΞ· Ο„ΞΏΟ… delayed data
                endcase
            end
            
            // Pack Output
            assign data_out_packed[i*DATA_WIDTH +: DATA_WIDTH] = lane_out[i];
        end
    endgenerate

    // --- Control Pipeline ---
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_d1 <= 0; valid_out <= 0;
            last_d1  <= 0; last_out  <= 0;
            mode_d1  <= 0;
        end else begin
            // Stage 1 Capture
            valid_d1 <= valid_in;
            last_d1  <= last_in;
            
            if (valid_in) begin
                mode_d1 <= active_mode;
            end

            // Stage 2 Output
            valid_out <= valid_d1;
            last_out  <= last_d1;
        end
    end

endmodule






/*

module activation_unit #(
    parameter int N          = 4,
    parameter int DATA_WIDTH = 32,
    parameter int TABLE_AW   = 10,
    parameter string GELU_FILE = "gelu_table.mem",
    parameter string SIGM_FILE = "sigmoid_table.mem"
)(
    input  logic clk,
    input  logic rst,
    input  logic [1:0] cfg_act_mode, 
    input  logic cfg_load, 

    input  logic [N*DATA_WIDTH-1:0] data_in_packed,
    input  logic                    valid_in,
    input  logic                    last_in,      
    output logic [N*DATA_WIDTH-1:0] data_out_packed,
    output logic                    valid_out,
    output logic                    last_out    
);

    logic [1:0] active_mode;
    always_ff @(posedge clk) begin
        if (rst) active_mode <= 0;
        else if (cfg_load) active_mode <= cfg_act_mode;
    end

    // Tables
    logic signed [DATA_WIDTH-1:0] gelu_mem [0:(1<<TABLE_AW)-1];
    logic signed [DATA_WIDTH-1:0] sigm_mem [0:(1<<TABLE_AW)-1];

    initial begin
        $readmemh(GELU_FILE, gelu_mem);
        $readmemh(SIGM_FILE, sigm_mem);
    end

    logic signed [DATA_WIDTH-1:0] lane_in [0:N-1];
    logic signed [DATA_WIDTH-1:0] lane_out [0:N-1];
    logic valid_d1;

    

    genvar i;
    generate
        for (i = 0; i < N; i++) begin : lanes
            assign lane_in[i] = data_in_packed[i*DATA_WIDTH +: DATA_WIDTH];
            
            logic [TABLE_AW-1:0] addr;
            assign addr = lane_in[i] + (1 << (TABLE_AW-1)); // Offset for signed to unsigned index

            always_ff @(posedge clk) begin
                case (active_mode)
                    2'b01:   lane_out[i] <= gelu_mem[addr];
                    2'b10:   lane_out[i] <= sigm_mem[addr];
                    default: lane_out[i] <= lane_in[i];
                endcase
            end
            assign data_out_packed[i*DATA_WIDTH +: DATA_WIDTH] = lane_out[i];
        end
    endgenerate

// --- Last Signal Pipeline (2 cycles delay) ---
    logic last_d1;
    always_ff @(posedge clk) begin
        if (rst) begin
            last_d1  <= 1'b0;
            last_out <= 1'b0;
        end else begin
            last_d1  <= last_in;
            last_out <= last_d1;
        end
    end

    // --- Valid Signal Pipeline (Ξ―Ξ΄ΞΉΞΏ delay) ---
    logic valid_d1;
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_d1  <= 1'b0;
            valid_out <= 1'b0;
        end else begin
            valid_d1  <= valid_in;
            valid_out <= valid_d1;
        end
    end
endmodule






*/
