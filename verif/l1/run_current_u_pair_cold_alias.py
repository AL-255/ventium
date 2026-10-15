"""Challenge current-U specialization with U-DTLB miss / warm V translation.

Use a previously untouched linear alias of resident U data. V's page and cache
line are warm. Ordinary reset, page tables and real page walk; no forced state.
Retain full QEMU and exact A/B cycle checks, so a lost pairing is a failure.
"""
import argparse
import ast
import hashlib
import os
from pathlib import Path
import subprocess

import prepare_current_u_pair as recipe

REPO = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args,extra = parser.parse_known_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    scaffold = REPO/'verif/fe_pipe/prefix-ex-system.S'
    source = scaffold.read_text()
    source = recipe.once(source, '    movl $0x003063,0x1200c\n',
        '    movl $0x003063,0x1200c\n    movl $0x003063,0x12014\n')
    source = recipe.once(source, '    jmp hot_u\n    .balign 32,0x90\n',
        '    movl $0x5000,%eax\n    jmp hot_u\n    .balign 32,0x90\n')
    fixture = root.with_suffix('.S')
    with fixture.open('x') as stream: stream.write(source)
    original = REPO/'verif/l1/run_l1_capture_cut_system.py'
    code = original.read_text()
    code = recipe.once(code, "HERE=Path(__file__).resolve().parent", f'HERE=Path({str(original.parent)!r})')
    code = recipe.once(code, "    scaffold=REPO/'verif/fe_pipe/prefix-ex-system.S'", f'    scaffold=Path({str(fixture)!r})')
    # Only V operands with independent warm translations. The other-line
    # pattern intentionally uses U's alias page, so it is not this scenario.
    code = recipe.once(code, "for p in PATTERNS for r in (0,1)",
        "for p in PATTERNS if p[0] in ('wide','byte','read-alu') for r in (0,1)")
    ast.parse(code)
    driver = root.with_suffix('.driver.py')
    with driver.open('x') as stream: stream.write(code)
    inputs = [Path(__file__).resolve(),Path(recipe.__file__).resolve(),scaffold,original,fixture,driver]
    pins = {str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    import json
    with root.with_suffix('.inputs.json').open('x') as stream: json.dump(pins,stream,indent=2)
    child = subprocess.run(['/usr/bin/python3','-B',str(driver),'--out',str(root),*extra],timeout=180)
    assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in pins.items())
    return child.returncode


if __name__ == '__main__': raise SystemExit(main())
