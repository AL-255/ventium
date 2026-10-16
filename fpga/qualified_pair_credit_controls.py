"""Retain exact cold input and short CRC controls for the pair-credit PC."""
import inspect
from pathlib import Path
from types import SimpleNamespace

import build_qualified_pair_credit_soc as build
import system_read_ack_controls as prior_controls

TEMPLATES = prior_controls.TEMPLATES


def changes(action):
    rows = [("'system-read-ack-soc-r1'", "'qualified-pair-credit-soc-r1'"),
            ('ventium-system-read-ack-cm10-', 'ventium-qualified-pair-cm10-'),
            ('.previous.parent_build.UI_MODEL', '.template.previous.parent_build.UI_MODEL'),
            ('Path(previous_controls.__file__),', 'Path(prior_controls.__file__),Path(previous_controls.__file__),')]
    return rows


def derive(action):
    assert build.sha(prior_controls.__file__) == '3ad78174acaba5195fbfc683abcea00125a86d41df467c2204c756d999ddea3b'
    source = prior_controls.derive(action)
    for old, new in changes(action):
        if old not in source:
            assert old in ("'system-read-ack-soc-r1'", 'ventium-system-read-ack-cm10-'), old
        source = source.replace(old, new)
    compile(source, __file__, 'exec')
    return source


def selected_model(soc):
    source = inspect.getsource(prior_controls.selected_model)
    assert source.count("'system-read-ack-soc-r1'") == 1
    source = source.replace("'system-read-ack-soc-r1'", "'qualified-pair-credit-soc-r1'")
    scope = dict(prior_controls.__dict__, build=build)
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
    scope = dict(prior_controls.__dict__, __file__=__file__, selected_model=selected_model,
                 namespace=namespace, derive=derive)
    exec(compile(inspect.getsource(prior_controls.main), __file__, 'exec'), scope)
    return scope['main']()


if __name__ == '__main__':
    raise SystemExit(main())
