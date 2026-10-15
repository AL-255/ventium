"""Bounded shared-FPU underflow experiment, with native x87 and bad control.

This does not promote RTL or a QEMU oracle. The two architectural matrices
are checked independently, including all payloads and defined status fields.
"""
import argparse
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

import prepare_remainder_underflow as recipe
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO/'verif/qemu-trace/remainder_sequence'))
import state_vectors
import underflow_vectors
import prepare_underflow
from remainder_execution import execute
from run_small_quotient import sha, save


def infinite_divisor_rows():
    """An infinite divisor has quotient zero; finite A is the exact result."""
    result = []
    labels = {'minimum-denormal', 'maximum-denormal', 'tiny-zero-quotient',
              'pseudo-normal', 'normal-exact-zero'}
    for row in underflow_vectors.rows():
        if row['label'] not in labels: continue
        for zero in ((False, True) if row['label'] == 'minimum-denormal' else (False,)):
            r = dict(row, label='infinite-divisor-'+('zero' if zero else row['label']),
                     b=(0x7fff | (row['b'][0]&0x8000), 1<<63))
            if zero: r['a'] = (row['a'][0]&0x8000, 0)
            top = (r['sw']>>11)&7
            r['tag'] = (state_vectors.tag(r['a'])<<(2*top)) | \
                       (state_vectors.tag(r['b'])<<(2*((top+1)%8)))
            result.append(r)
    assert len(result) == 576
    return result


