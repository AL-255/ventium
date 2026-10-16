"""Use the same guarded builder for the narrower, exact two-file experiment."""
import inspect
from pathlib import Path

import build_sfetch_beat_core as previous
import prepare_sfetch_boundary_stage as recipe


def main():
    assert previous.native.sha(previous.__file__) == '339803a98020ff65e382f8dc1097a961492019c2a08678c87838dcd8655ee1e5'
    text = inspect.getsource(previous.main)
    text = recipe.replace_once(text, "pins = dict(native.load(leaf/'started.json')['pins']) | checked['artifacts']",
        "pins = dict(native.load(leaf/'started.json')['pins']) | checked['artifacts']\n"
        "    default = leaf.with_name('sfetch-boundary-leaf-default-r1')\n"
        "    default_done = native.load(default/'closed.json')\n"
        "    assert default_done['passed'] and default_done['pins_unchanged'] and not default_done['errors']\n"
        "    pins.update(native.load(default/'started.json')['pins'])\n"
        "    pins.update(default_done['artifacts'])\n"
        "    pins[str(default/'closed.json')] = native.sha(default/'closed.json')")
    text = recipe.replace_once(text, '(Path(__file__),Path(recipe.__file__),Path(native.__file__),',
        '(Path(__file__),Path(recipe.__file__),Path(recipe.base.__file__),Path(previous.__file__),Path(native.__file__),')
    text = recipe.replace_once(text, "'tb_sfetch_beat_'", "'tb_sfetch_boundary_'")
    text = recipe.replace_once(text, 'One preparation clock per demanded slow-fetch beat; fast U/V path unchanged',
                              'One preparation clock per true boundary beat; interior-16 and fast U/V timing unchanged')
    namespace = dict(previous.__dict__, __file__=__file__, previous=previous, recipe=recipe)
    exec(compile(text,__file__,'exec'),namespace)
    return namespace['main']()


if __name__ == '__main__':
    raise SystemExit(main())
