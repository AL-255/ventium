"""Transfer the checked prefix memory-payload cut to the exact full-PC parent.

All shared RTL and UV-fast defines remain source matched. This experiment
inherits no canonical, standard-suite or physical FPGA qualification.
"""
import ast
import hashlib
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/fe_pipe'))
import prepare_prefix_mem_payload as recipe

DECODER_SOURCE = (Path('/home/yukidama/external/tmp').resolve(strict=True) /
                  'ventium-data-size.v2HaTO2X/fast-segment-core-r1/candidate'/recipe.DECODER_FILE)


def transform(name, source):
    if name == recipe.FILE:
        return recipe.transform(source, DECODER_SOURCE.read_text())
    raise ValueError('unreviewed source delta: '+name)


def derive():
    original = Path(__file__).with_name('build_window_current_soc.py')
    text = original.read_text()
    assert hashlib.sha256(text.encode()).hexdigest() == 'ddfd33d54a5952e9168c5957a4e7e1225d00a8c364f8c8e3a310b913d90ef4e9'
    tree = ast.parse(text)
    function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'transform')
    lines = text.splitlines(keepends=True)
    text = ''.join(lines[:function.lineno-1]+lines[function.end_lineno:])
    substitutions = (
        ('"""'+ast.get_docstring(tree, clean=False)+'"""', repr(__doc__)),
        ('c0de36c5456d737ed38431598095f3df7d5c03f4f61da5e9462d1ddb23cd772f',
         '93315731b334cfe12ced52ba1dda186907480a30584e56bb7389d5f3bc123924'),
        ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',
         'e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6'),
        ("CHANGES = [env_write.FILE, 'rtl/mem/ven_l1d.sv']", "CHANGES = [recipe.FILE]"),
        ("proof / 'window-current-core-r1'", "proof / 'prefix-payload-core-r1'"),
        ("proof / 'soc-r1'", "proof / 'fast-segment-soc-r1'"),
        ('window-current-regression-audit.json', 'prefix-payload-regression-audit.json'),
        ('sim_window_current_', 'sim_prefix_payload_'),
        ('Path(window.__file__), Path(env_write.__file__),',
         'original, Path(recipe.__file__), DECODER_SOURCE,'),
        ('Two-file transfer prepared;', 'One-file transfer prepared;'),
        ("    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]",
         "    affinity = command.index('taskset')\n"
         "    assert command[affinity+1:affinity+3] == ['-c', '0-9,12-31']\n"
         "    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]"),
    )
    for before, after in substitutions:
        assert text.count(before) == 1, before
        text = text.replace(before, after)
    ast.parse(text)
    return original, text


original, derived = derive()
exec(compile(derived, str(Path(__file__)), 'exec'), globals())
