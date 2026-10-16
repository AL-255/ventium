"""Close five state-coverage gaps in the first cold system A/B matrix.

Keep the original closed matrix and all its evidence immutable. This extension
uses its identical native supervision/QEMU/clock checks, two task-switch tests,
LAR/LSL queries, and a new cold nested real-mode interrupt microbenchmark.
"""
import inspect
from pathlib import Path

import run_system_read_ack_core as base


def case_dir(case):
    return (Path(__file__).resolve().parent/'system_read_ack_rm' if case=='nested-rm'
            else base.REPO/'verif/sys/tests'/case)


def main():
    source=inspect.getsource(base.main)
    for old,new in (
        ("folder=REPO/'verif/sys/tests'/case", "folder=case_dir(case)"),
        ("td=REPO/'verif/sys/tests'/case", "td=case_dir(case)"),
        ("(Path(__file__),Path(recipe.__file__)", "(Path(__file__),Path(base.__file__),Path(recipe.__file__)"),
    ):
        source=base.recipe.once(source,old,new)
    namespace=dict(base.__dict__,__file__=__file__,base=base,case_dir=case_dir,
        CASES=['plar','ptaskpg','pcalltss','nested-rm'],CPUS=(22,23,24,25))
    exec(compile(source,__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__':raise SystemExit(main())
