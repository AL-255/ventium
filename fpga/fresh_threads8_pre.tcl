# Vivado 2025.2 can omit a default-valued general.maxThreads from the native
# worker script. Read the worker's real setting; never infer it from omission
# or silently change a mismatched setting to make an audit pass.
if {[version -short] ne "2025.2"} {error "thread readback requires Vivado 2025.2"}
set fresh_observed_threads [get_param general.maxThreads]
if {$fresh_observed_threads ne "8"} {error "native worker thread mismatch: $fresh_observed_threads"}
puts "FRESH-NATIVE-THREADS-CHECK observed=$fresh_observed_threads"
unset fresh_observed_threads
