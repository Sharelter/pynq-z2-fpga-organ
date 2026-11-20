`timescale 1ns/1ps

// Eight time-multiplexed wavetable voices. One ROM port and one multiplier are
// shared because an audio frame contains over 1000 audio-clock cycles.
module wavetable_voice_engine #(
    parameter integer VOICES = 8,
    parameter integer PHASE_WIDTH = 32,
    parameter integer SAMPLE_WIDTH = 24
) (
    input  wire clk,
    input  wire resetn,
    input  wire frame_tick,
    input  wire master_enable,
    input  wire command_valid,
    input  wire [2:0] command_voice,
    input  wire command_gate,
    input  wire command_retrigger,
    input  wire [1:0] command_table,
    input  wire [31:0] command_ftw,
    input  wire [15:0] command_gain,
    output wire [7:0] active_mask,
    output reg signed [SAMPLE_WIDTH-1:0] mixed_sample
);
    localparam IDLE = 2'd0, ISSUE = 2'd1, WAIT_ROM = 2'd2, ACCUMULATE = 2'd3;

    reg [1:0] state;
    reg [2:0] voice_index;
    reg [PHASE_WIDTH-1:0] phase [0:VOICES-1];
    reg [31:0] ftw [0:VOICES-1];
    reg [15:0] gain [0:VOICES-1];
    reg [1:0] table_id [0:VOICES-1];
    reg [VOICES-1:0] gate;
    reg [15:0] gain_pipeline;
    reg signed [47:0] accumulator;
    reg [1:0] rom_table;
    reg [9:0] rom_address;
    wire signed [SAMPLE_WIDTH-1:0] rom_sample;
    wire signed [40:0] product =
        $signed(rom_sample) * $signed({1'b0, gain_pipeline});
    wire signed [47:0] extended_product = {{7{product[40]}}, product};
    wire signed [47:0] accumulator_next = accumulator + extended_product;
    wire signed [47:0] scaled_sum = accumulator_next >>> 15;
    integer index;

    assign active_mask = master_enable ? gate : 8'd0;

    organ_wavetable_rom table_rom (
        .clk(clk), .table_select(rom_table), .table_address(rom_address),
        .sample(rom_sample)
    );

    function signed [SAMPLE_WIDTH-1:0] saturate_24;
        input signed [47:0] value;
        begin
            if (value > 48'sd8388607)
                saturate_24 = 24'sh7fffff;
            else if (value < -48'sd8388608)
                saturate_24 = 24'sh800000;
            else
                saturate_24 = value[SAMPLE_WIDTH-1:0];
        end
    endfunction

    always @(posedge clk) begin
        if (!resetn) begin
            state <= IDLE; voice_index <= 0; gate <= 0;
            gain_pipeline <= 0; accumulator <= 0; mixed_sample <= 0;
            rom_table <= 0; rom_address <= 0;
            for (index = 0; index < VOICES; index = index + 1) begin
                phase[index] <= 0; ftw[index] <= 0; gain[index] <= 0;
                table_id[index] <= 0;
            end
        end else begin
            case (state)
                IDLE: if (frame_tick) begin
                    voice_index <= 0;
                    accumulator <= 0;
                    state <= ISSUE;
                end
                ISSUE: begin
                    rom_table <= table_id[voice_index];
                    rom_address <= phase[voice_index][PHASE_WIDTH-1 -: 10];
                    gain_pipeline <= (master_enable && gate[voice_index])
                                   ? gain[voice_index] : 16'd0;
                    if (master_enable && gate[voice_index])
                        phase[voice_index] <= phase[voice_index] + ftw[voice_index];
                    state <= WAIT_ROM;
                end
                WAIT_ROM: state <= ACCUMULATE;
                ACCUMULATE: begin
                    accumulator <= accumulator_next;
                    if (voice_index == VOICES-1) begin
                        mixed_sample <= saturate_24(scaled_sum);
                        state <= IDLE;
                    end else begin
                        voice_index <= voice_index + 1'b1;
                        state <= ISSUE;
                    end
                end
                default: state <= IDLE;
            endcase

            // A committed PS command wins over a same-cycle phase update.
            if (command_valid) begin
                gate[command_voice] <= command_gate;
                ftw[command_voice] <= command_ftw;
                gain[command_voice] <= command_gain;
                table_id[command_voice] <= command_table;
                if (command_retrigger)
                    phase[command_voice] <= 0;
            end
        end
    end
endmodule
