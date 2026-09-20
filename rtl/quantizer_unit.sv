`timescale 1ns / 1ps

module quantizer_unit #(
    parameter int N         = 4,   
    parameter int IN_WIDTH  = 32,  
    parameter int OUT_WIDTH = 8,   
    parameter int SCALE_W   = 16,
    parameter int FIFO_DEPTH = 4 
)(
    input  logic clk,
    input  logic rst,

    // -------------------------------------------------------------
    // 1. Configuration Interface (FIFO Input)
    // -------------------------------------------------------------
    input  logic signed [SCALE_W-1:0]  cfg_scale_factor,
    input  logic        [5:0]          cfg_right_shift,
    input  logic signed [OUT_WIDTH:0]  cfg_zero_point,
    input  logic                       cfg_relu_en,
    
    input  logic                       cfg_valid,
    output logic                       cfg_ready,

    // -------------------------------------------------------------
    // 2. Data Path
    // -------------------------------------------------------------
    input  logic [N*IN_WIDTH-1:0]  data_in_packed,
    input  logic                   valid_in,
    input  logic                   last_in,

    output logic [N*OUT_WIDTH-1:0] data_out_packed,
    output logic                   valid_out,
    output logic                   last_out
);

    // -------------------------------------------------------------
    // INTERNAL FIFO LOGIC
    // -------------------------------------------------------------
    localparam int CFG_WIDTH = SCALE_W + 6 + (OUT_WIDTH + 1) + 1;

    logic [CFG_WIDTH-1:0] fifo_din, fifo_dout;
    logic fifo_empty, fifo_pop, fifo_full;
    
    assign cfg_ready = !fifo_full;

    simple_fifo #(.WIDTH(CFG_WIDTH), .DEPTH(FIFO_DEPTH)) u_cfg_fifo (
        .clk(clk), .rst(rst), 
        .push(cfg_valid), .data_in(fifo_din),
        .pop(fifo_pop), .data_out(fifo_dout), 
        .full(fifo_full), .empty(fifo_empty)
    );

    assign fifo_din = {cfg_scale_factor, cfg_right_shift, cfg_zero_point, cfg_relu_en};

    // -------------------------------------------------------------
    // FSM (2-State Optimized - Zero Bubble)
    // -------------------------------------------------------------
    logic signed [SCALE_W-1:0]  active_scale;
    logic        [5:0]          active_shift;
    logic signed [OUT_WIDTH:0]  active_zp;
    logic                       active_relu;

    typedef enum logic {IDLE, BUSY} state_t;
    state_t state;

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= IDLE;
            fifo_pop     <= 0;
            active_scale <= 0;
            active_shift <= 0;
            active_zp    <= 0;
            active_relu  <= 0;
        end else begin
            fifo_pop <= 0;
            case (state)
                IDLE: begin
                    if (!fifo_empty) begin
                        {active_scale, active_shift, active_zp, active_relu} <= fifo_dout;
                        fifo_pop <= 1;
                        state    <= BUSY;
                    end
                end
                BUSY: begin
                    if (last_in) begin
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    // -------------------------------------------------------------
    // 4-STAGE PIPELINE DATA PATH (Timing Optimized)
    // -------------------------------------------------------------
    localparam int MULT_W = IN_WIDTH + SCALE_W;
    localparam int ACC_W  = MULT_W + 2;

    // Stage 1: Input Registration (To solve Timing WNS)
    logic signed [IN_WIDTH-1:0]  val_s1       [0:N-1];
    logic signed [SCALE_W-1:0]   scale_s1;    

    // Stage 2 & 3 & 4: Math Registers
    logic signed [MULT_W-1:0]    mult_reg     [0:N-1];
    logic signed [ACC_W-1:0]     shift_reg    [0:N-1];
    logic signed [OUT_WIDTH-1:0] final_reg    [0:N-1];

    // Configuration Pipeline
    logic [5:0]                p1_shift, p2_shift;
    logic signed [OUT_WIDTH:0] p1_zp,    p2_zp;
    logic                      p1_relu,  p2_relu, p3_relu;

    // Valid / Last Pipeline
    logic valid_s1, valid_s2, valid_s3;
    logic last_s1,  last_s2,  last_s3;

    // Unpack Input
    logic signed [IN_WIDTH-1:0]  val_in [0:N-1];
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : lane_logic
             assign val_in[i] = data_in_packed[i*IN_WIDTH +: IN_WIDTH];
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_s1 <= 0; valid_s2 <= 0; valid_s3 <= 0; valid_out <= 0;
            last_s1  <= 0; last_s2  <= 0; last_s3  <= 0; last_out  <= 0;
            p1_shift <= 0; p2_shift <= 0;
            p1_zp    <= 0; p2_zp    <= 0;
            p1_relu  <= 0; p2_relu  <= 0; p3_relu <= 0;
            scale_s1 <= 0;
        end else begin
            
            // ==============================================================
            // STAGE 1: Fast Input Registration (Fixes Timing)
            // ==============================================================
            valid_s1 <= valid_in;
            last_s1  <= last_in;
            
            if (valid_in) begin
                scale_s1 <= active_scale;
                p1_shift <= active_shift;
                p1_zp    <= active_zp;
                p1_relu  <= active_relu;
                for (int k=0; k<N; k++) begin
                    val_s1[k] <= val_in[k];
                end
            end

            // ==============================================================
            // STAGE 2: Multiplication (In DSP Block)
            // ==============================================================
            valid_s2 <= valid_s1;
            last_s2  <= last_s1;
            
            if (valid_s1) begin
                p2_shift <= p1_shift;
                p2_zp    <= p1_zp;
                p2_relu  <= p1_relu;
                for (int k=0; k<N; k++) begin
                    mult_reg[k] <= val_s1[k] * scale_s1;
                end
            end

            // ==============================================================
            // STAGE 3: Shift, Round, Add ZP
            // ==============================================================
            valid_s3 <= valid_s2;
            last_s3  <= last_s2;

            if (valid_s2) begin
                p3_relu <= p2_relu;
                for (int k=0; k<N; k++) begin
                    logic signed [ACC_W-1:0] rounded;
                    logic signed [ACC_W-1:0] shifted;
                    logic signed [ACC_W-1:0] round_add;

                    if (p2_shift > 0) begin
                        round_add = $signed({ {(ACC_W-1){1'b0}}, 1'b1 }) <<< (p2_shift - 1);
                        rounded   = mult_reg[k] + round_add;
                    end else begin
                        rounded   = mult_reg[k];
                    end
                    
                    shifted      = rounded >>> p2_shift;
                    shift_reg[k] <= shifted + $signed(p2_zp);
                end
            end

            // ==============================================================
            // STAGE 4: Saturation & ReLU (Output)
            // ==============================================================
            valid_out <= valid_s3;
            last_out  <= last_s3;

            if (valid_s3) begin
                for (int k=0; k<N; k++) begin
                    logic signed [ACC_W-1:0] val_check;
                    val_check = shift_reg[k];

                    if (p3_relu) begin 
                        if (val_check < 0)        final_reg[k] <= 0;
                        else if (val_check > 127) final_reg[k] <= 127;
                        else                      final_reg[k] <= val_check[OUT_WIDTH-1:0];
                    end else begin 
                        if (val_check > 127)       final_reg[k] <= 127;
                        else if (val_check < -128) final_reg[k] <= -128;
                        else                       final_reg[k] <= val_check[OUT_WIDTH-1:0];
                    end
                end
            end
        end
    end

    // Pack Output
    generate
        for (i = 0; i < N; i++) begin : gen_pack
             assign data_out_packed[i*OUT_WIDTH +: OUT_WIDTH] = final_reg[i];
        end
    endgenerate

endmodule











/*

`timescale 1ns / 1ps

