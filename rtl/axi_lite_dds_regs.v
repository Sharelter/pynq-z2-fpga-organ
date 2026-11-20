`timescale 1ns/1ps

// Single-outstanding-transaction AXI4-Lite register bank.
//   0x00 CONTROL: bit 0 = oscillator enable
//   0x04 FTW:     32-bit DDS frequency tuning word
//   0x08 STATUS:  bit 0 = enable as observed in the audio clock domain
//   0x0C ID:      0x4f524731 ("ORG1")
module axi_lite_dds_regs #(
    parameter integer ADDR_WIDTH = 6,
    parameter integer DATA_WIDTH = 32
) (
    input  wire                       aclk,
    input  wire                       aresetn,
    input  wire [ADDR_WIDTH-1:0]      s_axi_awaddr,
    input  wire                       s_axi_awvalid,
    output wire                       s_axi_awready,
    input  wire [DATA_WIDTH-1:0]      s_axi_wdata,
    input  wire [(DATA_WIDTH/8)-1:0]  s_axi_wstrb,
    input  wire                       s_axi_wvalid,
    output wire                       s_axi_wready,
    output wire [1:0]                 s_axi_bresp,
    output reg                        s_axi_bvalid,
    input  wire                       s_axi_bready,
    input  wire [ADDR_WIDTH-1:0]      s_axi_araddr,
    input  wire                       s_axi_arvalid,
    output wire                       s_axi_arready,
    output reg [DATA_WIDTH-1:0]       s_axi_rdata,
    output wire [1:0]                 s_axi_rresp,
    output reg                        s_axi_rvalid,
    input  wire                       s_axi_rready,
    input  wire                       audio_enable_status,
    output reg                        enable,
    output reg [31:0]                 ftw,
    output reg                        config_toggle
);
    reg aw_pending;
    reg w_pending;
    reg [ADDR_WIDTH-1:0] awaddr_hold;
    reg [DATA_WIDTH-1:0] wdata_hold;
    reg [(DATA_WIDTH/8)-1:0] wstrb_hold;
    integer byte_index;

    assign s_axi_awready = aresetn && !aw_pending && !s_axi_bvalid;
    assign s_axi_wready  = aresetn && !w_pending && !s_axi_bvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_arready = aresetn && !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_pending <= 1'b0;
            w_pending <= 1'b0;
            awaddr_hold <= {ADDR_WIDTH{1'b0}};
            wdata_hold <= {DATA_WIDTH{1'b0}};
            wstrb_hold <= {(DATA_WIDTH/8){1'b0}};
            s_axi_bvalid <= 1'b0;
            enable <= 1'b0;
            ftw <= 32'd0;
            config_toggle <= 1'b0;
        end else begin
            if (s_axi_awready && s_axi_awvalid) begin
                aw_pending <= 1'b1;
                awaddr_hold <= s_axi_awaddr;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                w_pending <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end

            if (!s_axi_bvalid && aw_pending && w_pending) begin
                case (awaddr_hold[5:2])
                    4'h0: begin
                        if (wstrb_hold[0]) enable <= wdata_hold[0];
                        config_toggle <= ~config_toggle;
                    end
                    4'h1: begin
                        for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                            if (wstrb_hold[byte_index])
                                ftw[byte_index*8 +: 8] <= wdata_hold[byte_index*8 +: 8];
                        config_toggle <= ~config_toggle;
                    end
                    default: ;
                endcase
                aw_pending <= 1'b0;
                w_pending <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata <= 32'd0;
        end else if (s_axi_arready && s_axi_arvalid) begin
            case (s_axi_araddr[5:2])
                4'h0: s_axi_rdata <= {31'd0, enable};
                4'h1: s_axi_rdata <= ftw;
                4'h2: s_axi_rdata <= {31'd0, audio_enable_status};
                4'h3: s_axi_rdata <= 32'h4f524731;
                default: s_axi_rdata <= 32'd0;
            endcase
            s_axi_rvalid <= 1'b1;
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end
endmodule
