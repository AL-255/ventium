"""Cold parent/candidate system differential checks for qualified pair credit.

Preserve the existing native supervisor, fresh QEMU oracle, fixtures, comparison
policy and all 180 RTL executions. Remove only unrelated ACK-owner observation;
the real master's contract assertions execute in the complete processor.
"""
import inspect
from pathlib import Path

import prepare_qualified_pair_credit as recipe
import run_system_read_ack_core as previous
from build_qualified_pair_credit_core import CHANGES, MODEL as PARENT

MODEL = '5a2fcb865e53dc67a3f866ab1edbc8bbbc4917708e984a62d60bc8400c67f2d3'
CPUS = (4, 5, 7, 8, 9, 12, 13, 15, 16, 17, 18, 19, 20, 21, 22)


def adapted_main():
    assert previous.sha(previous.__file__) == 'aca4df03ef544d9085bb8e366240afe27cb25a4842c24d58e6d95d8a9c4288df'
    source = inspect.getsource(previous.main)
    substitutions = [
        ("    for n in recipe.PARENTS:\n"
         "        assert (core/'candidate'/recipe.PREFIX/n).read_text()==recipe.transform(\n"
         "            (parent/'candidate'/recipe.PREFIX/n).read_text(),n)",
         "    assert start['changes'] == CHANGES\n"
         "    derived = recipe.transform({n:(parent/'candidate/rtl/mem'/n).read_text() for n in recipe.PINS})\n"
         "    for n,text in derived.items(): assert (core/'candidate/rtl/mem'/n).read_text() == text"),
        ("(Path(__file__),Path(recipe.__file__),Path(native.__file__),Path(compare.__file__),",
         "(Path(__file__),Path(previous.__file__),Path(recipe.__file__),Path(native.__file__),Path(compare.__file__),"),
        ("'+ven_faultlog','+ven_system_read_ack_witness'", "'+ven_faultlog'"),
        ("    result['uncovered_read_states']=sorted(set(recipe.STATES)-states)\n", ''),
        ("    result['all_read_owners_exercised']=not result['uncovered_read_states'] and walk=={0,2}\n", ''),
    ]
    for old, new in substitutions:
        assert source.count(old) == 1, old
        source = source.replace(old, new)
    return source


def main():
    namespace = dict(previous.__dict__, __file__=__file__, previous=previous,
                     recipe=recipe, MODEL=MODEL, PARENT=PARENT, CHANGES=CHANGES, CPUS=CPUS)
    exec(compile(adapted_main(), __file__, 'exec'), namespace)
    return namespace['main']()


if __name__ == '__main__':
    raise SystemExit(main())
