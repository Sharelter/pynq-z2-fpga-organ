`timescale 1ns/1ps

module reverb_config_cdc (
    input wire audio_clk, input wire audio_resetn,
    input wire source_toggle, input wire source_enable,
    input wire [15:0] source_feedback, input wire [15:0] source_wet,
    input wire source_clear_clip,
    output reg config_valid, output reg config_enable,
    output reg [15:0] config_feedback, output reg [15:0] config_wet,
    output reg config_clear_clip, output reg acknowledge_toggle
);
    (* ASYNC_REG = "TRUE" *) reg toggle_meta, toggle_sync;
    (* ASYNC_REG = "TRUE" *) reg enable_meta, clear_meta;
    (* ASYNC_REG = "TRUE" *) reg [15:0] feedback_meta, wet_meta;

    always @(posedge audio_clk) begin
        if (!audio_resetn) begin
            toggle_meta <= 0; toggle_sync <= 0; acknowledge_toggle <= 0;
            enable_meta <= 0; clear_meta <= 0; feedback_meta <= 0; wet_meta <= 0;
            config_valid <= 0; config_enable <= 0; config_feedback <= 0;
            config_wet <= 0; config_clear_clip <= 0;
        end else begin
            toggle_meta <= source_toggle; toggle_sync <= toggle_meta;
            enable_meta <= source_enable; clear_meta <= source_clear_clip;
            feedback_meta <= source_feedback; wet_meta <= source_wet;
            config_valid <= 0;
            if (toggle_sync != acknowledge_toggle) begin
                config_enable <= enable_meta;
                config_feedback <= feedback_meta;
                config_wet <= wet_meta;
                config_clear_clip <= clear_meta;
                config_valid <= 1;
                acknowledge_toggle <= toggle_sync;
            end
        end
    end
endmodule
