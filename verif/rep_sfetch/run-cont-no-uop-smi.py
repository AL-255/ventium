#!/usr/bin/env python3
"""Existing APIC self-SMI REP precise-boundary check, private outputs only.

RTL structural test: QEMU stepping masks SMI and is not an event oracle.
The existing checker requires actual ready/divert or immediate ARM/CANCEL,
P5 save-map state, exact pointers and RSM restart; none are fabricated here.
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


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, data):
    with path.open('x') as stream:
        json.dump(data, stream, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tb', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    tb = args.tb.resolve(strict=True)
    stamp = tb.parent / 'Vventium_top__verFiles.dat'
    command = next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
    defines = set(re.findall(r'\+define\+(\w+)', command))
    assert ' --assert ' in command and '-DVEN_KV260_SOC' not in command
    assert {'VEN_REP_CONT_NO_UOP', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
            'VEN_FE_PIPE', 'VEN_L1_AXI', 'VEN_REP_MOVS_STREAM'} <= defines
    assert not {'VEN_UOPCACHE', 'VEN_UOP_SFETCH', 'VEN_REP_STOS_STREAM', 'SYNTHESIS'} & defines
    source = REPO / 'verif/sys/tests/prepsmi/prepsmi.S'
    linker = REPO / 'verif/sys/tests/prepsmi/prepsmi.ld'
    checker = REPO / 'verif/sys/tests/prepsmi/prepsmi-rtl-selfcheck.py'
    pins = {str(p): sha(p) for p in (Path(__file__), tb, stamp, source, linker, checker)}
    save(args.out / 'inputs.json', pins)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VEN_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(TMPDIR=str(args.out), PYTHONDONTWRITEBYTECODE='1')

    def run(argv, leaf, name, expected=0, latency=0):
        command = ['timeout', '--signal=TERM', '--kill-after=3s', '60s', *map(str, argv)]
        save(leaf / (name + '.command.json'), command)
        with (leaf / (name + '.stdout')).open('x') as out, (leaf / (name + '.stderr')).open('x') as err:
            rc = subprocess.run(command, env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)),
                                stdout=out, stderr=err).returncode
        save(leaf / (name + '.exit.json'), {'exit': rc})
        assert rc == expected, (name, rc, expected)

    def case(job):
        movs, latency = job
        leaf = args.out / f'movs{movs}-l{latency}'
        leaf.mkdir()
        obj, elf, image = [leaf / ('fixture.' + ext) for ext in ('o', 'elf', 'bin')]
        run(['gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic', '-fno-pie',
             *(['-DPREP_SMI_MOVS'] if movs else []), '-c', source, '-o', obj], leaf, 'assemble')
        run(['gcc', '-m32', '-static', '-no-pie', '-nostdlib', '-Wl,-T,' + str(linker),
             '-Wl,--build-id=none', obj, '-o', elf], leaf, 'link')
        run(['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', elf, image], leaf, 'binary')
        symbols = {p[2]: int(p[0], 16) for line in subprocess.check_output(['nm', '-n', elf], text=True).splitlines()
                   if len(p := line.split()) == 3 and p[0] != 'U'}
        assert symbols['rep_smi'] % 32 == 19 and image.stat().st_size == 65536
        trace, dump = leaf / 'rtl.vtrace', leaf / 'smm.json'
        run([tb, '--l1-axi', '--system', '--cosim', '--cycle-func', '--image', image,
             '--out', trace, '--smm-dump', dump, '--smbase', '0x30000', '--max-insn',
             '3000', '--max-cycles', '3000000', '--quiesce', '200000', '+ven_repcontlog'],
            leaf, 'rtl', 133, latency)
        run([sys.executable, '-B', checker, trace, dump, leaf / 'rtl.stdout',
             hex(symbols['rep_smi']), '0', str(movs), str(movs)], leaf, 'check')
        return dict(movs=movs, latency=latency, passed=True)

    result = dict(passed=False, cases=[], errors=[], gameplay_ipc=None, standard_suite=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        pending = {pool.submit(case, (movs, latency)): (movs, latency)
                   for movs in (0, 1) for latency in (0, 7)}
        for future in concurrent.futures.as_completed(pending):
            try:
                result['cases'].append(future.result())
            except Exception as exc:
                result['errors'].append(dict(case=pending[future], error=repr(exc),
                                             traceback=traceback.format_exc()))
    result['inputs_unchanged'] = all(sha(p) == h for p, h in pins.items())
    result['passed'] = result['inputs_unchanged'] and not result['errors'] and len(result['cases']) == 4
    save(args.out / 'result.json', result)
    print(json.dumps(result, indent=2), flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
