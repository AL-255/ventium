"""Explicit, fail-closed selection of the qualified i386 QEMU 8.2.2 reference.

Compose the existing independently tested recipes directly from the canonical
source snapshot. Do not mutate that tree, infer qualification from a version
string, or accept an arbitrary environment-selected emulator. The exact binary
below has the retained native/exact-oracle qualification described in README.
System-mode QEMU, masks, timing bands and the default reference are unchanged.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
PROFILE = 'i386-defined-x87-preexit-20261016'
BINARY = '998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85'
BEFORE_TREE = 'a6bd62b25b25ca074cdc22de5ce1b48f0451b6efc9957b30cec71627830819b3'
AFTER_TREE = '4093b981d0910792574afc1d69125c846cb783bbd1fe9079432ba036a71058ed'
AFTER = {
    'fpu/softfloat.c': '56323d7a61fb8973d1881af0a8f00773c4073423a058a701e58acff69a73afbd',
    'fpu/softfloat-parts.c.inc': '846f32e0cf0bc15160496551409e5f586f0e6b2725d63918fdd98357d4686ea9',
    'linux-user/syscall.c': '0247b966058a83d13a4b0c95dff2dfdf439be4cac7350e139e1d9ad9c6ff33b8',
    'target/i386/tcg/fpu_helper.c': '9c7e1f80eee6205506f152a6fdbbb532f6f84c4604608c46c96f2be46110c78d',
    'include/fpu/softfloat-types.h': 'd1d7eefb2c95e8c12f1649a8f18e084597c4cde4613241c7ea7dd2643cba8858',
}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def closure(inventory):
    h = hashlib.sha256()
    for name, digest in sorted(inventory.items()):
        require(not Path(name).is_absolute() and '..' not in Path(name).parts,
                'unsafe source member')
        h.update(name.encode()+b'\0'+digest.encode()+b'\n')
    return h.hexdigest()


def inventory(source):
    source = source.resolve(strict=True)
    rows = {}
    for folder, dirs, names in os.walk(source):
        if Path(folder) == source:
            dirs[:] = [n for n in dirs if n not in ('.git', 'build', 'build-sys')]
        for name in names:
            path = Path(folder)/name
            if path.is_file():
                rows[str(path.relative_to(source))] = sha(path)
    return rows


def recipe(relative):
    name = 'vtm_reference_'+relative.replace('/', '_').replace('.', '_')
    spec = importlib.util.spec_from_file_location(name, HERE/relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def compose(inputs):
    """Exactly the already-qualified five-file delta; no frozen-run dependency."""
    require(set(inputs) == set(AFTER), 'need all five source inputs')
    c1 = recipe('c1_reference/prepare.py')
    derived = c1.transform({n:text for n,text in inputs.items() if n!='linux-user/syscall.c'})
    helper = 'target/i386/tcg/fpu_helper.c'
    for name in ('frndint/prepare.py', 'remainder_sequence/prepare.py',
                 'remainder_sequence/prepare_exception.py', 'remainder_sequence/prepare_underflow.py'):
        derived[helper] = recipe(name).transform(derived[helper])
    observer = recipe('prepare_preexit_observer.py')
    derived['linux-user/syscall.c'] = observer.transform(observer.host_compat(inputs['linux-user/syscall.c']))
    for name, text in derived.items():
        require(hashlib.sha256(text.encode()).hexdigest()==AFTER[name], 'derived source mismatch: '+name)
    return derived


def check_source(source):
    before = inventory(source)
    require(len(before)==11132 and closure(before)==BEFORE_TREE, 'canonical source closure drift')
    changed = compose({n:(source/n).read_text() for n in AFTER})
    after = dict(before, **{n:hashlib.sha256(t.encode()).hexdigest() for n,t in changed.items()})
    require(closure(after)==AFTER_TREE, 'composed source closure mismatch')
    return dict(profile=PROFILE, files=len(before), before=BEFORE_TREE, after=AFTER_TREE,
                changed=sorted(changed), source_modified=False)


def validate_receipt(closed, sources):
    require(closed.get('passed') is True and closed.get('pins_unchanged') is True,
            'reference build is not closed successfully')
    require(closed.get('sha256')==BINARY and closed.get('source_files')==11132,
            'binary is not independently qualified for this profile')
    require(len(sources)==11132 and closure(sources)==AFTER_TREE, 'reference source closure drift')
    require(all(sources.get(n)==h for n,h in AFTER.items()), 'reference recipe mismatch')


def select(build):
    build = build.resolve(strict=True)
    closed = json.loads((build/'closed.json').read_text())
    sources = json.loads((build/'source.json').read_text())['after']
    validate_receipt(closed, sources)
    binary = (build/'build/qemu-i386').resolve(strict=True)
    require(Path(closed['binary']).resolve(strict=True)==binary, 'build/binary path mismatch')
    require(sha(binary)==BINARY and os.access(binary,os.X_OK), 'reference executable drift')
    require(inventory(build/'source')==sources, 'reference source files drifted')
    require('\n' not in str(binary) and '\r' not in str(binary), 'invalid binary path')
    return binary


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument('--check-source', type=Path)
    group.add_argument('--select-build', type=Path)
    args = ap.parse_args()
    try:
        if args.check_source:
            print(json.dumps(check_source(args.check_source.resolve(strict=True))))
        else:
            print(select(args.select_build))
    except (OSError, ValueError, KeyError) as error:
        print('qualified QEMU profile rejected: '+str(error), file=sys.stderr)
        raise SystemExit(1)
