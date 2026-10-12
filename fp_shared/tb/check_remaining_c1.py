#!/usr/bin/env python3
"""Classify closed pre-exit differences without changing any acceptance oracle.

Uses real saved native packets, unchanged RTL/QEMU traces, and exact arithmetic.
Only three missing memory operands are read again, passively, from the original
ELFs. This is a diagnostic, not a .vtrace producer or a P54 silicon oracle.
Intel 241430-004, Table 6-4 (6-12), 7-27 and instruction pages apply.
"""
import argparse
from collections import Counter
from fractions import Fraction
import json
import os
from pathlib import Path
import shutil
import subprocess

from check_preexit_c1_native import exact_operation, records
from run_srt_c1_observe import fraction, sha


def binary32(bits):
    sign, exponent, mantissa = bits >> 31, (bits >> 23) & 255, bits & 0x7fffff
    assert exponent != 255, 'nonfinite memory operand outside this diagnostic'
    if exponent:
        mantissa |= 1 << 23
    power = max(exponent, 1) - 127 - 23
    value = Fraction(mantissa << max(power, 0), 1 << max(-power, 0))
    return -value if sign else value


def store_c1(value, precision, emin, emax, rc):
    """Exact binary32/64 narrowing increment; no host float or observed result."""
    assert precision in (24, 53) and rc in range(4)
    if not value:
        return 0
    magnitude = abs(value)
    exponent = magnitude.numerator.bit_length() - magnitude.denominator.bit_length()
    power = Fraction(1 << max(exponent, 0), 1 << max(-exponent, 0))
    if magnitude < power:
        exponent -= 1
    unit = max(exponent, emin) - precision + 1
    scaled = magnitude * Fraction(1 << max(-unit, 0), 1 << max(unit, 0))
    quotient, remainder = divmod(scaled.numerator, scaled.denominator)
    away = (rc == 1 and value < 0) or (rc == 2 and value > 0)
    increment = int((rc == 0 and (2*remainder > scaled.denominator or
                    (2*remainder == scaled.denominator and quotient & 1))) or
                    (away and remainder != 0))
    overflow = exponent > emax or (exponent == emax and
                                   quotient + increment == 1 << precision)
    return int(rc == 0 or away) if overflow else increment


