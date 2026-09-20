`timescale 1ns / 1ps

module tpu_top #(
    parameter int AXI_N       = 8,   // AXI Bus width (e.g., 8 lanes for 64-bit)
    parameter int ARRAY_N     = 16,  // Systolic Array size (e.g., 16x16)
    parameter int DATA_WIDTH  = 8,   
    parameter int ACC_WIDTH   = 32,  
    parameter int ADDR_WIDTH  = 12,  // 4096 words BRAM
    parameter int MATRIX_SIZE = 9,   
    parameter int FIFO_DEPTH  = 16   
)(
    input  logic clk,
    input  logic rst,

    // =========================================================================
    // AXI STREAM INTERFACES (Always AXI_N size)
    // =========================================================================
    
    // axis_to_bram_writer (Weights) - Input
    input  logic [AXI_N*DATA_WIDTH-1:0] s_axis_wgt_tdata,
    input  logic                        s_axis_wgt_tvalid,
    input  logic                        s_axis_wgt_tlast,
    output logic                        s_axis_wgt_tready,

    // axis_to_bram_writer (Data) - Input
    input  logic [AXI_N*DATA_WIDTH-1:0] s_axis_data_tdata,
    input  logic                        s_axis_data_tvalid,
    input  logic                        s_axis_data_tlast,
    output logic                        s_axis_data_tready,

    // axis_to_bram_writer (Bias) - Input (Bias is 32-bit, AXI_N=1)
    input  logic [ACC_WIDTH-1:0]        s_axis_bias_tdata,
    input  logic                        s_axis_bias_tvalid,
    input  logic                        s_axis_bias_tlast,
    output logic                        s_axis_bias_tready,

    // bram_to_axis_reader (Unloader) - Output
    output logic [AXI_N*DATA_WIDTH-1:0] m_axis_tdata,
    output logic                        m_axis_tvalid,
    output logic                        m_axis_tlast,
    input  logic                        m_axis_tready,

    // =========================================================================
    // CONFIGURATION INTERFACES
    // =========================================================================
    
    // ping_pong_memory
    input  logic                        swap_io_buffer,

    output logic                        irq_compute_done,
    output logic                        matrix_loader_done,
    output logic                        weight_axis_done,
    output logic                        data_axis_done,
    output logic                        bias_axis_done,
    output logic                        unloader_axis_done,

    // MATRIX B 
    // axis_to_bram_writer (Weights)
    input  logic [ADDR_WIDTH-1:0]   cfg_wr_wgt_addr,
    input  logic [MATRIX_SIZE-1:0]  cfg_wr_wgt_rows,
    input  logic [MATRIX_SIZE-1:0]  cfg_wr_wgt_cols,
    input  logic                    cfg_wr_wgt_valid, 
    output logic                    cfg_wr_wgt_ready,

    // axis_to_bram_writer (Data)
    input  logic [ADDR_WIDTH-1:0]   cfg_wr_data_addr,
    input  logic [MATRIX_SIZE-1:0]  cfg_wr_data_rows,
    input  logic [MATRIX_SIZE-1:0]  cfg_wr_data_cols,
    input  logic                    cfg_wr_data_valid,
    output logic                    cfg_wr_data_ready,

    // MATRIX B 
    // axis_to_bram_writer (Bias)
    input  logic [ADDR_WIDTH-1:0]   cfg_wr_bias_addr,
    input  logic [MATRIX_SIZE-1:0]  cfg_wr_bias_rows, // data cols
    input  logic                    cfg_wr_bias_valid,
    output logic                    cfg_wr_bias_ready,

    // OUTPUT UNLOADER
    // bram_to_axis_reader (Unloader)
    input  logic [ADDR_WIDTH-1:0]   cfg_unload_addr,
    input  logic [MATRIX_SIZE-1:0]  cfg_unload_rows,
    input  logic [MATRIX_SIZE-1:0]  cfg_unload_cols, 
    input  logic                    cfg_unload_valid,
    output logic                    cfg_unload_ready,


    // =========================================================================
    // COMPUTE CHAIN CONFIG
    // =========================================================================
    output logic compute_chain_ready,
    input  logic compute_chain_valid,

    input  logic [ADDR_WIDTH-1:0] weight_addr,
    input  logic [ADDR_WIDTH-1:0] data_addr,
    input  logic [ADDR_WIDTH-1:0] bias_addr,
    input  logic [ADDR_WIDTH-1:0] store_addr,

    input  logic [MATRIX_SIZE-1:0] weight_rows,
    input  logic [MATRIX_SIZE-1:0] weight_cols,
    input  logic [MATRIX_SIZE-1:0] data_rows,
    input  logic [MATRIX_SIZE-1:0] data_cols,

    input  logic                    cfg_accumulate_mode, // 1: Add, 0: Overwrite
    input  logic                    cfg_keep_in_bram,    // 1: No Readout
    
    input  logic                    bias_en,
    input  logic [1:0]              act_mode,
    input  logic signed [15:0]      quant_scale,
    input  logic [5:0]              quant_shift,
    input  logic signed [DATA_WIDTH:0] quant_zp,
    input  logic                    relu_en
);

    // =========================================================================
    // INTERNAL SIGNALS
    // =========================================================================
    
    logic post_process_valid;
    assign post_process_valid = compute_chain_valid && (!cfg_keep_in_bram);

    logic [MATRIX_SIZE-1:0] result_rows;
    logic [MATRIX_SIZE-1:0] result_cols;
    assign result_rows = data_rows;
    assign result_cols = weight_cols;

    logic cfg_rd_wgt_ready, cfg_rd_data_ready, cfg_acc_ready,
          cfg_bias_ready, cfg_act_ready, cfg_quant_ready,
          cfg_store_ready;

    assign compute_chain_ready = cfg_rd_wgt_ready && 
                                 cfg_rd_data_ready && 
                                 cfg_acc_ready && 
                                 cfg_bias_ready && 
                                 cfg_act_ready && 
                                 cfg_quant_ready &&                       
                                 cfg_store_ready;

    // control signals
    logic swap_shadow;
    logic weight_axis_busy;
    logic data_loader_start;
    logic data_axis_busy;
    logic accumulator_wrapper_busy;
    logic bias_axis_busy;
    logic unloader_axis_busy;

    // =========================================================================
    // WIDE BUSES (Sized for ARRAY_N)
    // =========================================================================
    logic                          we_w;
    logic [ADDR_WIDTH-1:0]         addr_wr_w, addr_rd_w;
    logic [ARRAY_N*DATA_WIDTH-1:0] data_wr_w, data_rd_w;
    logic                          re_w; 

    logic                          dma_we, dma_re;
    logic [ADDR_WIDTH-1:0]         dma_addr_wr, dma_addr_rd;
    logic [ARRAY_N*DATA_WIDTH-1:0] dma_wdata, dma_rdata;
    
    logic                          tpu_we, tpu_re;
    logic [ADDR_WIDTH-1:0]         tpu_addr_wr, tpu_addr_rd;
    logic [ARRAY_N*DATA_WIDTH-1:0] tpu_wdata, tpu_rdata;

    logic                          we_bias, re_bias;
    logic [ADDR_WIDTH-1:0]         addr_wr_bias, addr_rd_bias;
    logic [31:0]                   data_wr_bias, data_rd_bias;

    logic [ARRAY_N*DATA_WIDTH-1:0] w_flat, d_flat;
    logic                          w_valid, d_valid;

    logic signed [DATA_WIDTH-1:0]  skew_w [0:ARRAY_N-1];
    logic signed [DATA_WIDTH-1:0]  skew_d [0:ARRAY_N-1];
    logic                          skew_valid_d;
    logic [ARRAY_N-1:0]            skew_valid_w; 
    logic [ARRAY_N-1:0]            skew_last_w;

    logic                          swap_vec_left  [0:ARRAY_N-1];
    logic                          swap_vec_top   [0:ARRAY_N-1];
    logic signed [ACC_WIDTH-1:0]   z_sum          [0:ARRAY_N-1];
    logic signed [ACC_WIDTH-1:0]   raw_sum        [0:ARRAY_N-1];
    logic                          array_valid_out;

    logic signed [ACC_WIDTH-1:0]   flat_sum       [0:ARRAY_N-1];
    logic [ARRAY_N*ACC_WIDTH-1:0]  packed_sums;
    logic                          deskew_valid, deskew_last;

    logic                          acc_valid_out;
    logic [ARRAY_N*ACC_WIDTH-1:0]  acc_data_out; 

    logic                          bias_valid, bias_last;
    logic [ARRAY_N*ACC_WIDTH-1:0]  bias_data;

    logic                          act_valid, act_last;
    logic [ARRAY_N*ACC_WIDTH-1:0]  act_data;

    logic                          quant_valid, quant_last;
    logic [ARRAY_N*DATA_WIDTH-1:0] quant_data;

    logic store_done;
    logic col_last;
    logic row_last_in, row_last_out;
    logic weights_loaded;
    logic load_next_weights_enable;
    logic weight_loader_done;

    // =========================================================================
    // INSTANTIATIONS
    // =========================================================================

    // axis_to_bram_writer (Weights) -> Maps AXI_N to ARRAY_N
    axis_to_bram_writer #(
        .AXI_N(AXI_N), .BRAM_N(ARRAY_N), .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_axis_wr_w (
        .clk(clk), .rst(rst),
        .start(1'b1),
        .cfg_start_addr(cfg_wr_wgt_addr), 
        .cfg_rows(cfg_wr_wgt_rows), 
        .cfg_cols(cfg_wr_wgt_cols), 
        .cfg_valid(cfg_wr_wgt_valid), 
        .cfg_ready(cfg_wr_wgt_ready),
        .done(weight_axis_done), .busy(weight_axis_busy),
        .s_axis_tdata(s_axis_wgt_tdata), .s_axis_tvalid(s_axis_wgt_tvalid), 
        .s_axis_tlast(s_axis_wgt_tlast), .s_axis_tready(s_axis_wgt_tready),
        .bram_we(we_w), .bram_addr(addr_wr_w), .bram_wdata(data_wr_w)
    );

    // bram (Weights) -> Sized for ARRAY_N
    bram #(.N(ARRAY_N), .ELEM_WIDTH(DATA_WIDTH), .DEPTH(1<<ADDR_WIDTH)) u_bram_w (
        .clk(clk), .we_a(we_w), .addr_a(addr_wr_w), .din_a(data_wr_w),
        .re_b(re_w), .addr_b(addr_rd_w), .dout_b(data_rd_w)
    );

    // weight_loader
    weight_loader #(
        .N(ARRAY_N), .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)
    ) u_loader_w (
        .clk(clk), .rst(rst),
        .start(1'b1), 
        .cfg_start_addr(weight_addr), 
        .cfg_num_tile_rows(weight_rows), 
        .cfg_num_tile_cols(weight_cols),
        .cfg_valid(compute_chain_valid), 
        .cfg_ready(cfg_rd_wgt_ready),
        .load_next_en(load_next_weights_enable), 
        .weights_done(weight_loader_done), 
        .matrix_loader_done(matrix_loader_done),
        .bram_en(re_w), .bram_addr(addr_rd_w), .bram_dout(data_rd_w),
        .weight_data(w_flat), .weight_valid(w_valid), .weight_last(col_last),
        .matrix_loader_start(data_loader_start)
    );

    // axis_to_bram_writer (Data) -> Maps AXI_N to ARRAY_N
    axis_to_bram_writer #(
        .AXI_N(AXI_N), .BRAM_N(ARRAY_N), .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_axis_wr_d (
        .clk(clk), .rst(rst),
        .start(1'b1), 
        .cfg_start_addr(cfg_wr_data_addr), 
        .cfg_rows(cfg_wr_data_rows), 
        .cfg_cols(cfg_wr_data_cols), 
        .cfg_valid(cfg_wr_data_valid), 
        .cfg_ready(cfg_wr_data_ready),
        .done(data_axis_done), .busy(data_axis_busy),
        .s_axis_tdata(s_axis_data_tdata), .s_axis_tvalid(s_axis_data_tvalid),
        .s_axis_tlast(s_axis_data_tlast), .s_axis_tready(s_axis_data_tready),
        .bram_we(dma_we), .bram_addr(dma_addr_wr), .bram_wdata(dma_wdata)
    );

    // ping_pong_memory -> Sized for ARRAY_N
    ping_pong_memory #(.N(ARRAY_N), .ELEM_WIDTH(DATA_WIDTH), .DEPTH(1<<ADDR_WIDTH)) u_pp_mem (
        .clk(clk), .rst(rst), .swap_buffers(swap_io_buffer),
        .dma_we(dma_we), .dma_wr_addr(dma_addr_wr), .dma_wdata(dma_wdata),
        .dma_re(dma_re), .dma_rd_addr(dma_addr_rd), .dma_rdata(dma_rdata),
        .tpu_we(tpu_we), .tpu_wr_addr(tpu_addr_wr), .tpu_wdata(tpu_wdata),
        .tpu_re(tpu_re), .tpu_rd_addr(tpu_addr_rd), .tpu_rdata(tpu_rdata) 
    );

    // matrix_loader
    matrix_loader #(
        .N(ARRAY_N), .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)
    ) u_loader_d (
        .clk(clk), .rst(rst), .start(data_loader_start), 
        .cfg_start_addr(data_addr), 
        .cfg_num_tile_rows(data_rows), 
        .cfg_num_tile_cols(data_cols), 
        //.cfg_weight_rows(weight_rows),
        .cfg_weight_rows(weight_cols),
        .cfg_valid(compute_chain_valid), 
        .cfg_ready(cfg_rd_data_ready),
        .loader_done(matrix_loader_done),
        .bram_en(tpu_re), .bram_addr(tpu_addr_rd), .bram_dout(tpu_rdata),
        .m_axis_data(d_flat), .m_axis_valid(d_valid), .m_axis_last(row_last_in), .swap_enable(swap_shadow),
        .load_next_weights_enable(load_next_weights_enable)
    );

    // input_skewer_col (Weights)
    input_skewer_col #(.N(ARRAY_N), .DATA_WIDTH(DATA_WIDTH)) u_skewer_w (
        .clk(clk), .rst(rst),
        .input_valid(w_valid), .input_last(col_last),
        .data_in_packed(w_flat),
        .skewed_data_out(skew_w), 
        .output_valid(skew_valid_w), 
        .output_last(skew_last_w)
    );

    // input_skewer_row
    input_skewer_row #(.N(ARRAY_N), .DATA_WIDTH(DATA_WIDTH)) u_skewer_d (
        .clk(clk), .rst(rst),
        .input_valid(d_valid), .data_in_packed(d_flat),
        .stream_out(skew_d), .valid_out(skew_valid_d), .input_last(row_last_in),
        .output_last(row_last_out)
    );

    genvar i;
    generate
        for(i=0; i<ARRAY_N; i++) begin : wave_ctrl
            if (i == 0) begin
                assign swap_vec_top[i]  = swap_shadow; 
            end else begin
                assign swap_vec_top[i]  = 1'b0;
            end
            assign swap_vec_left[i] = 1'b0;
            assign z_sum[i]         = '0;
        end
    endgenerate

    // ws_systolic_array
    ws_systolic_array #(.N(ARRAY_N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) u_array (
        .clk(clk), .rst(rst),
        .valid_in(skew_valid_d), .valid_out(array_valid_out),
        .row_in(skew_d), .col_in(skew_w), .sum_in(z_sum),
        .load_in_cols(skew_last_w), .last_in_cols(skew_last_w),
        .swap_in_left(swap_vec_left), .swap_in_top(swap_vec_top),
        .swap_out_right(), 
        .swap_out_down(),  
        .sum_out(raw_sum), .weights_loaded(weights_loaded)
    );

    // ws_output_deskewer
    ws_output_deskewer #(.N(ARRAY_N), .ACC_WIDTH(ACC_WIDTH)) u_deskewer (
        .clk(clk), .rst(rst),
        .skewed_in(raw_sum), .flattened_out(flat_sum),
        .valid_in(array_valid_out), .valid_out(deskew_valid), .last_out(deskew_last)
    );

    generate
        for(i=0; i<ARRAY_N; i++) assign packed_sums[i*ACC_WIDTH +: ACC_WIDTH] = flat_sum[i];
    endgenerate

    // accumulator_wrapper
    accumulator_wrapper #(
        .N(ARRAY_N), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(11), .FIFO_DEPTH(FIFO_DEPTH)
    ) u_accum (
        .clk(clk), .rst(rst),
        .cmd_num_tile_rows(result_rows), 
        .cmd_num_tile_cols(result_cols),
        .cmd_num_tile_k(data_cols),
        .cmd_accumulate_mode(cfg_accumulate_mode), 
        .cmd_keep_in_bram(cfg_keep_in_bram),
        .cmd_valid(compute_chain_valid), 
        .cmd_ready(cfg_acc_ready),
        .new_sums_packed(packed_sums), .valid_in(deskew_valid), .last_in(deskew_last),
        .quant_valid(acc_valid_out), .quant_data(acc_data_out),
        .batch_done_tick(), .busy(accumulator_wrapper_busy) 
    );

    // axis_to_bram_writer (Bias) -> AXI_N=1, BRAM_N=1, DATA_WIDTH=32
    axis_to_bram_writer #(
        .AXI_N(1), .BRAM_N(1), .DATA_WIDTH(32), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_loader_bias (
        .clk(clk), .rst(rst),
        .start(1'b1), 
        .cfg_start_addr(cfg_wr_bias_addr), 
        .cfg_rows(cfg_wr_bias_rows), 
        .cfg_cols(1),
        .cfg_valid(cfg_wr_bias_valid), 
        .cfg_ready(cfg_wr_bias_ready), 
        .done(bias_axis_done), .busy(bias_axis_busy),
        .s_axis_tdata(s_axis_bias_tdata), .s_axis_tvalid(s_axis_bias_tvalid), 
        .s_axis_tlast(s_axis_bias_tlast), .s_axis_tready(s_axis_bias_tready),
        .bram_we(we_bias), .bram_addr(addr_wr_bias), .bram_wdata(data_wr_bias)
    );

    // bram (Bias) -> N=1, ELEM_WIDTH=32
    bram #(
        .N(1), .ELEM_WIDTH(32), .DEPTH(1 << ADDR_WIDTH)
    ) u_bram_bias (
        .clk(clk), .we_a(we_bias), .addr_a(addr_wr_bias), .din_a(data_wr_bias),
        .re_b(re_bias), .addr_b(addr_rd_bias), .dout_b(data_rd_bias)
    );

    // bias_adder
    bias_adder #(
        .N(ARRAY_N), .DATA_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)
    ) u_bias_add (
        .clk(clk), .rst(rst),
        .cfg_bias_base_addr(bias_addr), 
        .cfg_num_tile_rows(result_rows), 
        .cfg_num_tile_cols(1),
        .cfg_enable(bias_en),
        .cfg_valid(post_process_valid), 
        .cfg_ready(cfg_bias_ready),
        .data_in_packed(acc_data_out), .valid_in(acc_valid_out),
        .bram_en(re_bias), .bram_addr(addr_rd_bias), .bram_dout(data_rd_bias),
        .data_out_packed(bias_data), .valid_out(bias_valid), .last_out(bias_last)
    );

    // activation_unit
    activation_unit #(
        .N(ARRAY_N), .DATA_WIDTH(ACC_WIDTH), .TABLE_AW(10), .FIFO_DEPTH(FIFO_DEPTH)
    ) u_act (
        .clk(clk), .rst(rst),
        .cfg_act_mode(act_mode), 
        .cfg_valid(post_process_valid), 
        .cfg_ready(cfg_act_ready),
        .data_in_packed(bias_data), .valid_in(bias_valid), .last_in(bias_last),
        .data_out_packed(act_data), .valid_out(act_valid), .last_out(act_last)
    );

    // quantizer_unit
    quantizer_unit #(
        .N(ARRAY_N), .IN_WIDTH(ACC_WIDTH), .OUT_WIDTH(DATA_WIDTH), .SCALE_W(16), .FIFO_DEPTH(FIFO_DEPTH)
    ) u_quant (
        .clk(clk), .rst(rst),
        .cfg_scale_factor(quant_scale), .cfg_right_shift(quant_shift),
        .cfg_zero_point(quant_zp), .cfg_relu_en(relu_en),
        .cfg_valid(post_process_valid), 
        .cfg_ready(cfg_quant_ready),
        .data_in_packed(act_data), .valid_in(act_valid), .last_in(act_last),
        .data_out_packed(quant_data), .valid_out(quant_valid), .last_out(quant_last)
    );

    // output_store_unit
    output_store_unit #(
        .N(ARRAY_N), .OUT_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH), .CMD_FIFO_DEPTH(FIFO_DEPTH)
    ) u_store (
        .clk(clk), .rst(rst),
        .quant_valid(quant_valid), .quant_data(quant_data), 
        .cmd_base_addr(store_addr), 
        .cmd_rows(result_rows), 
        .cmd_cols(result_cols),
        .cmd_valid(post_process_valid), 
        .cmd_ready(cfg_store_ready),
        .write_done(store_done),
        .ub_we(tpu_we), .ub_addr(tpu_addr_wr), .ub_wdata(tpu_wdata)
    );

    // bram_to_axis_reader (Unloader) -> Maps BRAM_N to AXI_N
    bram_to_axis_reader #(
        .AXI_N(AXI_N), .BRAM_N(ARRAY_N), .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_unloader (
        .clk(clk), .rst(rst),
        .start(1'b1),
        .cfg_start_addr(cfg_unload_addr), 
        .cfg_rows(cfg_unload_rows), 
        .cfg_cols(cfg_unload_cols),
        .cfg_valid(cfg_unload_valid), 
        .cfg_ready(cfg_unload_ready),
        .done(unloader_axis_done), .busy(unloader_axis_busy), 
        .bram_en(dma_re), .bram_addr(dma_addr_rd), .bram_dout(dma_rdata),
        .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast(m_axis_tlast), .m_axis_tready(m_axis_tready)
    );

    assign irq_compute_done = store_done;

endmodule