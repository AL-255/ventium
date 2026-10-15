"""Transfer only the tested read/write wait cofactor into the full PC.

Keep the complete strict-MF feature profile and every parent source. The cold
boundary/system/x87/physical-owner and identical-input gates remain required;
add explicit mixed U-load/V-store, held-read and store-backpressure evidence.
This experimental build cannot inherit a canonical or physical-board pass.
"""
import inspect
from pathlib import Path
import sys

import build_demand_size_soc as previous

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/l1'))
import prepare_pipe_wait_read_ack as recipe
import run_pipe_wait_read_ack_leaf as leaf

PARENT_MODEL = '20cef474c2a10fca2ec27b26f09d88e9b7dc70ead963fab09ce28a6baaa4d60d'
CORE_MODEL = 'c9e4b9f86ad080f72ffd8ecef3d4ffc73eb1ecb8574ba7cd185bcae4fa3a643a'
CHANGES = [recipe.FILE]
sha, load, save, stable, base = previous.sha, previous.load, previous.save, previous.stable, previous.base
FLAG, keep_definitions = previous.FLAG, previous.keep_definitions


def extended_evidence(proof, core):
    pins = leaf.check_receipt(proof/'pipe-wait-leaf-r1')
    for name, expected in (('memory', 288), ('integer', 1024), ('mixed', 144)):
        folder = proof/('pipe-wait-'+name+'-r1')
        start, end = load(folder/'started.json'), load(folder/'closed.json')
        assert end['passed'] and end['pins_unchanged'] and not end['errors']
        assert len(end['measurements']) == expected and stable(start['pins'])
        assert start['pins'][str(core/'obj/tb_ventium')] == CORE_MODEL
        rows = [r for r in end['measurements'] if r['model'] == 'candidate']
        if name == 'integer':
            assert end['all_children_reaped'] and all(r['saved_clocks'] == 0 for r in end['deltas'])
            assert sum(r['stores_paired'] for r in rows) > 0
        else:
            assert end['memory_v_retirements'] == sum(r['memory_v'] for r in rows) > 0
            if name == 'mixed':
                assert end['wait_held'] == sum(r['wait_held'] for r in rows) > 0
                assert end['wait_paired'] == sum(r['wait_paired'] for r in rows) > 0
        pins.update(start['pins'])
        for p in (folder/'started.json', folder/'closed.json'):
            pins[str(p)] = sha(p)
    folder = proof/'pipe-wait-held-r1'
    inputs, end = load(folder/'inputs.json'), load(folder/'result.json')
    assert end['passed'] and end['inputs_unchanged'] and not end['errors'] and len(end['cases']) == 48
    assert inputs[str(core/'obj/tb_ventium')] == CORE_MODEL and stable(inputs)
    for row in end['cases']:
        assert row['measurements']['candidate'] == row['measurements']['control']
        assert row['pair_preserved'] and row['gain_fraction'] == 0
        if row['kind'] == 5:
            assert row['measurements']['candidate']['held_primes'] >= 12
    pins.update(inputs)
    for p in (folder/'inputs.json', folder/'result.json', Path(leaf.__file__)):
        pins[str(p)] = sha(p)
    assert stable(pins)
    return pins


def adapted_prepare():
    source = previous.adapted_prepare()
    source = source.replace('demand-size-', 'pipe-wait-').replace('sim_demand_size_', 'sim_pipe_wait_')
    source = source.replace('request-independent demand width; original issued-size and inactive-authority assertions',
                            'read/write wait cofactor; exact old wait and read-owner assertions')
    pin = "Path(__file__).with_name('build_early_bus_soc.py'),"
    assert source.count(pin) == 1
    source = source.replace(pin, pin+"Path(__file__).with_name('build_demand_size_soc.py'),")
    marker = "    exec(compile(text,__file__,'exec'),namespace)\n"
    assert source.count(marker) == 1
    source = source.replace(marker, "    extra_pins = extended_evidence(proof, core)\n"
        "    namespace['extra_pins'] = extra_pins\n"
        "    assert text.count(marker) == 1\n"
        "    text = text.replace(marker, marker+\"    pins.update(extra_pins)\\n\")\n"+marker)
    return source


def prepare(parent, core, proof, root):
    namespace = dict(previous.previous.__dict__)
    namespace.update(__file__=__file__, PARENT_MODEL=PARENT_MODEL, CORE_MODEL=CORE_MODEL,
                     recipe=recipe, CHANGES=CHANGES, extended_evidence=extended_evidence)
    exec(compile(adapted_prepare(), __file__, 'exec'), namespace)
    return namespace['prepare'](parent, core, proof, root)


def main():
    namespace = dict(previous.previous.__dict__)
    namespace.update(__file__=__file__, prepare=prepare)
    exec(compile(inspect.getsource(previous.previous.main), __file__, 'exec'), namespace)
    return namespace['main']()


if __name__ == '__main__':
    raise SystemExit(main())
