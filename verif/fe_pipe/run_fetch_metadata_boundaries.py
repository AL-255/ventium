"""Run the unchanged finite-CS replay with the buffered-metadata model.

This remains an RTL self-check and exact A/B test, not a QEMU pass: the
reference's finite-CS discrepancy is retained. Only model identities change.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

import prepare_fetch_metadata_owner as recipe
import run_fetch_fragment_finite_cs as previous
from build_fetch_metadata_core import MODEL as PARENT_MODEL

SOURCE_SHA='d3693b7c473b5d02fe6c4c3c28f1a628f94e9463f972637382400ead0adef604'


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('core','out'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();core=a.core.resolve(strict=True);root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert root.is_relative_to(scratch) and not root.exists()
    started=json.loads((core/'build-started.json').read_text());closed=json.loads((core/'build-closed.json').read_text())
    parent=Path(started['parent']);model=closed['binary_sha256']
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit']==0
    assert sha(core/'obj/tb_ventium')==model and sha(parent/'obj/tb_ventium')==PARENT_MODEL
    assert started['changes']==[recipe.FILE]
    assert recipe.transform((parent/'candidate'/recipe.FILE).read_text())==(core/'candidate'/recipe.FILE).read_text()
    assert all(sha(p)==h for p,h in started['pins'].items())
    assert sha(previous.__file__)==SOURCE_SHA
    pins={str(p.resolve()):sha(p) for p in (Path(__file__),Path(previous.__file__),Path(recipe.__file__),
        core/'build-started.json',core/'build-closed.json',core/'obj/tb_ventium',parent/'obj/tb_ventium')}
    previous.MODELS={'parent':(str(parent),PARENT_MODEL),'candidate':(str(core),model)}
    with root.with_suffix('.adapter.json').open('x') as f:
        json.dump(dict(pins=pins,models=previous.MODELS,invocation=os.environ['INVOCATION_ID'],
                       fixtures_and_comparisons_unchanged=True,qemu_differential=False),f,indent=2)
    sys.argv=[previous.__file__,'--out',str(root)]
    code=previous.main()
    stable=all(sha(p)==h for p,h in pins.items())
    with root.with_suffix('.adapter-closed.json').open('x') as f:
        json.dump(dict(native_exit=code,pins_unchanged=stable),f,indent=2)
    assert stable
    return code


if __name__=='__main__':raise SystemExit(main())
