"""Fresh qualified-reference corpus for the exact two-file pair-credit core.

Keep the worker, comparison policy, terminal-state observer and native child
checks unchanged. This does not replace or relabel the failed canonical gate.
"""
from pathlib import Path

import prepare_qualified_pair_credit as recipe
import run_system_read_ack_func as template
from build_qualified_pair_credit_core import CHANGES, MODEL as PARENT
from run_qualified_pair_credit_core import MODEL

REFERENCE, SOURCE, REPO = template.REFERENCE, template.SOURCE, template.REPO


def derive_functions():
    assert template.previous.sha(template.__file__) == 'd19086b70804e1b0983d2378c8697e89009a33c015278b54a863de77b3ee2e7e'
    source = template.derive_functions()
    substitutions = [
        ("    for n in CHANGES:\n        assert recipe.transform((parent/'candidate'/n).read_text(), n.removeprefix(recipe.PREFIX)) == (core/'candidate'/n).read_text()",
         "    derived = recipe.transform({n:(parent/'candidate/rtl/mem'/n).read_text() for n in recipe.PINS})\n"
         "    for n,text in derived.items(): assert (core/'candidate/rtl/mem'/n).read_text() == text"),
        ('(Path(__file__), Path(recipe.__file__), Path(previous.__file__), SOURCE,',
         '(Path(__file__), Path(recipe.__file__), Path(previous.__file__), Path(template.__file__), SOURCE,'),
    ]
    for old, new in substitutions:
        assert source.count(old) == 1, old
        source = source.replace(old, new)
    return source


def main():
    scope = dict(template.previous.__dict__, __file__=__file__, previous=template.previous,
                 template=template, recipe=recipe, MODEL=MODEL, PARENT=PARENT, CHANGES=CHANGES)
    exec(compile(derive_functions(), __file__, 'exec'), scope)
    return scope['main']()


if __name__ == '__main__':
    raise SystemExit(main())
