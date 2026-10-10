#!/usr/bin/env python3
"""Real tclsh, stubbed Vivado/filesystem: fail-closed placement-flow checks."""
import copy
import os
from pathlib import Path
import subprocess

SCRIPT = Path(__file__).with_name('place_completed_40mhz.tcl').resolve()
BASE = dict(version='2025.2', part='xczu15eg-ffvb1156-2-i', top='rk_ao486_bd_wrapper',
            status='synth_design Complete!', progress='100%', refresh='false',
            impl_status='Not started', impl_progress='0%', core='25.0', pl='10.0',
            black='0', placed='true', errors='0', hash='a'*64, directive='AltSpreadLogic_high',
            fail='', existing='0', missing='', help='RuntimeOptimized - Runs Default without bram_power_opt')
STUB = r'''
set argc 3
set argv [list /stub/project.xpr [string repeat a 64] /home/yukidama/external/tmp/stub-new-output]
rename file native_file
proc file {op args} {
    switch -- $op {
        normalize - dirname - join { return [native_file $op {*}$args] }
        isfile { return [expr {[native_file tail [lindex $args 0]] ne $::cfg(missing)}] }
        type { return file }
        size { return 1 }
        isdirectory { return 1 }
        lstat { if {$::cfg(existing)} { return {} }; error missing }
        mkdir { puts "CALL mkdir" }
        default { error "unexpected file op $op" }
    }
}
proc record {name args} {
    puts "CALL $name $args"
    if {$::cfg(fail) eq $name} { error "injected $name failure" }
}
proc version {args} { return $::cfg(version) }
proc exec {args} {
    if {[lrange $args 0 1] ne {sha256sum --}} { error "unexpected exec" }
    return "$::cfg(hash)  checkpoint.dcp"
}
proc current_project {} { return project }
proc get_filesets {args} { return sources }
proc get_runs {name} { return $name }
proc get_property {name object} {
    switch -- $name {
        PART { return $::cfg(part) }
        TOP { return $::cfg(top) }
        STATUS { if {$object eq "synth_1"} { return $::cfg(status) }; return $::cfg(impl_status) }
        PROGRESS { if {$object eq "synth_1"} { return $::cfg(progress) }; return $::cfg(impl_progress) }
        NEEDS_REFRESH { return $::cfg(refresh) }
        DIRECTORY { return /stub/synth_1 }
        PERIOD { if {$object eq "mmcm_clk"} { return $::cfg(core) }; return $::cfg(pl) }
        STEPS.PLACE_DESIGN.ARGS.DIRECTIVE { return $::cfg(directive) }
        default { error "unexpected property $name" }
    }
}
proc get_clocks {args} { return [lindex $args end] }
proc get_cells {args} { if {$::cfg(black)} { return blackbox }; return {} }
proc get_drc_checks {args} { return {MDRV-1 LUTLP-1} }
proc get_drc_violations {args} { if {$::cfg(errors)} { return violation }; return {} }
proc help {args} { return $::cfg(help) }
proc report_route_status {args} { record report_route_status {*}$args; return $::cfg(placed) }
proc set_param {args} {
    if {$args ne {general.maxThreads 1}} { error "unexpected concurrency" }
    record set_param {*}$args
}
proc opt_design {args} {
    if {$args ne {-directive RuntimeOptimized}} { error "wrong optimizer" }
    record opt_design {*}$args
}
proc place_design {args} {
    if {$args ne {-directive AltSpreadLogic_high}} { error "wrong placer" }
    record place_design {*}$args
}
foreach name {open_project open_run close_project write_checkpoint report_clocks
              report_utilization report_design_analysis report_high_fanout_nets
              report_timing_summary report_timing report_drc} {
    proc $name {args} "record $name {*}\$args"
}
'''


def run(name, settings, ok=False, admitted=False):
    if any('}' in v or '{' in v or '\n' in v for v in settings.values()):
        raise ValueError('unsafe Tcl test literal')
    assignments = '\n'.join(f'set ::cfg({k}) {{{v}}}' for k, v in settings.items())
    source = assignments + '\n' + STUB + f'\nif {{[catch {{source {{{SCRIPT}}}}} error]}} {{ puts stderr $error; exit 1 }}\n'
    env = os.environ.copy()
    result = subprocess.run(['tclsh'], input=source, text=True, capture_output=True, timeout=3, env=env)
    assert (result.returncode == 0) == ok, (name, result.stdout, result.stderr)
    assert ('NATIVE_PLACEMENT_DIAGNOSTIC_OK' in result.stdout) == ok, (name, result.stdout)
    if not admitted:
        assert 'CALL opt_design' not in result.stdout, (name, result.stdout)
    if ok:
        calls = [x.split()[1] for x in result.stdout.splitlines() if x.startswith('CALL ')]
        assert calls.count('place_design') == calls.count('opt_design') == 1
        assert calls.index('opt_design') < calls.index('place_design') < calls.index('close_project')
        assert calls.count('write_checkpoint') == 2
        assert 'routing_started=false timing_signoff=false hardware_accepted=false' in result.stdout
    print(name + ': PASS')


def main():
    run('native-success-control', BASE, ok=True, admitted=True)
    n = 1
    for key, values in dict(version=['2024.2'], part=['other'], top=['other'],
                            status=['synth_design ERROR'], progress=['99%'], refresh=['true', 'unknown'],
                            impl_status=['place_design Complete!'], impl_progress=['10%'],
                            core=['320', '22.222', 'NaN', 'Inf', '0', 'bad'], pl=['20', 'NaN'],
                            black=['1'], hash=['b'*64], directive=['Default'],
                            existing=['1'], help=['unknown']).items():
        for value in values:
            d = copy.deepcopy(BASE); d[key] = value
            run(key+'-'+value, d); n += 1
    for stage in ('opt_design', 'place_design', 'write_checkpoint', 'report_route_status',
                  'report_clocks', 'report_utilization', 'report_design_analysis',
                  'report_high_fanout_nets', 'report_timing_summary', 'report_timing', 'report_drc', 'close_project'):
        d = copy.deepcopy(BASE); d['fail'] = stage
        run('native-failure-'+stage, d, admitted=True); n += 1
    for key, value in [('placed', 'false'), ('errors', '1'), ('missing', 'placed.dcp'),
                       ('missing', 'optimized.dcp'), ('missing', 'core_setup.rpt')]:
        d = copy.deepcopy(BASE); d[key] = value
        run(key+'-'+value, d, admitted=True); n += 1
    print(f'PLACEMENT-FLOW-CONTROL-OK {n} checks; no Vivado or native artifacts produced')


if __name__ == '__main__':
    main()
