"""Bind the complete original boundary gate to a natively qualified backport.

No fixture, expected exit, trace comparison or latency matrix is changed.
In particular, original finite-CS failures remain failures of this gate.
"""
import ast
import hashlib
import json
from pathlib import Path

import prepare

REPO = Path(__file__).resolve().parents[3]
SOURCE = REPO/'verif/fe_pipe/run-prefix66-boundary.py'
SOURCE_SHA = '228547205cd3da23062acceb5ff23b067e48651d4a03ed0084b413207a587393'


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def qualified_qemu(build_root, native_root):
    build_root, native_root = build_root.resolve(strict=True), native_root.resolve(strict=True)
    built = json.loads((build_root/'closed.json').read_text())
    native = json.loads((native_root/'closed.json').read_text())
    started = json.loads((native_root/'started.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and len(built['rows']) == 2
    assert native['native_backport_passed'] and native['pins_unchanged'] and not native['errors']
    assert len(native['rows']) == 30 and not native['original_boundary_gate_passed']
    assert native['finite_cs_limit_discrepancy_unfixed']
    pins = dict(started['pins'])
    for name,digest_value in built['pins'].items():
        assert name not in pins or pins[name] == digest_value
        pins[name] = digest_value
    for row in built['rows']:
        for name,digest_value in row['artifacts'].items():
            assert name not in pins or pins[name] == digest_value
            pins[name] = digest_value
    for name,digest_value in native['artifacts'].items():
        pins[str(native_root/name)] = digest_value
    assert all(digest(name) == value for name,value in pins.items())
    assert (build_root/'candidate/tb-maint.c').read_text() == prepare.transform(
        (build_root/'control/tb-maint.c').read_text())
    candidate = [row for row in built['rows'] if row['variant'] == 'candidate']
    assert len(candidate) == 1
    qemu = Path(candidate[0]['binary']).resolve(strict=True)
    assert digest(qemu) == candidate[0]['sha256']
    for path in (SOURCE, Path(__file__), Path(prepare.__file__), build_root/'closed.json',
                 native_root/'closed.json', native_root/'started.json'):
        pins[str(path.resolve())] = digest(path)
    return qemu, pins


def derive():
    text = SOURCE.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == SOURCE_SHA
    changes = (
        ('HERE=Path(__file__).resolve().parent;REPO=HERE.parents[1]',
         'HERE=SOURCE.parent;REPO=HERE.parents[1]'),
        ("    args=ap.parse_args()", "    ap.add_argument('--qemu-build',type=Path,required=True)\n"
         "    ap.add_argument('--native-result',type=Path,required=True)\n    args=ap.parse_args()"),
        ("    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'",
         "    qemu,private_pins=qualified_qemu(args.qemu_build,args.native_result)"),
        ('    profiles={}', '    pins.update(private_pins)\n    profiles={}'),
    )
    for before,after in changes:
        assert text.count(before) == 1, before
        text = text.replace(before,after)
    ast.parse(text)
    return text


if __name__ == '__main__':
    exec(compile(derive(),str(__file__),'exec'),globals())
