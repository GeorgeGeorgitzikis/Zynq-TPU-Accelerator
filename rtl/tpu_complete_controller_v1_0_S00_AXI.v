`timescale 1 ns / 1 ps

	module tpu_complete_controller_v1_0_S00_AXI #
	(
		// Users to add parameters here

		// User parameters ends
		// Do not modify the parameters beyond this line

		// Width of S_AXI data bus
		parameter integer C_S_AXI_DATA_WIDTH	= 32,
		// Width of S_AXI address bus
		parameter integer C_S_AXI_ADDR_WIDTH	= 6
	)
	(
		// Users to add ports here
        // --- 1. AXI STREAM PORTS ---
        input  wire [63:0] s_axis_wgt_tdata,
        input  wire        s_axis_wgt_tvalid,
        input  wire        s_axis_wgt_tlast,
        output wire        s_axis_wgt_tready,

        input  wire [63:0] s_axis_data_tdata,
        input  wire        s_axis_data_tvalid,
        input  wire        s_axis_data_tlast,
        output wire        s_axis_data_tready,

        input  wire [31:0] s_axis_bias_tdata,
        input  wire        s_axis_bias_tvalid,
        input  wire        s_axis_bias_tlast,
        output wire        s_axis_bias_tready,

        output wire [63:0] m_axis_tdata,
        output wire        m_axis_tvalid,
        output wire        m_axis_tlast,
        input  wire        m_axis_tready,
		// User ports ends
		// Do not modify the ports beyond this line

		// Global Clock Signal
		input wire  S_AXI_ACLK,
		// Global Reset Signal. This Signal is Active LOW
		input wire  S_AXI_ARESETN,
		// Write address (issued by master, acceped by Slave)
		input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
		// Write channel Protection type. This signal indicates the
    		// privilege and security level of the transaction, and whether
    		// the transaction is a data access or an instruction access.
		input wire [2 : 0] S_AXI_AWPROT,
		// Write address valid. This signal indicates that the master signaling
    		// valid write address and control information.
		input wire  S_AXI_AWVALID,
		// Write address ready. This signal indicates that the slave is ready
    		// to accept an address and associated control signals.
		output wire  S_AXI_AWREADY,
		// Write data (issued by master, acceped by Slave) 
		input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
		// Write strobes. This signal indicates which byte lanes hold
    		// valid data. There is one write strobe bit for each eight
    		// bits of the write data bus.    
		input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
		// Write valid. This signal indicates that valid write
    		// data and strobes are available.
		input wire  S_AXI_WVALID,
		// Write ready. This signal indicates that the slave
    		// can accept the write data.
		output wire  S_AXI_WREADY,
		// Write response. This signal indicates the status
    		// of the write transaction.
		output wire [1 : 0] S_AXI_BRESP,
		// Write response valid. This signal indicates that the channel
    		// is signaling a valid write response.
		output wire  S_AXI_BVALID,
		// Response ready. This signal indicates that the master
    		// can accept a write response.
		input wire  S_AXI_BREADY,
		// Read address (issued by master, acceped by Slave)
		input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
		// Protection type. This signal indicates the privilege
    		// and security level of the transaction, and whether the
    		// transaction is a data access or an instruction access.
		input wire [2 : 0] S_AXI_ARPROT,
		// Read address valid. This signal indicates that the channel
    		// is signaling valid read address and control information.
		input wire  S_AXI_ARVALID,
		// Read address ready. This signal indicates that the slave is
    		// ready to accept an address and associated control signals.
		output wire  S_AXI_ARREADY,
		// Read data (issued by slave)
		output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
		// Read response. This signal indicates the status of the
    		// read transfer.
		output wire [1 : 0] S_AXI_RRESP,
		// Read valid. This signal indicates that the channel is
    		// signaling the required read data.
		output wire  S_AXI_RVALID,
		// Read ready. This signal indicates that the master can
    		// accept the read data and response information.
		input wire  S_AXI_RREADY
	);

	// AXI4LITE signals
	reg [C_S_AXI_ADDR_WIDTH-1 : 0] 	axi_awaddr;
	reg  	axi_awready;
	reg  	axi_wready;
	reg [1 : 0] 	axi_bresp;
	reg  	axi_bvalid;
	reg [C_S_AXI_ADDR_WIDTH-1 : 0] 	axi_araddr;
	reg  	axi_arready;
	reg [C_S_AXI_DATA_WIDTH-1 : 0] 	axi_rdata;
	reg [1 : 0] 	axi_rresp;
	reg  	axi_rvalid;

// Example-specific design signals
	localparam integer ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;
	localparam integer OPT_MEM_ADDR_BITS = 3; 
	//-- Number of Slave Registers 16
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg [0:15]; 
    
	wire	 slv_reg_rden;
	wire	 slv_reg_wren;
	reg [C_S_AXI_DATA_WIDTH-1:0]	 reg_data_out;
	integer	 byte_index;
    integer  i; // <--- ÐñïóèÞêç ãéá áðïöõãÞ warning óôï loop
	reg	 aw_en;

    // --- ÌÅÔÁÖÏÑÁ ÄÇËÙÓÅÙÍ ÓÇÌÁÔÙÍ ÅÄÙ (ÐÑÉÍ ÔÇ ×ÑÇÓÇ) ---
    wire w_weight_done, w_data_done, w_bias_done, w_compute_done, w_unload_done, w_store_done;
    reg  done_wgt, done_data, done_bias, done_compute, done_unload, store_done_sig;
    reg  trig_wgt, trig_data, trig_bias, trig_compute, trig_unload;

	// I/O Connections assignments
	assign S_AXI_AWREADY	= axi_awready;
	assign S_AXI_WREADY	= axi_wready;
	assign S_AXI_BRESP	= axi_bresp;
	assign S_AXI_BVALID	= axi_bvalid;
	assign S_AXI_ARREADY	= axi_arready;
	assign S_AXI_RDATA	= axi_rdata;
	assign S_AXI_RRESP	= axi_rresp;
	assign S_AXI_RVALID	= axi_rvalid;

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_awready <= 1'b0;
	      aw_en <= 1'b1;
	    end 
	  else
	    begin   
	      if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en)
	        begin
	          axi_awready <= 1'b1;
	          aw_en <= 1'b0;
	        end
	        else if (S_AXI_BREADY && axi_bvalid)
	            begin
	              aw_en <= 1'b1;
	              axi_awready <= 1'b0;
	            end
	      else           
	        begin
	          axi_awready <= 1'b0;
	        end
	    end 
	end       

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_awaddr <= 0;
	    end 
	  else
	    begin   
	      if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en)
	        begin
	          axi_awaddr <= S_AXI_AWADDR;
	        end
	    end 
	end       

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_wready <= 1'b0;
	    end 
	  else
	    begin   
	      if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en )
	        begin
	          axi_wready <= 1'b1;
	        end
	      else
	        begin
	          axi_wready <= 1'b0;
	        end
	    end 
	end       

	assign slv_reg_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
            for (i = 0; i < 16; i = i + 1) slv_reg[i] <= 0;
	    end 
	  else begin
	    if (slv_reg_wren)
	      begin
            if (axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] != 0) begin
                for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
                  if ( S_AXI_WSTRB[byte_index] == 1 ) begin
                    slv_reg[axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB]][(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                  end  
            end
            else if (axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 0 && S_AXI_WSTRB[0]) begin
                 slv_reg[0][5] <= S_AXI_WDATA[5];
            end
	      end
          
          if (w_weight_done && slv_reg[0][0]) slv_reg[0][0] <= 1'b0;
          if (w_data_done && slv_reg[0][1])   slv_reg[0][1] <= 1'b0;
          if (w_bias_done && slv_reg[0][2])   slv_reg[0][2] <= 1'b0;
          if (w_compute_done && slv_reg[0][3]) slv_reg[0][3] <= 1'b0;
          if (w_unload_done && slv_reg[0][4]) slv_reg[0][4] <= 1'b0;
	  end
	end

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_bvalid  <= 0;
	      axi_bresp   <= 2'b0;
	    end 
	  else
	    begin   
	      if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID)
	        begin
	          axi_bvalid <= 1'b1;
	          axi_bresp  <= 2'b0; 
	        end
	      else
	        begin
	          if (S_AXI_BREADY && axi_bvalid) 
	            begin
	              axi_bvalid <= 1'b0; 
	            end  
	        end
	    end
	end   

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_arready <= 1'b0;
	      axi_araddr  <= 32'b0;
	    end 
	  else
	    begin   
	      if (~axi_arready && S_AXI_ARVALID)
	        begin
	          axi_arready <= 1'b1;
	          axi_araddr  <= S_AXI_ARADDR;
	        end
	      else
	        begin
	          axi_arready <= 1'b0;
	        end
	    end 
	end       

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_rvalid <= 0;
	      axi_rresp  <= 0;
	    end 
	  else
	    begin   
	      if (axi_arready && S_AXI_ARVALID && ~axi_rvalid)
	        begin
	          axi_rvalid <= 1'b1;
	          axi_rresp  <= 2'b0; 
	        end   
	      else if (axi_rvalid && S_AXI_RREADY)
	        begin
	          axi_rvalid <= 1'b0;
	        end                
	    end
	end  

	assign slv_reg_rden = axi_arready & S_AXI_ARVALID & ~axi_rvalid;
    always @(*)
	   begin
        reg_data_out = slv_reg[axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB]]; 
        
        if (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 0) begin
            reg_data_out = {26'b0, 
                            store_done_sig, 
                            done_unload,    
                            done_compute,   
                            done_bias,      
                            done_data,      
                            done_wgt        
                           };
         end
	   end

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_rdata  <= 0;
	    end 
	  else
	    begin   
	      if (slv_reg_rden)
	        begin
	          axi_rdata <= reg_data_out; 
	        end   
	    end
	end  

	// Add user logic here

	// --- STATUS BITS ONLY (Clear on Read) ---
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin 
            done_wgt <= 0; 
            done_data <= 0; 
            done_bias <= 0; 
            done_compute <= 0; 
            done_unload <= 0; 
        end
        else begin
            if (w_weight_done) done_wgt <= 1;
            else if (slv_reg_rden && (axi_araddr[5:2]==0)) done_wgt <= 0;
            
            if (w_data_done) done_data <= 1;
            else if (slv_reg_rden && (axi_araddr[5:2]==0)) done_data <= 0;
            
            if (w_bias_done) done_bias <= 1;
            else if (slv_reg_rden && (axi_araddr[5:2]==0)) done_bias <= 0;
            
            if (w_compute_done) done_compute <= 1;
            else if (slv_reg_rden && (axi_araddr[5:2]==0)) done_compute <= 0;
            
            if (w_unload_done) done_unload <= 1;
            else if (slv_reg_rden && (axi_araddr[5:2]==0)) done_unload <= 0;
        end
    end
    
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) store_done_sig <= 0;
        else begin
            if (w_store_done) store_done_sig <= 1;
            else if (slv_reg_rden && (axi_araddr[5:2]==0)) store_done_sig <= 0;
        end
    end

    // INSTANTIATE TPU TOP
// INSTANTIATE TPU TOP
    tpu_top #(
        //.N(8), .DATA_WIDTH(8), .ACC_WIDTH(32), .ADDR_WIDTH(12), .MATRIX_SIZE(9), .FIFO_DEPTH(16) // <-- ÁËËÁÃÇ ÐÁÑÁÌÅÔÑÙÍ
        .AXI_N(8), .ARRAY_N(16), .DATA_WIDTH(8), .ACC_WIDTH(32), .ADDR_WIDTH(12), .MATRIX_SIZE(9), .FIFO_DEPTH(16)
    ) u_tpu_top (
        .clk(S_AXI_ACLK),
        .rst(~S_AXI_ARESETN), 

        .s_axis_wgt_tdata(s_axis_wgt_tdata), .s_axis_wgt_tvalid(s_axis_wgt_tvalid), .s_axis_wgt_tlast(s_axis_wgt_tlast), .s_axis_wgt_tready(s_axis_wgt_tready),
        .s_axis_data_tdata(s_axis_data_tdata), .s_axis_data_tvalid(s_axis_data_tvalid), .s_axis_data_tlast(s_axis_data_tlast), .s_axis_data_tready(s_axis_data_tready),
        .s_axis_bias_tdata(s_axis_bias_tdata), .s_axis_bias_tvalid(s_axis_bias_tvalid), .s_axis_bias_tlast(s_axis_bias_tlast), .s_axis_bias_tready(s_axis_bias_tready),
        .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid), .m_axis_tlast(m_axis_tlast), .m_axis_tready(m_axis_tready),

        // Triggers (1-Cycle Pulses)
        .cfg_wr_wgt_valid   (slv_reg_wren && (axi_awaddr[5:2]==0) && S_AXI_WDATA[0]),
        .cfg_wr_data_valid  (slv_reg_wren && (axi_awaddr[5:2]==0) && S_AXI_WDATA[1]),
        .cfg_wr_bias_valid  (slv_reg_wren && (axi_awaddr[5:2]==0) && S_AXI_WDATA[2]),
        .compute_chain_valid(slv_reg_wren && (axi_awaddr[5:2]==0) && S_AXI_WDATA[3]),
        .cfg_unload_valid   (slv_reg_wren && (axi_awaddr[5:2]==0) && S_AXI_WDATA[4]),
        .swap_io_buffer     (slv_reg[0][5]), 

        .weight_axis_done(w_weight_done),
        .data_axis_done(w_data_done),
        .bias_axis_done(w_bias_done),
        .irq_compute_done(w_compute_done),
        .unloader_axis_done(w_unload_done),
        .matrix_loader_done(w_store_done),
        .compute_chain_ready(), 

        // --- ÍÅÏ REGISTER MAPPING (ÐñïóáñìïóìÝíï ãéá 12-bit ADDR_WIDTH) ---
        // ADDR ðáßñíåé ôá bits [11:0], ROWS ôá [20:12], COLS ôá [29:21]
        .cfg_wr_wgt_addr(slv_reg[1][11:0]), .cfg_wr_wgt_rows(slv_reg[1][20:12]), .cfg_wr_wgt_cols(slv_reg[1][29:21]),
        .cfg_wr_data_addr(slv_reg[2][11:0]), .cfg_wr_data_rows(slv_reg[2][20:12]), .cfg_wr_data_cols(slv_reg[2][29:21]),
        .cfg_wr_bias_addr(slv_reg[3][11:0]), .cfg_wr_bias_rows(slv_reg[3][20:12]),
        .cfg_unload_addr(slv_reg[4][11:0]), .cfg_unload_rows(slv_reg[4][20:12]), .cfg_unload_cols(slv_reg[4][29:21]),
        
        // Ãéá äéðëÝò äéåõèýíóåéò: ADDR1 [11:0], ADDR2 [27:16]
        .weight_addr(slv_reg[5][11:0]), .data_addr(slv_reg[5][27:16]),
        .bias_addr(slv_reg[6][11:0]), .store_addr(slv_reg[6][27:16]),
        
        // Dims: 9 bits
        .data_rows(slv_reg[7][8:0]), .data_cols(slv_reg[7][24:16]), 
        .weight_rows(slv_reg[8][8:0]), .weight_cols(slv_reg[8][24:16]),
        
        // Quantization & Control
        .quant_scale(slv_reg[9][15:0]), .quant_shift(slv_reg[9][21:16]),
        .quant_zp(slv_reg[10][8:0]), .act_mode(slv_reg[10][10:9]), .relu_en(slv_reg[10][11]), 
        .cfg_accumulate_mode(slv_reg[10][12]), .bias_en(slv_reg[10][13]), .cfg_keep_in_bram(slv_reg[10][14]),

        .cfg_wr_wgt_ready(), .cfg_wr_data_ready(), .cfg_wr_bias_ready(), .cfg_unload_ready()
    );

	endmodule


