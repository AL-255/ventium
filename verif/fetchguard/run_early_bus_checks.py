"""Unchanged functional/system/delayed-x87 checks on the early payload model."""
import inspect
from pathlib import Path

import build_early_bus_core as builder
import prepare_early_bus_payload as recipe
import run_decode_bus_checks as predecessor

MODEL = 'c55b996c2c8309e2c152dbab2813a144e5e30db83df6acfa190425e94067b84f'


def main():
    inputs = (Path(__file__),Path(predecessor.__file__),Path(builder.__file__),Path(recipe.__file__))
    pins = {p:predecessor.sha(p) for p in inputs}
    namespace = dict(predecessor.__dict__)
    namespace.update(__file__=__file__,MODEL=MODEL,builder=builder,recipe=recipe)
    for function in (predecessor.derive,predecessor.validate,predecessor.main):
        text = inspect.getsource(function)
        if function is predecessor.derive:
            old = 'import prepare_decode_bus_payload as recipe'
            assert text.count(old) == 1
            text = text.replace(old,'import prepare_early_bus_payload as recipe')
        exec(compile(text,__file__,'exec'),namespace)
    result = namespace['main']()
    assert all(predecessor.sha(p)==h for p,h in pins.items())
    return result


if __name__ == '__main__':
    raise SystemExit(main())
