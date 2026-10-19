# PCAP / fpga_manager load: compressed bitstream, unused pins to none (no user PL I/O besides LEDs).
set_property BITSTREAM.GENERAL.COMPRESS TRUE     [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLNONE [current_design]
