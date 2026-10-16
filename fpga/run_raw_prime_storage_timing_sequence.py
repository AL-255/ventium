"""Observe one exact synthesis, then its prepared read-only timing audit."""
import argparse

import run_prime_width_timing_sequence as previous
import raw_prime_storage_evidence as evidence


def derive(invocation):
    text = previous.derive(invocation).replace('prime-width-','raw-prime-storage-')
    for old,new in ((previous.evidence.MANIFEST,evidence.MANIFEST),
                    (previous.evidence.MODEL,evidence.MODEL)):
        assert text.count(old) == 1
        text = text.replace(old,new)
    compile(text,__file__,'exec')
    return text


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--synth-invocation',required=True)
    a = ap.parse_args()
    exec(compile(derive(a.synth_invocation),__file__,'exec'),globals())
