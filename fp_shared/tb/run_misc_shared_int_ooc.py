#!/usr/bin/env python3
"""Measure this private sharing proposal only after both native leaf miters pass.

One normal exclusive Vivado family, 4 GiB RAM/1 GiB swap, ten-minute bound.
Do not launch while another intentional Vivado family is running: the global
launcher deliberately stops old Vivado processes. This tool refuses it first.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from run_misc_shared_int import sha, save


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--leaf', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    assert __debug__, 'assertions required'
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert scratch.stat().st_dev != repo.stat().st_dev
    assert Path(os.environ['TMPDIR']).resolve(strict=True).is_relative_to(scratch)
    leaf = args.leaf.resolve(strict=True)
    out = args.out.resolve()
    assert leaf.is_relative_to(scratch) and out.is_relative_to(scratch) and not out.exists()
    plan = json.loads((leaf/'prepared.json').read_text())
    closed = json.loads((leaf/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['error'] is None
    assert len(closed['results']) == 2
    for row in closed['results']:
        assert row['passed'] and row['build_native_exit'] == row['run_native_exit'] == 0
        assert sha(leaf/row['profile']/'obj/Vtb_misc_shared_int') == row['model_sha256']
    assert all(sha(p) == h for p,h in plan['pins'].items())
    state = subprocess.check_output(['systemctl','--user','show','ventium-vivado.scope',
                                   '-p','ActiveState','--value'], text=True).strip()
    assert state in ('inactive','failed'), 'wait for the active native FPGA run to close'
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    assert shutil.disk_usage(scratch).free > 2*1024**3
    out.mkdir()
    (out/'clock.xdc').write_text('create_clock -name core_clk -period 25.000 [get_ports clk]\n')
    # Work from an independent byte-identical input copy; leave the miter tree immutable.
    for name in ('original.sv','candidate.sv','fpu_x87_pkg.sv','ventium_decode_pkg.sv'):
        shutil.copyfile(leaf/name, out/name)
    script = Path(__file__).with_name('misc_shared_int_ooc.tcl').resolve()
    evidence = [Path(__file__), script, leaf/'prepared.json', leaf/'closed.json',
                repo/'fpga/run_vivado_exclusive.sh', repo/'tools/build_scope.sh', *out.iterdir()]
    pins = dict(plan['pins']) | {str(p):sha(p) for p in evidence}
    command = ['timeout','--signal=TERM','--kill-after=30s','600s',
        str(repo/'fpga/run_vivado_exclusive.sh'),'-mode','batch',
        '-log',str(out/'native.log'),'-journal',str(out/'native.jou'),
        '-source',str(script),'-tclargs',str(out),str(out/'reports')]
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VENTIUM_'))}
    env.update(TMPDIR=str(out),VENTIUM_VIVADO_MEMORY_MAX='4G',
        VENTIUM_VIVADO_MEMORY_SWAP_MAX='1G',VENTIUM_VIVADO_LOCK_DIR=str(scratch))
    save(out/'started.json',dict(command=command,pins=pins,architecture_qualified=False,
        whole_core_test=False,physical_board=False,gameplay_ipc=None))
    started = time.monotonic()
    with (out/'guard.log').open('xb') as stream:
        native = subprocess.run(command,cwd=out,env=env,stdout=stream,stderr=subprocess.STDOUT)
    stable = all(sha(p) == h for p,h in pins.items())
    artifacts = [out/'reports'/f'{variant}{suffix}' for variant in ('original','shared')
        for suffix in ('-utilization.rpt','-timing.rpt','-reg-timing.rpt','.dcp')]
    result = dict(native_exit=native.returncode,pins_unchanged=stable,seconds=time.monotonic()-started,
        completed=native.returncode==0 and stable and all(p.is_file() and p.stat().st_size>0 for p in artifacts)
        and 'MISC-SHARED-INT-OOC-PAIR-OK' in (out/'native.log').read_text(),
        timing_signoff=False,fpga_qualified=False,gameplay_ipc=None)
    save(out/'closed.json',result)
    print(json.dumps(result))
    return 0 if result['completed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
