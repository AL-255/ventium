#!/usr/bin/env python3
"""Exercise real wrapper profiles and compare exact expanded flow bodies.

Usage: python3 -B fpga/test_synth_profiles.py FROZEN_EXPORT
Host-only checks; use probe_synth_profile.tcl separately for native Vivado.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    frozen = Path(sys.argv[1]).resolve(strict=True)
    here = Path(__file__).resolve().parent
    scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
    assert __debug__ and scratch == Path('/home/yukidama/external/tmp').resolve(strict=True)
    command = ['tclsh', str(here/'test_rk_wrapper.tcl'),
        str(here/'create_project_3mhz_wrapper.tcl'), str(frozen/'flow'),
        str(frozen/'defines.txt'), str(frozen/'ventium'), str(frozen/'template')]
    checks = 0
    for profile in ('legacy', 'balanced', 'logic_only', 'no_timing_driven', '', 'balanced;exit 0'):
        run = subprocess.run(command+[profile],capture_output=True,text=True,timeout=15)
        good = profile in ('legacy', 'balanced', 'logic_only')
        assert (run.returncode == 0) == good, (profile, run.stdout, run.stderr)
        assert ('RK-WRAPPER-STATIC-OK' in run.stdout) == good
        if not good: assert 'VEN_FPGA_BUILD_PROFILE must be' in run.stderr
        checks += 1
    # Intercept the final board script but do not modify or execute it. The
    # new profile must change exactly one project-run property, not constraints,
    # RTL defines, run fan-out, placement or routing choices.
    with tempfile.TemporaryDirectory(prefix='ventium-synth-profiles.',dir=scratch) as temp:
        root=Path(temp)
        capture=root/'capture.tcl'
        capture.write_text('''
lassign $argv wrapper frozen output profile
set ::env(VEN_FPGA_CORE_MHZ) 40
set ::env(VEN_FPGA_JOBS) 1
set ::env(VEN_FPGA_BUILD_PROFILE) $profile
foreach {knob suffix} {VEN_FPGA_FLOW_ROOT flow VEN_FPGA_SOURCE_ROOT ventium VEN_FPGA_TEMPLATE_ROOT template VEN_FPGA_DEFINE_FILE defines.txt} {
    set ::env($knob) [file join $frozen $suffix]
}
proc set_param {name value} { if {$name ne "general.maxThreads" || $value != 1} { error "bad bound" } }
rename uplevel native_uplevel
proc uplevel {level body} {
    if {$level ne "#0"} { error "unexpected level" }
    set fh [open $::output {WRONLY CREAT EXCL}]
    puts -nonewline $fh $body
    close $fh
}
source $wrapper
''')
        for profile in ('balanced','logic_only'):
            subprocess.run(['tclsh',str(capture),str(here/'create_project_3mhz_wrapper.tcl'),
                str(frozen),str(root/(profile+'.tcl')),profile],check=True,
                stdout=subprocess.DEVNULL,timeout=15)
        balanced=(root/'balanced.tcl').read_text()
        logic=(root/'logic_only.tcl').read_text()
        addition='\nset_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-no_timing_driven} -objects [get_runs synth_1]\n\n'
        assert logic.count(addition)==1 and logic.replace(addition,'')==balanced
        checks += 1
    print(f'SYNTH-PROFILES-STATIC-OK checks={checks}; no hardware acceptance')


if __name__=='__main__': main()
