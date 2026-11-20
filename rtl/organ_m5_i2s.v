`timescale 1ns/1ps

module organ_m5_i2s (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 7" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *) input wire [6:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *) input wire s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *) output wire s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *) input wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *) input wire [3:0] s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *) input wire s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *) output wire s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *) output wire [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *) output wire s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *) input wire s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *) input wire [6:0] s_axi_araddr,
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
    output wire bclk, output wire lrclk, output wire sdata_o
);
    wire master_enable_axi, voice_toggle, voice_ack_audio;
    wire [6:0] source_voice, command_voice;
    wire source_gate, source_retrigger, command_gate, command_retrigger;
    wire [1:0] source_table, command_table;
    wire [31:0] source_ftw, command_ftw;
    wire [15:0] source_gain, command_gain;
    wire command_valid;
    wire reverb_enable_source, reverb_clear_source, reverb_toggle, reverb_ack_audio;
    wire [15:0] reverb_feedback_source, reverb_wet_source;
    wire reverb_config_valid, reverb_config_enable, reverb_config_clear;
    wire [15:0] reverb_config_feedback, reverb_config_wet;
    wire [127:0] active_audio;
    wire frame_tick, reverb_clip_audio;
    wire signed [23:0] dry_sample, left_reverb, right_reverb;
    (* ASYNC_REG = "TRUE" *) reg voice_ack_meta, voice_ack_sync;
    (* ASYNC_REG = "TRUE" *) reg reverb_ack_meta, reverb_ack_sync;
    (* ASYNC_REG = "TRUE" *) reg reverb_clip_meta, reverb_clip_sync;
    (* ASYNC_REG = "TRUE" *) reg master_meta, master_audio;
    (* ASYNC_REG = "TRUE" *) reg [127:0] active_meta, active_sync;

    axi_lite_m5_regs regs (
        .aclk(s_axi_aclk), .aresetn(s_axi_aresetn),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .voice_acknowledge(voice_ack_sync), .active_mask(active_sync),
        .reverb_acknowledge(reverb_ack_sync), .reverb_clip(reverb_clip_sync),
        .master_enable(master_enable_axi), .command_voice(source_voice), .command_gate(source_gate),
        .command_retrigger(source_retrigger), .command_table(source_table),
        .command_ftw(source_ftw), .command_gain(source_gain), .command_toggle(voice_toggle),
        .reverb_enable(reverb_enable_source), .reverb_feedback(reverb_feedback_source),
        .reverb_wet(reverb_wet_source), .reverb_clear_clip(reverb_clear_source),
        .reverb_toggle(reverb_toggle)
    );

    always @(posedge audio_clk) begin
        if (!audio_resetn) begin master_meta <= 0; master_audio <= 0; end
        else begin master_meta <= master_enable_axi; master_audio <= master_meta; end
    end
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            voice_ack_meta <= 0; voice_ack_sync <= 0; reverb_ack_meta <= 0;
            reverb_ack_sync <= 0; reverb_clip_meta <= 0; reverb_clip_sync <= 0;
            active_meta <= 0; active_sync <= 0;
        end else begin
            voice_ack_meta <= voice_ack_audio; voice_ack_sync <= voice_ack_meta;
            reverb_ack_meta <= reverb_ack_audio; reverb_ack_sync <= reverb_ack_meta;
            reverb_clip_meta <= reverb_clip_audio; reverb_clip_sync <= reverb_clip_meta;
            active_meta <= active_audio; active_sync <= active_meta;
        end
    end

    voice_command_cdc_m3 voice_cdc (
        .audio_clk(audio_clk), .audio_resetn(audio_resetn), .source_toggle(voice_toggle),
        .source_voice(source_voice), .source_gate(source_gate), .source_retrigger(source_retrigger),
        .source_table(source_table), .source_ftw(source_ftw), .source_gain(source_gain),
        .command_valid(command_valid), .command_voice(command_voice), .command_gate(command_gate),
        .command_retrigger(command_retrigger), .command_table(command_table),
        .command_ftw(command_ftw), .command_gain(command_gain), .acknowledge_toggle(voice_ack_audio)
    );
    reverb_config_cdc reverb_cdc (
        .audio_clk(audio_clk), .audio_resetn(audio_resetn), .source_toggle(reverb_toggle),
        .source_enable(reverb_enable_source), .source_feedback(reverb_feedback_source),
        .source_wet(reverb_wet_source), .source_clear_clip(reverb_clear_source),
        .config_valid(reverb_config_valid), .config_enable(reverb_config_enable),
        .config_feedback(reverb_config_feedback), .config_wet(reverb_config_wet),
        .config_clear_clip(reverb_config_clear), .acknowledge_toggle(reverb_ack_audio)
    );
    wavetable_voice_engine_128 engine (
        .clk(audio_clk), .resetn(audio_resetn), .frame_tick(frame_tick),
        .master_enable(master_audio), .command_valid(command_valid), .command_voice(command_voice),
        .command_gate(command_gate), .command_retrigger(command_retrigger), .command_table(command_table),
        .command_ftw(command_ftw), .command_gain(command_gain),
        .active_mask(active_audio), .mixed_sample(dry_sample)
    );
    fdn_reverb reverb (
        .clk(audio_clk), .resetn(audio_resetn), .frame_tick(frame_tick), .dry_sample(dry_sample),
        .config_valid(reverb_config_valid), .config_enable(reverb_config_enable),
        .config_feedback(reverb_config_feedback), .config_wet(reverb_config_wet),
        .config_clear_clip(reverb_config_clear), .left_sample(left_reverb),
        .right_sample(right_reverb), .clip_flag(reverb_clip_audio)
    );
    i2s_tx transmitter (
        .clk(audio_clk), .resetn(audio_resetn), .left_sample(left_reverb),
        .right_sample(right_reverb), .bclk(bclk), .lrclk(lrclk),
        .sdata(sdata_o), .frame_tick(frame_tick)
    );
endmodule