def check_infinite(row, raw):
    # The integer oracle is finite-only. Substitute a finite divisor whose
    # magnitude exceeds 2*A; independently guaranteed Q=0 for both modes.
    # Keep the real infinity payload/tag when checking the saved ST(1).
    finite = dict(row, b=(0x4000 | (row['b'][0]&0x8000), 1<<63))
    expected = underflow_vectors.expected(finite)
    actual = bytearray(raw)
    actual[38:48] = (1<<63).to_bytes(8,'little') + finite['b'][0].to_bytes(2,'little')
    top = (row['sw']>>11)&7; shift = 2*((top+1)%8)
    tag = int.from_bytes(actual[8:10],'little')
    errors = []
    if ((tag>>shift)&3) != state_vectors.tag(row['b']): errors.append('infinite-divisor-tag')
    if raw[38:48] != (1<<63).to_bytes(8,'little') + row['b'][0].to_bytes(2,'little'):
        errors.append('infinite-divisor-payload')
    actual[8:10] = ((tag&~(3<<shift)) | (state_vectors.tag(finite['b'])<<shift)).to_bytes(2,'little')
    finite['tag'] = (row['tag']&~(3<<shift)) | (state_vectors.tag(finite['b'])<<shift)
    assert expected['quotient'] == 0
    return errors + underflow_vectors.check(finite, actual)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'out', 'reference'): ap.add_argument('--'+name, type=Path, required=True)
    a = ap.parse_args(); root = a.out.resolve(); parent = a.parent.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    evidence = scratch/'ventium-fprem-sequence.iSZ9BAj4'
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and os.environ['INVOCATION_ID']
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.sched_getaffinity(0) == set(range(8,16))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'], check=True, pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'], check=True)
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode == 1
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    version = subprocess.check_output([REPO/'tools/verilator_serial.sh','--version'],
                                     text=True, pass_fds=(9,))
    assert version.startswith('Verilator 5.046 ')
    resource.setrlimit(resource.RLIMIT_CORE, (0,0))
    old, built = [json.loads((parent/n).read_text()) for n in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == built['binary_sha256'] == \
        'c4d914831fa7a23171e782bf558466ca31b92f42bee34a9c82b58c485e043f6f'
    files = sorted(p for p in (parent/'candidate').rglob('*') if p.is_file())
    assert len(files) == 195 and all(sha(p) == old['pins'][str(p)] for p in files)
    definitions = old['definitions']
    assert len(definitions) == len(set(definitions)) == 152 and 'VEN_FP_SHARED' in definitions
    probe = evidence/'exception-state-r2/probe'
    control = evidence/'srt-exceptions-r3/candidate/obj/test'
    assert sha(probe) == 'd380fe69cd85c632abe444e0adcc098ce9adaef47a79a554dffde9de438a3bd3'
    assert sha(control) == 'b8b49226de20f1ec0bdf263865909b80d3dd761137d2977fe55e5f868621e8d0'
    reference = a.reference.resolve(strict=True)
    reference_closed = json.loads((reference/'closed.json').read_text())
    reference_sources = json.loads((reference/'source.json').read_text())
    qemu = reference/'build/qemu-i386'
    assert reference_closed['passed'] and reference_closed['pins_unchanged']
    assert sha(qemu) == reference_closed['sha256']
    assert reference_sources['changed'] == [prepare_underflow.HELPER]
    helper_parent = evidence/'build-exceptions-r1/source'/prepare_underflow.HELPER
    assert (reference/'source'/prepare_underflow.HELPER).read_text() == \
        prepare_underflow.transform(helper_parent.read_text())
    pins = {str(p):sha(p) for p in files}
    pins.update({str(reference/'source'/n):h for n,h in reference_sources['after'].items()})
    assert all(sha(p)==h for p,h in pins.items())
    for p in (Path(__file__), Path(recipe.__file__), Path(state_vectors.__file__),
              Path(underflow_vectors.__file__), Path(underflow_vectors.oracle.__file__),
              HERE/'remainder_execution.py',
              REPO/'verif/qemu-trace/remainder_sequence/run_small_quotient.py',
              HERE/'tb_remainder_exceptions.sv', HERE/'tb_remainder_underflow_engine.sv',
              parent/'build-started.json', parent/'build-closed.json',
              parent/'obj/tb_ventium', probe, control, qemu, reference/'closed.json',
              reference/'source.json', Path(prepare_underflow.__file__), helper_parent,
              REPO/'tools/build_scope.sh',
              REPO/'tools/verilator_serial.sh', Path(os.environ['VENTIUM_VERILATOR_BIN'])):
        pins[str(p.resolve())] = sha(p)
    root.mkdir(); source = root/'source'; shutil.copytree(parent/'candidate', source)
    for n in recipe.PARENTS: (source/n).write_text(recipe.transform((source/n).read_text(), n))
    changes = sorted(str(p.relative_to(parent/'candidate')) for p in files
        if sha(p) != sha(source/p.relative_to(parent/'candidate')))
    assert changes == sorted(recipe.PARENTS)
    # Derive a private testbench instead of changing the historical diagnostic.
    tb = (HERE/'tb_remainder_exceptions.sv').read_text()
    tb = recipe.once(tb, 'module tb_remainder_exceptions;', 'module tb_remainder_underflow;')
    tb = recipe.once(tb, '      rem_latency=latency; fault=int\'(stack_fault); completed=st;',
        "      rem_latency=latency; fault=int'(stack_fault); completed=st;\n"
        "      if (!in_sw[4] && arith[81] !== sw[4])\n"
        '        $fatal(1,"REM-UE-RESPONSE row=%0d",count);\n'
        "      if (arith[82] || arith[80]) $fatal(1,\"REM-SPURIOUS-OE-PE\");")
    testbench = root/'tb_remainder_underflow.sv'; testbench.write_text(tb)
    pins[str(testbench)] = sha(testbench)
    pins.update({str(source/p.relative_to(parent/'candidate')):sha(source/p.relative_to(parent/'candidate'))
                 for p in files})
    command = [REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv',
        '-j','32','--verilate-jobs','1','--output-split','10000','--output-split-cfuncs','500',
        '-Wall','-Wno-UNUSED','-Wno-fatal',
        *['-Werror-'+n for n in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
        *['+define+'+d for d in definitions],'-f',source/'rtl_ven_core.f',
        '--top-module','tb_remainder_underflow','--Mdir',root/'obj','-o','test',testbench]
    save(root/'started.json', dict(pins=pins, changes=changes, definitions=definitions,
        invocation=os.environ['INVOCATION_ID'], command=list(map(str,command)),
        compiler_version=version, owner=os.environ['UNDERFLOW_OWNER'],
        whole_core=False, legacy_unmasked_underflow_fixed=False))
    result = dict(passed=False, errors=[], matrices={}, canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    begin = time.monotonic()
    try:
        with (root/'build.log').open('x') as out:
            result['build_exit'] = subprocess.run(command, cwd=source, stdout=out,
                stderr=subprocess.STDOUT, pass_fds=(9,), timeout=240).returncode
        assert result['build_exit'] == 0
        engine_command = [str(s).replace('tb_remainder_underflow', 'tb_remainder_underflow_engine')
                          if str(s) == 'tb_remainder_underflow' else s for s in command]
        engine_command[engine_command.index('--Mdir')+1] = root/'engine-obj'
        engine_command[-1] = HERE/'tb_remainder_underflow_engine.sv'
        with (root/'engine-build.log').open('x') as out:
            code = subprocess.run(engine_command, cwd=source, stdout=out, stderr=subprocess.STDOUT,
                                  pass_fds=(9,), timeout=120).returncode
        result['engine_build'] = dict(command=list(map(str,engine_command)), native_exit=code)
        assert code == 0
        os.sched_setaffinity(0, {12})
        result['engine_execution'] = execute('engine', [root/'engine-obj/test'], root)
        assert 'REM-UNDERFLOW-ENGINE-OK rows=758 reset=1 div_sqrt=2' in (root/'engine.out').read_text()
        for label, rows in (('underflow', underflow_vectors.rows()), ('operands', state_vectors.rows()),
                            ('infinite-divisor', infinite_divisor_rows())):
            folder = root/label; folder.mkdir(); save(folder/'cases.json', rows)
            inp = folder/'stdin.bin'; inp.write_bytes(b''.join(map(state_vectors.pack, rows)))
            vectors = folder/'vectors.txt'
            with vectors.open('x') as out:
                for r in rows:
                    out.write(f"{r['cw']:04x} {r['sw']:04x} {r['tag']:04x} {r['a'][0]:04x}{r['a'][1]:016x} {r['b'][0]:04x}{r['b'][1]:016x} {r['op']}\n")
            matrix = dict(cases=len(rows), executions=[], failures={}, latencies={})
            result['matrices'][label] = matrix; observations = {}
            for impl, argv, stdin in (('native', [probe], inp),
                ('control', [control, '+vectors='+str(vectors)], None),
                ('reference', [qemu, '-cpu', 'pentium', probe], inp),
                ('candidate', [root/'obj/test', '+vectors='+str(vectors)], None)):
                matrix['executions'].append(execute(impl, argv, folder, stdin))
                raw = (folder/(impl+'.out')).read_bytes()
                if impl in ('native','reference'):
                    assert len(raw) == 108*len(rows)
                    observations[impl] = [raw[i:i+108] for i in range(0,len(raw),108)]
                else:
                    text = raw.decode()
                    found = re.findall(r'^ROW (\d+) ([0-9a-f]{216}) (\d+) (\d+)$',text,re.M)
                    assert len(found) == len(rows)
                    assert f'REM-EXCEPTION-TRANSPORT-OK rows={len(rows)} resets=3' in text
                    assert [int(r[0]) for r in found] == list(range(len(rows)))
                    observations[impl] = [int(r[1],16).to_bytes(108,'little') for r in found]
                    matrix['latencies'][impl] = [int(r[2]) for r in found]
            for impl, data in observations.items():
                failures=[]
                for i,(r,raw,native) in enumerate(zip(rows,data,observations['native'])):
                    errors = (check_infinite(r,raw) if label == 'infinite-divisor' else
                        underflow_vectors.check(r,raw) if label == 'underflow' else
                        state_vectors.check_native(r,raw) if impl == 'native' else
                        state_vectors.compare(r,native,raw))
                    if errors: failures.append(dict(index=i, errors=errors))
                save(folder/(impl+'-graded.json'), dict(failures=failures))
                matrix['failures'][impl] = len(failures)
            matrix['latencies_unchanged'] = matrix['latencies']['control'] == matrix['latencies']['candidate']
            save(folder/'latencies.json', matrix.pop('latencies'))
            assert matrix['failures']['native'] == matrix['failures']['candidate'] == 0
            assert matrix['failures']['reference'] == 0
            assert matrix['failures']['control'] == {'underflow':3216, 'operands':0, 'infinite-divisor':72}[label]
            assert matrix['latencies_unchanged']
        result['binary_sha256'] = sha(root/'obj/test')
        result['passed'] = True
    except Exception as e: result['errors'].append(dict(error=repr(e), traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin, pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save(root/'closed.json',result); print(json.dumps(result,indent=2),flush=True)
    return int(not result['passed'])


if __name__ == '__main__': raise SystemExit(main())
