#!/usr/bin/env python3
"""Finite memory FST exception witness: native, pinned QEMU and optional RTL.

Uses real FLDCW/FNSTENV/FLDENV and no-wait FNSAVE. It does not synthesize
architectural state, mask trace fields or change the canonical golden. The
Intel P54C volume 3 sections 7.1.12--7.1.15 require an unmasked memory-store
overflow/underflow to preserve both memory and the stack; unmasked precision
still delivers the rounded result. Host x87 is supporting, not P54 silicon.
"""
import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time

import run_fst_memory_observe as masked


def cases():
    result = []
    for bits, emin, emax in ((32, -126, 127), (64, -1022, 1023)):
        for kind, exponent, mantissa in (
            ('normal-exact', 0, 1 << 63),
            ('normal-inexact', 0, (1 << 63)+1),
            ('overflow-exact', emax+1, 1 << 63),
            ('tiny-exact', emin-1, 1 << 63),
            ('tiny-inexact', emin-1, (1 << 63)+1),
            ('tiny-round-normal', emin-1, (1 << 64)-1)):
            for mask in (0x3f, 0x37, 0x2f, 0x1f, 0x07):
                for rc in range(4):
                    for sign in (0, 1):
                        for pop in (0, 1):
                            for seed in (0, 1):
                                result.append(dict(bits=bits, exponent=exponent, mantissa=mantissa,
                                    kind=kind, mask=mask, rc=rc, sign=sign, pop=pop, seed=seed))
    return result


def control(c):
    # Include the architecturally fixed bit 6; host x87 forces it to one.
    return 0x340 | c['mask'] | c['rc'] << 10


def assembly(items):
    lines = masked.assembly(items).splitlines()
    index = 0
    for at, line in enumerate(lines):
        if line.startswith('fldcw '):
            lines[at] = f'fldcw unmasked_cw_{index}'
            index += 1
    if index != len(items):
        raise ValueError('missing real control-word load')
    lines += ['.section .data', '.balign 2']
    for i, c in enumerate(items):
        lines.append(f'unmasked_cw_{i}: .word {control(c)}')
    return '\n'.join(lines)+'\n'


