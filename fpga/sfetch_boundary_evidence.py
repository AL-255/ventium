"""Recheck the sealed two-file experiment without inheriting acceptance."""
import inspect
from pathlib import Path

import backing_direction_evidence as previous
import build_sfetch_boundary_soc as native
import freeze_sfetch_boundary_rk_candidate as export

MANIFEST='34b2d154d926cd8731443576b7e786cabf2c70bd193d2d05c8e5b0505b37bafc'
MODEL=export.MODEL
VARIANT=export.VARIANT


def check(source):
    scope=dict(previous.__dict__,__file__=__file__,native=native,export=export,
               MANIFEST=MANIFEST,MODEL=MODEL,VARIANT=VARIANT)
    exec(compile(inspect.getsource(previous.check),__file__,'exec'),scope)
    pins=scope['check'](source)
    pins[str(Path(previous.__file__).resolve())]=native.sha(previous.__file__)
    return pins
