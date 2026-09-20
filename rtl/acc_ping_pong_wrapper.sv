`timescale 1ns / 1ps

// =============================================================================
// Module: acc_ping_pong_wrapper
// Description:
//   Double-buffering (ping-pong) accumulator memory wrapper.
//   Decouples the systolic compute/accumulation pipeline (Hot Path) from the
//   quantizer readout streaming pipeline (Cold Path).
//
// Operation:
//   - Bank 0 & Bank 1 alternate roles upon receiving 'swap_banks'.
//   - While one bank is accumulating systolic partial sums, the other bank
//     streams completed results out to the quantization/activation stage.
// =============================================================================

module acc_ping_pong_wrapper #(
    parameter int N = 4,
    parameter int ACC_WIDTH = 32,
    parameter int ADDR_WIDTH = 10
)(
    input  logic clk,
    input  logic rst,

    // Bank swap control
    input  logic swap_banks,

    // ============================================================
    // HOT PATH: Accumulator (Direct Pipeline Interface)
    // ============================================================
    input  logic                   acc_we,
    input  logic [ADDR_WIDTH-1:0]  acc_wr_addr,
    input  logic [N*ACC_WIDTH-1:0] acc_wr_data,

    input  logic                   acc_re,
    input  logic [ADDR_WIDTH-1:0]  acc_rd_addr,
    output logic [N*ACC_WIDTH-1:0] acc_rd_data,

    // ============================================================
    // COLD PATH: Quantizer Readout (Streaming Output)
    // ============================================================
    input  logic                   start_readout,
    input  logic [ADDR_WIDTH-1:0]  num_words,

    output logic                   quant_valid,
    output logic [N*ACC_WIDTH-1:0] quant_data
);

    // Bank Selection Toggle (0 = Bank 0 hot, 1 = Bank 1 hot)
    logic bank_sel;
    logic [ADDR_WIDTH-1:0] current_limit;

    // Bank Multiplexing Signals
    logic we_0, we_1;
    logic re_0, re_1;
    logic [ADDR_WIDTH-1:0]  addr_wr_0, addr_wr_1;
    logic [ADDR_WIDTH-1:0]  addr_rd_0, addr_rd_1;
    logic [N*ACC_WIDTH-1:0] din_0, din_1;
    logic [N*ACC_WIDTH-1:0] dout_0, dout_1;

    // Readout Counter & Pointers
    logic [ADDR_WIDTH-1:0]  q_read_ptr;
    logic [ADDR_WIDTH-1:0]  q_count;
    logic                   q_read_en;
    logic [N*ACC_WIDTH-1:0] raw_mem_data;

    // Ping-Pong Bank Toggle Logic
    always_ff @(posedge clk) begin
        if (rst) bank_sel <= 1'b0;
        else if (swap_banks) bank_sel <= ~bank_sel;
    end

    // ------------------------------------------------------------
    // 1. Bank Crossbar Multiplexer
    // ------------------------------------------------------------
    always_comb begin
        we_0 = 1'b0; we_1 = 1'b0; re_0 = 1'b0; re_1 = 1'b0;
        addr_wr_0 = '0; addr_wr_1 = '0;
        addr_rd_0 = '0; addr_rd_1 = '0;
        din_0 = '0; din_1 = '0;

        raw_mem_data = (bank_sel == 1'b0) ? dout_1 : dout_0;

        if (bank_sel == 1'b0) begin
            // Hot: Bank 0 | Cold: Bank 1
            we_0        = acc_we;
            addr_wr_0   = acc_wr_addr;
            din_0       = acc_wr_data;
            re_0        = acc_re;
            addr_rd_0   = acc_rd_addr;
            acc_rd_data = dout_0;

            re_1        = q_read_en;
            addr_rd_1   = q_read_ptr;
        end else begin
            // Hot: Bank 1 | Cold: Bank 0
            we_1        = acc_we;
            addr_wr_1   = acc_wr_addr;
            din_1       = acc_wr_data;
            re_1        = acc_re;
            addr_rd_1   = acc_rd_addr;
            acc_rd_data = dout_1;

            re_0        = q_read_en;
            addr_rd_0   = q_read_ptr;
        end
    end

    // ------------------------------------------------------------
    // 2. Readout FSM (Streaming Controller)
    // ------------------------------------------------------------
    typedef enum logic {IDLE, READ} state_t;
    state_t state;

    always_ff @(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            q_read_ptr <= '0;
            q_count    <= '0;
            q_read_en  <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    q_read_ptr <= '0;
                    q_count    <= '0;
                    q_read_en  <= 1'b0;
                    if (start_readout) begin
                        current_limit <= num_words;
                        state         <= READ;
                    end
                end

                READ: begin
                    if (q_count < current_limit) begin
                        q_read_en  <= 1'b1;
                        q_read_ptr <= q_count;
                        q_count    <= q_count + 1'b1;
                    end else begin
                        q_read_en  <= 1'b0;
                        state      <= IDLE;
                    end
                end
            endcase
        end
    end

    // ------------------------------------------------------------
    // 3. Output Pipeline Delay Alignment
    // ------------------------------------------------------------
    logic q_read_en_delay;

    always_ff @(posedge clk) begin
        if (rst) begin
            q_read_en_delay <= 1'b0;
            quant_valid     <= 1'b0;
            quant_data      <= '0;
        end else begin
            // 2-cycle pipeline delay matching BRAM read latency + output register
            q_read_en_delay <= q_read_en;
            quant_valid     <= q_read_en_delay;
            quant_data      <= raw_mem_data;
        end
    end

    // ------------------------------------------------------------
    // 4. Memory Bank Instantiation
    // ------------------------------------------------------------
    acc_bram #(.N(N), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) bank0 (
        .clk(clk),
        .we_a(we_0), .addr_a(addr_wr_0), .din_a(din_0),
        .re_b(re_0), .addr_b(addr_rd_0), .dout_b(dout_0)
    );

    acc_bram #(.N(N), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) bank1 (
        .clk(clk),
        .we_a(we_1), .addr_a(addr_wr_1), .din_a(din_1),
        .re_b(re_1), .addr_b(addr_rd_1), .dout_b(dout_1)
    );

endmodule