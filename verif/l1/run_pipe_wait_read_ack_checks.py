"""Retain the existing complete functional, system and x87 delivery checks."""
import inspect
from pathlib import Path
import sys

import build_pipe_wait_read_ack_core as builder
import prepare_pipe_wait_read_ack as recipe

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'fetchguard'))
import run_decode_bus_checks as predecessor

MODEL = 'c9e4b9f86ad080f72ffd8ecef3d4ffc73eb1ecb8574ba7cd185bcae4fa3a643a'


def main():
    inputs = (Path(__file__),Path(predecessor.__file__),Path(builder.__file__),Path(recipe.__file__))
    pins = {p:predecessor.sha(p) for p in inputs}
    namespace = dict(predecessor.__dict__)
    namespace.update(__file__=__file__,MODEL=MODEL,builder=builder,recipe=recipe)
    for function in (predecessor.derive,predecessor.validate,predecessor.main):
        source = inspect.getsource(function)
        if function is predecessor.derive:
            old = 'import prepare_decode_bus_payload as recipe'
            assert source.count(old)==1
            source = source.replace(old,'import prepare_pipe_wait_read_ack as recipe')
        exec(compile(source,__file__,'exec'),namespace)
    result = namespace['main']()
    assert all(predecessor.sha(p)==h for p,h in pins.items())
    return result


if __name__ == '__main__': raise SystemExit(main())
