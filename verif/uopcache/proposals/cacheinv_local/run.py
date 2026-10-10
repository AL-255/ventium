"""Bounded, pinned actual-decoder miter and three required negative controls.

--prepare only creates test artifacts. Run the prepared directory via this
driver under a retained service; the heavyweight body waits on build_scope.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
PACKAGES = ['rtl/ventium_pkg.sv', 'rtl/core/ventium_alu_pkg.sv',
            'rtl/core/ventium_decode_pkg.sv', 'rtl/fpu/fpu_x87_pkg.sv',
            'rtl/core/ventium_sys_pkg.sv', 'rtl/core/ventium_x87_pkg.sv']


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(path, obj):
    with path.open('x') as f:
        json.dump(obj, f, indent=2)


def once(source, old, new):
    if source.count(old) != 1:
        raise ValueError('negative control anchor drift')
    return source.replace(old, new)


def prepare(source, define_file, out):
    spec = importlib.util.spec_from_file_location('recipe', HERE / 'prepare_tb.py')
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    inputs = [source / p for p in PACKAGES + ['rtl/core/core.sv', 'rtl/core/decode_stages.sv']]
    inputs += [HERE / f for f in ('run.py', 'prepare_tb.py', 'body.svh', 'ven_cacheinv_local.sv')]
    inputs += [define_file, REPO / 'tools/build_scope.sh', REPO / 'tools/verilator_serial.sh']
    pins = {str(p.resolve()): sha(p) for p in inputs}
    defines = define_file.read_text().split()
    if not defines or any(not d.replace('_', '').isalnum() for d in defines):
        raise ValueError('expected one simple define per line')
    if not {'VEN_FP_SHARED', 'VEN_PIPE_SDISPATCH', 'VEN_P54_PREFIX_EX_CHAIN'} <= set(defines):
        raise ValueError('not the reviewed shared reference-decoder profile')
    defines = [d for d in defines if d not in {'VTM_NO_DPI', 'SYNTHESIS'}] + ['VTM_NO_DPI']
    prefix, shell = m.generate((source / 'rtl/core/decode_stages.sv').read_text(),
                               (source / 'rtl/core/core.sv').read_text(),
                               (HERE / 'body.svh').read_text())
    proposal = (HERE / 'ven_cacheinv_local.sv').read_text()
    profiles = {
        'candidate': (proposal, shell),
        'negative-lock': (once(proposal, " && ibuf[i]!=8'hf0", ''), shell),
        'negative-opcode': (proposal.replace("ibuf[i+1]==8'h09", "ibuf[i+1]==8'h0a"), shell),
        'negative-state': (proposal, once(shell,
            'assign proposed_go=recognized && (state==S_DECODE);', 'assign proposed_go=recognized;')),
    }
    out.mkdir()
    plans = []
    for name, (implementation, test) in profiles.items():
        leaf = out / name; leaf.mkdir()
        for rel in PACKAGES + ['rtl/core/decode_stages.sv']:
            dst = leaf / Path(rel).name
            shutil.copyfile(source / rel, dst); pins[str(dst)] = sha(dst)
        for filename, contents in (('state_types.sv', prefix), ('tb_cacheinv_local.sv', test),
                                   ('ven_cacheinv_local.sv', implementation)):
            dst = leaf / filename
            with dst.open('x') as f: f.write(contents)
            pins[str(dst)] = sha(dst)
        command = [str(REPO / 'tools/verilator_serial.sh'), '--binary', '--timing', '--assert',
                   '-sv', '-j', '1', '-Wall', '-Wno-fatal', '-Wno-UNUSED',
                   *['-Werror-' + w for w in ('IMPLICIT', 'PINMISSING', 'UNDRIVEN',
                                             'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                   '--output-split', '10000', '--output-split-cfuncs', '10000',
                   '-MAKEFLAGS', 'OPT_FAST=-O0', '--top-module', 'tb_cacheinv_local',
                   '--Mdir', str(leaf / 'obj'), *['+define+' + d for d in defines],
                   *[str(leaf / Path(p).name) for p in PACKAGES],
                   *[str(leaf / p) for p in ('state_types.sv', 'decode_stages.sv',
                                            'ven_cacheinv_local.sv', 'tb_cacheinv_local.sv')]]
        plans.append(dict(name=name, command=command))
    save(out / 'plan.json', dict(pins=pins, plans=plans, defines=defines,
                                 source=str(source), production_changed=False))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--source', type=Path)
    p.add_argument('--defines', type=Path)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--prepare', action='store_true')
    p.add_argument('--guarded', action='store_true')
    a = p.parse_args(); out = a.out.resolve()
    if a.prepare:
        if not a.source or not a.defines: p.error('--prepare needs --source and --defines')
        prepare(a.source.resolve(), a.defines.resolve(), out)
        return 0
    plan = json.loads((out / 'plan.json').read_text())
    assert all(sha(p) == h for p, h in plan['pins'].items())
    assert Path(os.environ['TMPDIR']).resolve() == out
    if not a.guarded:
        save(out / 'queued.json', dict(time=time.time(), invocation=os.environ.get('INVOCATION_ID'),
                                       pid=os.getpid()))
        command = [str(REPO / 'tools/build_scope.sh'), '--', 'timeout', '--signal=TERM',
                   '--kill-after=20s', '600', sys.executable, '-B', str(Path(__file__)),
                   '--out', str(out), '--guarded']
        result = subprocess.run(command)
        save(out / 'supervised.json', dict(native_exit=result.returncode))
        return result.returncode
    assert os.environ.get('VENTIUM_BUILD_SCOPE_ACTIVE') == '1'
    assert shutil.disk_usage(out).free > 2 * 1024**3
    cg = Path('/sys/fs/cgroup') / Path('/proc/self/cgroup').read_text().split('::', 1)[1].strip().lstrip('/')
    save(out / 'started.json', dict(time=time.time(), scope=os.environ.get('VENTIUM_BUILD_SCOPE_UNIT'),
                                    cgroup=str(cg), pid=os.getpid(), affinity=sorted(os.sched_getaffinity(0))))
    results, errors = [], []; start = time.monotonic()
    try:
        for row in plan['plans']:
            leaf = out / row['name']
            with (leaf / 'build.log').open('xb') as f:
                child = subprocess.run(row['command'], stdout=f, stderr=subprocess.STDOUT,
                                       pass_fds=(9,), timeout=120)
            result = dict(name=row['name'], build_exit=child.returncode, passed=False)
            results.append(result)
            if child.returncode: continue
            binary = leaf / 'obj/Vtb_cacheinv_local'
            with (leaf / 'run.log').open('xb') as f:
                child = subprocess.run([str(binary)], stdout=f, stderr=subprocess.STDOUT,
                                       pass_fds=(9,), timeout=20)
            text = (leaf / 'run.log').read_text()
            negative = row['name'].startswith('negative-')
            result.update(native_exit=child.returncode, model_sha256=sha(binary),
                passed=(child.returncode != 0 and 'CACHEINV-MISMATCH' in text) if negative else
                       (child.returncode == 0 and 'CACHEINV-LOCAL-OK' in text),
                negative_control=negative)
    except Exception as e:
        errors.append(repr(e))
    events = dict(line.split() for line in (cg / 'memory.events').read_text().splitlines())
    stable = all(sha(p) == h for p, h in plan['pins'].items())
    passed = stable and not errors and len(results) == 4 and all(r['passed'] for r in results)
    passed = passed and events['oom'] == events['oom_kill'] == '0'
    closed = dict(passed=passed, results=results, errors=errors, pins_unchanged=stable,
                  seconds=time.monotonic()-start, memory_events=events,
                  memory_peak=(cg / 'memory.peak').read_text().strip(),
                  full_core=False, standard_suite=False, hardware_accepted=False)
    save(out / 'closed.json', closed); print(json.dumps(closed), flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
