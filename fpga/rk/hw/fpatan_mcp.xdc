# fpatan_mcp.xdc — multicycle-path relaxation for the iterative FPATAN engine.
#
# fpu_fpatan.sv throttles its state machine to advance ONE FSM step every MCP=4 core clocks
# (localparam MCP, phase counter `ph`, gate `step_en`). Every intra-u_fpatan register therefore
# updates only once per 4 clk periods, so the ~315 ns combinational cones (128x128->256 wide
# multiplies feeding the state regs) have 4 clock periods to settle. Tell STA the same, so the
# FPATAN stops capping the core clock (it was the sole path forcing Fmax ~3 MHz; every other core
# path has large slack). FPATAN is a rare x87 op (D9 F3), so 4x its latency is negligible; the math
# is byte-identical (validated bit-exact vs qemu-i386, all 4 rounding modes, run-fpatan-gate.sh).
#
# Scope BOTH endpoints to inside u_fpatan (intra-engine paths only). Boundary paths (core->x_q/y_q
# load in S_IDLE, done_q/result_q sampled by the core) stay single-cycle and are NOT matched here.
# NOTE: XDC parsing does not allow Tcl `if`/`puts` — use plain constraint commands only.
set _fpatan_regs [get_cells -hierarchical -filter {NAME =~ *u_core/u_fpatan/* && IS_SEQUENTIAL}]
set_multicycle_path 4 -setup -from $_fpatan_regs -to $_fpatan_regs
set_multicycle_path 3 -hold  -from $_fpatan_regs -to $_fpatan_regs
