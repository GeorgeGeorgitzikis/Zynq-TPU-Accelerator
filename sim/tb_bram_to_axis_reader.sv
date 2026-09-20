`timescale 1ns / 1ps

module tb_bram_to_axis_reader();
    localparam int AXI_N = 8;
    localparam int BRAM_N = 16;
    localparam int DATA_WIDTH = 8;
    localparam int ADDR_WIDTH = 12;
    localparam int MATRIX_SIZE = 9;
    
    logic clk, rst, start;
    logic [MATRIX_SIZE-1:0] cfg_cols, cfg_rows;
    logic [ADDR_WIDTH-1:0] cfg_start_addr;
    logic cfg_valid, cfg_ready;
    logic done, busy;
    
    logic bram_en;
    logic [ADDR_WIDTH-1:0] bram_addr;
    logic [BRAM_N*DATA_WIDTH-1:0] bram_dout;
    
    logic [AXI_N*DATA_WIDTH-1:0] m_axis_tdata;
    logic m_axis_tvalid, m_axis_tlast, m_axis_tready;
    
    bram_to_axis_reader #(
        .AXI_N(AXI_N), .BRAM_N(BRAM_N), .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH), .MATRIX_SIZE(MATRIX_SIZE)
    ) uut (.*);

    // Mock 128-bit BRAM (Έχει 1 κύκλο Latency, όπως η πραγματική!)
    logic [127:0] mock_bram [0:15];
    initial begin
        for(int i=0; i<16; i++) begin
            // Γεμίζουμε τη BRAM: 
            // Κάτω 64 bits = "i", Πάνω 64 bits = "i + 100"
            // Για i=0: Κάτω=0000.., Πάνω=6464.. (100 σε hex)
            mock_bram[i] = { {8{i[7:0] + 8'd100}}, {8{i[7:0]}} };
        end
    end

    always_ff @(posedge clk) begin
        if (bram_en) bram_dout <= mock_bram[bram_addr];
    end

    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        rst = 1; start = 0; cfg_valid = 0; m_axis_tready = 1;
        #25 rst = 0;
        
        // Push Command (1 Tile 16x16 = 16 BRAM words)
        cfg_cols = 1; cfg_rows = 1; cfg_start_addr = 0;
        @(posedge clk) cfg_valid = 1;
        @(posedge clk) cfg_valid = 0;
        
        // Start Unloading
        @(posedge clk) start = 1;
        @(posedge clk) start = 0;
        
        wait(done);
        #50;
        $finish;
    end
    
    // Monitor το AXI Output
    always_ff @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            $display("Time: %0t | AXI_DATA: %h | TLAST: %b", $time, m_axis_tdata, m_axis_tlast);
        end
    end
endmodule