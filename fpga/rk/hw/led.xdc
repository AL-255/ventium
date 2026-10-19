# RK-XCZU15EG-F base-board PL user LEDs (LVCMOS33, active-high) — the only external PL pins.
set_property -dict {PACKAGE_PIN AP12 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN AN14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN AP14 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN C16  IOSTANDARD LVCMOS33} [get_ports {led[3]}]
