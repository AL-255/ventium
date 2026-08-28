# Heap-scan result-only completion witness

This follows the FPGA-best no-render heap-scan executable exactly through
startup and loading.  It changes only the existing timedemo-result `Con_Printf`
call: a wrapper records `969` in Quake's `con_debuglog` word immediately before
calling the original printer with its unmodified arguments.  The hardware
watcher can therefore observe a genuine completion before the known late PIO
write failure, without perturbing the startup layout or disk-read trajectory.
