"""Derive a read-only coverage controller from the closed timing controller.

Keep its exclusive native-tool lifecycle and every resource bound unchanged.
Preparation does not launch a tool. Runtime requires exact closed timing owners.
"""
import ast
import hashlib
import json
import os
from pathlib import Path

ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
REPO = Path(__file__).resolve().parent.parent
TEMPLATE_SHA = 'f642699e0a4966cb6a642d1775d8105ebb2495343f9de0c2da4e6474b471f582'


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def replace(text, before, after):
    assert text.count(before) == 1, before
    return text.replace(before, after)


def main():
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert ROOT.is_relative_to(scratch) and ROOT.stat().st_dev != REPO.stat().st_dev
    template = ROOT/'next-pair-cofactor-clock-r1/run.py'
    assert sha(template) == TEMPLATE_SHA
    original = template.read_text()
    text = replace(original, "'ventium-next-pair-cofactor-clock-oct12.service','-p','InvocationID'",
                   "'ventium-next-pair-cofactor-coverage-oct12.service','-p','InvocationID'")
    anchor = "assert state()['ActiveState'] in ('inactive','failed')"
    preflight = '''clock = root.parent/'next-pair-cofactor-clock-r1'
for unit, invocation in (
    ('ventium-next-pair-cofactor-clock-oct12.service', 'b2360d6fe40443afbd22a8d4e6d16edc'),
    ('ventium-next-pair-cofactor-report-queue-oct12.service', '4017a795c0f8441fa0378de46989ce76')):
    actual = dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show',unit,'-pInvocationID','-pMainPID',
        '-pSubState','-pExecMainStatus'],text=True,timeout=10).splitlines())
    assert actual == dict(InvocationID=invocation,MainPID='0',SubState='exited',ExecMainStatus='0'),actual
clock_before = json.loads((clock/'started.json').read_text())
clock_done = json.loads((clock/'closed.json').read_text())
assert clock_done['native_exit'] == 0 and clock_done['inputs_unchanged']
assert clock_done['resource_stop'] is None and clock_done['controller_failure'] is None
assert json.loads((clock/'audit.json').read_text())['passed']
assert all(sha(p) == h for p,h in clock_before['pins'].items())
'''
    text = replace(text, anchor, preflight+anchor)
    text = replace(text, "root/'audit.tcl',synthesis/'closed.json'",
                   "repo/'fpga/report_rk_timing_coverage.tcl',synthesis/'closed.json'")
    text = replace(text, "wrapper = str(root/'audit.tcl')",
                   "wrapper = str(repo/'fpga/report_rk_timing_coverage.tcl')")
    text = replace(text, "str(project),str(root),str(parent_checkpoint),parent_sha,str(parent_project)]",
                   "str(project),str(root/'reports')]")
    text = replace(text, 'host = available()\nassert shutil.disk_usage',
        "for p in (clock/'run.py',clock/'started.json',clock/'closed.json',clock/'audit.json',\n"
        "          repo/'fpga/prepare_next_pair_coverage.py',\n"
        "          root.parent/'next-pair-cofactor-report-queue-closed.json'):\n"
        "    pins[str(p)] = sha(p)\nhost = available()\nassert shutil.disk_usage")
    text = replace(text, 'native audit; inspect native-audit.txt and reports',
                   'coverage diagnostic only; inspect reports; no timing acceptance')
    assert text[text.index('owner = None\n'):] .replace(
        'coverage diagnostic only; inspect reports; no timing acceptance',
        'native audit; inspect native-audit.txt and reports') == original[original.index('owner = None\n'):]
    ast.parse(text)
    root = ROOT/'next-pair-cofactor-coverage-r1'
    root.mkdir()
    with (root/'run.py').open('x') as f:
        f.write(text)
    with (root/'prepared.json').open('x') as f:
        json.dump(dict(launched=False,template=str(template),template_sha256=TEMPLATE_SHA,
            output_sha256=sha(root/'run.py'),diagnostic_sha256=sha(REPO/'fpga/report_rk_timing_coverage.tcl'),
            lifecycle_unchanged=True,hardware_acceptance=False),f,indent=2)
    print(root)


if __name__ == '__main__':
    main()
