"""Native source-extracted selector miter; bounded, no Verilator/core build.

The eight profiles cover all combinations of the three controlling definitions.
This tiny Icarus-only test may run beside a separately capped Vivado family:
one CPU, 512 MiB/no swap, and >4 GiB available host RAM at admission. It takes
no global compiler lock and launches no C++ or full-core build. Negative builds
check wrong sources and a change incorrectly extended to other owner models.
This is not sequential-core verification or a performance measurement.
"""
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

import prepare_v_load_payload as recipe

HERE = Path(__file__).resolve().parent


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--unit', required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent, out = args.parent.resolve(strict=True), args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert not out.is_relative_to(parent)
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert os.sched_getaffinity(0) == {18}
    assert re.fullmatch(r'ventium-v-load-payload-leaf-[a-z0-9-]+\.service', args.unit)
    assert os.environ['INVOCATION_ID'] == subprocess.check_output([
        'systemctl', '--user', 'show', args.unit, '-pInvocationID', '--value'], text=True).strip()
    available = next(int(line.split()[1])*1024 for line in Path('/proc/meminfo').read_text().splitlines()
                     if line.startswith('MemAvailable:'))
    assert available > 4*1024**3, 'tiny-leaf host RAM admission'
    group = Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::', 1)[1].strip().lstrip('/')
    assert (group/'memory.max').read_text().strip() == str(512*1024**2)
    assert (group/'memory.swap.max').read_text().strip() == '0'
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_FSIZE, (16*1024**2, 16*1024**2))
    old = {p: (parent/p).read_text() for p in recipe.PARENTS}
    new = recipe.transform(old)
    template = (HERE/'tb_v_load_payload.sv').read_text()
    marker = '  // SOURCE_EXTRACTED_EQUATIONS'
    assert template.count(marker) == 1
    assert new['rtl/core/core_gpr_wb.svh'].count(recipe.NEW) == 1
    equations = recipe.ACCEPT + recipe.payload_assignment(recipe.OLD, 'old_data') + recipe.payload_assignment(recipe.NEW, 'new_data')
    tb = template.replace(marker, equations)
    inputs = [*(parent/p for p in recipe.PARENTS), Path(__file__), Path(recipe.__file__),
              HERE/'test_v_load_payload.py', HERE/'tb_v_load_payload.sv',
              HERE/'v_load_payload_contract.smt2', Path('/usr/bin/z3'),
              Path('/usr/bin/iverilog'), Path('/usr/bin/vvp'), Path('/usr/bin/timeout')]
    pins = {str(p): sha(p) for p in inputs}
    out.mkdir()

    def save(name, value):
        with (out/name).open('x') as stream:
            json.dump(value, stream, indent=2)

    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'], unit=args.unit,
        parent=str(parent), cpu=18, max_seconds_per_command=20, host_available_bytes=available,
        memory_limit_bytes=512*1024**2, swap_limit_bytes=0, standard_suite=False,
        gameplay_ipc=None, timing_mhz=None, sequential_core=False))
    start = time.monotonic()
    rows, error = [], None

    def run(label, argv, expected=0, env=None):
        # timeout owns/signals the whole native process group (Icarus can
        # spawn ivl), not only the immediate wrapper process.
        command = ['/usr/bin/timeout', '--signal=TERM', '--kill-after=2s', '20s', *map(str, argv)]
        save(label+'.command.json', command)
        with (out/(label+'.log')).open('x') as stream:
            result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=25, env=env)
        log = (out/(label+'.log')).read_text()
        assert result.returncode == expected, (label, result.returncode, expected, log[-1500:])
        return log

    try:
        run('recipe', ['python3', '-B', HERE/'test_v_load_payload.py', '-v'],
            env=dict(os.environ, V_LOAD_PAYLOAD_PARENT=str(parent)))
        proof = run('abstract-contract', ['/usr/bin/z3', HERE/'v_load_payload_contract.smt2'])
        assert proof.splitlines() == ['unsat', 'unsat', 'sat', 'sat', 'sat', 'sat']
        for path, content in new.items():
            target = out/'proposal'/path
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('x') as stream:
                stream.write(content)
        macros = ('VEN_P54_DUAL_BYTE_LOAD_PAIR', 'VEN_RAW_V_READ_PRIME', 'VEN_P54_DUAL_LOAD_PRIME')
        cases = [(f'profile-{bits}', tb, [m for i, m in enumerate(macros) if bits & (1 << i)], False)
                 for bits in range(8)]
        old_mux = 'pipe_mem_v_hit_q ? mem_pair_rsp_data[1] : mem_pair_now_data'
        assert tb.count(old_mux) == 1
        for name, wrong in (('held-only', 'mem_pair_rsp_data[1]'), ('immediate-only', 'mem_pair_now_data'),
                            ('inverted', 'pipe_mem_v_hit_q ? mem_pair_now_data : mem_pair_rsp_data[1]')):
            cases.append(('mutant-'+name, tb.replace(old_mux, wrong), list(macros[:2]), True))
        # Original non-RAW permits both data owners abstractly. Applying the
        # optimization there without a qualified invariant must fail.
        original = recipe.payload_assignment(recipe.NEW, 'new_data')
        broad = tb.replace(original, '  assign new_data = '+old_mux+';\n')
        cases.append(('mutant-broad-profile', broad, [macros[0]], True))
        for label, source, defines, negative in cases:
            sv, binary = out/(label+'.sv'), out/(label+'.vvp')
            with sv.open('x') as stream:
                stream.write(source)
            run(label+'-build', ['/usr/bin/iverilog', '-g2012', '-Wall', '-s', 'tb',
                *['-D'+d for d in defines], '-o', binary, sv])
            log = run(label, ['/usr/bin/vvp', binary], 1 if negative else 0)
            assert ('V-LOAD-PAYLOAD-MISMATCH' if negative else 'V-LOAD-PAYLOAD-OK ') in log
            rows.append(dict(name=label, defines=defines, expected_failure=negative,
                native_exit=1 if negative else 0, output=log.strip(),
                artifacts={str(p): sha(p) for p in (sv, binary, out/(label+'.log'), out/(label+'-build.log'))}))
    except Exception as exc:
        error = repr(exc)
    stable = all(sha(p) == h for p, h in pins.items())
    events = dict(row.split() for row in (group/'memory.events').read_text().splitlines())
    no_oom = all(events[k] == '0' for k in ('oom', 'oom_kill', 'oom_group_kill'))
    result = dict(passed=error is None and stable and no_oom, error=error, rows=rows,
        pins_unchanged=stable, seconds=time.monotonic()-start, memory_events=events,
        proposal_sha256={p: hashlib.sha256(text.encode()).hexdigest() for p, text in new.items()},
        sequential_core=False, automatic_rtl_formal=False, standard_suite=False,
        physical_board=False, gameplay_ipc=None, timing_mhz=None)
    save('closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
