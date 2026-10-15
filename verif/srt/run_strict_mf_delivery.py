"""Replay the exact cold delivery matrix on a strict-policy derivative.

Keep fixture generation, native launch/reaping/identity, state checks, pins,
limits and architectural verdict unchanged. Only select one model instead of
three and remove the old repaired-parent equality check (the repair must
intentionally differ on the failing FLD1 cases).
"""
import argparse
import inspect
import json
from pathlib import Path
import sys

import run_underflow_delivery as base


def adapt(text):
    start = text.index('        # The address-shape experiment must not alter these architectural tests.\n')
    end = text.index('    except Exception as error:\n', start)
    removed = text[start:end]
    assert "for i in range(0, len(rows), 3):" in removed
    assert "assert arow[key] == brow[key]" in removed
    text = text[:start]+text[end:]
    assert text.count('len(rows) == 216') == 1
    text = text.replace('len(rows) == 216', 'len(rows) == 72')
    assert text.count('(BASE, LINK, Path(__file__), Path(tracefmt.__file__),') == 1
    text = text.replace('(BASE, LINK, Path(__file__), Path(tracefmt.__file__),',
        '(BASE, LINK, Path(__file__), Path(BASE_RUNNER), Path(tracefmt.__file__),')
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    core = a.core.resolve(strict=True)
    before = json.loads((core/'build-started.json').read_text())
    closed = json.loads((core/'build-closed.json').read_text())
    assert before['added_define'] == 'VEN_X87_MF_STRICT' and before['changes'] == []
    assert len(before['definitions']) == 153
    assert before['parent_model'] == base.MODELS['branch'][1]
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
    digest = base.sha(core/'obj/tb_ventium')
    assert digest == closed['binary_sha256']
    namespace = dict(base.__dict__)
    namespace.update(__file__=str(Path(__file__).resolve()), BASE_RUNNER=base.__file__,
                     MODELS={'branch': (core.name, digest)})
    exec(compile(adapt(inspect.getsource(base.main)), str(Path(__file__).resolve()), 'exec'), namespace)
    sys.argv = [sys.argv[0], '--evidence', str(core.parent), '--out', str(a.out)]
    return namespace['main']()


if __name__ == '__main__':
    raise SystemExit(main())
