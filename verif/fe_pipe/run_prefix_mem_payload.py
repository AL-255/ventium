"""Bounded actual-decoder full-payload comparison; run inside build_scope.sh.

No root RTL mutation, FPGA programming, whole-core acceptance or Fmax claim.
The candidate is emitted only into a new external temporary leaf.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import time

import prepare_prefix_mem_payload as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
WRAPPER = '''module prefix_payload_NAME
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
(
  input logic [7:0] ub[7],
  input logic [31:0] eflags,
  input logic def16,cycle_mode,p54_prefix66_context_ok,
  input logic pipe_mem_active_q,fp_async_pending,fp_occ_pending,xp_pend,xs_act,fx_act,
  output fpd_t u_d,raw_base,
  output logic admitted
);
`include "prefix_NAME.svh"
assign raw_base=p54_prefix66_base;
assign admitted=p54_prefix66_candidate;
endmodule
'''


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', required=True, type=Path,
                    help='frozen core root containing candidate/ and prepared.json')
    ap.add_argument('--out', required=True, type=Path)
    args = ap.parse_args()
    if not __debug__:
        raise RuntimeError('assertions must remain enabled')
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    parent = args.parent.resolve(strict=True)
    assert root.is_relative_to(scratch) and not root.exists()
    assert parent.is_relative_to(scratch)
    assert scratch.stat().st_dev != REPO.stat().st_dev
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.sched_getaffinity(0) == {14}
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'default'
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    unit = os.environ['VENTIUM_BUILD_SCOPE_UNIT'] + '.scope'
    subprocess.run(['systemctl', '--user', 'set-property', '--runtime', unit,
                    'MemoryMax=2G', 'MemorySwapMax=0', 'TasksMax=64'], check=True, timeout=10)
    cg = Path('/sys/fs/cgroup' + Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert (cg/'memory.max').read_text().strip() == str(2*1024**3)
    assert (cg/'memory.swap.max').read_text().strip() == '0'
    subprocess.run([REPO/'tools/verilator_serial.sh', '--version'], check=True, timeout=10)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    start = time.monotonic()

    def guard():
        if time.monotonic() - start > 580:
            raise RuntimeError('580-second leaf budget exceeded')
        if shutil.disk_usage(scratch).free < 4*1024**3:
            raise RuntimeError('external 4 GiB floor reached')
        available = next(int(line.split()[1])*1024
                         for line in Path('/proc/meminfo').read_text().splitlines()
                         if line.startswith('MemAvailable:'))
        if available < 2*1024**3:
            raise RuntimeError('host 2 GiB reserve reached')

    guard()
    source = parent/'candidate'
    prepared = json.loads((parent/'prepared.json').read_text())
    definitions = prepared['definitions']
    assert len(definitions) == len(set(definitions)) == 152
    old = (source/recipe.FILE).read_text()
    decoder = (source/recipe.DECODER_FILE).read_text()
    fixed = recipe.transform(old, decoder)
    relative = ('rtl/ventium_pkg.sv', 'rtl/core/ventium_alu_pkg.sv',
                'rtl/core/ventium_decode_pkg.sv', recipe.DECODER_FILE, recipe.FILE)
    pinned = [source/p for p in relative] + [parent/'prepared.json',
        Path(__file__), Path(recipe.__file__), HERE/'tb_prefix_mem_payload.sv',
        HERE/'test_prefix_mem_payload.py', REPO/'tools/build_scope.sh',
        REPO/'tools/verilator_serial.sh', Path(os.environ['VENTIUM_VERILATOR_BIN'])]
    pins = {str(p): sha(p) for p in pinned}
    root.mkdir()

    def save(path, contents):
        with path.open('xb') as stream:
            stream.write(contents if isinstance(contents, bytes) else contents.encode())
        return path

    def generated(name, contents):
        path = save(root/name, contents)
        pins[str(path)] = sha(path)
        return path

    sources = [generated(Path(p).name, (source/p).read_bytes()) for p in relative[:-1]]
    generated('prefix_parent.svh', old)
    generated('prefix_fixed.svh', fixed)
    generated('core_prefix66_decode.svh', fixed)
    for name in ('parent', 'fixed'):
        sources.append(generated('prefix_payload_'+name+'.sv', WRAPPER.replace('NAME', name)))
    sources.append(generated('tb_prefix_mem_payload.sv', (HERE/'tb_prefix_mem_payload.sv').read_bytes()))
    result = dict(passed=False, errors=[], profiles=[], native=[], input_pins=pins,
                  full_core=False, standard_suite=False, fmax_mhz=None, gameplay_ipc=None,
                  hardware_acceptance=False)
    save(root/'started.json', json.dumps(dict(pins=pins, scope=unit,
         invocation=os.environ.get('INVOCATION_ID'), affinity=sorted(os.sched_getaffinity(0))), indent=2))

    def native(command, logpath, limit):
        guard()
        with logpath.open('x') as log:
            proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                    pass_fds=(9,), start_new_session=True)
            affinity = sorted(os.sched_getaffinity(proc.pid))
            assert affinity == [14]
            deadline = time.monotonic() + limit
            try:
                while proc.poll() is None:
                    guard()
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f'native {limit}s deadline: {command[0]}')
                    time.sleep(0.2)
                code = proc.wait()
            except BaseException:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                raise
        result['native'].append(dict(command=list(map(str, command)), exit=code,
            affinity=affinity, log=str(logpath), log_sha256=sha(logpath)))
        return code, logpath.read_text()

    try:
        for name, defines in (('minimal', ()), ('candidate', definitions)):
            folder = root/name
            folder.mkdir()
            command = [str(REPO/'tools/verilator_serial.sh'), '--binary', '--timing',
                '--assert', '-sv', '-j', '1', '--threads', '1', '-Wall', '-Wno-UNUSED',
                '-Wno-fatal', *['-Werror-'+w for w in
                ('IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                '+define+VTM_NO_DPI', *['+define+'+d for d in defines], '-I'+str(root),
                '--top-module', 'tb_prefix_mem_payload', '--Mdir', str(folder/'obj'),
                '-o', 'test', *map(str, sources)]
            code, _ = native(command, folder/'build.log', 120)
            assert code == 0, folder/'build.log'
            model = folder/'obj/test'
            model_hash = sha(model)
            code, log = native([str(model)], folder/'run.log', 150)
            assert code == 0 and 'PREFIX-PAYLOAD-OK checks=17532577 ' in log, log
            for mutant in (1, 2, 3):
                code, log = native([str(model), f'+mutant={mutant}'], folder/f'mutant-{mutant}.log', 5)
                assert code in (-6, 1, 134) and 'PREFIX-PAYLOAD-MISMATCH' in log, log
                assert 'PREFIX-PAYLOAD-OK' not in log
            assert sha(model) == model_hash
            result['profiles'].append(dict(name=name, definitions=defines, model_sha256=model_hash,
                                           checks=17532577, rejected_mutants=3))
            print('PREFIX-PAYLOAD-PROFILE-CLOSED '+name, flush=True)
        result['passed'] = True
    except Exception as error:
        result['errors'].append(repr(error))
    result['pins_unchanged'] = all(sha(p) == digest for p, digest in pins.items())
    result['memory_events'] = (cg/'memory.events').read_text()
    result['memory_peak'] = int((cg/'memory.peak').read_text())
    result['passed'] &= result['pins_unchanged'] and all(
        int(line.split()[1]) == 0 for line in result['memory_events'].splitlines()
        if line.split()[0] in ('oom', 'oom_kill', 'oom_group_kill'))
    result['seconds'] = time.monotonic()-start
    save(root/'closed.json', json.dumps(result, indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('native', 'input_pins')}, indent=2))
    return int(not result['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
