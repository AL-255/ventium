"""Recheck the exact single-L1 export, without inheriting guest acceptance."""
import inspect
from pathlib import Path

import backing_direction_evidence as previous
import build_next_ready_soc as native
import freeze_next_ready_rk_candidate as export
import sfetch_boundary_evidence as parent_evidence

MANIFEST = '2a7343b2d3f022ab891712c3cad0fb6b6f7f9460f05f60c1080a26e3c77c4982'
MODEL = export.MODEL
VARIANT = export.VARIANT


def check(source):
    text = inspect.getsource(previous.check)
    old = "source.parent/'v-result-carry-posted-mouse-fpga-r1'"
    assert text.count(old) == 1
    text = text.replace(old, "source.parent/'sfetch-boundary-fpga-r1'")
    scope = dict(previous.__dict__, __file__=__file__, native=native, export=export,
        mouse=parent_evidence, MANIFEST=MANIFEST, MODEL=MODEL, VARIANT=VARIANT)
    exec(compile(text, __file__, 'exec'), scope)
    pins = scope['check'](source)
    for p in (Path(previous.__file__).resolve(),Path(parent_evidence.__file__).resolve()):
        pins[str(p)] = native.sha(p)
    return pins
