"""Cold paged immediate same-line load pairs, including relocation/boundaries.

Reuse the complete architectural and cycle comparisons, changing only the
fixture instruction pairs. The older matrix used different physical lines
and therefore did not exercise the immediate-return consumer.
"""
import json
from pathlib import Path
import sys

import run_l1_capture_cut_system as backend

BACKEND_SHA='eef20073c94274da3aa01862d45a78d8751bd9a92594c591544608376ce0e9ef'
PATTERNS=(
    ('wide', 'movl (%eax),%edx', 'movl 4(%eax),%ebx'),
    ('byte', 'movb (%eax),%dl', 'movb 31(%eax),%bl'),
    ('same-bank', 'movl (%eax),%edx', 'movl (%eax),%ebx'),
    ('split', 'movl (%eax),%edx', 'movl 31(%eax),%ebx'),
)


def main():
    pins={str(Path(__file__).resolve()):backend.sha(__file__),
          str(Path(backend.__file__).resolve()):BACKEND_SHA}
    assert all(backend.sha(p)==h for p,h in pins.items())
    out=Path(sys.argv[sys.argv.index('--out')+1]).resolve()
    backend.PATTERNS=PATTERNS
    result=backend.main()
    unchanged=all(backend.sha(p)==h for p,h in pins.items())
    backend.save(out/'adapter.json',dict(pins=pins,pins_unchanged=unchanged,
        patterns=PATTERNS,native_runner_exit=result,
        result_sha256=backend.sha(out/'closed.json')))
    assert unchanged
    return result


if __name__=='__main__': raise SystemExit(main())
