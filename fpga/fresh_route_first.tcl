# Reach routing directly after placement. This does not suppress checkpoints,
# router timing/hold repair, or final reports; only optional phys_opt passes.
proc fresh_route_first {obj} {
    foreach step {PHYS_OPT_DESIGN POST_ROUTE_PHYS_OPT_DESIGN} {
        set_property STEPS.${step}.IS_ENABLED false $obj
        set_property STEPS.${step}.ARGS.DIRECTIVE Default $obj
        set_property -name "STEPS.${step}.ARGS.MORE OPTIONS" -value {} -objects $obj
        if {[get_property STEPS.${step}.IS_ENABLED $obj] ni {0 false} ||
            [get_property STEPS.${step}.ARGS.DIRECTIVE $obj] ne "Default" ||
            [get_property "STEPS.${step}.ARGS.MORE OPTIONS" $obj] ne ""} {
            error "route-first physical stage policy drift: $step"
        }
    }
}
