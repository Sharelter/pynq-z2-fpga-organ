`timescale 1ns/1ps

// Milestone-3 AXI4-Lite control mailbox.
// 0x00 GLOBAL_CONTROL bit0: master enable
// 0x04 VOICE_SELECT bits6:0
// 0x08 VOICE_CONTROL bit0 gate, bit1 retrigger, bits9:8 table
// 0x0c VOICE_FTW
// 0x10 VOICE_GAIN bits15:0 unsigned Q1.15
// 0x14 COMMIT bit0; ignored while busy
// 0x18 STATUS bit31 command busy
// 0x1c ID = 0x4f524733 ("ORG3")
// 0x20..0x2c ACTIVE_MASK words 0..3
// 0x30 VOICE_CAPACITY = 128
module axi_lite_m3_regs #(
    parameter integer ADDR_WIDTH = 6,
    parameter integer DATA_WIDTH = 32
) (
    input wire aclk, input wire aresetn,
    input wire [ADDR_WIDTH-1:0] s_axi_awaddr, input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [DATA_WIDTH-1:0] s_axi_wdata,
    input wire [(DATA_WIDTH/8)-1:0] s_axi_wstrb, input wire s_axi_wvalid,
    output wire s_axi_wready, output wire [1:0] s_axi_bresp,
    output reg s_axi_bvalid, input wire s_axi_bready,
    input wire [ADDR_WIDTH-1:0] s_axi_araddr, input wire s_axi_arvalid,
    output wire s_axi_arready, output reg [DATA_WIDTH-1:0] s_axi_rdata,
    output wire [1:0] s_axi_rresp, output reg s_axi_rvalid,
    input wire s_axi_rready,
    input wire acknowledge_toggle,
    input wire [127:0] active_mask,
    output reg master_enable,
    output reg [6:0] command_voice,
    output reg command_gate,
    output reg command_retrigger,
    output reg [1:0] command_table,
    output reg [31:0] command_ftw,
    output reg [15:0] command_gain,
    output reg command_toggle
);
    reg aw_pending, w_pending;
    reg [ADDR_WIDTH-1:0] awaddr_hold;
    reg [DATA_WIDTH-1:0] wdata_hold;
    reg [(DATA_WIDTH/8)-1:0] wstrb_hold;
    wire command_busy = command_toggle != acknowledge_toggle;
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
            command_retrigger <= 0; command_table <= 0;
            command_ftw <= 0; command_gain <= 0; command_toggle <= 0;
        end else begin
            if (s_axi_awready && s_axi_awvalid) begin
                aw_pending <= 1; awaddr_hold <= s_axi_awaddr;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                w_pending <= 1; wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end
            if (!s_axi_bvalid && aw_pending && w_pending) begin
                case (awaddr_hold[5:2])
                    4'h0: if (wstrb_hold[0]) master_enable <= wdata_hold[0];
                    4'h1: if (wstrb_hold[0]) command_voice <= wdata_hold[6:0];
                    4'h2: begin
                        if (wstrb_hold[0]) begin
                            command_gate <= wdata_hold[0];
                            command_retrigger <= wdata_hold[1];
                        end
                        if (wstrb_hold[1]) command_table <= wdata_hold[9:8];
                    end
                    4'h3: for (byte_index=0; byte_index<4; byte_index=byte_index+1)
                        if (wstrb_hold[byte_index])
                            command_ftw[byte_index*8 +: 8] <= wdata_hold[byte_index*8 +: 8];
                    4'h4: begin
                        if (wstrb_hold[0]) command_gain[7:0] <= wdata_hold[7:0];
                        if (wstrb_hold[1]) command_gain[15:8] <= wdata_hold[15:8];
                    end
                    4'h5: if (wstrb_hold[0] && wdata_hold[0] && !command_busy)
                        command_toggle <= ~command_toggle;
                    default: ;
                endcase
                aw_pending <= 0; w_pending <= 0; s_axi_bvalid <= 1;
            end else if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 0;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin s_axi_rvalid <= 0; s_axi_rdata <= 0; end
        else if (s_axi_arready && s_axi_arvalid) begin
            case (s_axi_araddr[5:2])
                4'h0: s_axi_rdata <= {31'd0, master_enable};
                4'h1: s_axi_rdata <= {25'd0, command_voice};
                4'h2: s_axi_rdata <= {22'd0, command_table, 6'd0,
                                      command_retrigger, command_gate};
                4'h3: s_axi_rdata <= command_ftw;
                4'h4: s_axi_rdata <= {16'd0, command_gain};
                4'h5: s_axi_rdata <= 32'd0;
                4'h6: s_axi_rdata <= {command_busy, 31'd0};
                4'h7: s_axi_rdata <= 32'h4f524733;
                4'h8: s_axi_rdata <= active_mask[31:0];
                4'h9: s_axi_rdata <= active_mask[63:32];
                4'ha: s_axi_rdata <= active_mask[95:64];
                4'hb: s_axi_rdata <= active_mask[127:96];
                4'hc: s_axi_rdata <= 32'd128;
                default: s_axi_rdata <= 0;
            endcase
            s_axi_rvalid <= 1;
        end else if (s_axi_rvalid && s_axi_rready)
            s_axi_rvalid <= 0;
    end
endmodule
