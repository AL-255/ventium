#!/usr/bin/env python3
"""Audit stored-status propagation in CLOSED pre-exit traces; no simulator run.

This is not an oracle, a mask generator, or an architectural C1 qualification.
It checks the complete 32-bit FNSTSW/MOVZX/preservation equations independently
on both traces, explaining GPR divergences without replacing either value.
Intel 241430-004, printed pp. 25-143/144, specifies that FNSTSW AX stores the
status from the prior ESC; its post-instruction condition codes are undefined.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path


def number(row, field):
    return int(row[field], 16)


def analyze(golden, rtl, differences):
    assert len(golden) == len(rtl) and golden, 'trace length'
    wanted = {(d['n'], d['field']): d for d in differences
              if d['field'] in ('eax', 'ecx')}
    assert len(wanted) == sum(d['field'] in ('eax', 'ecx') for d in differences)
    origin = {}
    observations = []
    for n, (g, r) in enumerate(zip(golden, rtl)):
        assert g['n'] == r['n'] == n and g['pc'] == r['pc'], 'record identity'
        code = bytes.fromhex(g['bytes'])
        assert code, 'missing opcode'
        old_origin = dict(origin)
        for field in ('eax', 'ecx'):
            gv, rv = number(g, field), number(r, field)
            if gv == rv:
                assert (n, field) not in wanted, 'reported difference disappeared'
                origin.pop(field, None)
                continue
            assert n and gv ^ rv == 0x200, 'unexpected GPR divergence'
            pg, pr = golden[n-1], rtl[n-1]
            if code.startswith(b'\xdf\xe0') and field == 'eax':
                for before, after in ((pg, g), (pr, r)):
                    assert number(after, field) == (
                        (number(before, field) & 0xffff0000) |
                        number(before, 'fstat')), 'FNSTSW full EAX equation'
                assert number(pg, 'fstat') ^ number(pr, 'fstat') == 0x200
                origin[field] = dict(fnstsw_record=n, fsw_input_record=n-1,
                                     pc=g['pc'])
                kind = 'FNSTSW_AX_from_prior_status'
            elif code.startswith(b'\x0f\xb7\xc8') and field == 'ecx':
                for before, after in ((pg, g), (pr, r)):
                    assert number(after, field) == number(before, 'eax') & 0xffff, \
                        'MOVZX full ECX equation'
                assert 'eax' in old_origin, 'MOVZX input has no status origin'
                origin[field] = dict(old_origin['eax'])
                kind = 'MOVZX_ECX_AX'
            else:
                # Only instructions observed here which cannot write this GPR.
                # Do not treat unchanged XOR, or an unknown opcode, as proof.
                raw = code[1:] if code[0] == 0x9b else code
                x87 = bool(raw) and 0xd8 <= raw[0] <= 0xdf
                writes_ax = raw.startswith(b'\xdf\xe0')
                permitted = (x87 and not (writes_ax and field == 'eax')) or (
                    code.startswith(b'\x0f\xb7\xc8') and field == 'eax')
                assert permitted, ('unsupported preserving opcode', code.hex(), field)
                assert number(pg, field) == gv and number(pr, field) == rv, \
                    'full GPR preservation equation'
                assert field in old_origin, 'unexplained preexisting difference'
                kind = 'preserved_status_copy'
            assert (n, field) in wanted, 'unreported GPR divergence'
            d = wanted[(n, field)]
            assert int(d['expected'], 16) == gv and int(d['actual'], 16) == rv
            observations.append(dict(n=n, field=field, kind=kind,
                golden=gv, rtl=rv, origin=dict(origin[field])))
    assert len(observations) == len(wanted), 'reported coverage'
    return observations


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def records(path):
    with Path(path).open() as stream:
        header = json.loads(next(stream))
        assert header['vtrace'] == 1 and header['mode'] == 'func'
        return [json.loads(line) for line in stream]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--native-result', type=Path, required=True)
    ap.add_argument('--functional-audit', type=Path, required=True)
    args = ap.parse_args()
    assert __debug__, 'assertions must be enabled'
    native = json.loads(args.native_result.read_text())
    audit = json.loads(args.functional_audit.read_text())
    assert native['inputs_unchanged'] and audit['audit_complete']
    pins = dict(native['pins'])
    for path in (Path(__file__), args.native_result, args.functional_audit):
        resolved = str(path.resolve(strict=True))
        digest = sha(path)
        assert resolved not in pins or pins[resolved] == digest
        pins[resolved] = digest
    assert all(sha(path) == digest for path, digest in pins.items()), 'input drift'
    native_fields = {(row['test'], row['n'], f['field']): f
        for row in native['rows'] for f in row['fields'] if f['field'] in ('eax', 'ecx')}
    observations = []
    for report in audit['reports']:
        golden_path, rtl_path = map(Path, report['command'][-2:])
        for path in (golden_path, rtl_path):
            assert str(path.resolve(strict=True)) in pins, 'unqualified trace'
        for row in analyze(records(golden_path), records(rtl_path), report['differences']):
            key = (report['name'], row['n'], row['field'])
            witness = native_fields[key]
            assert witness['native'] == witness['rtl'] == row['rtl']
            assert witness['qemu'] == row['golden']
            observations.append(dict(test=report['name'], **row))
    assert len(observations) == len(native_fields), 'native field coverage'
    assert all(sha(path) == digest for path, digest in pins.items()), 'closure drift'
    print(json.dumps(dict(kind='CLOSED_PREEXIT_GPR_PROPAGATION_AUDIT',
        passed=True, fields=len(observations),
        categories=dict(Counter(row['kind'] for row in observations)),
        source_pins_rechecked=len(pins), pins=pins, observations=observations,
        c1_architectural_value_qualified=False, canonical_gate_pass=False,
        traces_or_masks_changed=False, standard_suite=False,
        physical_board=False, gameplay_ipc=None), indent=2))


if __name__ == '__main__':
    main()
