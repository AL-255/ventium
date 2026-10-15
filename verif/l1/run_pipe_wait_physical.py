"""Preserve the cold INT/IRET and SMM witnesses for the wait cofactor.

These are simulated physical-address-owner checks, not physical FPGA passes.
Use the already established eight-million-cycle SMM cap, without fixture,
comparison, native-exit or witness changes.
"""
from pathlib import Path
import sys

import run_pipe_wait_read_ack_checks as identity

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'fetchguard'))
import run_demand_size_physical as predecessor


def main():
    paths = (Path(__file__), Path(predecessor.__file__),
             Path(predecessor.predecessor.__file__), Path(identity.__file__))
    pins = {p: predecessor.predecessor.sha(p) for p in paths}
    namespace = dict(predecessor.predecessor.__dict__)
    namespace.update(__file__=__file__, identity=identity)
    exec(compile(predecessor.adapted_main(), __file__, 'exec'), namespace)
    result = namespace['main']()
    assert all(predecessor.predecessor.sha(p) == h for p, h in pins.items())
    return result


if __name__ == '__main__':
    raise SystemExit(main())
