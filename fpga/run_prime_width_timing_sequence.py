"""Observe one exact synthesis and run its prepared read-only clock audit."""
import argparse

import run_sfetch_interior_timing_sequence as previous
import prime_width_evidence as evidence


def derive(invocation):
    text=previous.derive(invocation).replace('sfetch-interior-','prime-width-')
    for old,new in ((previous.evidence.MANIFEST,evidence.MANIFEST),
                    (previous.evidence.MODEL,evidence.MODEL)):
        assert text.count(old)==1,old;text=text.replace(old,new)
    compile(text,__file__,'exec')
    return text


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--synth-invocation',required=True)
    a=ap.parse_args()
    exec(compile(derive(a.synth_invocation),__file__,'exec'),globals())
