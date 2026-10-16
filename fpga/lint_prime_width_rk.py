"""Strict CPU-hierarchy lint of the exact width export; no full-SoC claim."""
import inspect
from pathlib import Path

import lint_v_result_carry_rk as previous
import freeze_prime_width_rk_candidate as export


def main():
    assert export.builder.sha(previous.__file__)=='17c01b1ca5f5c339dbc5bbd6cf156edd58c7d859cb95759540745df9fbf8de62'
    text=inspect.getsource(previous.main)
    for old,new in (
        ("manifest['variant']=='v_result_carry_aux_mouse_unqualified'","manifest['variant']==export.VARIANT"),
        ('(Path(__file__),original,driver,Path(export.__file__))',
         '(Path(__file__),Path(previous.__file__),original,driver,Path(export.__file__))'),
    ):
        assert text.count(old)==1,old;text=text.replace(old,new)
    scope=dict(previous.__dict__,__file__=__file__,previous=previous,export=export)
    exec(compile(text,__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__':raise SystemExit(main())
