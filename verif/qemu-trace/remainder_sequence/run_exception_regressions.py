"""Rerun exact sequences/PC retention with both instruction-local repairs."""
from pathlib import Path
import sys
import prepare
import prepare_exception
import run_fixed

HELPER = prepare.HELPER


def transform(text):
    return prepare_exception.transform(prepare.transform(text))


original_save = run_fixed.save


def save(path, value):
    if path.name == 'started.json':
        for p in (Path(__file__), Path(prepare.__file__), Path(prepare_exception.__file__)):
            value['pins'][str(p.resolve())] = run_fixed.sha(p)
    original_save(path, value)


run_fixed.prepare = sys.modules[__name__]
run_fixed.save = save
if __name__ == '__main__': raise SystemExit(run_fixed.main())
