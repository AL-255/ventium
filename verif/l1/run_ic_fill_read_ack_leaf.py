#!/usr/bin/env python3
"""Source-extracted I-fill/request cofactor miter; no whole-core claim."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time
import traceback

import prepare_ic_fill_read_ack as recipe
from run_payload_fetch_kind_leaf import extract

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
MODEL = 'e6d2b404b1613b200d673075d4d1b325c3e1c681db4e81516e038dfdef4d5c46'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def source_text(core, bus, template):
    frontend, requests, branch = extract(core, bus)
    module, tb = template.split('\nmodule tb_ic_fill_read_ack;', 1)
    original = recipe.fill_body(core)
    candidate = recipe.fill_body(recipe.transform(core))
    # Negative controls alter the actual candidate's guards, not expectations.
    candidate = candidate.replace('!pipe_mem_active_q &&',
                                  '(!pipe_mem_active_q || mutant==3) &&')
    candidate = candidate.replace('!exec_flush_all', '(!exec_flush_all || mutant==4)')
    variants = []
    for name, body in (('reference', original), ('candidate', candidate)):
        variants.append(module.replace('module fill_permit(', 'module fill_'+name+'(')
            .replace('FRONTEND', frontend).replace('REQUESTS', requests)
            .replace('BRANCH', branch).replace('FILL_BODY', body))
    return '\n'.join(variants)+'\nmodule tb_ic_fill_read_ack;'+tb


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'out'):
        ap.add_argument('--'+name, type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent, out = args.parent.resolve(strict=True), args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 4*1024**3
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    old = json.loads((parent/'build-started.json').read_text())
    built = json.loads((parent/'build-closed.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(parent/'obj/tb_ventium') == MODEL
    core, bus = [parent/'candidate/rtl/core'/n for n in ('core.sv', 'core_bus_driver.svh')]
    for path in (core, bus):
        assert sha(path) == old['pins'][str(path)]
    changed = recipe.transform(core.read_text())
    flags = next(s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES='))
    defs = set(re.findall(r'\+define\+(\w+)', flags))
    assert len(defs) == 150 and {'VEN_IC_BRAM', 'VEN_FP_PIPE', 'VEN_L1_AXI', 'VEN_FP_LOAD_EARLY_CMD'} <= defs
    assert 'VEN_UOPCACHE' not in defs
    out.mkdir()
    (out/'core.sv').write_text(changed)
    tb = out/'tb_ic_fill_read_ack.sv'
    template = HERE/'ic_fill_read_ack_leaf.svh'
    tb.write_text(source_text(core.read_text(), bus.read_text(), template.read_text()))
    sources = [Path(__file__), Path(recipe.__file__), HERE/'run_payload_fetch_kind_leaf.py',
               core, bus, template, tb, out/'core.sv', parent/'build-started.json', parent/'build-closed.json']
    pins = {str(path): sha(path) for path in sources}

    def save(name, value):
        with (out/name).open('x') as stream:
            json.dump(value, stream, indent=2)

    def run(name, command, timeout):
        save(name+'.command.json', list(map(str, command)))
        with (out/(name+'.log')).open('x') as stream:
            proc = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                                  timeout=timeout, pass_fds=(9,))
        return proc.returncode, (out/(name+'.log')).read_text()

    save('started.json', dict(pins=pins, defines=sorted(defs), parent=str(parent),
        invocation=os.environ['INVOCATION_ID'], affinity=sorted(os.sched_getaffinity(0)),
        abstraction='18 request guards + 6 fill/ACK guards exhaustive; fault cancellation is input-only'))
    begin = time.monotonic()
    result = dict(passed=False, errors=[], rows=[], whole_core=False, standard_suite=False,
                  timing_verified=False, gameplay_ipc=None)
    try:
        for profile in ('early', 'fallback'):
            enabled = defs if profile == 'early' else defs-{'VEN_FP_LOAD_EARLY_CMD'}
            command = [os.environ['VENTIUM_VERILATOR_BIN'], '--binary', '--timing', '--assert',
                '-j', '32', '-Wno-fatal', '-Wno-UNUSED', *['-Werror-'+w for w in
                ('IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                '--top-module', 'tb_ic_fill_read_ack', '--Mdir', out/profile,
                *['+define+'+d for d in sorted(enabled)], tb]
            rc, _ = run(profile+'-build', command, 180)
            assert rc == 0, (profile, 'build', rc)
            binary = out/profile/'Vtb_ic_fill_read_ack'
            for mutant in ((0, 1, 2, 3, 4) if profile == 'early' else (0,)):
                name = profile+'-'+str(mutant)
                rc, log = run(name, [binary, '+mutant='+str(mutant)], 120)
                row = dict(profile=profile, mutant=mutant, build_exit=0, native_exit=rc,
                           binary_sha256=sha(binary), log_sha256=sha(out/(name+'.log')))
                if mutant:
                    assert rc != 0 and 'IC-FILL-EQUIV' in log, (profile, mutant, rc)
                else:
                    match = re.search(r'^IC-FILL-READ-ACK-OK (.+)$', log, re.M)
                    assert rc == 0 and match, (profile, mutant, rc)
                    row['counts'] = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', match[1])}
                    assert all(row['counts'].values())
                result['rows'].append(row)
        result['passed'] = True
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins=pins, pins_unchanged=all(sha(p)==h for p, h in pins.items()),
                  seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save('closed.json', result)
    print(json.dumps({k: v for k, v in result.items() if k != 'pins'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
