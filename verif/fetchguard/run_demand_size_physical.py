"""Retain the physical-owner witnesses with the already established SMM cap.

Physical-owner means bus address ownership in this simulated core test, not
physical FPGA acceptance. No guest or comparator changes. The parent already
needs 6,040,521 cycles for latency-31 SMM metadata, so allow eight million.
"""
import inspect
from pathlib import Path

import run_demand_size_checks as identity
import run_early_bus_physical as predecessor


def adapted_main():
    source = inspect.getsource(predecessor.main)
    edits = [("'5000000'", "'8000000'"), ("'.exit.json'),90)", "'.exit.json'),180)")]
    for old, new in edits:
        assert source.count(old) == 1
        source = source.replace(old, new)
    return source


def main():
    paths = (Path(__file__), Path(predecessor.__file__), Path(identity.__file__))
    pins = {p: predecessor.sha(p) for p in paths}
    namespace = dict(predecessor.__dict__)
    namespace.update(__file__=__file__, identity=identity)
    exec(compile(adapted_main(), __file__, 'exec'), namespace)
    result = namespace['main']()
    assert all(predecessor.sha(p) == h for p, h in pins.items())
    return result


if __name__ == '__main__':
    raise SystemExit(main())
