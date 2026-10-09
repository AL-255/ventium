#!/usr/bin/env python3
"""Compile the real short-capture equation; reject boundary/owner/snoop hazards."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--candidate', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
assert __debug__ and args.out.resolve().is_relative_to(scratch)
assert Path(os.environ['TMPDIR']).resolve() == scratch
subprocess.run([HERE.parents[1] / 'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
args.out.mkdir()
source = args.candidate / 'rtl/core/core.sv'
text = re.sub(r'//[^\n]*', '', source.read_text())
equations = re.findall(r'  assign pipe_fp_short_window_ok\s*=.*?;', text, re.S)
assert len(equations) == 1
generated = args.out / 'fp_short_equation.svh'
generated.write_text(equations[0] + '\n')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
pins = {str(p): sha(p) for p in (source, generated, HERE / 'tb_fp_short_window.sv', Path(__file__))}
(args.out / 'pins.json').write_text(json.dumps(pins, indent=2))
command = ['/tools/verilator/v5.046/bin/verilator', '--binary', '--assert', '-sv', '-Wall',
           '-Wno-UNUSED', '-Wno-fatal', '-j', '32', '+define+VEN_L1_AXI',
           *['-Werror-' + c for c in ('IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
           '+incdir+' + str(args.out), '--top-module', 'tb_fp_short_window',
           '-Mdir', str(args.out / 'obj'), str(HERE / 'tb_fp_short_window.sv')]
for name, argv in [('build', command), ('run', [str(args.out / 'obj/Vtb_fp_short_window')])]:
    (args.out / (name + '.command.json')).write_text(json.dumps(argv, indent=2))
    with (args.out / (name + '.log')).open('x') as log:
        rc = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, timeout=120).returncode
    (args.out / (name + '.exit.json')).write_text(json.dumps(dict(native_exit=rc)))
    assert rc == 0, (name, rc)
match = re.search(r'FP-SHORT-PREDICATE-OK checks=(\d+)', (args.out / 'run.log').read_text())
assert match and int(match[1]) == 492
assert all(sha(Path(p)) == h for p, h in pins.items())
(args.out / 'closed.json').write_text(json.dumps(dict(passed=True, checks=492,
    inputs_unchanged=True, binary_sha256=sha(args.out / 'obj/Vtb_fp_short_window')), indent=2))
print('FP-SHORT-PREDICATE-UNIT-OK checks=492', flush=True)
