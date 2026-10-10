#!/usr/bin/env python3
"""Triangulate eight canonical C1 first divergences without changing a gate.

Runs each exact, unmodified gate ELF on native x87. The passive observer steps
only this diagnostic child, reads the selected instruction's operands/status,
and resumes it to exit. This is neither RTL single-step acceptance nor a P54
timing oracle. Results are diagnostic JSON, not a new .vtrace producer.
"""
import argparse
from fractions import Fraction
import json
import os
from pathlib import Path
import re
import subprocess
import time

from run_srt_c1_observe import fraction, sha

TESTS = ('tx_unifdiv', 'tx_muldiv', 'tx_fprem', 'tx_round',
         'tx_fp_denorm', 'tx_addsub', 'tx_chain', 'tx_sqrt')


def binary64(bits):
    sign, exp, mant = bits >> 63, (bits >> 52) & 2047, bits & ((1 << 52)-1)
    assert exp != 2047
    if exp:
        mant |= 1 << 52
    power = max(exp, 1) - 1023 - 52
    value = Fraction(mant << max(0, power), 1 << max(0, -power))
    return -value if sign else value


def exact_operation(witness):
    """Decode just the seven observed encodings, fail closed for anything else."""
    code = bytes.fromhex(witness['instruction_prefix'])
    st = [fraction(int(x, 16)) for x in witness['before']['st'][:2]]
    result_bits = int(witness['after']['st'][0], 16)
    is_inf = ((result_bits >> 64) & 0x7fff) == 0x7fff
    if is_inf:
        assert (result_bits & ((1 << 64)-1)) == 1 << 63, 'NaN outside this witness'
        r = None
    else:
        r = fraction(result_bits)
    if code[:2] == b'\xde\xf1':
        operation, e = 'FDIVRP ST1,ST0: old ST0 / old ST1', st[0] / st[1]
    elif code[:2] == b'\xde\xf9':
        operation, e = 'FDIVP ST1,ST0: old ST1 / old ST0', st[1] / st[0]
    elif code[:2] == b'\xd8\xf9':
        operation, e = 'FDIVR ST0,ST1: old ST1 / old ST0', st[1] / st[0]
    elif code[:2] == b'\xd8\xf1':
        operation, e = 'FDIV ST0,ST1: old ST0 / old ST1', st[0] / st[1]
    elif code[:2] == b'\xde\xc9':
        operation, e = 'FMULP ST1,ST0', st[0] * st[1]
    elif code[:2] == b'\xdc\x25':
        assert int.from_bytes(code[2:6], 'little') == int(witness['operand_address'], 16)
        operation, e = 'FSUB ST0,m64real', st[0] - binary64(int(witness['operand_bits64'], 16))
    elif code[:2] == b'\xd9\xfa':
        assert r is not None and st[0] >= 0 and r >= 0
        return dict(operation='FSQRT ST0', exact_c1=int(r*r > st[0]),
                    exact_inexact=int(r*r != st[0]), comparison='result squared vs input')
    else:
        raise AssertionError(('unsupported instruction', code.hex()))
    if is_inf:
        assert (result_bits >> 79) == (e < 0)
        assert abs(e) > fraction(0x7ffeffffffffffffffff), 'finite result must overflow'
        return dict(operation=operation, exact_c1=1, exact_inexact=1,
                    comparison='infinite magnitude exceeds finite exact result',
                    exact_numerator_hex=hex(e.numerator), exact_denominator_hex=hex(e.denominator))
    assert not r or not e or (r < 0) == (e < 0)
    # Python 3.11's decimal digit guard need not be changed for the underflow case.
    return dict(operation=operation, exact_c1=int(abs(r) > abs(e)),
                exact_inexact=int(r != e), exact_numerator_hex=hex(e.numerator),
                exact_denominator_hex=hex(e.denominator))


