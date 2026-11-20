`timescale 1ns/1ps

// Four-delay Feedback Delay Network with an orthonormal Hadamard matrix.
// Prime delay lengths avoid coincident modes. Coefficients are unsigned Q1.15.
module fdn_reverb #(
    parameter integer D0 = 1493,
    parameter integer D1 = 1601,
    parameter integer D2 = 1747,
    parameter integer D3 = 1867
) (
    input wire clk, input wire resetn, input wire frame_tick,
    input wire signed [23:0] dry_sample,
    input wire config_valid, input wire config_enable,
    input wire [15:0] config_feedback, input wire [15:0] config_wet,
    input wire config_clear_clip,
    output reg signed [23:0] left_sample,
    output reg signed [23:0] right_sample,
    output reg clip_flag
);
    (* ram_style = "block" *) reg signed [23:0] delay0 [0:D0-1];
    (* ram_style = "block" *) reg signed [23:0] delay1 [0:D1-1];
    (* ram_style = "block" *) reg signed [23:0] delay2 [0:D2-1];
    (* ram_style = "block" *) reg signed [23:0] delay3 [0:D3-1];

    reg [10:0] pointer0, pointer1, pointer2, pointer3;
    reg [10:0] fill0, fill1, fill2, fill3;
    reg signed [23:0] read0, read1, read2, read3, dry_hold;
    reg read_valid0, read_valid1, read_valid2, read_valid3;
    reg process_pending;
    reg enabled;
    reg [15:0] feedback_q15, wet_q15;

    wire signed [23:0] tap0 = read_valid0 ? read0 : 24'sd0;
    wire signed [23:0] tap1 = read_valid1 ? read1 : 24'sd0;
    wire signed [23:0] tap2 = read_valid2 ? read2 : 24'sd0;
    wire signed [23:0] tap3 = read_valid3 ? read3 : 24'sd0;
    wire signed [25:0] ext0 = {{2{tap0[23]}}, tap0};
    wire signed [25:0] ext1 = {{2{tap1[23]}}, tap1};
    wire signed [25:0] ext2 = {{2{tap2[23]}}, tap2};
    wire signed [25:0] ext3 = {{2{tap3[23]}}, tap3};

    wire signed [25:0] matrix0 = (ext0 + ext1 + ext2 + ext3) >>> 1;
    wire signed [25:0] matrix1 = (ext0 - ext1 + ext2 - ext3) >>> 1;
    wire signed [25:0] matrix2 = (ext0 + ext1 - ext2 - ext3) >>> 1;
    wire signed [25:0] matrix3 = (ext0 - ext1 - ext2 + ext3) >>> 1;
    wire signed [16:0] feedback_signed = $signed({1'b0, feedback_q15});
    wire signed [42:0] feedback0 = $signed(matrix0) * feedback_signed;
    wire signed [42:0] feedback1 = $signed(matrix1) * feedback_signed;
    wire signed [42:0] feedback2 = $signed(matrix2) * feedback_signed;
    wire signed [42:0] feedback3 = $signed(matrix3) * feedback_signed;
    wire signed [43:0] write0 = (feedback0 >>> 15) + ($signed(dry_hold) >>> 1);
    wire signed [43:0] write1 = (feedback1 >>> 15) + ($signed(dry_hold) >>> 1);
    wire signed [43:0] write2 = (feedback2 >>> 15) + ($signed(dry_hold) >>> 1);
    wire signed [43:0] write3 = (feedback3 >>> 15) + ($signed(dry_hold) >>> 1);

    wire signed [24:0] wet_left_wide =
        ({{1{tap0[23]}}, tap0} + {{1{tap2[23]}}, tap2}) >>> 1;
    wire signed [24:0] wet_right_wide =
        ({{1{tap1[23]}}, tap1} + {{1{tap3[23]}}, tap3}) >>> 1;
    wire signed [23:0] wet_left = wet_left_wide[23:0];
    wire signed [23:0] wet_right = wet_right_wide[23:0];
    wire [15:0] dry_q15 = 16'd32767 - wet_q15;
    wire signed [16:0] wet_signed = $signed({1'b0, wet_q15});
    wire signed [16:0] dry_signed = $signed({1'b0, dry_q15});
    wire signed [40:0] dry_product = $signed(dry_hold) * dry_signed;
    wire signed [40:0] wet_left_product = $signed(wet_left) * wet_signed;
    wire signed [40:0] wet_right_product = $signed(wet_right) * wet_signed;
    wire signed [41:0] mix_left = dry_product + wet_left_product;
    wire signed [41:0] mix_right = dry_product + wet_right_product;
    wire signed [43:0] mix_left_scaled = mix_left >>> 15;
    wire signed [43:0] mix_right_scaled = mix_right >>> 15;

    function signed [23:0] saturate24;
        input signed [43:0] value;
        begin
            if (value > 44'sd8388607) saturate24 = 24'sh7fffff;
            else if (value < -44'sd8388608) saturate24 = 24'sh800000;
            else saturate24 = value[23:0];
        end
    endfunction

    wire clip_now = write0 > 44'sd8388607 || write0 < -44'sd8388608
                 || write1 > 44'sd8388607 || write1 < -44'sd8388608
                 || write2 > 44'sd8388607 || write2 < -44'sd8388608
                 || write3 > 44'sd8388607 || write3 < -44'sd8388608
                 || mix_left_scaled > 44'sd8388607 || mix_left_scaled < -44'sd8388608
                 || mix_right_scaled > 44'sd8388607 || mix_right_scaled < -44'sd8388608;

    always @(posedge clk) begin
        if (!resetn) begin
            pointer0 <= 0; pointer1 <= 0; pointer2 <= 0; pointer3 <= 0;
            fill0 <= 0; fill1 <= 0; fill2 <= 0; fill3 <= 0;
            read0 <= 0; read1 <= 0; read2 <= 0; read3 <= 0; dry_hold <= 0;
            read_valid0 <= 0; read_valid1 <= 0; read_valid2 <= 0; read_valid3 <= 0;
            process_pending <= 0; enabled <= 0; feedback_q15 <= 16'd29491;
            wet_q15 <= 16'd8192; left_sample <= 0; right_sample <= 0;
            clip_flag <= 0;
        end else begin
            if (config_valid) begin
                enabled <= config_enable;
                feedback_q15 <= config_feedback > 16'd32440 ? 16'd32440 : config_feedback;
                wet_q15 <= config_wet > 16'd32767 ? 16'd32767 : config_wet;
                if (config_clear_clip) clip_flag <= 0;
            end

            if (frame_tick && !process_pending) begin
                if (!enabled) begin
                    left_sample <= dry_sample; right_sample <= dry_sample;
                    pointer0 <= 0; pointer1 <= 0; pointer2 <= 0; pointer3 <= 0;
                    fill0 <= 0; fill1 <= 0; fill2 <= 0; fill3 <= 0;
                end else begin
                    dry_hold <= dry_sample;
                    read0 <= delay0[pointer0]; read1 <= delay1[pointer1];
                    read2 <= delay2[pointer2]; read3 <= delay3[pointer3];
                    read_valid0 <= fill0 >= D0; read_valid1 <= fill1 >= D1;
                    read_valid2 <= fill2 >= D2; read_valid3 <= fill3 >= D3;
                    process_pending <= 1;
                end
            end else if (process_pending) begin
                delay0[pointer0] <= saturate24(write0);
                delay1[pointer1] <= saturate24(write1);
                delay2[pointer2] <= saturate24(write2);
                delay3[pointer3] <= saturate24(write3);
                pointer0 <= pointer0 == D0-1 ? 0 : pointer0 + 1'b1;
                pointer1 <= pointer1 == D1-1 ? 0 : pointer1 + 1'b1;
                pointer2 <= pointer2 == D2-1 ? 0 : pointer2 + 1'b1;
                pointer3 <= pointer3 == D3-1 ? 0 : pointer3 + 1'b1;
                if (fill0 < D0) fill0 <= fill0 + 1'b1;
                if (fill1 < D1) fill1 <= fill1 + 1'b1;
                if (fill2 < D2) fill2 <= fill2 + 1'b1;
                if (fill3 < D3) fill3 <= fill3 + 1'b1;
                left_sample <= saturate24(mix_left_scaled);
                right_sample <= saturate24(mix_right_scaled);
                if (clip_now) clip_flag <= 1;
                process_pending <= 0;
            end
        end
    end
endmodule
