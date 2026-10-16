"""Observe one exact synthesis, then audit it and its read-only clock report.

No synthesis retry, implementation, bitstream or deployment. A failed or changed
owner stops the sequence; the previous native lifecycle is unchanged.
"""
import argparse
import hashlib
from pathlib import Path

import run_posted_mouse_timing_sequence as previous


def derive(invocation):
    assert hashlib.sha256(Path(previous.__file__).read_bytes()).hexdigest()=='233f51cbae2b860d165bac16e917d4653e49cfc719bf198c402fa0c0ab025cfc'
    text=previous.derive(invocation).replace('posted-mouse-','sfetch-boundary-')
    for old,new in (
        ('ab1c791f3f472ec72a0c36628291d3c6d2e78a6a4a1b449a71a06840800ba8e0',
         '34b2d154d926cd8731443576b7e786cabf2c70bd193d2d05c8e5b0505b37bafc'),
        ('b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e',
         'b32ab4b34482669c03ea57ce7be0dbd475623fa00b00c4c814fec976d75c86d2'),
    ):
        assert text.count(old)==1
        text=text.replace(old,new)
    compile(text,__file__,'exec')
    return text


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synth-invocation',required=True)
    args=parser.parse_args()
    exec(compile(derive(args.synth_invocation),__file__,'exec'),globals())
