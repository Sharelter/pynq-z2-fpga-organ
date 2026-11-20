`timescale 1ns/1ps

module axi_lite_m6_regs #(
    parameter [31:0] DESIGN_ID = 32'h4f524736
) (
    input wire aclk, input wire aresetn,
    input wire [6:0] s_axi_awaddr, input wire s_axi_awvalid, output wire s_axi_awready,
    input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid, output wire s_axi_wready,
    output wire [1:0] s_axi_bresp, output reg s_axi_bvalid, input wire s_axi_bready,
    input wire [6:0] s_axi_araddr, input wire s_axi_arvalid, output wire s_axi_arready,
    output reg [31:0] s_axi_rdata, output wire [1:0] s_axi_rresp,
    output reg s_axi_rvalid, input wire s_axi_rready,
    input wire voice_acknowledge, input wire [127:0] active_mask,
    input wire reverb_acknowledge, input wire reverb_clip,
    output reg master_enable, output reg [6:0] command_voice,
    output reg command_gate, output reg command_retrigger,
    output reg [1:0] command_table, output reg [31:0] command_ftw,
    output reg [15:0] command_gain, output reg command_toggle,
    output reg reverb_enable, output reg early_enable,
    output reg [15:0] reverb_feedback,
    output reg [15:0] reverb_wet, output reg reverb_clear_clip,
    output reg [63:0] damping_alpha, output reg [63:0] early_gain,
    output reg reverb_toggle
);
    reg aw_pending, w_pending;
    reg [6:0] awaddr_hold;
    reg [31:0] wdata_hold;
    reg [3:0] wstrb_hold;
    wire voice_busy = command_toggle != voice_acknowledge;
    wire reverb_busy = reverb_toggle != reverb_acknowledge;
    integer byte_index;

    assign s_axi_awready = aresetn && !aw_pending && !s_axi_bvalid;
    assign s_axi_wready = aresetn && !w_pending && !s_axi_bvalid;
    assign s_axi_bresp = 2'b00;
    assign s_axi_arready = aresetn && !s_axi_rvalid;
    assign s_axi_rresp = 2'b00;

    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_pending <= 0; w_pending <= 0; s_axi_bvalid <= 0;
            awaddr_hold <= 0; wdata_hold <= 0; wstrb_hold <= 0;
            master_enable <= 0; command_voice <= 0; command_gate <= 0;
            command_retrigger <= 0; command_table <= 0; command_ftw <= 0;
            command_gain <= 0; command_toggle <= 0;
            reverb_enable <= 0; early_enable <= 1; reverb_feedback <= 16'd29491;
            reverb_wet <= 16'd8192; reverb_clear_clip <= 0; reverb_toggle <= 0;
            damping_alpha <= {16'd15073,16'd15728,16'd16384,16'd17039};
            early_gain <= {16'd6553,16'd9830,16'd13107,16'd19660};
        end else begin
            if (s_axi_awready && s_axi_awvalid) begin
                aw_pending <= 1; awaddr_hold <= s_axi_awaddr;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                w_pending <= 1; wdata_hold <= s_axi_wdata; wstrb_hold <= s_axi_wstrb;
            end
            if (!s_axi_bvalid && aw_pending && w_pending) begin
                case (awaddr_hold[6:2])
                    5'h00: if (wstrb_hold[0]) master_enable <= wdata_hold[0];
                    5'h01: if (wstrb_hold[0]) command_voice <= wdata_hold[6:0];
                    5'h02: begin
                        if (wstrb_hold[0]) begin command_gate <= wdata_hold[0]; command_retrigger <= wdata_hold[1]; end
                        if (wstrb_hold[1]) command_table <= wdata_hold[9:8];
                    end
                    5'h03: for (byte_index=0; byte_index<4; byte_index=byte_index+1)
                        if (wstrb_hold[byte_index]) command_ftw[byte_index*8 +: 8] <= wdata_hold[byte_index*8 +: 8];
                    5'h04: begin
                        if (wstrb_hold[0]) command_gain[7:0] <= wdata_hold[7:0];
                        if (wstrb_hold[1]) command_gain[15:8] <= wdata_hold[15:8];
                    end
                    5'h05: if (wstrb_hold[0] && wdata_hold[0] && !voice_busy) command_toggle <= ~command_toggle;
                    5'h0d: if (wstrb_hold[0]) begin
                        reverb_enable <= wdata_hold[0]; reverb_clear_clip <= wdata_hold[1];
                        early_enable <= wdata_hold[2];
                    end
                    5'h0e: begin
                        if (wstrb_hold[0]) reverb_feedback[7:0] <= wdata_hold[7:0];
                        if (wstrb_hold[1]) reverb_feedback[15:8] <= wdata_hold[15:8];
                    end
                    5'h0f: begin
                        if (wstrb_hold[0]) reverb_wet[7:0] <= wdata_hold[7:0];
                        if (wstrb_hold[1]) reverb_wet[15:8] <= wdata_hold[15:8];
                    end
                    5'h10: if (wstrb_hold[0] && wdata_hold[0] && !reverb_busy) reverb_toggle <= ~reverb_toggle;
                    5'h12: for (byte_index=0; byte_index<4; byte_index=byte_index+1)
                        if(wstrb_hold[byte_index]) damping_alpha[byte_index*8 +:8] <= wdata_hold[byte_index*8 +:8];
                    5'h13: for (byte_index=0; byte_index<4; byte_index=byte_index+1)
                        if(wstrb_hold[byte_index]) damping_alpha[32+byte_index*8 +:8] <= wdata_hold[byte_index*8 +:8];
                    5'h14: for (byte_index=0; byte_index<4; byte_index=byte_index+1)
                        if(wstrb_hold[byte_index]) early_gain[byte_index*8 +:8] <= wdata_hold[byte_index*8 +:8];
                    5'h15: for (byte_index=0; byte_index<4; byte_index=byte_index+1)
                        if(wstrb_hold[byte_index]) early_gain[32+byte_index*8 +:8] <= wdata_hold[byte_index*8 +:8];
                    default: ;
                endcase
                aw_pending <= 0; w_pending <= 0; s_axi_bvalid <= 1;
            end else if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin s_axi_rvalid <= 0; s_axi_rdata <= 0; end
        else if (s_axi_arready && s_axi_arvalid) begin
            case (s_axi_araddr[6:2])
                5'h00: s_axi_rdata <= {31'd0, master_enable};
                5'h01: s_axi_rdata <= {25'd0, command_voice};
                5'h02: s_axi_rdata <= {22'd0, command_table, 6'd0, command_retrigger, command_gate};
                5'h03: s_axi_rdata <= command_ftw;
                5'h04: s_axi_rdata <= {16'd0, command_gain};
                5'h06: s_axi_rdata <= {voice_busy, 31'd0};
                5'h07: s_axi_rdata <= DESIGN_ID;
                5'h08: s_axi_rdata <= active_mask[31:0];
                5'h09: s_axi_rdata <= active_mask[63:32];
                5'h0a: s_axi_rdata <= active_mask[95:64];
                5'h0b: s_axi_rdata <= active_mask[127:96];
                5'h0c: s_axi_rdata <= 32'd128;
                5'h0d: s_axi_rdata <= {29'd0, early_enable, reverb_clear_clip, reverb_enable};
                5'h0e: s_axi_rdata <= {16'd0, reverb_feedback};
                5'h0f: s_axi_rdata <= {16'd0, reverb_wet};
                5'h10: s_axi_rdata <= 0;
                5'h11: s_axi_rdata <= {reverb_busy, 30'd0, reverb_clip};
                5'h12: s_axi_rdata <= damping_alpha[31:0];
                5'h13: s_axi_rdata <= damping_alpha[63:32];
                5'h14: s_axi_rdata <= early_gain[31:0];
                5'h15: s_axi_rdata <= early_gain[63:32];
                default: s_axi_rdata <= 0;
            endcase
            s_axi_rvalid <= 1;
        end else if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
    end
endmodule
