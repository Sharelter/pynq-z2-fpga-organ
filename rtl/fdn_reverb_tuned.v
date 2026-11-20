`timescale 1ns/1ps

// Separate simple-dual-port template keeps the sparse-tap history in BRAM.
module early_reflection_memory (
    input wire clk,
    input wire write_enable,
    input wire [10:0] write_address,
    input wire signed [23:0] write_data,
    input wire read_enable,
    input wire [10:0] read_address,
    output reg signed [23:0] read_data
);
    (* ram_style="block" *) reg signed [23:0] memory [0:2047];
    always @(posedge clk) begin
        if (write_enable)
            memory[write_address] <= write_data;
        if (read_enable)
            read_data <= memory[read_address];
    end
endmodule

// Four-line FDN with per-line one-pole damping and an independent sparse
// stereo early-reflection branch. One multiplier is shared by damping and ERs.
module fdn_reverb_tuned #(
    parameter integer D0=1493, D1=1601, D2=1747, D3=1867
) (
    input wire clk, input wire resetn, input wire frame_tick,
    input wire signed [23:0] dry_sample,
    input wire config_valid, input wire config_enable, input wire config_early_enable,
    input wire [15:0] config_feedback, input wire [15:0] config_wet,
    input wire [63:0] config_alpha, input wire [63:0] config_early_gain,
    input wire config_clear_clip,
    output reg signed [23:0] left_sample, output reg signed [23:0] right_sample,
    output reg clip_flag
);
    localparam IDLE=4'd0, WAIT_FDN=4'd1, DAMP_LAUNCH=4'd2, DAMP_STORE=4'd3,
               FDN_WRITE=4'd4, ER_READ=4'd5, ER_LAUNCH=4'd6,
               ER_ACCUM=4'd7, FINAL_MIX=4'd8;
    (* ram_style="block" *) reg signed [23:0] delay0 [0:D0-1];
    (* ram_style="block" *) reg signed [23:0] delay1 [0:D1-1];
    (* ram_style="block" *) reg signed [23:0] delay2 [0:D2-1];
    (* ram_style="block" *) reg signed [23:0] delay3 [0:D3-1];

    reg [3:0] state;
    reg enabled, early_enabled;
    reg [15:0] feedback_q15, wet_q15;
    reg [15:0] alpha [0:3];
    reg [15:0] early_gain [0:3];
    reg [10:0] pointer0, pointer1, pointer2, pointer3, early_pointer, early_base;
    reg [11:0] fill0, fill1, fill2, fill3, early_fill;
    reg signed [23:0] tap0, tap1, tap2, tap3, dry_hold;
    wire signed [23:0] early_read;
    reg early_read_valid;
    reg valid0, valid1, valid2, valid3;
    reg signed [23:0] damped [0:3];
    reg [1:0] damp_index;
    reg [3:0] early_index;
    reg signed [43:0] early_left_acc, early_right_acc;
    reg signed [26:0] shared_a;
    reg signed [16:0] shared_b;
    wire signed [43:0] shared_product = shared_a * shared_b;

    wire signed [23:0] t0 = valid0 ? tap0 : 0;
    wire signed [23:0] t1 = valid1 ? tap1 : 0;
    wire signed [23:0] t2 = valid2 ? tap2 : 0;
    wire signed [23:0] t3 = valid3 ? tap3 : 0;
    wire signed [25:0] e0={{2{t0[23]}},t0}, e1={{2{t1[23]}},t1};
    wire signed [25:0] e2={{2{t2[23]}},t2}, e3={{2{t3[23]}},t3};
    wire signed [25:0] matrix0=(e0+e1+e2+e3)>>>1;
    wire signed [25:0] matrix1=(e0-e1+e2-e3)>>>1;
    wire signed [25:0] matrix2=(e0+e1-e2-e3)>>>1;
    wire signed [25:0] matrix3=(e0-e1-e2+e3)>>>1;
    reg signed [25:0] selected_matrix;
    always @* begin
        case (damp_index)
            0: selected_matrix=matrix0; 1: selected_matrix=matrix1;
            2: selected_matrix=matrix2; default: selected_matrix=matrix3;
        endcase
    end
    wire signed [26:0] damp_difference =
        $signed({selected_matrix[25],selected_matrix})
        - $signed({{3{damped[damp_index][23]}},damped[damp_index]});
    wire signed [43:0] damp_wide =
        $signed({{20{damped[damp_index][23]}},damped[damp_index]})
        + (shared_product >>> 15);

    wire signed [16:0] feedback_signed=$signed({1'b0,feedback_q15});
    wire signed [40:0] fb0=$signed(damped[0])*feedback_signed;
    wire signed [40:0] fb1=$signed(damped[1])*feedback_signed;
    wire signed [40:0] fb2=$signed(damped[2])*feedback_signed;
    wire signed [40:0] fb3=$signed(damped[3])*feedback_signed;
    wire signed [43:0] write0=(fb0>>>15)+($signed(dry_hold)>>>1);
    wire signed [43:0] write1=(fb1>>>15)+($signed(dry_hold)>>>1);
    wire signed [43:0] write2=(fb2>>>15)+($signed(dry_hold)>>>1);
    wire signed [43:0] write3=(fb3>>>15)+($signed(dry_hold)>>>1);

    reg [10:0] selected_early_delay;
    wire [1:0] early_gain_index=early_index[1:0];
    always @* begin
        case (early_index)
            0: selected_early_delay=11'd528; 1: selected_early_delay=11'd816;
            2: selected_early_delay=11'd1104; 3: selected_early_delay=11'd1392;
            4: selected_early_delay=11'd576; 5: selected_early_delay=11'd864;
            6: selected_early_delay=11'd1152; default: selected_early_delay=11'd1440;
        endcase
    end
    wire [11:0] wrapped_early = {1'b0,early_base}+12'd2048-{1'b0,selected_early_delay};
    wire [10:0] early_address = early_base>=selected_early_delay
                                    ? early_base-selected_early_delay : wrapped_early[10:0];

    early_reflection_memory early_history (
        .clk(clk),
        .write_enable(state == IDLE && frame_tick),
        .write_address(early_pointer),
        .write_data(dry_sample),
        .read_enable(state == ER_READ),
        .read_address(early_address),
        .read_data(early_read)
    );
    wire signed [43:0] early_left_scaled=early_left_acc>>>15;
    wire signed [43:0] early_right_scaled=early_right_acc>>>15;
    wire signed [23:0] early_left_sample;
    wire signed [23:0] early_right_sample;

    wire signed [24:0] late_left_wide=
        ($signed({t0[23],t0})+$signed({t2[23],t2}))>>>1;
    wire signed [24:0] late_right_wide=
        ($signed({t1[23],t1})+$signed({t3[23],t3}))>>>1;
    wire signed [24:0] combined_left=
        ($signed(late_left_wide)+$signed({early_left_sample[23],early_left_sample}))>>>1;
    wire signed [24:0] combined_right=
        ($signed(late_right_wide)+$signed({early_right_sample[23],early_right_sample}))>>>1;
    wire [15:0] dry_q15=16'd32767-wet_q15;
    wire signed [16:0] wet_signed=$signed({1'b0,wet_q15});
    wire signed [16:0] dry_signed=$signed({1'b0,dry_q15});
    wire signed [40:0] dry_product=$signed(dry_hold)*dry_signed;
    wire signed [40:0] wet_left_product=$signed(combined_left[23:0])*wet_signed;
    wire signed [40:0] wet_right_product=$signed(combined_right[23:0])*wet_signed;
    wire signed [41:0] mix_left_sum=
        $signed({dry_product[40],dry_product})+$signed({wet_left_product[40],wet_left_product});
    wire signed [41:0] mix_right_sum=
        $signed({dry_product[40],dry_product})+$signed({wet_right_product[40],wet_right_product});
    wire signed [43:0] mix_left=mix_left_sum>>>15;
    wire signed [43:0] mix_right=mix_right_sum>>>15;

    function signed [23:0] sat24;
        input signed [43:0] value;
        begin
            if(value>44'sd8388607) sat24=24'sh7fffff;
            else if(value< -44'sd8388608) sat24=24'sh800000;
            else sat24=value[23:0];
        end
    endfunction
    assign early_left_sample=sat24(early_left_scaled);
    assign early_right_sample=sat24(early_right_scaled);
    function is_clip;
        input signed [43:0] value;
        begin is_clip=(value>44'sd8388607)||(value< -44'sd8388608); end
    endfunction

    integer k;
    always @(posedge clk) begin
        if(!resetn) begin
            state<=IDLE; enabled<=0; early_enabled<=0; feedback_q15<=16'd29491; wet_q15<=16'd8192;
            pointer0<=0; pointer1<=0; pointer2<=0; pointer3<=0; early_pointer<=0; early_base<=0;
            fill0<=0; fill1<=0; fill2<=0; fill3<=0; early_fill<=0;
            tap0<=0; tap1<=0; tap2<=0; tap3<=0; dry_hold<=0; early_read_valid<=0;
            valid0<=0; valid1<=0; valid2<=0; valid3<=0; damp_index<=0; early_index<=0;
            shared_a<=0; shared_b<=0; early_left_acc<=0; early_right_acc<=0;
            left_sample<=0; right_sample<=0; clip_flag<=0;
            for(k=0;k<4;k=k+1) begin damped[k]<=0; alpha[k]<=16'd16384; early_gain[k]<=0; end
        end else begin
            if(config_valid) begin
                enabled<=config_enable; early_enabled<=config_early_enable;
                feedback_q15 <= config_feedback > 16'd32440
                                    ? 16'd32440 : config_feedback;
                wet_q15 <= config_wet > 16'd32767
                               ? 16'd32767 : config_wet;
                for(k=0;k<4;k=k+1) begin
                    alpha[k]<=config_alpha[k*16 +:16]<16'd3277 ? 16'd3277
                              : config_alpha[k*16 +:16]>16'd29491 ? 16'd29491
                              : config_alpha[k*16 +:16];
                    early_gain[k]<=config_early_gain[k*16 +:16];
                end
                if(config_clear_clip) clip_flag<=0;
            end
            case(state)
                IDLE: if(frame_tick) begin
                    early_base<=early_pointer;
                    early_pointer<=early_pointer+1'b1;
                    if(early_fill<2048) early_fill<=early_fill+1'b1;
                    if(!enabled) begin
                        left_sample<=dry_sample; right_sample<=dry_sample;
                        pointer0<=0; pointer1<=0; pointer2<=0; pointer3<=0;
                        fill0<=0; fill1<=0; fill2<=0; fill3<=0;
                        for(k=0;k<4;k=k+1) damped[k]<=0;
                    end else begin
                        dry_hold<=dry_sample;
                        tap0<=delay0[pointer0]; tap1<=delay1[pointer1];
                        tap2<=delay2[pointer2]; tap3<=delay3[pointer3];
                        valid0<=fill0>=D0; valid1<=fill1>=D1;
                        valid2<=fill2>=D2; valid3<=fill3>=D3;
                        state<=WAIT_FDN;
                    end
                end
                WAIT_FDN: begin damp_index<=0; state<=DAMP_LAUNCH; end
                DAMP_LAUNCH: begin
                    shared_a<=damp_difference; shared_b<=$signed({1'b0,alpha[damp_index]});
                    state<=DAMP_STORE;
                end
                DAMP_STORE: begin
                    damped[damp_index]<=sat24(damp_wide);
                    if(is_clip(damp_wide)) clip_flag<=1;
                    if(damp_index==3) state<=FDN_WRITE;
                    else begin damp_index<=damp_index+1'b1; state<=DAMP_LAUNCH; end
                end
                FDN_WRITE: begin
                    delay0[pointer0]<=sat24(write0); delay1[pointer1]<=sat24(write1);
                    delay2[pointer2]<=sat24(write2); delay3[pointer3]<=sat24(write3);
                    pointer0<=pointer0==D0-1?0:pointer0+1'b1;
                    pointer1<=pointer1==D1-1?0:pointer1+1'b1;
                    pointer2<=pointer2==D2-1?0:pointer2+1'b1;
                    pointer3<=pointer3==D3-1?0:pointer3+1'b1;
                    if(fill0<D0) fill0<=fill0+1'b1; if(fill1<D1) fill1<=fill1+1'b1;
                    if(fill2<D2) fill2<=fill2+1'b1; if(fill3<D3) fill3<=fill3+1'b1;
                    if(is_clip(write0)||is_clip(write1)||is_clip(write2)||is_clip(write3)) clip_flag<=1;
                    early_left_acc<=0; early_right_acc<=0; early_index<=0;
                    state<=early_enabled?ER_READ:FINAL_MIX;
                end
                ER_READ: begin
                    early_read_valid<=early_fill>=selected_early_delay;
                    state<=ER_LAUNCH;
                end
                ER_LAUNCH: begin
                    shared_a<=early_read_valid
                                ? {{3{early_read[23]}},early_read} : 27'sd0;
                    shared_b<=$signed({1'b0,early_gain[early_gain_index]});
                    state<=ER_ACCUM;
                end
                ER_ACCUM: begin
                    if(early_index<4) early_left_acc<=early_left_acc+shared_product;
                    else early_right_acc<=early_right_acc+shared_product;
                    if(early_index==7) state<=FINAL_MIX;
                    else begin early_index<=early_index+1'b1; state<=ER_READ; end
                end
                FINAL_MIX: begin
                    left_sample<=sat24(mix_left); right_sample<=sat24(mix_right);
                    if(is_clip(early_left_scaled)||is_clip(early_right_scaled)
                       ||is_clip(mix_left)||is_clip(mix_right)) clip_flag<=1;
                    state<=IDLE;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
