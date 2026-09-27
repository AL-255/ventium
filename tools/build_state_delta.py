#!/usr/bin/env python3
"""Host-only observer relink; invoke through tools/build_scope.sh.

Regenerate the exhaustive field list on EVERY invocation. Hash-check that the
generated model sources and compiled RTL archive were not changed by the relink.
"""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from gen_state_delta import generate


def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('objdir', type=Path)
    obj = p.parse_args().objdir.resolve()
    mk = obj/'Vsystem.mk'
    if not (obj/'Vsystem__ALL.a').is_file():
        p.error('requires an already compiled savable Vsystem model')
    paths = [*obj.glob('Vsystem*.h'), *obj.glob('Vsystem*.cpp'), obj/'Vsystem__ALL.a']
    before = {p.name: digest(p) for p in paths}
    generate(obj)
    match = re.search(r'^sim_ven\.o:\s*(\S+)', mk.read_text(), re.M)
    if not match:
        raise RuntimeError('unrecognized generated simulator build rule')
    sources = {match[1]}
    dep = obj/'sim_ven.d'
    if dep.exists():
        sources.update(re.findall(r'\S*sim_ven\.cpp', dep.read_text()))
    # -W on an unresolved VPATH spelling suppresses make's path search and
    # hands that nonexistent spelling to the compiler. Use resolved deps only.
    sources = {source for source in sources if (obj/source).is_file()}
    if not sources:
        raise RuntimeError('no existing sim_ven.cpp dependency; build the host once normally first')
    cmd = ['make', '-C', str(obj), '-f', 'Vsystem.mk', '-j1', 'LDLIBS=-lz',
           'USER_CPPFLAGS=-DVEN_STATE_DELTA_HOST']
    for source in sorted(sources):
        cmd += ['-W', source]
    cmd += ['ao486sim_ven']
    subprocess.run(cmd, check=True, pass_fds=(9,))
    after = {p.name: digest(p) for p in paths}
    if before != after:
        raise RuntimeError('model changed during host-only relink; do not use prior snapshots')
    result = dict(model_unchanged=True, model_hashes=after,
                  profiler_sha256=digest(obj/'ao486sim_ven'))
    (obj/'ven_state_relink.json').write_text(json.dumps(result, indent=2)+'\n')
    print('STATE-DELTA-RELINK-OK: generated RTL and archive unchanged')


if __name__ == '__main__':
    main()
