"""Compose the fetch-size CPU with the previously qualified input transport.

No CPU source, definitions, memory timing or host protocol changes are allowed.
Preparation is source-only; the original exclusive compiler guard is retained.
"""
import inspect
from pathlib import Path

import build_sfetch_interior_soc as cpu
import build_next_ready_ui_soc as previous

ROOT = cpu.ROOT
PARENT = ROOT/'sfetch-interior-soc-r1'
PARENT_MODEL = 'bccf110432a3ce42085841ee7dbb9056adaf277220b571b106cf91e6364eec76'
UI_PARENT, UI_MODEL = previous.UI_PARENT, previous.UI_MODEL
ui, bound = previous.ui, previous.bound
sha, load, save, stable = cpu.sha, cpu.load, cpu.save, cpu.stable
check_delta = previous.check_delta


def prepare_source():
    assert sha(previous.__file__) == '523fe624ef9194c67d04527094941100a481babccd2fbe40de2613a3e42e5352'
    text = inspect.getsource(previous.prepare)
    for old,new in (
        ("'sim_next_ready_ui_'", "'sim_sfetch_interior_ui_'"),
        ('for p in (Path(__file__),Path(cpu.__file__),',
         'for p in (Path(__file__),Path(previous.__file__),Path(cpu.__file__),'),
        ("    source = PARENT/'source'",
         "    controls=load(PARENT/'coremark-r1/audit.json')\n"
         "    assert controls['passed'] and controls['model']==PARENT_MODEL and controls['no_oom']\n"
         "    assert all(r['parent_ticks']==r['candidate_ticks'] for r in controls['measurements'])\n"
         "    pins.update(controls['artifact_pins'])\n"
         "    pins[str(PARENT/'coremark-r1/audit.json')]=sha(PARENT/'coremark-r1/audit.json')\n"
         "    source = PARENT/'source'"),
        ('Latest timing CPU unchanged; exact retained controller and already-tested native input host.',
         'Fetch-size CPU unchanged; exact retained controller and already-tested native input host.'),
    ):
        assert text.count(old)==1, old
        text=text.replace(old,new)
    return text


def namespace():
    scope=dict(previous.__dict__,__file__=__file__,previous=previous,cpu=cpu,
               ROOT=ROOT,PARENT=PARENT,PARENT_MODEL=PARENT_MODEL)
    exec(compile(prepare_source(),__file__,'exec'),scope)
    return scope


def prepare(root):
    return namespace()['prepare'](root)


def main():
    scope=namespace()
    text=inspect.getsource(previous.main)
    old='Combined next-read/UI source prepared; no compiler or guest launched.'
    assert text.count(old)==1
    text=text.replace(old,'Combined fetch-size/UI source prepared; no compiler or guest launched.')
    exec(compile(text,__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__': raise SystemExit(main())
