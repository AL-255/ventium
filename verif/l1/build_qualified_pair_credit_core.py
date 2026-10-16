"""Build the isolated two-file pair-credit derivative from the RAW parent.

Require independently audited native fault/wrapper evidence. Preserve the
parent's entire 195-source/153-define closure and private harness dependency
checks; this build does not grant processor, timing or hardware acceptance.
"""
import inspect
from pathlib import Path
import sys

import audit_qualified_pair_credit as audit
import prepare_qualified_pair_credit as recipe

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'fetchguard'))
import build_decode_bus_core as previous

native = previous.native
MODEL = '41f99bcff8125a2caa7fe768f03f242bed1a43323e4d3a190109167248a34e9b'
CHANGES = ['rtl/mem/ven_axi_master.sv', 'rtl/mem/ventium_l1_axi.sv']


def check_leaf(leaf):
    receipt = leaf.parent/'qualified-pair-credit-native-audit-r1.json'
    checked = native.load(receipt)
    assert checked['passed'] and checked['original_controller_still_failed']
    assert checked['fault_native_passes'] == 18 and checked['wrapper_native_passes'] == 2
    assert not checked['whole_core'] and not checked['hardware_acceptance']
    assert native.stable(checked['pins'])
    audit.owner(leaf, 'ventium-qualified-pair-wrapper-oct16-r3.service',
                'success', '0c43425c096f45cfabfa17809d89da57')
    closed = native.load(leaf/'closed.json')
    assert closed['passed'] and closed['pins_unchanged'] and len(closed['rows']) == 2
    for row in closed['rows']:
        audit.artifacts(row)
    pins = dict(checked['pins'])
    for path in (receipt, Path(audit.__file__), Path(previous.__file__)):
        pins[str(path.resolve())] = native.sha(path)
    return pins


def adapted_main():
    assert native.sha(previous.__file__) == '8fa9b0f1db1225b6feeb6aa2e9c73262657bbc24651530bc128724d49c3132e6'
    source = inspect.getsource(previous.main)
    substitutions = [
        ("replacement = recipe.transform((source/recipe.FILE).read_text())\n    assert replacement == (leaf/'core_bus_driver.svh').read_text()",
         "derived = recipe.transform({n:(source/'rtl/mem'/n).read_text() for n in recipe.PINS})\n"
         "    replacements = {n:derived[Path(n).name] for n in CHANGES}\n"
         "    for n,text in replacements.items(): assert text == (leaf/Path(n).name).read_text()"),
        ("(root/'candidate'/recipe.FILE).write_text(replacement)",
         "for name,text in replacements.items(): (root/'candidate'/name).write_text(text)"),
        ("[recipe.FILE]", "CHANGES"),
        ("'tb_decode_bus_'", "'tb_qualified_pair_credit_'"),
        ('Only no-request DECODE address payload; MMU/fault/request authority unchanged',
         'Qualified same-clock no-L2 paired-store enqueue only; generic admission, allocation, faults and latency unchanged'),
    ]
    for old, new in substitutions:
        assert source.count(old) == (3 if old == '[recipe.FILE]' else 1), old
        source = source.replace(old, new)
    return source


def main():
    namespace = dict(previous.__dict__, __file__=__file__, recipe=recipe,
                     MODEL=MODEL, CHANGES=CHANGES, check_leaf=check_leaf)
    exec(compile(adapted_main(), __file__, 'exec'), namespace)
    return namespace['main']()


if __name__ == '__main__':
    raise SystemExit(main())
