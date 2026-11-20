`timescale 1ns/1ps

// One-entry acknowledged mailbox for a 128-voice command. The AXI-domain
// source holds every field stable until acknowledge_toggle catches up.
module voice_command_cdc_m3 (
    input  wire        audio_clk,
    input  wire        audio_resetn,
    input  wire        source_toggle,
    input  wire [6:0]  source_voice,
    input  wire        source_gate,
    input  wire        source_retrigger,
    input  wire [1:0]  source_table,
    input  wire [31:0] source_ftw,
    input  wire [15:0] source_gain,
    output reg         command_valid,
    output reg  [6:0]  command_voice,
    output reg         command_gate,
    output reg         command_retrigger,
    output reg  [1:0]  command_table,
    output reg  [31:0] command_ftw,
    output reg  [15:0] command_gain,
    output reg         acknowledge_toggle
);
    (* ASYNC_REG = "TRUE" *) reg toggle_meta, toggle_sync;
    (* ASYNC_REG = "TRUE" *) reg [6:0] voice_meta;
    (* ASYNC_REG = "TRUE" *) reg gate_meta, retrigger_meta;
    (* ASYNC_REG = "TRUE" *) reg [1:0] table_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] ftw_meta;
    (* ASYNC_REG = "TRUE" *) reg [15:0] gain_meta;

    always @(posedge audio_clk) begin
        if (!audio_resetn) begin
            toggle_meta <= 0; toggle_sync <= 0; acknowledge_toggle <= 0;
            voice_meta <= 0; gate_meta <= 0; retrigger_meta <= 0;
            table_meta <= 0; ftw_meta <= 0; gain_meta <= 0;
            command_valid <= 0; command_voice <= 0; command_gate <= 0;
            command_retrigger <= 0; command_table <= 0;
            command_ftw <= 0; command_gain <= 0;
        end else begin
            toggle_meta <= source_toggle;
            toggle_sync <= toggle_meta;
            voice_meta <= source_voice;
            gate_meta <= source_gate;
            retrigger_meta <= source_retrigger;
            table_meta <= source_table;
            ftw_meta <= source_ftw;
            gain_meta <= source_gain;
            command_valid <= 1'b0;
            if (toggle_sync != acknowledge_toggle) begin
                command_voice <= voice_meta;
                command_gate <= gate_meta;
                command_retrigger <= retrigger_meta;
                command_table <= table_meta;
                command_ftw <= ftw_meta;
                command_gain <= gain_meta;
                command_valid <= 1'b1;
                acknowledge_toggle <= toggle_sync;
            end
        end
    end
endmodule
