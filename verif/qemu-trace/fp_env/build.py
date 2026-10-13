"""Private matched QEMU relinks; rebuild only the real environment helper.

The canonical source, objects and executable are read-only. Original Ninja
commands supply the compiler/linker options, including all unchanged objects.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time
import traceback

import prepare

REPO = Path(__file__).resolve().parents[3]
QEMU = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu'
BUILD = QEMU/'build-sys'
CANONICAL = 'b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd'
NINJA = Path('/home/yukidama/miniconda3/bin/ninja')


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, value):
    with p.open('x') as f:
        json.dump(value, f, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3+512*1024**2
    assert os.environ['INVOCATION_ID'] and os.sched_getaffinity(0)==set(range(8,16))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'], check=True, pass_fds=(9,))
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode==1
    assert sha(BUILD/'qemu-system-i386')==CANONICAL
    source = QEMU/'target/i386/tcg/fpu_helper.c'
    original = source.read_text()
    repaired = prepare.transform(original)
    commands = json.loads((BUILD/'compile_commands.json').read_text())
    rows = [c for c in commands if c['file'].endswith('/target/i386/tcg/fpu_helper.c')]
    assert len(rows)==1
    old_compile = shlex.split(rows[0]['command'])
    links = json.loads(subprocess.check_output([NINJA,'-t','compdb','-x','c_LINKER_RSP'], cwd=BUILD, text=True))
    links = [c for c in links if c['output']=='qemu-system-i386']
    assert len(links)==1
    old_link = shlex.split(links[0]['command'])
    old_object = old_compile[old_compile.index('-o')+1]
    assert old_link.count(old_object)==1 and old_link.count('-o')==1
    pins = {}
    def pin(p):
        p = Path(p).resolve(strict=True)
        pins[str(p)] = sha(p)
    for p in (source, BUILD/'qemu-system-i386', BUILD/'build.ninja', BUILD/'compile_commands.json',
              Path(__file__), Path(prepare.__file__), Path(__file__).with_name('test_prepare.py'),
              REPO/'tools/build_scope.sh', NINJA, Path(shutil.which(old_compile[0]))):
        pin(p)
    # Include thin-archive members, not just their small archive indexes.
    for token in old_link[1:]:
        p = (BUILD/token).resolve()
        if p.is_file():
            pin(p)
            with p.open('rb') as f:
                thin = f.read(8)==b'!<thin>\n'
            if thin:
                for member in subprocess.check_output(['ar','t',p], text=True).splitlines():
                    pin(p.parent/member)
    root.mkdir()
    save(root/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), compiler=old_compile, linker=old_link,
        canonical_changed=False, matched_helper_relink=True))
    begin = time.monotonic()
    result = dict(passed=False, rows=[], errors=[], canonical_gate_passed=False,
                  hardware_acceptance=False, gameplay_ipc=None)
    try:
        for variant in ('control','candidate','wrong-v86-mode'):
            assert shutil.disk_usage(scratch).free > 4*1024**3+128*1024**2
            folder = root/variant
            folder.mkdir()
            text = original if variant=='control' else repaired
            if variant=='wrong-v86-mode':
                anchor = ' || (env->eflags & VM_MASK)'
                assert text.count(anchor)==2
                text = text.replace(anchor, '')
            local_source, obj, binary = folder/'fpu_helper.c', folder/'helper.o', folder/'qemu-system-i386'
            local_source.write_text(text)
            pin(local_source)
            flags = []
            i = 1
            while i < len(old_compile):
                token = old_compile[i]
                if token in ('-MQ','-MF','-o','-c'):
                    i += 2
                    continue
                if token=='-MD':
                    i += 1
                    continue
                flags.append(token)
                i += 1
            # Preserve the original source-directory quoted-include lookup.
            # Only the .c translation unit is private; its headers stay pinned.
            flags = ['-iquote', str(source.parent), *flags]
            def run(label, command):
                save(folder/(label+'-command.json'), list(map(str, command)))
                with (folder/(label+'.log')).open('x') as log:
                    native = subprocess.run(command, cwd=BUILD, stdout=log, stderr=subprocess.STDOUT, timeout=180)
                save(folder/(label+'-exit.json'), dict(native_exit=native.returncode))
                assert native.returncode==0, (variant,label,native.returncode)
            def deps(p):
                return {(BUILD/n).resolve(strict=True) for n in shlex.split(p.read_text().replace('\\\n',' '))[1:]}
            run('dependencies', [old_compile[0], *flags, '-M','-MF',folder/'before.d','-MT','helper',local_source])
            before = deps(folder/'before.d')
            assert local_source in before
            for p in before:
                pin(p)
            save(folder/'compile-inputs.json', dict(pins=pins))
            assert all(sha(p)==h for p,h in pins.items())
            run('compile', [old_compile[0], *flags, '-MD','-MF',folder/'after.d','-c',local_source,'-o',obj])
            assert deps(folder/'after.d')==before
            command = [str(obj) if s==old_object else s for s in old_link]
            command[command.index('-o')+1] = str(binary)
            run('link', command)
            version = subprocess.check_output([binary,'--version'], text=True)
            assert '8.2.2' in version
            result['rows'].append(dict(variant=variant, binary=str(binary), sha256=sha(binary),
                helper_sha256=sha(obj), source_sha256=sha(local_source), version=version,
                artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()}))
        result['passed'] = True
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins=pins, pins_unchanged=all(sha(p)==h for p,h in pins.items()), seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save(root/'closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}, indent=2), flush=True)
    return int(not result['passed'])


if __name__=='__main__':
    raise SystemExit(main())
