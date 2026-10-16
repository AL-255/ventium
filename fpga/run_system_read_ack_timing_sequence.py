"""Observe one exact ACK synthesis, then its prepared read-only clock audit.

No retries or implementation/deployment. Native owner checks and lifetime are
the existing hash-pinned sequence, with only candidate identities changed.
"""
import argparse

import run_raw_prime_storage_timing_sequence as previous
import system_read_ack_evidence as evidence


def derive(invocation):
    text=previous.derive(invocation).replace('raw-prime-storage-','system-read-ack-')
    for old,new in ((previous.evidence.MANIFEST,evidence.MANIFEST),
                    (previous.evidence.MODEL,evidence.MODEL)):
        assert text.count(old)==1
        text=text.replace(old,new)
    compile(text,__file__,'exec')
    return text


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--synth-invocation',required=True)
    args=ap.parse_args()
    exec(compile(derive(args.synth_invocation),__file__,'exec'),globals())
