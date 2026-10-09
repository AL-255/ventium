#!/usr/bin/env python3
"""Check extracted candidate hold/admission equations, default-off and enabled."""
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
source = args.candidate / 'rtl/core/core_fp_async.svh'
text = source.read_text()
assert 'VEN_FP_POP_DRAIN' in text
# Comments contain semicolons; do not truncate the production expression at
# prose punctuation. The async-disabled arms intentionally tie hold to zero.
equation_text = re.sub(r'//[^\n]*', '', text)
expressions = []
for name in ('fp_async_stream_shape', 'fp_async_hold'):
    match = re.findall(r'  assign ' + name + r'\s*=.*?;', equation_text, re.S)
    if name == 'fp_async_hold':
        match = [m for m in match if 'fp_async_pending &&' in m]
    assert len(match) == 1
    expressions.append(match[0])
generated = args.out / 'pop_drain_equations.svh'
generated.write_text('\n'.join(expressions) + '\n')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
pins = {str(p): sha(p) for p in (source, generated, HERE / 'tb_fp_pop_drain.sv', Path(__file__))}
(args.out / 'pins.json').write_text(json.dumps(pins, indent=2))
rows = []
for enabled in (False, True):
    leaf = args.out / ('on' if enabled else 'off')
    leaf.mkdir()
    macros = ['VEN_FP_ASYNC_STREAM', 'VEN_FP_FXCH_QUEUE', 'VEN_FP_OPERAND_OVERLAP',
              'VEN_FP_REG_ADMIT', 'VEN_FP_MEM_QUEUE', 'VEN_FP_ASYNC_MEM',
              'VEN_FP_ASYNC_STACK', 'VEN_FP_ASYNC_BRANCH']
    if enabled: macros.append('VEN_FP_POP_DRAIN')
    cmd = ['/tools/verilator/v5.046/bin/verilator', '--binary', '--assert', '-sv', '-Wall',
           '-Wno-UNUSED', '-Wno-fatal', '-j', '32',
           *['-Werror-' + c for c in ('IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
           *['+define+' + m for m in macros], '+incdir+' + str(args.out),
           '--top-module', 'tb_fp_pop_drain', '-Mdir', str(leaf / 'obj'), str(HERE / 'tb_fp_pop_drain.sv')]
    for name, command in [('build', cmd), ('run', [str(leaf / 'obj/Vtb_fp_pop_drain')])]:
        (leaf / (name + '.command.json')).write_text(json.dumps(command, indent=2))
        with (leaf / (name + '.log')).open('x') as log:
            rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=120).returncode
        assert rc == 0, (name, rc, leaf)
    match = re.search(r'FP-POP-DRAIN-PREDICATES-OK checks=(\d+)', (leaf / 'run.log').read_text())
    assert match and int(match[1]) == 102
    rows.append(dict(enabled=enabled, checks=int(match[1]), binary_sha256=sha(leaf / 'obj/Vtb_fp_pop_drain')))
assert all(sha(Path(p)) == h for p, h in pins.items())
(args.out / 'closed.json').write_text(json.dumps(dict(passed=True, rows=rows, inputs_unchanged=True), indent=2))
print('FP-POP-DRAIN-PREDICATE-UNIT-OK checks=204', flush=True)
