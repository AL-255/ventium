# Heap-scan no-log completion marker

This hardware-only workaround retains the original `-condebug` setup and all
normal `Con_Printf` formatting.  It bypasses only the DOS file logger that
flushes buffered startup text through the known failing IDE PIO-write path.
The exact timedemo-result call writes a persistent `969` witness at
`DS:0x90b48` before invoking the original printer.  The marker is therefore
independent of `con_debuglog` and remains observable after the call returns.
