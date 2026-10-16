"""Prepare one matched width-path synthesis and clock audit; launch nothing.

Keep the original measured-growth admission, limits, exclusive owner and
cleanup. Compare with the faster boundary parent, not the rejected cofactor.
"""
import inspect
from pathlib import Path

import prepare_sfetch_interior_timing as previous
import prime_width_evidence as evidence

ROOT=previous.ROOT
SOURCE,SYNTH,CLOCK=('prime-width-fpga-r1','prime-width-synthesis-r1','prime-width-clock-r1')
RECEIPT='prime-width-timing-prepared-r1.json'
TEMPLATES=previous.TEMPLATES
synth_guarded,clock_guarded=previous.synth_guarded,previous.clock_guarded


def common(text):
    text=previous.common(text)
    for old,new in (
        ('sfetch-interior-','prime-width-'),('sfetch_interior_','prime_width_'),
        (previous.evidence.MANIFEST,evidence.MANIFEST),
        (previous.evidence.MODEL,evidence.MODEL),
        ('baseline_gameplay_ipc=0.49046518,baseline_window=[1600065247,1700065247]',
         'baseline_gameplay_ipc=0.51045343,baseline_window=[1200065247,1300065247]'),
        ("baseline_model='7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68'",
         "baseline_model='b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e'"),
    ):
        text=text.replace(old,new)
    return text


def namespace():
    assert previous.sha(Path(previous.__file__))=='00a34a5a9be954bbe3d61d61bf663cd4b7ad29be4446e7a3aa5ee7551bb9c87e'
    return dict(previous.__dict__,__file__=__file__,previous=previous,evidence=evidence,
                ROOT=ROOT,SOURCE=SOURCE,SYNTH=SYNTH,CLOCK=CLOCK,RECEIPT=RECEIPT,common=common)


def derive(original):
    text=inspect.getsource(previous.derive).replace('sfetch-interior-','prime-width-')
    text=text.replace('prime-width-func-r1/audit.json','prime-width-func-r2/audit.json')
    text=text.replace('cycle-neutral interior fetch-size cofactor','early prime-width payload')
    text=text.replace('single-core interior fetch-size cofactor','single-header early prime-width payload')
    text=text.replace('Only interior fetch-size cofactor; boundary-stage and corrected wrapper unchanged',
                      'Only early prime-width payload; boundary-stage and corrected wrapper unchanged')
    # This is adjacent Python string source, so change the three original
    # source literals individually rather than claiming a binary formal proof.
    for a,b in (
        ('One exact interior fetch-size output cofactor against the boundary-stage parent.',
         'One exact early prime-width payload change against the boundary-stage parent.'),
        ('No added registers/cycles/ports; binary proof, boundary/interior traces and short cold CRC controls pass.',
         'No added registers/cycles/ports; source tests, 4240 full same-input trace pairs and short cold CRC controls pass. Historical counter gate remains failed; every counter equals the actual parent.'),
    ):
        assert text.count(a)==1;text=text.replace(a,b)
    scope=namespace()
    exec(compile(text,__file__,'exec'),scope)
    return scope['derive'](original)


def main():
    text=inspect.getsource(previous.main)
    text=text.replace('prepare_sfetch_interior_timing.py','prepare_prime_width_timing.py')
    text=text.replace('for module in (evidence,previous):','for module in (evidence,previous,previous.previous):')
    text=text.replace('Matched interior-fetch','Matched prime-width')
    scope=namespace();scope['derive']=derive
    exec(compile(text,__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__':main()
