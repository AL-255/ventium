#!/usr/bin/env python3
"""Actual-decoder/source-extracted priming miter; does not qualify the full CPU."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import sys
import time
import traceback

import prepare_prime_noack as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO/'verif/issue_uv'))
from run_fp_nomem_exec_leaf import statement


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def first_equation(source, name):
    # Enabled arm plus disabled fallback. Include directives inside the
    # expression (not an assumed preprocessing result).
    matches = re.findall(r'  assign '+re.escape(name)+r'\s*=.*?;', source, re.S)
    if len(matches) != 2 or not re.search(r"= (?:1'b0|[34]'d0);$", matches[1]):
        raise ValueError('enabled/disabled equation drift: '+name)
    return matches[0]+'\n'


def equations(inputs, changed):
    core = inputs['rtl/core/core.sv']
    text = statement(core, 'pipe_u_eff')
    clean = re.sub(r'/\*.*?\*/|//[^\n]*', '', core, flags=re.S)
    text += clean[clean.index('  assign fp_sys_bail ='):].split(';', 1)[0]+';\n'
    for name in ('pipe_new_load_req', 'pipe_new_store_req', 'pipe_new_mem_req', 'pipe_load_req', 'pipe_store_req'):
        text += statement(core, name, False)
    text += statement(core, 'pipe_mem_wait')
    text += statement(core, 'pipe_fp_live_arm').replace('pipe_fp_live_arm', 'reference_arm')
    new = statement(changed['rtl/core/core.sv'], 'pipe_prime_live_arm')
    text += new.replace('pipe_prime_live_arm', 'raw_candidate_arm')
    assert new.count('fsm_case_enabled') == 1
    text += new.replace('pipe_prime_live_arm', 'unguarded_arm').replace('fsm_case_enabled', "1'b1")
    for kind, leaf, fields in (
        ('agi', 'core_agi_resident_prime.svh', ('select', 'width', 'offer')),
        ('ref', 'core_ref_operand_prime.svh', ('select', 'bytes', 'strb', 'offer'))):
        path = 'rtl/core/'+leaf
        for field in fields:
            text += first_equation(inputs[path], kind+'_prime_'+field)
        old = recipe.statement(inputs[path], kind+'_prime_commit', starts=kind+'_prime_offer')
        new = recipe.statement(changed[path], kind+'_prime_commit', starts=kind+'_prime_offer')
        text += old.replace(kind+'_prime_commit', 'reference_'+kind).replace('pipe_fp_live_arm', 'reference_arm')+'\n'
        text += new.replace(kind+'_prime_commit', 'candidate_'+kind).replace('pipe_prime_live_arm', 'candidate_arm')+'\n'
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'out'):
        ap.add_argument('--'+name, type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent, out = args.parent.resolve(strict=True), args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 4*1024**3
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    out.mkdir()
    inputs = {name: (parent/'candidate'/name).read_text() for name in recipe.HASHES}
    changed = recipe.transform(inputs)
    started = json.loads((parent/'build-started.json').read_text())
    closed = json.loads((parent/'build-closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
    assert closed['binary_sha256'] == sha(parent/'obj/tb_ventium')
    for name in recipe.HASHES:
        assert sha(parent/'candidate'/name) == started['pins'][str(parent/'candidate'/name)]
        target = out/'candidate'/name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(changed[name])
    flags = next(s for s in started['command'] if s.startswith('VL_EXTRA_DEFINES='))
    defs = set(re.findall(r'\+define\+(\w+)', flags))
    assert len(defs) == 150 and {'VEN_RAW_AGI_PRIME', 'VEN_REF_OPERAND_PRIME', 'VEN_SYS_FASTPATH', 'VEN_FP_MEM_ADMIT'} <= defs
    # Standalone module has no retire observer. Only its leaf uses VTM_NO_DPI.
    defs.add('VTM_NO_DPI')
    modules = [parent/'candidate/rtl'/p for p in (
        'ventium_pkg.sv', 'core/ventium_alu_pkg.sv', 'core/ventium_decode_pkg.sv', 'core/decode.sv')]
    sources = [Path(__file__), Path(recipe.__file__), REPO/'verif/issue_uv/run_fp_nomem_exec_leaf.py',
               HERE/'prime_noack_leaf.svh', parent/'build-started.json', parent/'build-closed.json',
               *modules, *[parent/'candidate'/p for p in recipe.HASHES],
               *[out/'candidate'/p for p in recipe.HASHES]]
    tb = out/'tb_prime_noack.sv'
    template = (HERE/'prime_noack_leaf.svh').read_text()
    marker = '// ASSIGNMENTS_INSERTED_FROM_FROZEN_CORE'
    assert template.count(marker) == 1
    tb.write_text('module tb_prime_noack;\nimport ventium_pkg::*;\nimport ventium_alu_pkg::*;\nimport ventium_decode_pkg::*;\n'+
                  template.replace(marker, equations(inputs, changed))+'\nendmodule\n')
    sources.append(tb)
    pins = {str(p): sha(p) for p in sources}

    def save(name, value):
        with (out/name).open('x') as f:
            json.dump(value, f, indent=2)

    def run(name, command, timeout):
        save(name+'.command.json', list(map(str, command)))
        with (out/(name+'.log')).open('x') as stream:
            p = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout, pass_fds=(9,))
        return p.returncode, (out/(name+'.log')).read_text()

    result = dict(passed=False, errors=[], rows=[], standard_suite=False, gameplay_ipc=None,
                  mutation_kind='runtime predicate injection, same compiled native binary')
    save('started.json', dict(pins=pins, defines=sorted(defs), invocation=os.environ['INVOCATION_ID'],
                             parent=str(parent), affinity=sorted(os.sched_getaffinity(0))))
    begin = time.monotonic()
    try:
        command = [os.environ['VENTIUM_VERILATOR_BIN'], '--binary', '--timing', '--assert',
                   '-j', '32', '-Wno-fatal', '-Wno-UNUSED', *['-Werror-'+w for w in
                   ('IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                   '--top-module', 'tb_prime_noack', '--Mdir', out/'obj',
                   *['+define+'+d for d in sorted(defs)], *modules, tb]
        rc, log = run('build', command, 180)
        result['build_exit'] = rc
        assert rc == 0, ('build', rc)
        binary = out/'obj/Vtb_prime_noack'
        result['binary_sha256'] = sha(binary)
        for mutant in range(4):
            rc, log = run('run-'+str(mutant), [binary, '+mutant='+str(mutant)], 120)
            row = dict(mutant=mutant, native_exit=rc, log_sha256=sha(out/('run-'+str(mutant)+'.log')))
            if mutant:
                assert rc != 0 and 'PRIME_EQUIV' in log, (mutant, rc)
            else:
                match = re.search(r'^PRIME-NOACK-OK (.+)$', log, re.M)
                assert rc == 0 and match, (mutant, rc)
                row['counts'] = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', match[1])}
                assert all(row['counts'].values())
            result['rows'].append(row)
        result['passed'] = True
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins=pins, pins_unchanged=all(sha(p) == h for p, h in pins.items()), seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save('closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
