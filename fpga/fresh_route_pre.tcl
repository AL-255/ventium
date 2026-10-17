# Gives the external resource guard a native route-stage timestamp.
set f [open [file join $::env(VEN_FRESH_OUT) stages.tsv] a]
puts $f "route_design\t[clock seconds]"
close $f
puts "FRESH-ROUTE-BEGIN"
