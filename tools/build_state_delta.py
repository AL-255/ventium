#!/usr/bin/env python3
"""Host-only observer relink; invoke through tools/build_scope.sh.

Regenerate the exhaustive field list on EVERY invocation. Hash-check that the
generated model sources and compiled RTL archive were not changed by the relink.
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
from pathlib import Path
from gen_state_delta import generate

ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = Path('/tmp/ventium-heavy-build.lock')
EXECUTABLES = frozenset(('ao486sim_ven', 'ao486sim_ven_standard'))


def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def executable_target(makefile):
    """Accept only the two literal executable shapes emitted by our generator."""
    defaults = re.findall(r'^default[ \t]*:([^\n]*)$', makefile, re.M)
    if len(defaults) != 1 or defaults[0].strip() not in EXECUTABLES:
        raise ValueError('requires one literal legacy or standard executable default target')
    target = defaults[0].strip()
    rules = re.findall(r'^' + re.escape(target) + r':([^\n]*)\n([^\n]*)',
                       makefile, re.M)
    dependencies = '$(VK_USER_OBJS) $(VK_GLOBAL_OBJS) $(VM_PREFIX)__ALL.a'
    recipe = ('$(LINK) $(LDFLAGS) $^ $(LOADLIBES) $(LDLIBS) '
              '$(LIBS) $(SC_LIBS) -o $@')
    if (len(rules) != 1 or ' '.join(rules[0][0].split()) != dependencies
            or not rules[0][1].startswith('\t')
            or rules[0][1].strip() != recipe):
        raise ValueError('unrecognized generated executable link rule')
    lines = makefile.splitlines()
    index = next(i for i, line in enumerate(lines) if line.startswith(target + ':'))
    recipe_lines = []
    for line in lines[index + 1:]:
        if line.startswith('\t'):
            recipe_lines.append(line)
        elif line.strip() and not line.startswith('#'):
            break
    if recipe_lines != ['\t' + recipe]:
        raise ValueError('extra or malformed executable recipe')
    return target


def regular_file(path, *, required=True, output=False):
    if path.is_symlink():
        raise ValueError(f'symlinked build input/output is unsafe: {path}')
    if not path.exists():
        if required:
            raise ValueError(f'requires existing compiled model file: {path}')
    elif not path.is_file():
        raise ValueError(f'non-regular build input/output is unsafe: {path}')
    elif output and path.stat().st_nlink != 1:
        raise ValueError(f'hard-linked build output is unsafe: {path}')


def prepare_relink(objdir):
    """Validate all target/output/dependency shapes before any generation writes."""
    supplied = objdir.absolute()
    if any(path.is_symlink() for path in (supplied, *supplied.parents)):
        raise ValueError('object directory must not traverse a symlink')
    obj = supplied.resolve(strict=True)
    if not obj.is_dir():
        raise ValueError('object directory is not a directory')
    mk = obj/'Vsystem.mk'
    regular_file(mk)
    makefile = mk.read_text()
    target = executable_target(makefile)
    regular_file(obj/target, output=True)
    regular_file(obj/'sim_ven.o', output=True)
    for name in ('Vsystem__ALL.a', 'Vsystem___024root.h',
                 'Vsystem___024root__Slow.cpp', 'Vsystem__Syms.h'):
        regular_file(obj/name)
    for name in ('ven_state_fields.inc', 'ven_state_fields.audit.json',
                 'ven_state_relink.json', 'sim_ven.d'):
        regular_file(obj/name, required=False, output=True)
    paths = [*obj.glob('Vsystem*.h'), *obj.glob('Vsystem*.cpp'), obj/'Vsystem__ALL.a']
    for path in paths:
        regular_file(path)
    matches = re.findall(r'^sim_ven\.o:[ \t]*([^\n]*)$', makefile, re.M)
    if len(matches) != 1 or not re.fullmatch(r'\S*sim_ven\.cpp[ \t]*', matches[0]):
        raise ValueError('unrecognized generated simulator build rule')
    sources = {matches[0].strip()}
    dep = obj/'sim_ven.d'
    if dep.exists():
        sources.update(re.findall(r'\S*sim_ven\.cpp', dep.read_text()))
    # -W on an unresolved VPATH spelling suppresses make's path search and
    # hands that nonexistent spelling to the compiler. Retain the existing
    # .d spelling exactly: GNU Make does not normalize an absolute -W alias
    # to the relative prerequisite already present in its dependency graph.
    sources = {source for source in sources if (obj/source).is_file()}
    if not sources:
        raise ValueError('no existing sim_ven.cpp dependency; build the host once normally first')
    cmd = ['make', '-C', str(obj), '-f', 'Vsystem.mk', '-j1', 'LDLIBS=-lz',
           'USER_CPPFLAGS=-DVEN_STATE_DELTA_HOST']
    for source in sorted(sources):
        cmd += ['-W', source]
    cmd += [target]
    return obj, target, paths, cmd


def inherited_lock_fds(lock_path=LOCK_PATH):
    """Preserve only real descriptors for the guard's fixed lock, never guess 9."""
    try:
        expected = lock_path.stat()
    except OSError as exc:
        raise ValueError('no inherited build-scope lock') from exc
    if not stat.S_ISREG(expected.st_mode):
        raise ValueError('build-scope lock is not a regular file')
    descriptors = []
    for path in Path('/proc/self/fd').iterdir():
        if not path.name.isdecimal() or int(path.name) < 3:
            continue
        fd = int(path.name)
        try:
            if Path(os.readlink(path)) != lock_path:
                continue
            actual = os.fstat(fd)
            if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
                continue
            # Same open-file description as the launcher succeeds without
            # releasing its existing lock. A conflicting owner fails closed.
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            continue
        descriptors.append(fd)
    if not descriptors:
        raise ValueError('no usable inherited build-scope lock descriptor')
    return tuple(sorted(descriptors))


