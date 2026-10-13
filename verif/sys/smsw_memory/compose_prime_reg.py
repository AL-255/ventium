"""Compose the separately tested SMSW repair and register-flag timing change.

Only prepare immutable sources here: no compilation, synthesis or promotion.
Require a common, byte-identical ancestor and exact, disjoint changes. The
combined model still needs its own native build, differential and system tests.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys

import prepare as smsw

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO/'verif/l1'))
import prepare_prime_reg_flags as flags
from build_mc_branch_residency_core import relocate

MODELS = {
    'ancestor': '73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca',
    'flags': '0070aec34169c368f11fb723f33aaeb8f60f0617d9e2f33948e2cd347567c143',
    'smsw': 'cbf749f16babd88fb5dcf508c2381d48b77dedd348e9b23a5ed9083de9f4e65e',
}
FLAG_PATH = 'rtl/core/core_mem_chain.svh'
SMSW_PATHS = sorted('rtl/core/'+name for name in smsw.PARENTS)
AUDITS = {
    'prime-reg-core-audit-r1.json': 'f826b73fd800c991ce937cdee74f85502cca05db7be88abf35c6167b6db13bed',
    'smsw-diff-r1/audit.json': 'b2dcb434a336f655330994bd8f3082185e54d20b3879a0562ecac56d63f6ad52',
    'smsw-corners-audit-r1.json': '40789a717d90f1e201945b4b608799e57c23b33ea54ba40da559ad08dafe72f6',
    'smsw-retry-audit-r1.json': 'a255b4306164502c097503620f7f6e5be3958e9120e4726b566759ae47d94844',
}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def check_audit(name, audit):
    # A successful audit of expected reference disagreements is not a green gate.
    if name == 'smsw-corners-audit-r1.json':
        assert audit['audit_passed']
        assert (audit['differential_cases'], audit['intel_spec_only_cases']) == (85, 20)
        assert not audit['complete_fault_differential_gate_passed']
    else:
        assert audit['passed']
    assert not audit['standard_suite'] and not audit['hardware_acceptance']
    assert audit['gameplay_ipc'] is None


def combine(ancestor, register_flags, repair):
    """Return the exact four-file union, or reject any source/recipe drift."""
    if not ancestor or ancestor.keys() != register_flags.keys() or ancestor.keys() != repair.keys():
        raise ValueError('source closure differs')
    changed_flags = {p for p in ancestor if ancestor[p] != register_flags[p]}
    changed_smsw = {p for p in ancestor if ancestor[p] != repair[p]}
    if changed_flags != {FLAG_PATH} or changed_smsw != set(SMSW_PATHS):
        raise ValueError('unexpected or overlapping source changes')
    expected_flags = flags.transform({n: ancestor['rtl/core/'+n].decode() for n in flags.PARENTS}).encode()
    if register_flags[FLAG_PATH] != expected_flags:
        raise ValueError('flag candidate differs from tested recipe')
    for path in SMSW_PATHS:
        if repair[path] != smsw.transform(ancestor[path].decode(), Path(path).name).encode():
            raise ValueError('SMSW candidate differs from tested recipe')
    output = dict(register_flags)
    output.update({p: repair[p] for p in SMSW_PATHS})
    # Both orders must produce exactly the same bytes, including untouched files.
    reverse = dict(repair)
    reverse[FLAG_PATH] = register_flags[FLAG_PATH]
    assert output == reverse
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    evidence, out = args.evidence.resolve(strict=True), args.out.resolve()
    assert __debug__ and evidence.is_relative_to(scratch)
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    roots = {k: evidence/v for k, v in (
        ('ancestor', 'prime-cs-core-r1'), ('flags', 'prime-reg-core-r1'), ('smsw', 'smsw-core-r1'))}
    pins, sources, starts = {}, {}, {}
    for label, root in roots.items():
        started = json.loads((root/'build-started.json').read_text())
        closed = json.loads((root/'build-closed.json').read_text())
        assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
        assert sha(root/'obj/tb_ventium') == closed['binary_sha256'] == MODELS[label]
        source = root/'candidate'
        paths = sorted(p for p in source.rglob('*') if p.is_file())
        assert len(paths) == 195 and not any(p.is_symlink() for p in source.rglob('*'))
        assert all(sha(p) == started['pins'][str(p)] for p in paths)
        sources[label] = {str(p.relative_to(source)): p.read_bytes() for p in paths}
        starts[label] = started
        for p in (*paths, root/'obj/tb_ventium', root/'build-started.json', root/'build-closed.json'):
            pins[str(p)] = sha(p)
    definition_args = [[s for s in starts[k]['command'] if s.startswith('VL_EXTRA_DEFINES=')]
                       for k in roots]
    assert len(definition_args[0]) == 1 and all(x == definition_args[0] for x in definition_args)
    definitions = re.findall(r'\+define\+(\w+)', definition_args[0][0])
    assert len(definitions) == len(set(definitions)) == 152 and '--assert' in definition_args[0][0]
    assert {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_RAW_V_READ_PRIME'} <= set(definitions)
    output = combine(sources['ancestor'], sources['flags'], sources['smsw'])
    for name, digest in AUDITS.items():
        path = evidence/name
        assert sha(path) == digest
        audit = json.loads(path.read_text())
        check_audit(name, audit)
        for p, h in audit['pins'].items():
            assert sha(p) == h
            pins[p] = h
        pins[str(path)] = digest
    parent = roots['flags']
    old = starts['flags']
    # Retain build inputs, not just RTL; never reuse the model-dependent object.
    for p, h in old['pins'].items():
        assert sha(p) == h
        pins[p] = h
    for path in (Path(__file__).resolve(), Path(smsw.__file__), Path(flags.__file__),
                 Path(__file__).with_name('test_compose_prime_reg.py')):
        pins[str(path)] = sha(path)
    assert all(sha(p) == h for p, h in pins.items())
    out.mkdir()
    shutil.copytree(parent/'candidate', out/'candidate')
    for name in SMSW_PATHS:
        (out/'candidate'/name).write_bytes(output[name])
    assert all((out/'candidate'/p).read_bytes() == content for p, content in output.items())
    host = out/('tb_smsw_prime_reg_'+hashlib.sha256(str(out).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'], host)
    command = relocate(old['command'], parent, out, Path(old['host']), host)
    assert 'VL_J=32' in command
    pins[str(host)] = sha(host)
    pins.update({str(out/'candidate'/p): sha(out/'candidate'/p) for p in output})
    receipt = dict(pins=pins, command=command, host=str(host), parent=str(parent),
        parent_model=MODELS['flags'], input_models=MODELS, definitions=definitions,
        changes=SMSW_PATHS, ancestor_changes=sorted([FLAG_PATH]+SMSW_PATHS),
        exact_disjoint_composition=True, compiler_started=False,
        parent_fault_differential_gate_passed=False, parent_intel_spec_only_cases=20,
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
        gameplay_ipc=None, fmax_mhz=None)
    with (out/'prepared.json').open('x') as stream:
        json.dump(receipt, stream, indent=2)
    print(json.dumps(dict(prepared=str(out), sources=len(output), pins=len(pins),
                         exact_disjoint_composition=True, compiler_started=False)))


if __name__ == '__main__':
    main()
