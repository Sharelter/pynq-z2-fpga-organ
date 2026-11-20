`timescale 1ns/1ps

// Four 1024-sample, signed 24-bit additive organ tables in block RAM.
module organ_wavetable_rom #(
    parameter integer SAMPLE_WIDTH = 24,
    parameter integer TABLE_ADDR_WIDTH = 10,
    parameter integer TABLE_COUNT = 4,
    parameter ROM_FILE = "organ_wavetables_4x1024x24.mem"
) (
    input  wire clk,
    input  wire [1:0] table_select,
    input  wire [TABLE_ADDR_WIDTH-1:0] table_address,
    output reg signed [SAMPLE_WIDTH-1:0] sample
);
    localparam integer TOTAL_DEPTH = TABLE_COUNT * (1 << TABLE_ADDR_WIDTH);
    (* rom_style = "block" *)
    reg signed [SAMPLE_WIDTH-1:0] memory [0:TOTAL_DEPTH-1];

    wire [TABLE_ADDR_WIDTH+1:0] combined_address =
        {table_select, table_address};

    initial $readmemh(ROM_FILE, memory);

    always @(posedge clk)
        sample <= memory[combined_address];
endmodule
