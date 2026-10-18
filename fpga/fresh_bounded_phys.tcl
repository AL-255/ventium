# Explicit operations avoid the repeated Explore/AggressiveExplore loops.
# These are operation-bounded, not individual wall-clock deadlines; the owner
# still enforces the total implementation deadline. No physical retiming here.
proc fresh_bounded_phys {obj} {
    foreach {step options} {
        PHYS_OPT_DESIGN {-fanout_opt -placement_opt -restruct_opt -equ_drivers_opt}
        POST_ROUTE_PHYS_OPT_DESIGN {-placement_opt -routing_opt -restruct_opt -hold_fix}
    } {
        set_property STEPS.$step.IS_ENABLED true $obj
        # Native Vivado must omit this default directive when serializing
        # explicit operations: -directive and operation flags cannot coexist.
        set_property STEPS.$step.ARGS.DIRECTIVE Default $obj
        set_property -name "STEPS.$step.ARGS.MORE OPTIONS" -value $options -objects $obj
        if {[get_property STEPS.$step.ARGS.DIRECTIVE $obj] ne "Default" ||
            [get_property "STEPS.$step.ARGS.MORE OPTIONS" $obj] ne $options ||
            [get_property STEPS.$step.IS_ENABLED $obj] ni {1 true}} {
            error "bounded physical optimization property drift: $step"
        }
    }
}
