"""Reuse the exact FP/store corpora; allocate non-overlapping case GDB ports."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
import run_load_read_ack_core as prior


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--suite',choices=('fp','integer'),required=True)
    ap.add_argument('--out',type=Path,required=True)
    args,extra=ap.parse_known_args(); root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and not root.exists()
    source=prior.corpus.SOURCES[args.suite]
    text=prior.adapt(source.read_text(),args.suite)
    old="""        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
"""
    # The original loop has distinct (kind, reloc, offset), each in 6/2/32
    # (FP) or 4/2/32 (store). Refuse drift rather than reintroducing port races.
    assert text.count(old)==1
    portbase=47000 if args.suite=='fp' else 48000
    text=text.replace(old,f'        port = {portbase} + 64 * kind + 32 * reloc + offset\n')
    runner=root.with_suffix('.driver.py')
    with runner.open('x') as stream: stream.write(text)
    pins={str(p):prior.corpus.base.sha(p) for p in (Path(__file__).resolve(),Path(prior.__file__),
        Path(prior.corpus.__file__),Path(prior.corpus.base.__file__),source,runner)}
    command=[sys.executable,'-B',str(runner),'--out',str(root),*extra]
    with root.with_suffix('.driver.json').open('x') as stream:
        json.dump(dict(pins=pins,command=command,case_port_base=portbase,changed_acceptance=False),stream,indent=2)
    with root.with_suffix('.driver.log').open('x') as stream:
        child=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=300)
    assert all(prior.corpus.base.sha(p)==h for p,h in pins.items())
    return child.returncode


if __name__=='__main__': raise SystemExit(main())