def relink(objdir):
    obj, target, paths, cmd = prepare_relink(objdir)
    lock_fds = inherited_lock_fds()
    subprocess.run([str(ROOT/'tools/build_scope.sh'), '--is-active'],
                   check=True, pass_fds=lock_fds, timeout=10)
    before = {path.name: digest(path) for path in paths}
    host_before = file_identity(obj/'sim_ven.o')
    executable_before = file_identity(obj/target)
    generate(obj)
    subprocess.run(cmd, check=True, pass_fds=lock_fds)
    after = {p.name: digest(p) for p in paths}
    if before != after:
        raise RuntimeError('model changed during host-only relink; do not use prior snapshots')
    host_after = file_identity(obj/'sim_ven.o')
    executable_after = file_identity(obj/target)
    if host_before == host_after:
        raise RuntimeError('host object was not rebuilt; refusing successful relink')
    if executable_before == executable_after:
        raise RuntimeError('executable was not relinked; refusing successful relink')
    result = dict(model_unchanged=True, model_hashes=after,
                  executable=target, profiler_sha256=executable_after['sha256'],
                  host_object_rebuilt=True, executable_relinked=True,
                  host_object_before=host_before, host_object_after=host_after,
                  executable_before=executable_before, executable_after=executable_after)
    (obj/'ven_state_relink.json').write_text(json.dumps(result, indent=2)+'\n')
    print('STATE-DELTA-RELINK-OK: generated RTL and archive unchanged')


def file_identity(path):
    regular_file(path, output=True)
    metadata = path.stat()
    return dict(sha256=digest(path), mtime_ns=metadata.st_mtime_ns,
                ctime_ns=metadata.st_ctime_ns, size=metadata.st_size,
                device=metadata.st_dev, inode=metadata.st_ino)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('objdir', type=Path)
    args = p.parse_args()
    try:
        relink(args.objdir)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
        p.error(str(exc))


if __name__ == '__main__':
    main()
