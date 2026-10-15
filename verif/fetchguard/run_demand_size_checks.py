"""Replay unchanged whole-core checks on the demand-width payload candidate."""
import inspect
from pathlib import Path

import build_demand_size_core as builder
import prepare_demand_size_payload as recipe
import run_decode_bus_checks as predecessor

MODEL = 'cce12fc71c394b5a154e8bad108a3b88ab1d1acccba000f1961a26ea4f19d07d'


def main():
    inputs = (Path(__file__), Path(predecessor.__file__), Path(builder.__file__), Path(recipe.__file__))
    pins = {p: predecessor.sha(p) for p in inputs}
    namespace = dict(predecessor.__dict__)
    namespace.update(__file__=__file__, MODEL=MODEL, builder=builder, recipe=recipe)
    for function in (predecessor.derive, predecessor.validate, predecessor.main):
        text = inspect.getsource(function)
        if function is predecessor.derive:
            old = 'import prepare_decode_bus_payload as recipe'
            assert text.count(old) == 1
            text = text.replace(old, 'import prepare_demand_size_payload as recipe')
        exec(compile(text, __file__, 'exec'), namespace)
    result = namespace['main']()
    assert all(predecessor.sha(p) == h for p, h in pins.items())
    return result


if __name__ == '__main__':
    raise SystemExit(main())
