module input_skewer_col #(
    parameter int N = 4,           // Matrix Size
    parameter int DATA_WIDTH = 8   // Element Bit Width
)(
    input  logic clk,
    input  logic rst,
    //input  logic enable,

    input  logic input_valid,
    input  logic input_last,
    
    // --- Outputs: Skewed output signals ---
    output logic [N-1:0] output_valid, 
    output logic [N-1:0] output_last,

    input  logic [N*DATA_WIDTH-1:0] data_in_packed,      
    output logic signed [DATA_WIDTH-1:0] skewed_data_out [0:N-1] 
);



// --- 1. Unpacking data_in_packed into a 2D array ---
    logic [DATA_WIDTH-1:0] data_in_unpacked [N];

    genvar m;
    generate
        for (m = 0; m < N; m++) begin : gen_unpack_input
            assign data_in_unpacked[m] = data_in_packed[(m+1)*DATA_WIDTH-1 : m*DATA_WIDTH];
        end
    endgenerate





    genvar i;
    generate
        for (i = 0; i < N; i++) begin : delay_columns
            
            // Register depth = i + 1
            // Col 0: 1 reg, Col 1: 2 regs, etc.
            
            // Define the "packet" width containing {Last, Valid, Data}
            // Width = 1 (Last) + 1 (Valid) + DATA_WIDTH (Data)
            localparam int PKT_WIDTH = DATA_WIDTH + 2;
            
            logic [PKT_WIDTH-1:0] shift_reg [0:i]; 
            integer k;

            always_ff @(posedge clk) begin
                if (rst) begin
                    for (k = 0; k <= i; k++) begin
                        shift_reg[k] <= '0; // Reset all (valid/last -> 0)
                    end
                end 
                else begin // if (enable)
                    // 1. Load the first stage (concatenate data and control)
                    // shift_reg[0] <= {
                    //     input_last, 
                    //     input_valid, 
                    //     data_in_packed[i*DATA_WIDTH +: DATA_WIDTH]
                    // };
                    // 1. Load the first stage (concatenate data and control)
                    // Zero padding when input_valid is 0
                    shift_reg[0] <= {
                        input_last, 
                        input_valid, 
                        input_valid ? data_in_packed[i*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}}
                    };
                    
                    // 2. Shift
                    for (k = 1; k <= i; k++) begin
                        shift_reg[k] <= shift_reg[k-1];
                    end
                end
            end
            
            // --- Unpacking Outputs ---
            // Assign the results from the respective stage [i]
            // which is the "tail" of the shift register.
            
            assign output_last[i]      = shift_reg[i][PKT_WIDTH-1];   // MSB
            assign output_valid[i]     = shift_reg[i][PKT_WIDTH-2];   // Middle
            assign skewed_data_out[i]  = shift_reg[i][DATA_WIDTH-1:0]; // LSBs

        end
    endgenerate

endmodule







/*
module input_skewer_col #(
    parameter int N = 4,           // Matrix Size
    parameter int DATA_WIDTH = 8   // Element Bit Width
)(
    input  logic clk,
    input  logic rst,
    //input  logic enable,

    input  logic input_valid,
    input  logic input_last,
    
    // --- ������: ??����� �������� ����??����� (Skewed) ---
    output logic [N-1:0] output_valid, 
    output logic [N-1:0] output_last,

    input  logic [N*DATA_WIDTH-1:0] data_in_packed,      
    output logic signed [DATA_WIDTH-1:0] skewed_data_out [0:N-1] 
);



// --- 1. Unpacking ��� data_in_packed �� ��������� ������ ---
    logic [DATA_WIDTH-1:0] data_in_unpacked [N];

    genvar m;
    generate
        for (m = 0; m < N; m++) begin : gen_unpack_input
            assign data_in_unpacked[m] = data_in_packed[(m+1)*DATA_WIDTH-1 : m*DATA_WIDTH];
        end
    endgenerate





    genvar i;
    generate
        for (i = 0; i < N; i++) begin : delay_columns
            
            // Register depth = i + 1
            // Col 0: 1 reg, Col 1: 2 regs, etc.
            
            // ���������� ��� "������" ��� ��??����� {Last, Valid, Data}
            // ������ = 1 (Last) + 1 (Valid) + DATA_WIDTH (Data)
            localparam int PKT_WIDTH = DATA_WIDTH + 2;
            
            logic [PKT_WIDTH-1:0] shift_reg [0:i]; 
            integer k;

            always_ff @(posedge clk) begin
                if (rst) begin
                    for (k = 0; k <= i; k++) begin
                        shift_reg[k] <= '0; // Reset �� ����� (valid/last -> 0)
                    end
                end 
                else begin // if (enable)
                    // 1. ������� ��� �????�� ������ (���������� ��������� ��� control)
                    // shift_reg[0] <= {
                    //     input_last, 
                    //     input_valid, 
                    //     data_in_packed[i*DATA_WIDTH +: DATA_WIDTH]
                    // };
                    // 1. ������� ��� �????�� ������ (���������� ��������� ��� control)
                    // Zero padding ??��� �� input_valid ������ ��� 0
                    shift_reg[0] <= {
                        input_last, 
                        input_valid, 
                        input_valid ? data_in_packed[i*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}}
                    };
                    
                    // 2. ??������� (Shift)
                    for (k = 1; k <= i; k++) begin
                        shift_reg[k] <= shift_reg[k-1];
                    end
                end
            end
            
            // --- Unpacking Outputs ---
            // ���??����� �� ���������� ��?? �� ��������� ������ [i]
            // ��� �� "�����" ��� ������ ��??���.
            
            assign output_last[i]      = shift_reg[i][PKT_WIDTH-1];   // MSB
            assign output_valid[i]     = shift_reg[i][PKT_WIDTH-2];   // Middle
            assign skewed_data_out[i]  = shift_reg[i][DATA_WIDTH-1:0]; // LSBs

        end
    endgenerate

endmodule










*/


