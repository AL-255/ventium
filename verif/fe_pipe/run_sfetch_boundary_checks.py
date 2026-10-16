"""Reuse the exact fault/state and cycle-cost experiments for boundary-only RTL."""
import inspect
from pathlib import Path

import prepare_sfetch_boundary_stage as recipe
import run_sfetch_beat_checks as previous


def main():
    assert previous.sha(previous.__file__) == 'f2d00b6389602d4c01ce46a6348f9b40ad3ebfbc7d19b1d258960b3bb1c90f56'
    text = inspect.getsource(previous.main)
    text = recipe.replace_once(text, '(Path(__file__),Path(recipe.__file__),source,driver,',
        '(Path(__file__),Path(recipe.__file__),Path(recipe.base.__file__),Path(previous.__file__),source,driver,')
    namespace = dict(previous.__dict__, __file__=__file__, previous=previous, recipe=recipe)
    exec(compile(text,__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__':
    raise SystemExit(main())
