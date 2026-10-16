"""Compose the tested width CPU and retained-input repair without CPU changes."""
import inspect
from pathlib import Path

import build_prime_width_soc as cpu
import build_sfetch_interior_ui_soc as template

ROOT=cpu.ROOT
PARENT=ROOT/'prime-width-soc-r1'
PARENT_MODEL='cabf2f1198f476de7ec64fd18e179e6a1c2f57dc9ceeee6883a7f14ee3f9096d'
UI_PARENT,UI_MODEL=template.UI_PARENT,template.UI_MODEL
ui,bound=template.ui,template.bound
sha,load,save,stable=cpu.sha,cpu.load,cpu.save,cpu.stable
check_delta=template.check_delta


def prepare_source():
    assert sha(template.__file__)=='ff5c4634f7a2b357ce690683c302bac0391c3d22b84239efc0e7eacd87980a89'
    text=template.prepare_source()
    for old,new in (
        ("'sim_sfetch_interior_ui_'","'sim_prime_width_ui_'"),
        ('Path(previous.__file__),Path(cpu.__file__),',
         'Path(previous.__file__),Path(template.__file__),Path(cpu.__file__),'),
        ('Fetch-size CPU unchanged; exact retained controller and already-tested native input host.',
         'Prime-width CPU unchanged; exact retained controller and already-tested native input host.'),
    ):
        assert text.count(old)==1,old;text=text.replace(old,new)
    return text


def namespace():
    scope=template.namespace()
    scope.update(__file__=__file__,template=template,cpu=cpu,ROOT=ROOT,
                 PARENT=PARENT,PARENT_MODEL=PARENT_MODEL)
    exec(compile(prepare_source(),__file__,'exec'),scope)
    return scope


def prepare(root):
    return namespace()['prepare'](root)


def main():
    scope=namespace()
    text=inspect.getsource(template.previous.main)
    text=text.replace('Combined next-read/UI source prepared; no compiler or guest launched.',
                      'Combined prime-width/UI source prepared; no compiler or guest launched.')
    exec(compile(text,__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__':raise SystemExit(main())