def expected(c):
    want = masked.expected(c)
    p = 24 if c['bits'] == 32 else 53
    magnitude = want['value'] & ((1 << (c['bits']-1))-1)
    tiny = magnitude < (1 << (p-1))
    overflow = bool(want['flags'] & 8)
    blocked = (overflow and not c['mask'] & 8) or (tiny and not c['mask'] & 16)
    if blocked:
        # P54 requires no store/pop. Native x87 reports only the prior-priority
        # range exception, with no rounding increment for these finite cases.
        want = dict(value=int.from_bytes(b'\xa5'*(c['bits']//8), 'little'),
                    flags=8 if overflow else 16, c1=0)
    popped = bool(c['pop'] and not blocked)
    summary = 0x8080 if want['flags'] & ~c['mask'] else 0
    want.update(cw=control(c), sw=(0 if popped else 7 << 11) | summary |
                want['flags'] | want['c1'] << 9,
                tw=0xffff if popped else 0x3fff, blocked=bool(blocked), popped=popped)
    if not popped:
        want['st0'] = masked.input80(c)
    return want


def differences(row, want):
    return [key for key in ('value', 'flags', 'c1', 'cw', 'sw', 'tw', 'st0')
            if key in want and row[key] != want[key]]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--model', type=Path)
    ap.add_argument('--model-sha256')
    a = ap.parse_args()
    if bool(a.model) != bool(a.model_sha256):
        ap.error('--model and --model-sha256 must be supplied together')
    assert __debug__
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = a.out.resolve()
    assert out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch)
    out.mkdir()
    qemu = repo/'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386'
    generator = repo/'verif/qemu-trace/gen_trace.py'
    sources = [Path(__file__).resolve(), Path(masked.__file__).resolve(), qemu,
               generator, repo/'verif/diff/tracefmt.py']
    if a.model:
        assert masked.sha(a.model) == a.model_sha256
        sources.append(a.model.resolve())
    pins = {str(p): masked.sha(p) for p in sources}
    env = {k:v for k,v in os.environ.items()
           if not k.startswith(('VEN_', 'TB_', 'AXI_', 'QEMU_', 'VTM_'))}
    env.update(TMPDIR=str(out), AXI_RLAT='7', AXI_WLAT='7')
    calls = []
    def run(name, argv):
        argv = list(map(str, argv)); start = time.monotonic()
        p = subprocess.run(argv, env=env, capture_output=True, timeout=180)
        (out/(name+'.stdout')).write_bytes(p.stdout)
        (out/(name+'.stderr')).write_bytes(p.stderr)
        calls.append(dict(name=name, argv=argv, native_exit=p.returncode,
                          seconds=time.monotonic()-start))
        assert p.returncode == 0, (name, p.returncode, p.stderr[-1000:])
        return p.stdout
    items = cases()
    (out/'cases.json').write_text(json.dumps(items, indent=2)+'\n')
    (out/'probe.S').write_text(assembly(items))
    run('assemble', ['as', '--32', out/'probe.S', '-o', out/'probe.o'])
    run('link', ['ld', '-m', 'elf_i386', '-Ttext', '0x08048000', '-o', out/'probe.elf', out/'probe.o'])
    streams = {'native': run('native', [out/'probe.elf']),
               'qemu': run('qemu', [qemu, '-cpu', 'pentium', out/'probe.elf'])}
    paired = None
    if a.model:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        run('entry', [sys.executable, '-B', generator, '--qemu', qemu, '--elf', out/'probe.elf',
            '--syscall-proxy', '--image-out', out/'entry.image.json', '--out', out/'entry.vtrace',
            '--max-insn', '0', '--port', str(port)])
        assert len((out/'entry.vtrace').read_text().splitlines()) == 1
        run('rtl', [a.model, '--quake-image', out/'entry.image.json', '--emulate-syscalls',
            '--x87', '--cycle-func', '--l1-axi', '--max-insn', '200000', '--max-cycles',
            '12000000', '--out', out/'rtl.vtrace', '--user-stdout', out/'guest.stdout'])
        stderr = (out/'rtl.stderr').read_text(); stdout = (out/'rtl.stdout').read_text()
        assert 'tb: stop: FREE-RUN guest exit_group(0)' in stderr
        assert '[fault-deliveries] actual=0' in stderr
        match = re.search(r'pairedV=(\d+)', stdout)
        assert match and int(match[1]) > 0
        paired = int(match[1])
        assert re.search(r'backing-ack=[1-9][0-9]*', stdout+stderr)
        streams['rtl'] = (out/'guest.stdout').read_bytes()
    decoded = {name: masked.decode(data, items) for name, data in streams.items()}
    findings = []
    for i, c in enumerate(items):
        want = expected(c)
        observed = {name: rows[i] for name, rows in decoded.items()}
        findings.append(dict(case=c, expected=want, observed=observed,
            differences={name: differences(row, want) for name, row in observed.items()}))
    counts = {name: sum(bool(row['differences'][name]) for row in findings) for name in streams}
    stable = all(masked.sha(p) == h for p,h in pins.items())
    result = dict(kind='FST_MEMORY_UNMASKED_FINITE_DIAGNOSTIC', cases=len(items),
        model=a.model_sha256, mismatch_cases=counts, findings=findings, pins=pins,
        inputs_unchanged=stable, invocations=calls, v_retirements=paired,
        native_is_p54=False, full_instruction_differential=False, standard_suite=False,
        gameplay_ipc=None, nan_or_unsupported_covered=False)
    (out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('findings', 'pins', 'invocations')}))
    return int(not stable or counts['native'] != 0 or counts.get('rtl', 0) != 0)


if __name__ == '__main__':
    raise SystemExit(main())
