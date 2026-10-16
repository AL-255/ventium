"""Rerun the unchanged extra matrix with only the real-mode fixture link fixed."""
import inspect
from pathlib import Path
import run_system_read_ack_extra as previous


def case_dir(case):
    return (Path(__file__).resolve().parent/'system_read_ack_rm_fixed' if case=='nested-rm'
            else previous.base.REPO/'verif/sys/tests'/case)


def main():
    source=inspect.getsource(previous.main)
    source=previous.base.recipe.once(source,
        '"(Path(__file__),Path(base.__file__),Path(recipe.__file__)"',
        '"(Path(__file__),Path(previous.__file__),Path(base.__file__),Path(recipe.__file__)"')
    source=previous.base.recipe.once(source,
        'namespace=dict(base.__dict__,__file__=__file__,base=base,case_dir=case_dir,',
        'namespace=dict(base.__dict__,__file__=__file__,base=base,previous=previous,case_dir=case_dir,')
    scope=dict(previous.__dict__,__file__=__file__,previous=previous,case_dir=case_dir)
    exec(compile(source,__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__':raise SystemExit(main())
