# Synth-probe clock constraint. 100 MHz target on the single core clock `clk`.
# Post-synth WNS against this period tells us the achievable Fmax for the
# as-is (un-reworked) core. This is a fit/timing PROBE, not a real constraint.
create_clock -period 10.000 -name clk [get_ports clk]
