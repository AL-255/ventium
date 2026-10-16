"""Retain strict CPU structural lint for the one-file direction export."""
import argparse
import inspect
from pathlib import Path
import sys
from types import SimpleNamespace

import lint_v_result_carry_rk as previous
import freeze_backing_direction_rk_candidate as export


def main():
    # Reuse the sealed-export lint lifecycle and unmodified structural policy.
    # This adapter changes identity admission only, not the native flags.
    ap=argparse.ArgumentParser(add_help=False)
    ap.add_argument('--source',type=Path,required=True)
    a,_=ap.parse_known_args()
    manifest=previous.json.loads((a.source/'input-manifest.json').read_text())
    assert manifest['variant']==export.VARIANT
    model=manifest['processor_platform_simulator_sha256']
    original=inspect.getsource(previous.main)
    old="manifest['variant']=='v_result_carry_aux_mouse_unqualified'"
    new="manifest['variant']==export.VARIANT"
    assert original.count(old)==1
    source=original.replace(old,new)
    pin_old='(Path(__file__),original,driver,Path(export.__file__))'
    assert source.count(pin_old)==1
    source=source.replace(pin_old,'(Path(__file__),predecessor_file,original,driver,Path(export.__file__))')
    namespace=dict(previous.__dict__)
    namespace.update(__file__=__file__,export=SimpleNamespace(MODEL=model,
        VARIANT=export.VARIANT,__file__=export.__file__),predecessor_file=Path(previous.__file__))
    exec(compile(source,__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__':raise SystemExit(main())
