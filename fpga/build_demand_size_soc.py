"""Transfer one demand-width RTL delta into the full PC, with no define changes.

Require cold boundary, fault, x87, physical-owner and matched-input controls.
Physical-owner tests are simulations; no physical FPGA acceptance is implied.
"""
import inspect
from pathlib import Path
import sys

import build_early_bus_soc as previous

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/fetchguard'))
import prepare_demand_size_payload as recipe

PARENT_MODEL = '593833e1650b5869373abbd74debcc63d15ea53eca1aa87f62e833982ead2fe9'
CORE_MODEL = 'cce12fc71c394b5a154e8bad108a3b88ab1d1acccba000f1961a26ea4f19d07d'
CHANGES = [recipe.FILE]
sha, load, save, stable, base = previous.sha, previous.load, previous.save, previous.stable, previous.base
FLAG, keep_definitions = previous.FLAG, previous.keep_definitions


def adapted_prepare():
    source = inspect.getsource(previous.prepare)
    source = source.replace('early-bus-', 'demand-size-').replace('sim_early_bus_', 'sim_demand_size_')
    source = source.replace('func-r2', 'func-r1').replace('delivery-r2', 'delivery-r1').replace('physical-r2', 'physical-r1')
    pin = '"Path(__file__),Path(predecessor.__file__),\\n"'
    assert source.count(pin) == 1
    source = source.replace(pin, '"Path(__file__),Path(predecessor.__file__),Path(__file__).with_name(\'build_early_bus_soc.py\'),\\n"')
    old = 'early linear payload default; original bus driver assertions'
    assert source.count(old) == 1
    return source.replace(old, 'request-independent demand width; original issued-size and inactive-authority assertions')


def prepare(parent, core, proof, root):
    namespace = dict(previous.__dict__)
    namespace.update(__file__=__file__, PARENT_MODEL=PARENT_MODEL, CORE_MODEL=CORE_MODEL,
                     recipe=recipe, CHANGES=CHANGES)
    exec(compile(adapted_prepare(), __file__, 'exec'), namespace)
    return namespace['prepare'](parent, core, proof, root)


def main():
    namespace = dict(previous.__dict__)
    namespace.update(__file__=__file__, prepare=prepare)
    exec(compile(inspect.getsource(previous.main), __file__, 'exec'), namespace)
    return namespace['main']()


if __name__ == '__main__':
    raise SystemExit(main())
