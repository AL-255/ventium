"""Observe one exact synthesis, then its prepared read-only clock audit."""
import argparse

import run_sfetch_boundary_timing_sequence as previous
import sfetch_interior_evidence as evidence


def derive(invocation):
    text = previous.derive(invocation).replace('sfetch-boundary-', 'sfetch-interior-')
    for old, new in ((evidence.parent_evidence.MANIFEST,evidence.MANIFEST),
                     (evidence.parent_evidence.MODEL,evidence.MODEL)):
        assert text.count(old) == 1, old
        text = text.replace(old,new)
    compile(text, __file__, 'exec')
    return text


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--synth-invocation', required=True)
    a = ap.parse_args()
    exec(compile(derive(a.synth_invocation), __file__, 'exec'), globals())