def classify(witness):
    code = bytes.fromhex(witness['instruction_prefix'])
    before, after = witness['before'], witness['after']
    sw0, sw1 = int(before['fstat'], 16), int(after['fstat'], 16)
    top = (sw0 >> 11) & 7
    tags = int(before['fxsave_tag'], 16)
    if code[:2] == b'\xdd\xd8':
        exact = exact_operation(witness)  # Also checks actual pop/tag semantics.
        return 'defined_zero', exact['exact_c1']
    if code[:2] in (b'\xd9\x05', b'\xdd\x05'):
        assert not tags & (1 << ((top-1) & 7)), 'stack overflow outside scope'
        assert ((sw1 >> 11) & 7) == (top-1) & 7
        assert int(after['fxsave_tag'], 16) == tags | (1 << ((top-1) & 7))
        assert not sw1 & 0x41, 'invalid/stack exception outside scope'
        return 'defined_zero', 0
    if code[:2] in (b'\xd9\x15', b'\xdd\x15'):
        assert tags & (1 << top), 'stack underflow outside scope'
        assert before['st'] == after['st'] and before['fxsave_tag'] == after['fxsave_tag']
        assert before['fctrl'] == after['fctrl'] and ((sw1 >> 11) & 7) == top
        args = (24, -126, 127) if code[0] == 0xd9 else (53, -1022, 1023)
        return 'defined_rounding', store_c1(fraction(int(before['st'][0], 16)),
                                            *args, (int(before['fctrl'], 16) >> 10) & 3)
    if code[:2] == b'\xd8\x35':
        assert int.from_bytes(code[2:6], 'little') == int(witness['operand_address'], 16)
        divisor = binary32(int(witness['operand_bits64'], 16) & 0xffffffff)
        assert divisor
        exact = fraction(int(before['st'][0], 16)) / divisor
        actual = fraction(int(after['st'][0], 16))
        return 'defined_rounding', int(abs(actual) > abs(exact))
    if code[:2] in (b'\xdc\x25', b'\xde\xf9', b'\xde\xc9', b'\xde\xf1',
                    b'\xd8\xf1', b'\xd8\xf9', b'\xd9\xfa'):
        return 'defined_rounding', exact_operation(witness)['exact_c1']
    if code[:2] == b'\xdf\xe0' or code[:3] == b'\x0f\xb7\xc8':
        assert (sw0 ^ sw1) & 0x200 == 0
        return 'observed_retention', None
    if code[0] == 0x9b:
        # The eight-byte peek is not an instruction-length claim. Native and
        # both traces retire FWAIT separately from the following FNINIT here.
        assert int(witness['gprs_after']['eip'], 16) == int(witness['gprs_before']['eip'], 16) + 1
        assert before == after
        assert not ((sw0 & 0x3f) & ~int(before['fctrl'], 16))
        return 'observed_retention', None
    raise AssertionError(('instruction outside diagnostic scope', code.hex()))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--native-result', type=Path, required=True)
    ap.add_argument('--gate-audit', type=Path, required=True)
    ap.add_argument('--manual', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert scratch.stat().st_dev != Path('/').stat().st_dev
    assert shutil.disk_usage(scratch).free > 4 * 1024**3
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.sched_getaffinity(0) == {12}
    out = args.out.resolve()
    assert out.is_relative_to(scratch) and not out.exists()
    out.mkdir()
    pins = {}

    def pin(path):
        path = Path(path).resolve(strict=True)
        pins[str(path)] = sha(path)
        return path

    for path in (Path(__file__), Path(__file__).with_name('check_preexit_c1_native.py'),
                 Path(__file__).with_name('run_srt_c1_observe.py'), args.manual):
        pin(path)
    source = json.loads(pin(args.native_result).read_text())
    gate = json.loads(pin(args.gate_audit).read_text())
    assert source['inputs_unchanged'] and gate['audit_complete']
    assert source['sites'] == 117 and source['fields'] == 161
    assert all(sha(path) == digest for path, digest in source['pins'].items())
    expected = {(r['name'], d['n'], d['field']): d for r in gate['reports'] for d in r['differences']}
    traces = {}
    for report in gate['reports']:
        _, golden = records(pin(report['command'][-2]))
        _, rtl = records(pin(report['command'][-1]))
        assert len(golden) == len(rtl)
        traces[report['name']] = golden, rtl
    observer = pin(source['rows'][0]['command'][0])
    findings, counts, calls, seen = [], Counter(), [], set()
    for row in source['rows']:
        name, n = row['test'], row['n']
        golden, rtl = traces[name]
        witness = row['witness']
        assert witness == json.loads(pin(args.native_result.parent / f'{name}-{n}.stdout').read_text())
        assert witness['child_reaped'] and witness['native_exit'] == 0
        assert witness['instruction_prefix'] == golden[n]['bytes'][:16]
        assert witness['before']['fctrl'] == golden[n-1]['fctrl'] == rtl[n-1]['fctrl']
        code = bytes.fromhex(witness['instruction_prefix'])
        if code[:2] in (b'\xdc\x25', b'\xd8\x35'):
            command = row['command'] + [hex(int.from_bytes(code[2:6], 'little'))]
            assert Path(command[0]).resolve() == observer
            pin(command[1])
            proc = subprocess.run(command, capture_output=True, text=True, timeout=15)
            (out / f'{name}-{n}.stdout').write_text(proc.stdout)
            (out / f'{name}-{n}.stderr').write_text(proc.stderr)
            assert proc.returncode == 0, proc.stderr
            memory_witness = json.loads(proc.stdout)
            for field in ('before', 'after', 'instruction_prefix', 'pc', 'occurrence'):
                assert memory_witness[field] == witness[field]
            assert memory_witness['child_reaped'] and memory_witness['native_exit'] == 0
            witness = memory_witness
            calls.append(dict(command=command, native_exit=proc.returncode))
        for field in row['fields']:
            key = name, n, field['field']
            assert key in expected and key not in seen
            seen.add(key)
            difference = expected[key]
            value = int(witness['after']['fstat'] if key[2] == 'fstat'
                        else witness['gprs_after'][key[2]], 16)
            assert value == int(difference['actual'], 16) == int(rtl[n][key[2]], 16)
            assert int(difference['expected'], 16) == int(golden[n][key[2]], 16) != value
            if key[2] != 'fstat':
                # Full native value comparison; no claim of complete taint analysis.
                category, c1 = 'native_gpr_only', None
            elif value ^ int(difference['expected'], 16) == 0x100:
                assert code[:2] == b'\xcd\x80' and name == 'tx_fprem' and n == 300
                category, c1 = 'terminal_c0_unqualified', None
            else:
                assert value ^ int(difference['expected'], 16) == 0x200
                category, c1 = classify(witness)
                if c1 is not None:
                    assert c1 == (value >> 9) & 1
                    assert c1 != (int(difference['expected'], 16) >> 9) & 1
                    # Arithmetic input and result values agree independently;
                    # the C1 decision does not come from either status packet.
                    if category == 'defined_rounding':
                        needed = 2 if code[0] == 0xde or code[:2] in (b'\xd8\xf1', b'\xd8\xf9') else 1
                        for i in range(needed):
                            assert int(witness['before']['st'][i], 16) == int(golden[n-1][f'st{i}'], 16) == int(rtl[n-1][f'st{i}'], 16)
                        assert int(witness['after']['st'][0], 16) == int(golden[n]['st0'], 16) == int(rtl[n]['st0'], 16)
            counts[category] += 1
            findings.append(dict(test=name, n=n, field=key[2], category=category, exact_c1=c1))
    assert seen == expected.keys()
    assert all(sha(path) == digest for path, digest in pins.items())
    assert all(sha(path) == digest for path, digest in source['pins'].items())
    result = dict(kind='REMAINING_C1_SPEC_DIAGNOSTIC', counts=dict(counts), fields=len(seen),
                  source_model=gate['model'], calls=calls, findings=findings, pins=pins,
                  invocation=os.environ.get('INVOCATION_ID'), affinity=sorted(os.sched_getaffinity(0)),
                  manual_pages=[151, 218, 704, 739, 740, 754, 755],
                  native_host_is_p54=False, canonical_gate_pass=False,
                  masks_goldens_bands_rtl_changed=False, gameplay_ipc=None,
                  complete_architectural_oracle=False, inputs_unchanged=True)
    with (out / 'result.json').open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps({k: v for k, v in result.items() if k not in ('pins', 'findings', 'calls')}))


if __name__ == '__main__':
    main()
