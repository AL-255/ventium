"""Recheck the exact single-core export without inheriting guest acceptance."""
import inspect
from pathlib import Path

import backing_direction_evidence as previous
import build_sfetch_interior_soc as native
import freeze_sfetch_interior_rk_candidate as export
import sfetch_boundary_evidence as parent_evidence

MANIFEST = 'eeccdcf17f7641c80d07718ba6d88b2241912b7f6e3e53d325a1a5d2710c7cd0'
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
