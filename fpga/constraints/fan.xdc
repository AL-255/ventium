# fpga/constraints/fan.xdc — KV260 cooling-fan output pin.
# The temperature-controlled fan (ven_fan_ctrl, driven by a PL SYSMONE4) drives
# the fan transistor on KV260 package pin A12 (LVCMOS33) — per Tai-Min's
# hackster.io "KV260 temperature-controlled cooling fan". Loaded only when the
# FAN_CTRL build knob is on (the external port `fan_pin` exists only then).
set_property -dict { PACKAGE_PIN A12  IOSTANDARD LVCMOS33 } [get_ports fan_pin]
# The fan PWM is a slow (~8 Hz) control output — exclude it from timing analysis.
set_false_path -to [get_ports fan_pin]
