# Pure Tcl, also regression-tested under tclsh without Vivado.
proc require_zero_apr_target {report} {
    set directives [regexp -all -inline {\|\s*Incremental Directive\s*\|\s*([^|]+)\|} $report]
    set targets [regexp -all -inline {\|\s*Target WNS\s*\|\s*([^|]+)\|} $report]
    if {[llength $directives] != 2 || [string trim [lindex $directives 1]] ne "TimingClosure" ||
        [llength $targets] != 2} {error "missing/ambiguous TimingClosure policy"}
    set target [string trim [lindex $targets 1]]
    if {![string is double -strict $target] || $target != 0.0} {
        error "native target WNS is not zero"
    }
}
