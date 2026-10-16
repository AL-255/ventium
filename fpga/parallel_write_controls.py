"""Unchanged cold input and short CRC controls for parallel write admission."""
import inspect
from types import SimpleNamespace

import build_parallel_write_soc as build
import qualified_pair_credit_controls as prior_controls

TEMPLATES = prior_controls.TEMPLATES


def changes(action):
    return [
        ("'qualified-pair-credit-soc-r1'", "'parallel-write-soc-r1'"),
        ('ventium-qualified-pair-cm10-', 'ventium-parallel-write-cm10-'),
        ('.template.previous.parent_build.UI_MODEL', '.template.template.previous.parent_build.UI_MODEL'),
        ('Path(prior_controls.__file__),', 'Path(prior_controls.__file__),Path(prior_controls.prior_controls.__file__),'),
    ]


def derive(action):
    assert build.sha(prior_controls.__file__) == 'e7c53217f6dd519c44b58ce161f78c7dcc7660512e2bfb25d45911d7a7c8546b'
    source = prior_controls.derive(action)
    for old, new in changes(action):
        if old not in source:
            assert old in ("'qualified-pair-credit-soc-r1'", 'ventium-qualified-pair-cm10-'), old
        source = source.replace(old, new)
    compile(source, __file__, 'exec')
    return source


def selected_model(soc):
    source = build.recipe.once(inspect.getsource(prior_controls.prior_controls.selected_model),
                               "'system-read-ack-soc-r1'", "'parallel-write-soc-r1'")
    scope = dict(prior_controls.prior_controls.__dict__, build=build)
    exec(compile(source, __file__, 'exec'), scope)
    return scope['selected_model'](soc)


def namespace(action, model):
    scope = prior_controls.namespace(action, model)
    runner = SimpleNamespace(MODEL=model, PARENT_MODEL=build.PARENT_MODEL,
                             CONTROLLER=build.PS2_SHA, __file__=__file__)
    scope.update(__file__=__file__, prior_controls=prior_controls, build=build,
                 integration=build, runner=runner, MODEL=model,
                 PARENT_MODEL=build.PARENT_MODEL, CONTROLLER=build.PS2_SHA)
    return scope


def main():
    scope = dict(prior_controls.prior_controls.__dict__, __file__=__file__,
                 selected_model=selected_model, namespace=namespace, derive=derive)
    exec(compile(inspect.getsource(prior_controls.prior_controls.main), __file__, 'exec'), scope)
    return scope['main']()


if __name__ == '__main__': raise SystemExit(main())
