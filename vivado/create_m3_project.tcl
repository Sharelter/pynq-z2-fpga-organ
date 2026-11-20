# Build the PYNQ-Z2 Milestone-3 128-voice wavetable organ overlay.
# Usage: vivado -mode batch -source vivado/create_m3_project.tcl -tclargs build
set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ..]]
set build_dir [file join $repo_dir build]
set project_dir [file join $build_dir organ_m3_z2]
set do_build [expr {[llength $argv] > 0 && [lindex $argv 0] eq "build"}]
if {[info exists ::env(PYNQ_BOARD_REPO)]} {
    set_param board.repoPaths [list [file normalize $::env(PYNQ_BOARD_REPO)]]
}
file mkdir $build_dir
create_project organ_m3_z2 $project_dir -part xc7z020clg400-1 -force
set board_vlnv tul.com.tw:pynq-z2:part0:1.0
if {[llength [get_board_parts -quiet $board_vlnv]] == 0} {
    error "PYNQ-Z2 board files not found; set PYNQ_BOARD_REPO."
}
set_property board_part $board_vlnv [current_project]
set_property target_language Verilog [current_project]
add_files -norecurse [glob [file join $repo_dir rtl *.v]]
foreach mem [glob [file join $repo_dir rtl *.mem]] {
    add_files -norecurse $mem
    set_property file_type {Memory Initialization Files} [get_files $mem]
}
set audio_xdc [file join $script_dir pynq_z2_audio.xdc]
add_files -fileset constrs_1 -norecurse $audio_xdc
set_property USED_IN_SYNTHESIS false [get_files $audio_xdc]
update_compile_order -fileset sources_1

create_bd_design organ_m3_z2
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1"} $ps7
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_I2C1_PERIPHERAL_ENABLE {1} CONFIG.PCW_I2C1_I2C1_IO {EMIO}] $ps7
make_bd_intf_pins_external [get_bd_intf_pins ps7/IIC_1]
set_property name IIC_1 [get_bd_intf_ports IIC_1_0]

set axi_rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 axi_rst]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins ${axi_rst}/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins ${axi_rst}/ext_reset_in]

set mclk [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 codec_mclk]
set_property -dict [list CONFIG.PRIM_IN_FREQ {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {10.000} CONFIG.USE_LOCKED {true} \
    CONFIG.RESET_TYPE {ACTIVE_LOW} CONFIG.RESET_PORT {resetn}] $mclk
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ${mclk}/clk_in1]
connect_bd_net [get_bd_pins ${axi_rst}/peripheral_aresetn] [get_bd_pins ${mclk}/resetn]

set i2s_clock [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 i2s_clock]
set_property -dict [list CONFIG.PRIM_IN_FREQ {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {49.152} CONFIG.USE_LOCKED {true} \
    CONFIG.RESET_TYPE {ACTIVE_LOW} CONFIG.RESET_PORT {resetn}] $i2s_clock
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ${i2s_clock}/clk_in1]
connect_bd_net [get_bd_pins ${axi_rst}/peripheral_aresetn] [get_bd_pins ${i2s_clock}/resetn]

set audio_rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 audio_rst]
connect_bd_net [get_bd_pins ${i2s_clock}/clk_out1] [get_bd_pins ${audio_rst}/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins ${audio_rst}/ext_reset_in]
connect_bd_net [get_bd_pins ${i2s_clock}/locked] [get_bd_pins ${audio_rst}/dcm_locked]

set organ [create_bd_cell -type module -reference organ_m3_i2s organ_m3_i2s_0]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ${organ}/s_axi_aclk]
connect_bd_net [get_bd_pins ${axi_rst}/peripheral_aresetn] [get_bd_pins ${organ}/s_axi_aresetn]
connect_bd_net [get_bd_pins ${i2s_clock}/clk_out1] [get_bd_pins ${organ}/audio_clk]
connect_bd_net [get_bd_pins ${audio_rst}/peripheral_aresetn] [get_bd_pins ${organ}/audio_resetn]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/ps7/M_AXI_GP0" Clk "Auto" intc_ip "New AXI Interconnect"} \
    [get_bd_intf_pins ${organ}/S_AXI]
assign_bd_address -offset 0x43C00000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces ps7/Data] \
    [get_bd_addr_segs ${organ}/S_AXI/reg0] -force
foreach name {bclk lrclk sdata_o} {
    set port [create_bd_port -dir O $name]
    connect_bd_net $port [get_bd_pins ${organ}/$name]
}
set mclk_port [create_bd_port -dir O -type clk audio_clk_10MHz]
connect_bd_net $mclk_port [get_bd_pins ${mclk}/clk_out1]
set codec_addr [create_bd_port -dir O -from 1 -to 0 codec_addr]
set addr_const [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 codec_addr_const]
set_property -dict [list CONFIG.CONST_WIDTH {2} CONFIG.CONST_VAL {3}] $addr_const
connect_bd_net $codec_addr [get_bd_pins ${addr_const}/dout]

validate_bd_design
save_bd_design
make_wrapper -files [get_files organ_m3_z2.bd] -top
add_files -norecurse [file join $project_dir organ_m3_z2.gen sources_1 bd \
    organ_m3_z2 hdl organ_m3_z2_wrapper.v]
set_property top organ_m3_z2_wrapper [current_fileset]
update_compile_order -fileset sources_1

if {$do_build} {
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "Implementation failed" }
    open_run impl_1
    report_timing_summary -file [file join $build_dir m3_timing_summary.rpt]
    report_utilization -file [file join $build_dir m3_utilization.rpt]
    report_clocks -file [file join $build_dir m3_clocks.rpt]
    set setup_slack [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
    set hold_slack [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
    if {$setup_slack < 0.0 || $hold_slack < 0.0} {
        error "Timing failed: setup=$setup_slack hold=$hold_slack"
    }
    file copy -force [get_property DIRECTORY [get_runs impl_1]]/organ_m3_z2_wrapper.bit \
        [file join $build_dir organ_m3.bit]
    file copy -force [file join $project_dir organ_m3_z2.gen sources_1 bd \
        organ_m3_z2 hw_handoff organ_m3_z2.hwh] [file join $build_dir organ_m3.hwh]
    puts "Milestone-3 overlay: [file join $build_dir organ_m3.bit]"
} else { puts "Project created; add -tclargs build to implement." }
