# OOC-synth the uopcache to confirm the store_slots_a/b RAM-equivalence DECLONE
# (residual fast-path fetch corruption; same class as the icache, but uopcache lacks
# the Method-B word-reversal). Watch for "[Synth 8-223] decloning ... RAMB36".
set ROOT [file normalize [file dirname [info script]]/../..]
set OUT  $ROOT/fpga/build/uopcache_ooc
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART uop_ooc
read_verilog -sv $ROOT/rtl/ventium_pkg.sv
read_verilog -sv $ROOT/rtl/core/ventium_alu_pkg.sv
read_verilog -sv $ROOT/rtl/core/ventium_decode_pkg.sv
read_verilog -sv $ROOT/rtl/core/decode.sv
read_verilog -sv $ROOT/rtl/mem/uopcache.sv
synth_design -top uopcache -part $PART -mode out_of_context \
    -verilog_define {VTM_NO_DPI VEN_UOPCACHE VEN_CACHE_HALF}
report_utilization -file $OUT/util.rpt
write_verilog -force -mode funcsim $OUT/uopcache_funcsim.v
puts "UOPCACHE_OOC_DONE"