def records(path):
    with path.open() as f:
        header = json.loads(next(f))
        rows = [json.loads(line) for line in f]
    assert [r['n'] for r in rows] == list(range(len(rows)))
    return header, rows


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--work', type=Path, required=True)
    ap.add_argument('--cache', type=Path, required=True)
    ap.add_argument('--observer', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert out.is_relative_to(scratch) and not out.exists()
    out.mkdir()
    pins = {}

    def pin(path):
        path = path.resolve(strict=True)
        pins[str(path)] = sha(path)
        return path

    pin(Path(__file__))
    pin(Path(__file__).with_name('run_srt_c1_observe.py'))
    pin(Path(__file__).with_name('native_x87_at_pc.c'))
    pin(args.observer)
    golden = {}
    for path in args.cache.glob('*.vtrace'):
        with path.open() as f:
            head = json.loads(next(f))
        for name in TESTS:
            if head.get('mode') == 'func' and f'elf={name}.func.elf ' in head.get('note', ''):
                assert name not in golden
                golden[name] = path
    assert set(golden) == set(TESTS)
    findings, invocations = [], []
    for name in TESTS:
        report = pin(args.work / (name+'.func_cmp.txt')).read_text()
        match = re.search(r'n=(\d+) pc=(0x[0-9a-f]+) field=fstat: '
                          r'expected\(A\)=(0x[0-9a-f]+) got\(C\)=(0x[0-9a-f]+)', report)
        assert match, (name, 'not an unmasked first FSW divergence')
        n, pc, qsw, rsw = (int(x, 0 if i else 10) for i, x in enumerate(match.groups()))
        assert qsw ^ rsw == 0x0200
        elf = pin(args.work / (name+'.func.elf'))
        _, rtl = records(pin(args.work / (name+'.func_rtl.vtrace')))
        _, qemu = records(pin(golden[name]))
        assert n > 0 and int(rtl[n]['pc'], 16) == int(qemu[n]['pc'], 16) == pc
        assert int(rtl[n]['fstat'], 16) == rsw and int(qemu[n]['fstat'], 16) == qsw
        count = sum(int(r['pc'], 16) == pc for r in qemu[:n+1])
        argv = [str(args.observer), str(elf), hex(pc), str(count)]
        code = bytes.fromhex(qemu[n]['bytes'])
        if code[:2] == b'\xdc\x25':
            argv.append(hex(int.from_bytes(code[2:6], 'little')))
        start = time.monotonic()
        proc = subprocess.run(argv, capture_output=True, timeout=15,
                              env={**os.environ, 'TMPDIR': str(scratch)})
        (out/(name+'.stdout')).write_bytes(proc.stdout)
        (out/(name+'.stderr')).write_bytes(proc.stderr)
        invocations.append(dict(argv=argv, status=proc.returncode, seconds=time.monotonic()-start))
        assert proc.returncode == 0, (name, proc.stderr)
        witness = json.loads(proc.stdout)
        assert witness['child_reaped'] and witness['native_exit'] == 0
        assert witness['pc'] == qemu[n]['pc'] and witness['occurrence'] == count
        assert bytes.fromhex(witness['instruction_prefix']) == code[:8]
        assert witness['before']['fctrl'] == qemu[n-1]['fctrl'] == rtl[n-1]['fctrl']
        needed = 1 if code[:2] in (b'\xdc\x25', b'\xd9\xfa') else 2
        for i in range(needed):
            assert int(witness['before']['st'][i], 16) == int(qemu[n-1][f'st{i}'], 16) == int(rtl[n-1][f'st{i}'], 16), (name, 'operand mismatch', i)
        assert int(witness['after']['st'][0], 16) == int(qemu[n]['st0'], 16) == int(rtl[n]['st0'], 16), (name, 'result mismatch')
        exact = exact_operation(witness)
        native_c1 = (int(witness['after']['fstat'], 16) >> 9) & 1
        assert native_c1 == exact['exact_c1'] == ((rsw >> 9) & 1), (name, witness, exact)
        assert native_c1 != ((qsw >> 9) & 1)
        findings.append(dict(test=name, gate_record=n, pc=hex(pc), witness=witness,
                             qemu_status=hex(qsw), rtl_status=hex(rsw), exact=exact,
                             operands_equal=True, result_equal=True, rtl_native_exact_c1_equal=True))
    # Fail-closed controls: missing target and non-ELF must fail, not emit a witness.
    controls = []
    for label, argv in [('unreached', [args.observer, args.work/'tx_round.func.elf', '0x1', '1']),
                        ('not_elf', [args.observer, Path(__file__), '0x1', '1'])]:
        proc = subprocess.run(list(map(str, argv)), capture_output=True, timeout=15)
        (out/(label+'.stderr')).write_bytes(proc.stderr)
        assert proc.returncode != 0 and not proc.stdout
        controls.append(dict(name=label, status=proc.returncode))
    assert all(sha(p) == h for p, h in pins.items())
    result = dict(kind='CANONICAL_C1_NATIVE_DIAGNOSTIC', cases=len(findings),
                  all_exact_first_divergences_reproduced=True, pins=pins,
                  invocations=invocations, controls=controls, findings=findings,
                  canonical_gate_pass=False, goldens_changed=False, masks_changed=False,
                  gameplay_ipc=None, native_host_is_p54=False)
    (out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','invocations','findings')}))


if __name__ == '__main__':
    main()
