"""Full fresh private-reference corpus; does not relabel canonical failures."""
import prepare_parallel_write_admission as recipe
import run_qualified_pair_credit_func as prototype
from build_parallel_write_core import CHANGES, MODEL as PARENT
from run_parallel_write_core import MODEL

REFERENCE,SOURCE,REPO=prototype.REFERENCE,prototype.SOURCE,prototype.REPO


def derive_functions():
    return recipe.once(prototype.derive_functions(),
        'Path(template.__file__), SOURCE,',
        'Path(template.__file__), Path(prototype.__file__), SOURCE,')


def main():
    scope=dict(prototype.template.previous.__dict__,__file__=__file__,
        previous=prototype.template.previous,template=prototype.template,prototype=prototype,
        recipe=recipe,MODEL=MODEL,PARENT=PARENT,CHANGES=CHANGES)
    exec(compile(derive_functions(),__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__': raise SystemExit(main())
