# The historical exporter merged SLICE, BRAM and DSP coordinate namespaces,
# omitted empty sites, and guessed module ownership from substrings.
# Reject its lossy CSV workflow instead of silently generating misleading maps.
error "Retired mixed-coordinate exporter. Use fpga/scripts/export_physical_map.tcl routed.dcp empty-output-dir through fpga/run_vivado_exclusive.sh; then render_device_view.py --export ... --route-log ... --output ... --image-id ..."
