"""Bind one actually live current-candidate Win95 invocation; never award PASS.

Retain the existing independent /proc, cgroup, source, media and native-argv
checks. The caller must supply the exact service invocation returned at launch.
This script cannot launch a guest or fabricate a desktop review.
"""
import argparse
import inspect
from pathlib import Path
import re
import sys
from types import SimpleNamespace

import freeze_fp_repair_win95_expectation as previous
import prepare_raw_prime_storage_win95 as preparation

ROOT = preparation.ROOT
TEMPLATE_SHA = '4a5a5802496318a008ee52eff8687239ee24d7bdb16ee777362c9d97f647fe17'
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
import check_win95_standard_closed as checker


def add_lineage(expected, before, root, run):
    expected.update(schema=6, profile='board-posted16-40mhz-retained-input160')
    for role, name in (
        ('fpga_manifest', 'raw-prime-storage-fpga-r1/input-manifest.json'),
        ('input_audit', 'raw-prime-storage-input-r1/audit.json'),
    ):
        path = root/name
        expected[role+'_path'] = str(path)
        expected[role+'_sha256'] = before['input_sha256_before'][str(path)]
    files, roles = checker.Files(), {}
    checker.retained_input_roles(files, run, expected, roles)
    assert all(before['input_sha256_before'][p] == h for p, h in roles.items())
    cm = str(run.parent/'coremark-ui-disabled-r1/audit.json')
    assert previous.sha(cm) == before['input_sha256_before'][cm]
    files.finish()


def derive():
    assert previous.sha(previous.__file__) == TEMPLATE_SHA
    code = inspect.getsource(previous.main)
    replacements = (
        ("root == config.SCRATCH / 'ventium-fp-repair-transfer.a8nzrjHu'", 'root == current.ROOT'),
        ("soc = root / 'soc-r1'", "soc = root / 'raw-prime-storage-soc-r1'"),
        ("'win95-cold-fp-repair-oct13.1'", "'win95-cold-raw-prime-storage-oct16.1'"),
        ("'win95-expectation.json'", "'raw-prime-storage-win95-expectation.json'"),
        ("'win95-admission-audit.json'", "'raw-prime-storage-win95-admission-audit.json'"),
        ("'win95-prepared.json'", "'raw-prime-storage-win95-prepared.json'"),
        ("'soc-r1/run_win95_full_cold.py'", "'raw-prime-storage-soc-r1/run_win95_full_cold.py'"),
        ("    assert expected['boot_id'] == before['boot_id']",
         "    current.add_lineage(expected, before, root, run)\n"
         "    assert expected['boot_id'] == before['boot_id']"),
    )
    for old, new in replacements:
        assert code.count(old) == 1, old
        code = code.replace(old, new)
    compile(code, __file__, 'exec')
    return code


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    ap.add_argument('--invocation', required=True)
    args = ap.parse_args()
    assert re.fullmatch('[0-9a-f]{32}', args.invocation), 'exact live invocation required'
    assert args.root.resolve(strict=True) == ROOT
    # The inherited parser still checks exactly --root. Native owner argv is
    # read from /proc independently; changing this observer's argv cannot alter it.
    sys.argv = [__file__, '--root', str(args.root)]
    scope = dict(previous.__dict__, __file__=__file__, current=sys.modules[__name__],
        config=SimpleNamespace(SCRATCH=ROOT.parent, MODEL=preparation.MODEL,
                               MANIFEST=preparation.evidence.MANIFEST),
        UNIT=preparation.UNIT, INVOCATION=args.invocation)
    exec(compile(derive(), __file__, 'exec'), scope)
    scope['main']()


if __name__ == '__main__':
    main()
