"""Cold system tests that naturally seed a complete line before immediate pairs.

The old tight loop repeatedly uses the registered paired-bank return, which
intentionally does not retain a complete line. An ordinary dependent read in
each iteration seeds the line through the real cache interface. No state forcing,
saved state, feature disable, trace filtering or comparison change is allowed.
"""
import importlib.util
import os
from pathlib import Path
import sys

import run_l1_capture_cut_system as original
from run_pair_now_read_system import PATTERNS, BACKEND_SHA


def main():
    out = Path(sys.argv[sys.argv.index('--out')+1]).resolve()
    root = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(root) and out != root and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == root
    source = Path(original.__file__).resolve()
    assert original.sha(source) == BACKEND_SHA
    code = source.read_text()
    old = 'HERE=Path(__file__).resolve().parent'
    assert code.count(old) == 1
    code = code.replace(old, 'HERE=Path('+repr(str(source.parent))+')')
    anchor = '    text=scaffold.read_text()\n'
    assert code.count(anchor) == 1
    warm = ('warm_u:\n    movl (%eax),%edx\n    addl %edx,%edx\n'
            '    jmp hot_u\n')
    addition = ('    assert text.count("    jmp hot_u\\n") == 2\n'
                '    text=text.replace("    jmp hot_u\\n", "    jmp warm_u\\n")\n'
                '    text=text.replace("    .balign 32,0x90\\n", '+repr(warm)+
                '+"    .balign 32,0x90\\n", 1)\n')
    code = code.replace(anchor, anchor+addition)
    out.mkdir(); driver = out/'driver.py'; driver.write_text(code)
    pins = {str(p):original.sha(p) for p in (Path(__file__).resolve(), source, driver,
            source.parent/'run_pair_now_read_system.py')}
    spec = importlib.util.spec_from_file_location('warm_pair_backend', driver)
    backend = importlib.util.module_from_spec(spec); spec.loader.exec_module(backend)
    backend.PATTERNS = PATTERNS
    sys.argv[sys.argv.index('--out')+1] = str(out/'matrix')
    result = backend.main()
    unchanged = all(original.sha(p)==h for p,h in pins.items())
    original.save(out/'adapter.json', dict(pins=pins,pins_unchanged=unchanged,
        native_runner_exit=result,result_sha256=original.sha(out/'matrix/closed.json')))
    assert unchanged
    return result


if __name__ == '__main__': raise SystemExit(main())
