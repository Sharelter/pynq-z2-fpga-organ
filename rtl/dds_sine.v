`timescale 1ns/1ps

// Direct digital synthesizer with a phase accumulator and synchronous ROM.
// The ROM contains one complete signed sine period. It is inferred as block RAM.
module dds_sine #(
    parameter integer PHASE_WIDTH = 32,
    parameter integer OUTPUT_WIDTH = 24,
    parameter integer ROM_ADDR_WIDTH = 10,
    parameter ROM_FILE = "sine_1024x24.mem"
) (
    input  wire                         clk,
    input  wire                         resetn,
    input  wire                         sample_tick,
    input  wire                         enable,
    input  wire [PHASE_WIDTH-1:0]       phase_increment,
    output reg  signed [OUTPUT_WIDTH-1:0] sample,
    output reg  [PHASE_WIDTH-1:0]       phase_accumulator
);
    localparam integer ROM_DEPTH = 1 << ROM_ADDR_WIDTH;

    (* rom_style = "block" *)
    reg signed [OUTPUT_WIDTH-1:0] sine_rom [0:ROM_DEPTH-1];

    wire [ROM_ADDR_WIDTH-1:0] rom_address =
        phase_accumulator[PHASE_WIDTH-1 -: ROM_ADDR_WIDTH];

    initial begin
        $readmemh(ROM_FILE, sine_rom);
    end

    always @(posedge clk) begin
        if (!resetn) begin
            phase_accumulator <= {PHASE_WIDTH{1'b0}};
            sample <= {OUTPUT_WIDTH{1'b0}};
        end else if (sample_tick) begin
            if (enable) begin
                sample <= sine_rom[rom_address];
                phase_accumulator <= phase_accumulator + phase_increment;
            end else begin
                sample <= {OUTPUT_WIDTH{1'b0}};
                phase_accumulator <= {PHASE_WIDTH{1'b0}};
            end
        end
    end
endmodule
