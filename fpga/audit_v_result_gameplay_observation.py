"""Regrade a reviewed periodic V-result gameplay window; never suite acceptance.

Explicit sample/frame indices and visual observations keep later windows from
requiring a new copy of the checker. Original source, owner, raw-pixel, counter
profile and mode checks remain mandatory. Selection is post-hoc, not an A/B
performance experiment. Existing observations are never overwritten.
"""
import argparse
from pathlib import Path

import audit_v_result_gameplay_window as previous


def derive(samples, frames, reviews):
    assert len(samples) == len(frames) == len(reviews) == 2
    assert 11 <= samples[0] < samples[1]
    assert 0 <= frames[0] < frames[1]
    assert all(isinstance(s, str) and len(s.strip()) >= 12 for s in reviews)
    assert previous.previous.window.sha(previous.__file__) == 'c84f60c149edf9e015cf96506cb8456de6db91b4bc171a6a4a7bab9566b39f6f'
    text = previous.derive()
    first, last = (n * 100000000 + 65247 for n in samples)
    edits = (
        ('observed_cycles[:12]', f'observed_cycles[:{samples[1]}]'),
        ('range(4,13)', f'range(4,{samples[1]+1})'),
        ('window.cpi.samples(lines,1100065247,1200065247)',
         f'window.cpi.samples(lines,{first},{last})'),
        ('(first[\'cycle\'],last[\'cycle\'])==(1100065247,1200065247)',
         f"(first['cycle'],last['cycle'])==({first},{last})"),
        ("assert delta['retires']==delta['u']+delta['v']==48146083",
         "assert delta['retires']==delta['u']+delta['v'] and delta['u']>0 and delta['v']>0"),
        ("assert delta['u']==37609117 and delta['v']==10536966 and delta['clocks']==100000000",
         f"assert delta['clocks']=={last-first}"),
        ("((6,first,'Weapon firing in stone room with enemy and HUD'),\n"
         "                                     (7,last,'Weapon in stone corridor with HUD; different view'))",
         f"(({frames[0]},first,{reviews[0]!r}), ({frames[1]},last,{reviews[1]!r}))"),
        ('sample_indices=[11,12]', f'sample_indices={list(samples)!r}'),
        ("(root/'v-result-carry-gameplay-window-oct16-r1.json').open('x')",
         "output.open('x')"),
        ('(Path(__file__),Path(previous.__file__),',
         '(Path(__file__),Path(adapter.__file__),Path(previous.__file__),'),
    )
    for old, new in edits:
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    compile(text, __file__, 'exec')
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--samples', nargs=2, type=int, required=True)
    ap.add_argument('--frames', nargs=2, type=int, required=True)
    ap.add_argument('--reviews', nargs=2, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    output = args.out.resolve()
    root = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
    assert output.parent == root and output.suffix == '.json' and not output.exists()
    scope = dict(previous.previous.__dict__, __file__=__file__,
                 previous=previous.previous, adapter=previous,
                 MODEL=previous.MODEL, output=output)
    exec(compile(derive(args.samples, args.frames, args.reviews), __file__, 'exec'), scope)
    scope['main']()


if __name__ == '__main__': main()
