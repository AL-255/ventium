"""Private worker repair: isolate observer modes and use the real FUNC key.

The production worker is pinned by an active FPGA synthesis. This exact-source
recipe prepares a separate worker without changing its producer, comparator,
RTL options, instruction limits, masks or cycle bands. It does not enable the
experimental observer or qualify the canonical gate.
"""
import argparse
import hashlib
from pathlib import Path

PARENT = '9638c5548faf39409e8696ef7f7f72cbb4a68b3b0dc429f930092e449d7a3cd4'
CHANGES = (
    ('GOLDEN_FMT="v2"', '''GOLDEN_FMT="v3-preexit"
# The private observer changes terminal trace coverage with the SAME binary.
# Only literal 1 enables its hook; all other values retain default behavior.
PREEXIT_OBSERVER_MODE=0
[ "${VTM_QEMU_GDB_PREEXIT:-}" = "1" ] && PREEXIT_OBSERVER_MODE=1'''),
    ("ORACLE_SIG=\"$(printf '%s|%s|%s|%s|%s|%s|%s\\n' \\",
     "ORACLE_SIG=\"$(printf '%s|%s|%s|%s|%s|%s|%s|%s\\n' \\"),
    ('    "load=$LOAD,entry=$ENTRY" \\\n',
     '    "load=$LOAD,entry=$ENTRY" \\\n    "preexit=$PREEXIT_OBSERVER_MODE" \\\n'),
    ('FUNC_GOLD="$CACHE_DIR/${SRC_SHA}.func.x87${X87}.max${MAX}.vtrace"',
     'FUNC_GOLD="$CACHE_DIR/${SRC_SHA}.${ELF_SHA:0:12}.${ORACLE_SIG:0:12}.func.x87${X87}.max${MAX}.vtrace"'),
)


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('worker predecessor drift/reapplication')
    changed = source
    for old, new in CHANGES:
        if changed.count(old) != 1:
            raise ValueError('cache anchor missing/ambiguous: '+old)
        changed = changed.replace(old, new)
    return changed


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    args = ap.parse_args()
    output = transform(args.source.read_text())
    with args.out.open('x') as stream: stream.write(output)
