"""Private matched QEMU relinks for the upstream two-page TB fix.

Never writes the canonical tree. Run under tools/build_scope.sh after Vivado
has closed, with taskset -c 8-15 and TMPDIR=/home/yukidama/external/tmp.
Compilation is one original translation unit; every other linked object and
thin-archive member remains pinned. Native regressions are a separate step.
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


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def private_flags(command, source):
    """Keep original compiler policy and original quoted-header resolution."""
    result = ['-iquote', str(source.parent)]
    index = 1
    while index < len(command):
        token = command[index]
        if token in ('-MQ', '-MF', '-o', '-c'):
            if index + 1 == len(command):
                raise ValueError('missing argument for '+token)
            index += 2
        elif token == '-MD':
            index += 1
        else:
            result.append(token)
            index += 1
    return result


def private_link(command, original, replacement, binary):
    if command.count(original) != 1 or command.count('-o') != 1:
        raise ValueError('ambiguous original link target or object')
    result = [str(replacement) if token == original else token for token in command]
    result[result.index('-o')+1] = str(binary)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3+512*1024**2
    assert os.environ['INVOCATION_ID'] and os.sched_getaffinity(0) == set(range(8,16))
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    # The shared default scope bounds RAM/tasks, but does not set swap. Lower
    # this small relink's own scope and verify the real effective limits.
    scope = os.environ['VENTIUM_BUILD_SCOPE_UNIT']+'.scope'
    subprocess.run(['systemctl','--user','set-property','--runtime',scope,
                    'MemoryMax=2G','MemorySwapMax=0'],check=True)
    scope_state = dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show',scope,'-p','ActiveState','-p','InvocationID',
        '-p','ControlGroup','-p','MemoryMax','-p','MemorySwapMax','-p','TasksMax'],text=True).splitlines())
    assert scope_state['ActiveState'] == 'active' and scope_state['InvocationID']
    group = Path('/sys/fs/cgroup'+scope_state['ControlGroup'])
    assert Path('/proc/self/cgroup').read_text().strip() == '0::'+scope_state['ControlGroup']
    assert (group/'memory.max').read_text().strip() == str(2*1024**3)
    assert (group/'memory.swap.max').read_text().strip() == '0'
    assert (group/'pids.max').read_text().strip() == '64'
    assert sha(BUILD/'qemu-system-i386') == CANONICAL
    source = QEMU/prepare.FILE
    original = source.read_text()
    repaired = prepare.transform(original)
    commands = json.loads((BUILD/'compile_commands.json').read_text())
    rows = [row for row in commands if row['file'].endswith('/'+prepare.FILE)]
    assert len(rows) == 1
    old_compile = shlex.split(rows[0]['command'])
    links = json.loads(subprocess.check_output(
        [NINJA, '-t', 'compdb', '-x', 'c_LINKER_RSP'], cwd=BUILD, text=True))
    links = [row for row in links if row['output'] == 'qemu-system-i386']
    assert len(links) == 1
    old_link = shlex.split(links[0]['command'])
    old_object = old_compile[old_compile.index('-o')+1]
    assert old_object == 'libqemu-i386-softmmu.fa.p/accel_tcg_tb-maint.c.o'
    assert old_link.count(old_object) == 1
    pins = {}

    def pin(path):
        path = Path(path).resolve(strict=True)
        digest = sha(path)
        assert str(path) not in pins or pins[str(path)] == digest, 'previous input drift'
        pins[str(path)] = digest

    def stable():
        return all(sha(path) == digest for path, digest in pins.items())

    for path in (source, BUILD/'qemu-system-i386', BUILD/'build.ninja', BUILD/'compile_commands.json',
                 Path(__file__), Path(prepare.__file__), Path(__file__).with_name('test_prepare.py'),
                 Path(__file__).with_name('test_build.py'), REPO/'tools/build_scope.sh',
                 NINJA, Path(shutil.which(old_compile[0]))):
        pin(path)
    # Thin archives contain paths to real members, not their object contents.
    for token in old_link[1:]:
        path = (BUILD/token).resolve()
        if path.is_file():
            pin(path)
            with path.open('rb') as stream:
                thin = stream.read(8) == b'!<thin>\n'
            if thin:
                for member in subprocess.check_output(['ar', 't', path], text=True).splitlines():
                    pin(path.parent/member)
    root.mkdir()
    save(root/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
         affinity=sorted(os.sched_getaffinity(0)), compiler=old_compile, linker=old_link,
         canonical_changed=False, matched_tb_object_relink=True, scope=scope_state))
    begin = time.monotonic()
    result = dict(passed=False, rows=[], errors=[], canonical_gate_passed=False,
                  native_regression_passed=False, hardware_acceptance=False, gameplay_ipc=None)
    try:
        for variant, text in (('control', original), ('candidate', repaired)):
            assert stable() and shutil.disk_usage(scratch).free > 4*1024**3+256*1024**2
            folder = root/variant
            folder.mkdir()
            local_source, obj, binary = folder/'tb-maint.c', folder/'tb-maint.o', folder/'qemu-system-i386'
            local_source.write_text(text)
            pin(local_source)
            flags = private_flags(old_compile, source)

            def run(label, command):
                save(folder/(label+'-command.json'), list(map(str, command)))
                with (folder/(label+'.log')).open('x') as log:
                    native = subprocess.run(command, cwd=BUILD, stdout=log,
                        stderr=subprocess.STDOUT, timeout=180)
                save(folder/(label+'-exit.json'), dict(native_exit=native.returncode))
                assert native.returncode == 0, (variant, label, native.returncode)

            def deps(path):
                tokens = shlex.split(path.read_text().replace('\\\n', ' '))
                return {(BUILD/name).resolve(strict=True) for name in tokens[1:]}

            run('dependencies', [old_compile[0], *flags, '-M', '-MF', folder/'before.d',
                                 '-MT', 'private_tb', local_source])
            before = deps(folder/'before.d')
            assert local_source in before
            for path in before:
                pin(path)
            save(folder/'compile-inputs.json', dict(pins=pins))
            assert stable()
            run('compile', [old_compile[0], *flags, '-MD', '-MF', folder/'after.d',
                            '-c', local_source, '-o', obj])
            assert deps(folder/'after.d') == before
            run('link', private_link(old_link, old_object, obj, binary))
            version = subprocess.check_output([binary, '--version'], text=True, timeout=10)
            assert '8.2.2' in version and stable()
            result['rows'].append(dict(variant=variant, binary=str(binary), sha256=sha(binary),
                object_sha256=sha(obj), source_sha256=sha(local_source), version=version,
                artifacts={str(path):sha(path) for path in folder.iterdir() if path.is_file()}))
        result['passed'] = True
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    events = {key:int(value) for key,value in
              (line.split() for line in (group/'memory.events').read_text().splitlines())}
    result.update(pins=pins, pins_unchanged=stable(), seconds=time.monotonic()-begin,
                  memory_events=events, memory_peak=int((group/'memory.peak').read_text()),
                  swap_current=int((group/'memory.swap.current').read_text()))
    result['passed'] &= result['pins_unchanged']
    result['passed'] &= not events['oom'] and not events['oom_kill'] and not result['swap_current']
    save(root/'closed.json', result)
    print(json.dumps({key:value for key,value in result.items() if key not in ('pins','rows')}, indent=2), flush=True)
    return int(not result['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
