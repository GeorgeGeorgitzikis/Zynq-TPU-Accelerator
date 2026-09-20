`timescale 1ns / 1ps

module tb_tpu_system();

    // =========================================================================
    // 1. PARAMETERS (64-bit AXI / 16x16 Array)
    // =========================================================================
    parameter int AXI_N       = 8;   // 8 lanes * 8 bits = 64-bit AXI Bus
    parameter int ARRAY_N     = 16;  // 16x16 Systolic Array
    parameter int DATA_WIDTH  = 8;
    parameter int ACC_WIDTH   = 32;
    parameter int ADDR_WIDTH  = 12;  
    parameter int MATRIX_SIZE = 9;
    parameter int FIFO_DEPTH  = 16;

    // =========================================================================
    // 2. SIGNALS
    // =========================================================================
    logic clk;
    logic rst;

    logic [AXI_N*DATA_WIDTH-1:0] s_axis_wgt_tdata;
    logic s_axis_wgt_tvalid, s_axis_wgt_tlast, s_axis_wgt_tready;

    logic [AXI_N*DATA_WIDTH-1:0] s_axis_data_tdata;
    logic s_axis_data_tvalid, s_axis_data_tlast, s_axis_data_tready;

    logic [ACC_WIDTH-1:0] s_axis_bias_tdata; 
    logic s_axis_bias_tvalid, s_axis_bias_tlast, s_axis_bias_tready;

    logic [AXI_N*DATA_WIDTH-1:0] m_axis_tdata;
    logic m_axis_tvalid, m_axis_tlast, m_axis_tready;

    logic swap_io_buffer;
    logic irq_compute_done;
    logic matrix_loader_done; 
    logic weight_axis_done, data_axis_done, bias_axis_done; 
    logic unloader_axis_done;

    // Config Signals
    logic [ADDR_WIDTH-1:0]   cfg_wr_wgt_addr, cfg_wr_data_addr, cfg_wr_bias_addr, cfg_unload_addr;
    logic [MATRIX_SIZE-1:0]  cfg_wr_wgt_rows, cfg_wr_wgt_cols;
    logic [MATRIX_SIZE-1:0]  cfg_wr_data_rows, cfg_wr_data_cols;
    logic [MATRIX_SIZE-1:0]  cfg_wr_bias_rows;
    logic [MATRIX_SIZE-1:0]  cfg_unload_rows, cfg_unload_cols;
    
    logic cfg_wr_wgt_valid, cfg_wr_data_valid, cfg_wr_bias_valid, cfg_unload_valid;
    logic cfg_wr_wgt_ready, cfg_wr_data_ready, cfg_wr_bias_ready, cfg_unload_ready;

    logic [ADDR_WIDTH-1:0]   weight_addr, data_addr, bias_addr, store_addr;
    logic [MATRIX_SIZE-1:0]  weight_rows, weight_cols, data_rows, data_cols;
    logic cfg_accumulate_mode, cfg_keep_in_bram, bias_en, relu_en;
    logic [1:0] act_mode;
    logic signed [15:0] quant_scale;
    logic [5:0] quant_shift;
    logic signed [DATA_WIDTH:0] quant_zp;

    reg compute_chain_valid; 

    // =========================================================================
    // 3. INSTANTIATE DUT
    // =========================================================================
    tpu_top #(
        .AXI_N(AXI_N), .ARRAY_N(ARRAY_N), .DATA_WIDTH(DATA_WIDTH), 
        .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .MATRIX_SIZE(MATRIX_SIZE), .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .clk(clk), .rst(rst),
        .s_axis_wgt_tdata(s_axis_wgt_tdata), .s_axis_wgt_tvalid(s_axis_wgt_tvalid), 
        .s_axis_wgt_tlast(s_axis_wgt_tlast), .s_axis_wgt_tready(s_axis_wgt_tready),
        .s_axis_data_tdata(s_axis_data_tdata), .s_axis_data_tvalid(s_axis_data_tvalid), 
        .s_axis_data_tlast(s_axis_data_tlast), .s_axis_data_tready(s_axis_data_tready),
        .s_axis_bias_tdata(s_axis_bias_tdata), .s_axis_bias_tvalid(s_axis_bias_tvalid), 
        .s_axis_bias_tlast(s_axis_bias_tlast), .s_axis_bias_tready(s_axis_bias_tready),
        .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid), 
        .m_axis_tlast(m_axis_tlast), .m_axis_tready(m_axis_tready),
        
        .cfg_wr_wgt_addr(cfg_wr_wgt_addr), .cfg_wr_wgt_rows(cfg_wr_wgt_rows), .cfg_wr_wgt_cols(cfg_wr_wgt_cols), 
        .cfg_wr_wgt_valid(cfg_wr_wgt_valid), .cfg_wr_wgt_ready(cfg_wr_wgt_ready),
        .cfg_wr_data_addr(cfg_wr_data_addr), .cfg_wr_data_rows(cfg_wr_data_rows), .cfg_wr_data_cols(cfg_wr_data_cols), 
        .cfg_wr_data_valid(cfg_wr_data_valid), .cfg_wr_data_ready(cfg_wr_data_ready),
        .cfg_wr_bias_addr(cfg_wr_bias_addr), .cfg_wr_bias_rows(cfg_wr_bias_rows), 
        .cfg_wr_bias_valid(cfg_wr_bias_valid), .cfg_wr_bias_ready(cfg_wr_bias_ready),
        .cfg_unload_addr(cfg_unload_addr), .cfg_unload_rows(cfg_unload_rows), .cfg_unload_cols(cfg_unload_cols), 
        .cfg_unload_valid(cfg_unload_valid), .cfg_unload_ready(cfg_unload_ready),
        
        .swap_io_buffer(swap_io_buffer),
        .irq_compute_done(irq_compute_done), .matrix_loader_done(matrix_loader_done),
        .weight_axis_done(weight_axis_done), .data_axis_done(data_axis_done), .bias_axis_done(bias_axis_done),
        .unloader_axis_done(unloader_axis_done),
        .compute_chain_valid(compute_chain_valid),
        
        .weight_addr(weight_addr), .data_addr(data_addr), .bias_addr(bias_addr), .store_addr(store_addr),
        .weight_rows(weight_rows), .weight_cols(weight_cols), .data_rows(data_rows), .data_cols(data_cols),
        .cfg_accumulate_mode(cfg_accumulate_mode), .cfg_keep_in_bram(cfg_keep_in_bram),
        .bias_en(bias_en), .act_mode(act_mode), .quant_scale(quant_scale), 
        .quant_shift(quant_shift), .quant_zp(quant_zp), .relu_en(relu_en)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        $display("------------------------------------------------");
        $display("STARTING 16x16 ARRAY RANDOM DATA SIMULATION");
        $display("------------------------------------------------");
        
        rst = 1; swap_io_buffer = 0;
        s_axis_wgt_tvalid = 0; s_axis_data_tvalid = 0; s_axis_bias_tvalid = 0;
        cfg_wr_wgt_valid = 0; cfg_wr_data_valid = 0; cfg_wr_bias_valid = 0;
        cfg_unload_valid = 0; compute_chain_valid = 0; m_axis_tready = 0;

        #100 rst = 0; #20;

        // --- PHASE 1: LOAD WEIGHTS (1 Tile 16x16) ---
        cfg_wr_wgt_addr = 0; cfg_wr_wgt_rows = 1; cfg_wr_wgt_cols = 1; 
        @(posedge clk); cfg_wr_wgt_valid <= 1;
        wait(cfg_wr_wgt_ready); @(posedge clk); cfg_wr_wgt_valid <= 0; 
        
        for (int i = 0; i < 32; i++) begin
            s_axis_wgt_tvalid <= 1;
            // 64-BIT RANDOM DATA (Δύο 32-bit $urandom μαζί)
            s_axis_wgt_tdata  <= {$urandom, $urandom}; 
            s_axis_wgt_tlast  <= (i == 31) ? 1 : 0;
            @(posedge clk);
            while (!s_axis_wgt_tready) @(posedge clk);
        end
        s_axis_wgt_tvalid <= 0;
        wait(weight_axis_done);
        $display("[PHASE 1] Weights Loaded (Random)");

        // --- PHASE 2: LOAD DATA (1 Tile 16x16) ---
        cfg_wr_data_addr = 0; cfg_wr_data_rows = 1; cfg_wr_data_cols = 1; 
        @(posedge clk); cfg_wr_data_valid <= 1;
        wait(cfg_wr_data_ready); @(posedge clk); cfg_wr_data_valid <= 0;
        
        for (int r = 0; r < 32; r++) begin
            s_axis_data_tvalid <= 1;
            // 64-BIT RANDOM DATA (Δύο 32-bit $urandom μαζί)
            s_axis_data_tdata  <= {$urandom, $urandom}; 
            s_axis_data_tlast  <= (r == 31) ? 1 : 0;
            @(posedge clk);
            while (!s_axis_data_tready) @(posedge clk);
        end
        s_axis_data_tvalid <= 0;
        wait(data_axis_done);
        $display("[PHASE 2] Data Loaded (Random)");

        // --- PHASE 3: LOAD BIAS (16 Words for 16x16 Array) ---
        cfg_wr_bias_addr = 0; cfg_wr_bias_rows = 16; 
        @(posedge clk); cfg_wr_bias_valid <= 1;
        wait(cfg_wr_bias_ready); @(posedge clk); cfg_wr_bias_valid <= 0;
        
        for (int i = 0; i < 16; i++) begin
            s_axis_bias_tvalid <= 1;
            // Αφήνουμε το Bias μηδέν για να δούμε καθαρά τα αποτελέσματα των πολλαπλασιασμών
            s_axis_bias_tdata  <= 32'h00000000; 
            s_axis_bias_tlast  <= (i == 15) ? 1 : 0;
            @(posedge clk);
            while (!s_axis_bias_tready) @(posedge clk);
        end
        s_axis_bias_tvalid <= 0;
        wait(bias_axis_done);
        $display("[PHASE 3] Bias Loaded");

        // --- PHASE 4: SWAP ---
        #20; swap_io_buffer = 1; #20; swap_io_buffer = 0; #10;
        $display("[PHASE 4] Ping-Pong Swapped");

        // --- PHASE 5: COMPUTE (1 Tile) ---
        weight_addr = 0; data_addr = 0; bias_addr = 0; store_addr = 0;
        weight_rows = 1; weight_cols = 1; 
        data_rows = 1; data_cols = 1;     
        cfg_accumulate_mode = 0; cfg_keep_in_bram = 0; 
        bias_en = 0; relu_en = 0; act_mode = 0;
        
        // Κρατάμε το shift στο 12 για να μην κάνουν saturation τα τεράστια τυχαία γινόμενα
        quant_scale = 1; quant_shift = 12; quant_zp = 0;

        @(posedge clk); compute_chain_valid <= 1;
        @(posedge clk); compute_chain_valid <= 0;
        
        wait(irq_compute_done);
        $display("[PHASE 5] Compute Done! Array 16x16 calculated.");

        // --- PHASE 6: UNLOAD ---
        #20; swap_io_buffer = 1; #20; swap_io_buffer = 0; 
        
        cfg_unload_addr = 0; cfg_unload_rows = 1; cfg_unload_cols = 1; 
        @(posedge clk); cfg_unload_valid <= 1;
        wait(cfg_unload_ready); @(posedge clk); cfg_unload_valid <= 0;

        // Σηκώνουμε το ready για να αδειάσει το Unpacker
        m_axis_tready <= 1;
        
        wait(dut.unloader_axis_done);
        $display("[PHASE 6] Unload Finished!");
        
        $display("------------------------------------------------");
        $display("[SUCCESS] All systems go. Simulation complete.");
        $display("------------------------------------------------");
        
        #200;
        $finish;
    end

endmodule