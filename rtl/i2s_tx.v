`timescale 1ns/1ps

// Stereo I2S transmitter for the ADAU1761.
//
// With AUDIO_CLOCK_HZ = 49.152 MHz:
//   BCLK  = audio_clk / 16   = 3.072 MHz
//   LRCLK = audio_clk / 1024 = 48 kHz
//
// LRCLK low is left and high is right. Each channel has a 32-bit slot. The
// 24-bit sample starts one BCLK after the LRCLK transition, as required by I2S.
module i2s_tx #(
    parameter integer SAMPLE_WIDTH = 24
) (
    input  wire                           clk,
    input  wire                           resetn,
    input  wire signed [SAMPLE_WIDTH-1:0] left_sample,
    input  wire signed [SAMPLE_WIDTH-1:0] right_sample,
    output wire                           bclk,
    output wire                           lrclk,
    output reg                            sdata,
    output reg                            frame_tick
);
    reg [9:0] divider;
    reg previous_bclk;
    reg previous_lrclk;
    reg signed [SAMPLE_WIDTH-1:0] left_latched;
    reg signed [SAMPLE_WIDTH-1:0] right_latched;
    reg [5:0] bit_count;
    reg transmitting;

    assign bclk = divider[3];
    assign lrclk = divider[9];

    wire bclk_falling = previous_bclk && !divider[3];
    wire lrclk_edge = previous_lrclk ^ divider[9];
    wire left_boundary = previous_lrclk && !divider[9];

    always @(posedge clk) begin
        if (!resetn) begin
            divider <= 10'd0;
            previous_bclk <= 1'b0;
            previous_lrclk <= 1'b0;
            left_latched <= {SAMPLE_WIDTH{1'b0}};
            right_latched <= {SAMPLE_WIDTH{1'b0}};
            bit_count <= 6'd0;
            transmitting <= 1'b0;
            sdata <= 1'b0;
            frame_tick <= 1'b0;
        end else begin
            divider <= divider + 1'b1;
            previous_bclk <= divider[3];
            previous_lrclk <= divider[9];
            frame_tick <= 1'b0;

            // Leave SDATA low on the LRCLK transition. The next falling BCLK
            // edge launches the MSB, providing the mandatory one-bit delay.
            if (lrclk_edge) begin
                bit_count <= 6'd0;
                transmitting <= 1'b1;
                sdata <= 1'b0;
                if (left_boundary) begin
                    left_latched <= left_sample;
                    right_latched <= right_sample;
                    frame_tick <= 1'b1;
                end
            end else if (bclk_falling && transmitting) begin
                if (bit_count < SAMPLE_WIDTH) begin
                    sdata <= divider[9]
                           ? right_latched[SAMPLE_WIDTH-1-bit_count]
                           : left_latched[SAMPLE_WIDTH-1-bit_count];
                    bit_count <= bit_count + 1'b1;
                end else begin
                    sdata <= 1'b0;
                    transmitting <= 1'b0;
                end
            end
        end
    end
endmodule