module quantizer_unit #(
    parameter int N         = 4,   
    parameter int IN_WIDTH  = 32,  
    parameter int OUT_WIDTH = 8,   
    parameter int SCALE_W   = 16,
    parameter int FIFO_DEPTH = 4 
)(
    input  logic clk,
    input  logic rst,

    // ?????????????????????????????????????????????????????????????
    // 1. Configuration Interface (FIFO Input)
    // ?????????????????????????????????????????????????????????????
    input  logic signed [SCALE_W-1:0]   cfg_scale_factor,
    input  logic        [5:0]           cfg_right_shift,
    input  logic signed [OUT_WIDTH:0]   cfg_zero_point,
    input  logic                        cfg_relu_en,
    
    input  logic                        cfg_valid,
    output logic                        cfg_ready,

    // ?????????????????????????????????????????????????????????????
    // 2. Data Path
    // ?????????????????????????????????????????????????????????????
    input  logic [N*IN_WIDTH-1:0]  data_in_packed,
    input  logic                   valid_in,
    input  logic                   last_in,

    output logic [N*OUT_WIDTH-1:0] data_out_packed,
    output logic                   valid_out,
    output logic                   last_out
);

    // ?????????????????????????????????????????????????????????????
    // INTERNAL FIFO LOGIC
    // ?????????????????????????????????????????????????????????????
    // Calculate FIFO width: Scale + Shift + ZP + ReLU
    localparam int CFG_WIDTH = SCALE_W + 6 + (OUT_WIDTH + 1) + 1;

    logic [CFG_WIDTH-1:0] fifo_din, fifo_dout;
    logic fifo_empty, fifo_pop, fifo_full;
    
    assign cfg_ready = !fifo_full;

    simple_fifo #(.WIDTH(CFG_WIDTH), .DEPTH(FIFO_DEPTH)) u_cfg_fifo (
        .clk(clk), .rst(rst), 
        .push(cfg_valid), .data_in(fifo_din),
        .pop(fifo_pop), .data_out(fifo_dout), 
        .full(fifo_full), .empty(fifo_empty)
    );

    // Pack configuration into a single word for the FIFO
    assign fifo_din = {cfg_scale_factor, cfg_right_shift, cfg_zero_point, cfg_relu_en};

    // ?????????????????????????????????????????????????????????????
    // FSM (2-State Optimized - Zero Bubble)
    // ?????????????????????????????????????????????????????????????
    // Active Config Registers (hold values for the current Tile)
    logic signed [SCALE_W-1:0]   active_scale;
    logic        [5:0]           active_shift;
    logic signed [OUT_WIDTH:0]   active_zp;
    logic                        active_relu;

    typedef enum logic {IDLE, BUSY} state_t;
    state_t state;

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= IDLE;
            fifo_pop     <= 0;
            active_scale <= 0;
            active_shift <= 0;
            active_zp    <= 0;
            active_relu  <= 0;
        end else begin
            fifo_pop <= 0;

            case (state)
                IDLE: begin
                    // If there is a new config, load it and start IMMEDIATELY
                    if (!fifo_empty) begin
                        {active_scale, active_shift, active_zp, active_relu} <= fifo_dout;
                        fifo_pop <= 1;
                        state    <= BUSY;
                    end
                end

                BUSY: begin
                    // If the last pixel arrived, return IMMEDIATELY to catch the next config
                    if (last_in) begin
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    // ?????????????????????????????????????????????????????????????
    // PIPELINE DATA PATH (Tapered Config)
    // ?????????????????????????????????????????????????????????????
    localparam int MULT_W = IN_WIDTH + SCALE_W;
    localparam int ACC_W  = MULT_W + 2;

    // Pipeline Registers for Data
    logic signed [IN_WIDTH-1:0]  val_in    [0:N-1];
    logic signed [MULT_W-1:0]    mult_reg  [0:N-1];
    logic signed [ACC_W-1:0]     shift_reg [0:N-1];
    logic signed [OUT_WIDTH-1:0] final_reg [0:N-1];

    // Pipeline Registers for CONFIG (Config follows Data)
    // Stage 1 -> Stage 2 (Carry Shift, ZP, ReLU)
    logic [5:0]                p1_shift;
    logic signed [OUT_WIDTH:0] p1_zp;
    logic                      p1_relu;

    // Stage 2 -> Stage 3 (Carry ReLU only)
    logic                      p2_relu;

    // Valid / Last Pipeline
    logic valid_s1, valid_s2;
    logic last_s1, last_s2;

    // Unpack Input
    genvar i;
    generate
        for (i = 0; i < N; i++) begin : lane_logic
             assign val_in[i] = data_in_packed[i*IN_WIDTH +: IN_WIDTH];
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_s1 <= 0; valid_s2 <= 0; valid_out <= 0;
            last_s1  <= 0; last_s2  <= 0; last_out  <= 0;
            p1_shift <= 0; p1_zp    <= 0; p1_relu   <= 0;
            p2_relu  <= 0;
        end else begin
            // ????????????????????????????????????????????????????????
            // STAGE 1: Multiplication & Config Capture
            // ????????????????????????????????????????????????????????
            valid_s1 <= valid_in;
            last_s1  <= last_in;
            
            if (valid_in) begin
                // Critical: "Snapshot" the currently active config 
                // and pass it to the next pipeline stage.
                p1_shift <= active_shift;
                p1_zp    <= active_zp;
                p1_relu  <= active_relu;

                // Execute with the current active_scale
                for (int k=0; k<N; k++) begin
                    mult_reg[k] <= val_in[k] * active_scale;
                end
            end

            // ????????????????????????????????????????????????????????
            // STAGE 2: Shift, Round, Add ZP
            // ????????????????????????????????????????????????????????
            valid_s2 <= valid_s1;
            last_s2  <= last_s1;

            if (valid_s1) begin
                // Pass ReLU flag to Stage 3
                p2_relu <= p1_relu;

                // Execute using p1_ variables (Config from Stage 1)
                for (int k=0; k<N; k++) begin
                    logic signed [ACC_W-1:0] rounded;
                    logic signed [ACC_W-1:0] shifted;
                    logic signed [ACC_W-1:0] round_add; // Explicit width for rounding addition

                    if (p1_shift > 0) begin
                        // Safely create an ACC_W-bit signed '1' before shifting
                        // to prevent bit-width mismatch during addition
                        round_add = $signed({ {(ACC_W-1){1'b0}}, 1'b1 }) <<< (p1_shift - 1);
                        rounded   = mult_reg[k] + round_add;
                    end else begin
                        rounded   = mult_reg[k];
                    end
                    
                    shifted      = rounded >>> p1_shift;
                    shift_reg[k] <= shifted + $signed(p1_zp);
                end
            end

            // ????????????????????????????????????????????????????????
            // STAGE 3: Saturation & ReLU (Output)
            // ????????????????????????????????????????????????????????
            valid_out <= valid_s2;
            last_out  <= last_s2;

            if (valid_s2) begin
                // Execute using p2_ variables (Config from Stage 2)
                for (int k=0; k<N; k++) begin
                    logic signed [ACC_W-1:0] val_check;
                    val_check = shift_reg[k];

                    if (p2_relu) begin 
                        // ReLU Mode (Clamp 0 to 127)
                        if (val_check < 0)        final_reg[k] <= 0;
                        else if (val_check > 127) final_reg[k] <= 127;
                        else                      final_reg[k] <= val_check[OUT_WIDTH-1:0];
                    end else begin 
                        // Standard Mode (Clamp -128 to 127)
                        if (val_check > 127)       final_reg[k] <= 127;
                        else if (val_check < -128) final_reg[k] <= -128;
                        else                       final_reg[k] <= val_check[OUT_WIDTH-1:0];
                    end
                end
            end
        end
    end

    // Pack Output
    generate
        for (i = 0; i < N; i++) begin : gen_pack
             assign data_out_packed[i*OUT_WIDTH +: OUT_WIDTH] = final_reg[i];
        end
    endgenerate

endmodule








*/






