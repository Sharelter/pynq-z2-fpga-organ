`timescale 1ns/1ps

// Bundled-data clock-domain crossing. AXI-side data stays stable after the
// toggle changes; the two-stage toggle synchronizer gives it ample settling
// time before it is sampled in the audio clock domain.
module dds_config_cdc (
    input  wire        audio_clk,
    input  wire        audio_resetn,
    input  wire        source_toggle,
    input  wire        source_enable,
    input  wire [31:0] source_ftw,
    output reg         audio_enable,
    output reg  [31:0] audio_ftw
);
    (* ASYNC_REG = "TRUE" *) reg toggle_meta;
    (* ASYNC_REG = "TRUE" *) reg toggle_sync;
    (* ASYNC_REG = "TRUE" *) reg enable_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] ftw_meta;
    reg toggle_seen;

    always @(posedge audio_clk) begin
        if (!audio_resetn) begin
            toggle_meta <= 1'b0;
            toggle_sync <= 1'b0;
            enable_meta <= 1'b0;
            ftw_meta <= 32'd0;
            toggle_seen <= 1'b0;
            audio_enable <= 1'b0;
            audio_ftw <= 32'd0;
        end else begin
            toggle_meta <= source_toggle;
            toggle_sync <= toggle_meta;
            enable_meta <= source_enable;
            ftw_meta <= source_ftw;
            if (toggle_sync != toggle_seen) begin
                audio_enable <= enable_meta;
                audio_ftw <= ftw_meta;
                toggle_seen <= toggle_sync;
            end
        end
    end
endmodule
