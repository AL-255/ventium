#!/usr/bin/env python3
"""UV-fast REP restart under a held external IRQ; RTL structural coverage.

Uses the existing pin-only IrqInjectProbe, never writes internal state or
manufactures a QEMU interrupt trace. The guest checks the entire committed
memory prefix and untouched suffix in its handler, then verifies all data.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import traceback

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO / 'verif/diff'), str(REPO / 'verif/sys')]
import tracefmt
import check_faultlog


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, data):
    with path.open('x') as stream:
        json.dump(data, stream, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control', 'candidate', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models = {n: getattr(args, n).resolve(strict=True) for n in ('control', 'candidate')}
    profiles, pins = {}, {}
    for name, tb in models.items():
        stamp = tb.parent / 'Vventium_top__verFiles.dat'
        command = next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        profiles[name] = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command
        assert {'VEN_L1_AXI', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_FE_PIPE',
                'VEN_REP_MOVS_CONT', 'VEN_REP_MOVS_LOAD_FUSE', 'VEN_REP_MOVS_STREAM'} <= profiles[name]
        assert not {'VEN_UOPCACHE', 'VEN_UOP_SFETCH', 'VTM_NO_DPI', 'SYNTHESIS'} & profiles[name]
        pins.update({str(p): sha(p) for p in (tb, stamp)})
    assert profiles['candidate'] == profiles['control'] | {'VEN_REP_CONT_NO_UOP'}
    assert 'VEN_REP_CONT_NO_UOP' not in profiles['control']
    source = REPO / 'verif/rep_sfetch/rep-no-uop-irq.S'
    linker = REPO / 'verif/sys/tests/ppage/ppage.ld'
    for p in (Path(__file__), source, linker, REPO / 'verif/tb/irq_inject_probe.h',
              REPO / 'verif/diff/tracefmt.py', REPO / 'verif/sys/check_faultlog.py'):
        pins[str(p)] = sha(p)
    save(args.out / 'inputs.json', pins)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VEN_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(TMPDIR=str(args.out), PYTHONDONTWRITEBYTECODE='1')

    def run(argv, leaf, name, expected=0, extra=None):
        command = ['timeout', '--signal=TERM', '--kill-after=3s', '60s', *map(str, argv)]
        save(leaf / (name + '.command.json'), dict(command=command, environment=extra))
        with (leaf / (name + '.stdout')).open('x') as out, (leaf / (name + '.stderr')).open('x') as err:
            rc = subprocess.run(command, env=dict(env, **(extra or {})), stdout=out, stderr=err).returncode
        save(leaf / (name + '.exit.json'), {'exit': rc})
        assert rc == expected, (name, rc, expected)

    def prepare(case):
        count, offset = case
        leaf = args.out / f'n{count}-o{offset}'
        leaf.mkdir()
        obj, elf, image = [leaf / ('fixture.' + ext) for ext in ('o', 'elf', 'bin')]
        run(['gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic', '-fno-pie',
             f'-DCOUNT={count}', f'-DOFFSET={offset}', '-c', source, '-o', obj], leaf, 'assemble')
        run(['gcc', '-m32', '-static', '-no-pie', '-nostdlib', '-Wl,-T,' + str(linker),
             '-Wl,--build-id=none', obj, '-o', elf], leaf, 'link')
        run(['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', elf, image], leaf, 'binary')
        symbols = {p[2]: int(p[0], 16) for line in subprocess.check_output(['nm', '-n', elf], text=True).splitlines()
                   if len(p := line.split()) == 3 and p[0] != 'U'}
        assert symbols['rep_hot'] % 32 == offset and image.stat().st_size == 65536
        return count, offset, leaf, image, symbols

    def measure(job):
        prepared, name, latency = job
        count, offset, leaf, image, symbols = prepared
        fields, pairs = {}, 0
        extra = dict(AXI_RLAT=str(latency), AXI_WLAT=str(latency),
                     VEN_TEST_IRQ_PC=hex(symbols['rep_hot']), VEN_TEST_IRQ_VECTOR='64', VEN_TEST_IRQ_COUNT='1')
        for mode in ('cycle-func', 'cycle'):
            stem = f'{name}-l{latency}-{mode}'
            path = leaf / (stem + '.vtrace')
            run([models[name], '+ven_repcontlog', '+ven_faultlog', '--system', '--cosim', '--' + mode,
                 '--l1-axi', '--image', image, '--out', path, '--max-insn', '5000',
                 '--max-cycles', '3000000', '--quiesce', '200000'], leaf, stem, 133, extra)
            stdout, stderr = [(leaf / (stem + ext)).read_text() for ext in ('.stdout', '.stderr')]
            assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL', stdout + stderr)
            check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()), {(64, 0): 1})
            assert stderr.count('[TEST-IRQ] REQUEST ') == stderr.count('[TEST-IRQ] INTA ') == 1
            assert '[TEST-IRQ] PASS requests=1 acknowledgements=1 vector=64' in stderr
            requested = re.findall(r'\[TEST-IRQ\] REQUEST n=1 cycle=(\d+) ', stderr)
            acked = re.findall(r'\[TEST-IRQ\] INTA n=1 cycle=(\d+) ', stderr)
            assert len(requested) == len(acked) == 1
            request_cycle, ack_cycle = int(requested[0]), int(acked[0])
            assert request_cycle < ack_cycle
            if name == 'candidate':
                arm = re.findall(r'\[MOVSSTREAM\] ARM cyc=(\d+) pc=' + f'{symbols["rep_hot"]:08x}' +
                    r' esi=00002004 edi=00004004 ecx=' + f'{count-1:08x}', stdout)
                second = re.findall(r'\[MOVSFUSE\] LOAD cyc=(\d+) pc=' + f'{symbols["rep_hot"]:08x}' +
                    r' esi=00002004 edi=00004004 ecx=' + f'{count-1:08x}', stdout)
                assert len(arm) == len(second) == 1
                assert int(arm[0]) + 1 == request_cycle <= int(second[0]) < ack_cycle
                # This is the already-started source case, not the separately
                # checked SMI preissue cancellation case.
                assert not re.search(r'\[MOVSSTREAM\] CANCEL ', stdout)
            else:
                assert '[MOVSSTREAM]' not in stdout and '[MOVSFUSE]' not in stdout
            trace = tracefmt.read_trace(str(path))
            rows = trace.records
            assert [r['n'] for r in rows] == list(range(len(rows)))
            if mode == 'cycle-func':
                assert int(rows[-1]['eax'], 0) & 255 == 0x42
                handlers = [r for r in rows if int(r['pc'], 0) == symbols['irq_checks']]
                assert len(handlers) == 1
                h = handlers[0]
                remaining = int(h['ecx'], 0)
                assert 0 < remaining < count
                assert count - remaining == (2 if name == 'candidate' else 1)
                assert int(h['esi'], 0) == 0x2000 + 4 * (count - remaining)
                assert int(h['edi'], 0) == 0x4000 + 4 * (count - remaining)
                assert int(h['esp'], 0) == 0x90000 - 12 - 32
                assert not int(h['eflags'], 0) & 0x200
                returns = [r for r in rows if int(r['pc'], 0) == symbols['irq_return']]
                assert len(returns) == 1
                for key in ('ecx', 'esi', 'edi'):
                    assert returns[0][key] == h[key]
                assert int(returns[0]['esp'], 0) == 0x90000
                assert int(returns[0]['eflags'], 0) & 0x200
                fields = dict(remaining_at_irq=remaining, committed_before_irq=count-remaining,
                              handler_record=h['n'], return_record=returns[0]['n'], records=len(rows))
            else:
                pairs = sum(r.get('pipe') == 'V' and r.get('paired', False) for r in rows)
                assert pairs > 0
        return dict(count=count, offset=offset, model=name, latency=latency, passed=True,
                    paired_v=pairs, **fields)

    result = dict(passed=False, cases=[], errors=[], gameplay_ipc=None, standard_suite=False,
                  authority='RTL guest memory/frame checks and external-pin handshakes; no QEMU event oracle')
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            prepared = list(pool.map(prepare, [(n, o) for n in (4, 32) for o in (0, 17, 31)]))
        jobs = [(case, name, latency) for case in prepared for name in models for latency in (0, 7, 31)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
            pending = {pool.submit(measure, job): (job[0][:2], job[1:]) for job in jobs}
            for future in concurrent.futures.as_completed(pending):
                try:
                    result['cases'].append(future.result())
                except Exception as exc:
                    result['errors'].append(dict(case=pending[future], error=repr(exc), traceback=traceback.format_exc()))
        assert len(result['cases']) == len(jobs) and not result['errors']
        result['passed'] = True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc), traceback=traceback.format_exc()))
    finally:
        result['inputs_unchanged'] = all(sha(p) == h for p, h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        save(args.out / 'result.json', result)
    print(json.dumps(dict(passed=result['passed'], cases=len(result['cases']),
        errors=[dict(case=e.get('case'), error=e['error']) for e in result['errors']],
        inputs_unchanged=result['inputs_unchanged'], gameplay_ipc=None, standard_suite=False), indent=2), flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
