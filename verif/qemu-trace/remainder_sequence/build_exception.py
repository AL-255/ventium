"""Reuse the bounded fresh QEMU builder with an explicit new parent/recipe."""
from pathlib import Path
import build
import prepare_exception

build.PARENT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/build-r1')
build.PARENT_BINARY_SHA = '1418bd574ee8c484987eacb87463fb1defa2629ce0ee7be9959ee37b7cc41f41'
build.prepare = prepare_exception
original_save = build.save


def save(path, value):
    # The reused builder already pins itself and the selected recipe. Include
    # this parent-selection wrapper in the same before/after pin dictionary.
    if path.name == 'started.json':
        wrapper = Path(__file__).resolve()
        value['pins'][str(wrapper)] = build.sha(wrapper)
    original_save(path, value)


build.save = save
if __name__ == '__main__': raise SystemExit(build.main())
