`timescale 1ns/1ps

module organ_dds_i2s #(
    parameter integer PHASE_WIDTH = 32,
    parameter integer SAMPLE_WIDTH = 24
) (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 6" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *) input wire [5:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *) input wire s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *) output wire s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *) input wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *) input wire [3:0] s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *) input wire s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *) output wire s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *) output wire [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *) output wire s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *) input wire s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *) input wire [5:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *) input wire s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *) output wire s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *) output wire [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *) output wire [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *) output wire s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *) input wire s_axi_rready,

    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME AXI_CLK, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 100000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 AXI_CLK CLK" *) input wire s_axi_aclk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aresetn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *) input wire s_axi_aresetn,

    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME AUDIO_CLK, ASSOCIATED_RESET audio_resetn, FREQ_HZ 49154929" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 AUDIO_CLK CLK" *) input wire audio_clk,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME audio_resetn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 audio_resetn RST" *) input wire audio_resetn,

    output wire bclk,
    output wire lrclk,
    output wire sdata_o
);
    wire axi_enable;
    wire [31:0] axi_ftw;
    wire config_toggle;
    wire audio_enable;
    (* ASYNC_REG = "TRUE" *) reg audio_enable_axi_meta;
    (* ASYNC_REG = "TRUE" *) reg audio_enable_axi_sync;
    wire [31:0] audio_ftw;
    wire frame_tick;
    wire signed [SAMPLE_WIDTH-1:0] sine_sample;
    wire [PHASE_WIDTH-1:0] phase_accumulator;

    axi_lite_dds_regs regs (
        .aclk(s_axi_aclk),
        .aresetn(s_axi_aresetn),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .audio_enable_status(audio_enable_axi_sync),
        .enable(axi_enable),
        .ftw(axi_ftw),
        .config_toggle(config_toggle)
    );

    // Return only a diagnostic bit to AXI; synchronize it independently.
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            audio_enable_axi_meta <= 1'b0;
            audio_enable_axi_sync <= 1'b0;
        end else begin
            audio_enable_axi_meta <= audio_enable;
            audio_enable_axi_sync <= audio_enable_axi_meta;
        end
    end

    dds_config_cdc config_cdc (
        .audio_clk(audio_clk),
        .audio_resetn(audio_resetn),
        .source_toggle(config_toggle),
        .source_enable(axi_enable),
        .source_ftw(axi_ftw),
        .audio_enable(audio_enable),
        .audio_ftw(audio_ftw)
    );

    dds_sine #(
        .PHASE_WIDTH(PHASE_WIDTH),
        .OUTPUT_WIDTH(SAMPLE_WIDTH),
        .ROM_ADDR_WIDTH(10),
        .ROM_FILE("sine_1024x24.mem")
    ) oscillator (
        .clk(audio_clk),
        .resetn(audio_resetn),
        .sample_tick(frame_tick),
        .enable(audio_enable),
        .phase_increment(audio_ftw),
        .sample(sine_sample),
        .phase_accumulator(phase_accumulator)
    );

    i2s_tx #(.SAMPLE_WIDTH(SAMPLE_WIDTH)) transmitter (
        .clk(audio_clk),
        .resetn(audio_resetn),
        .left_sample(sine_sample),
        .right_sample(sine_sample),
        .bclk(bclk),
        .lrclk(lrclk),
        .sdata(sdata_o),
        .frame_tick(frame_tick)
    );
endmodule
