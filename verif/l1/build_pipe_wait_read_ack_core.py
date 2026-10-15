"""Build the exact-parent wait cofactor with the existing guarded 32-job flow."""
import inspect
from pathlib import Path
import sys

import prepare_pipe_wait_read_ack as recipe
import run_pipe_wait_read_ack_leaf as leaf_runner

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'fetchguard'))
import build_decode_bus_core as predecessor

MODEL = leaf_runner.MODEL
native = predecessor.native


def check_leaf(root):
    pins = leaf_runner.check_receipt(root)
    for p in (Path(leaf_runner.__file__),Path(predecessor.__file__)):
        pins[str(p.resolve())] = native.sha(p)
    return pins


def main():
    namespace = dict(predecessor.__dict__)
    namespace.update(__file__=__file__,recipe=recipe,MODEL=MODEL,check_leaf=check_leaf)
    source = inspect.getsource(predecessor.main)
    changes = [("(leaf/'core_bus_driver.svh')","(leaf/'core.sv')"),
        ("'tb_decode_bus_'","'tb_pipe_wait_'"),
        ("contract_change='Only no-request DECODE address payload; MMU/fault/request authority unchanged'",
         "contract_change='Read/write wait cofactor; same request, fragment, fault and commit authority'")]
    for old,new in changes:
        assert source.count(old)==1
        source = source.replace(old,new)
    exec(compile(source,__file__,'exec'),namespace)
    return namespace['main']()


if __name__ == '__main__': raise SystemExit(main())
