"""Fresh QEMU and exact RAW-parent A/B for the parallel-admission processor.

Retain all 15 cold system fixtures, AXI 0/7/31 latencies, actual U/V retirement
and complete architectural/cycle comparisons. No snapshots, STEP or slow mode.
"""
import prepare_parallel_write_admission as recipe
import run_qualified_pair_credit_core as template
from build_parallel_write_core import CHANGES, MODEL as PARENT

MODEL = '6cacb95c1f32fb83b87bb99b6ac7a9dec72a8b8a228035d1234f1cfd76f51b22'
CPUS = template.CPUS


def adapted_main():
    source = template.adapted_main()
    return recipe.once(source,
        '(Path(__file__),Path(previous.__file__),Path(recipe.__file__),',
        '(Path(__file__),Path(previous.__file__),Path(template.__file__),Path(recipe.__file__),')


def main():
    namespace = dict(template.previous.__dict__,__file__=__file__,previous=template.previous,
                     template=template,recipe=recipe,MODEL=MODEL,PARENT=PARENT,CHANGES=CHANGES,CPUS=CPUS)
    exec(compile(adapted_main(),__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__': raise SystemExit(main())
