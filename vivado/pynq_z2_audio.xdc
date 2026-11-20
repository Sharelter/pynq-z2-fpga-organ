## PYNQ-Z2 ADAU1761 pins. These match the official PYNQ-Z2 base overlay.

## PS I2C1 routed through EMIO to the codec.
set_property -dict {PACKAGE_PIN U9 IOSTANDARD LVCMOS33} [get_ports IIC_1_scl_io]
set_property PULLUP true [get_ports IIC_1_scl_io]
set_property -dict {PACKAGE_PIN T9 IOSTANDARD LVCMOS33} [get_ports IIC_1_sda_io]
set_property PULLUP true [get_ports IIC_1_sda_io]

## Codec clocks and playback serial data.
set_property -dict {PACKAGE_PIN U5  IOSTANDARD LVCMOS33} [get_ports audio_clk_10MHz]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports bclk]
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports lrclk]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports sdata_o]

## Both ADAU1761 address straps high selects 7-bit I2C address 0x3b.
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports {codec_addr[0]}]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports {codec_addr[1]}]

## AXI control and audio sample logic deliberately communicate through the
## acknowledged CDC mailboxes and status synchronizers. Treat the two clock
## domains as asynchronous so implementation does not optimize for a spurious
## MMCM phase relationship.
set_clock_groups -asynchronous \
    -group [get_clocks clk_fpga_0] \
    -group [get_clocks -regexp {clk_out1_.*i2s_clock.*}]
