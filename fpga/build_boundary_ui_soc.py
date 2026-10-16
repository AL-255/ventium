"""Compose retained input with the faster boundary-stage CPU, not prime-width.

Keep the parent's explicit diagnostic cycle-cost policy and canonical failure.
Only the already-tested controller and native keyboard host may change.
"""
import argparse
import inspect
import os
from pathlib import Path
import shutil

import build_next_ready_ui_soc as template
import build_sfetch_boundary_soc as cpu

ROOT = template.ROOT
PARENT = ROOT/'sfetch-boundary-soc-r1'
PARENT_MODEL = 'b32ab4b34482669c03ea57ce7be0dbd475623fa00b00c4c814fec976d75c86d2'
UI_PARENT, UI_MODEL = template.UI_PARENT, template.UI_MODEL
ui, bound = template.ui, template.bound
sha, load, save, stable = cpu.sha, cpu.load, cpu.save, cpu.stable
check_delta = template.check_delta


def check_control_costs(controls):
    """Retain the measured parent cost; never assert zero cost against its ancestor."""
    assert controls['passed'] and controls['model'] == PARENT_MODEL
    assert controls['no_oom'] and controls['all_children_reaped']
    assert not controls['duration_valid'] and not controls['standard_suite']
    assert not controls['physical_board'] and controls['gameplay_ipc'] is None
    rows = controls['measurements']
    assert [(r['seed'], r['parent_ticks'], r['candidate_ticks'], r['added_clocks'],
             r['actual_v'], r['crcs']) for r in rows] == [
        ('performance', 4767218, 4771298, 4080, 1055307,
         ['e9f5', 'e714', '1fd7', '8e3a', 'fcaf']),
        ('validation', 4753406, 4755366, 1960, 1054254,
         ['18f2', 'e3c1', '0747', '8d84', 'c64e'])]
    assert all(not r['duration_valid'] for r in rows)


def prepare_source():
    assert sha(template.__file__) == '523fe624ef9194c67d04527094941100a481babccd2fbe40de2613a3e42e5352'
    text = inspect.getsource(template.prepare)
    for old, new in (
        ("'sim_next_ready_ui_'", "'sim_boundary_ui_'"),
        ('cpu.check_definitions(', 'cpu.previous.check_definitions('),
        ('Path(__file__),Path(cpu.__file__),',
         'Path(__file__),Path(template.__file__),Path(cpu.__file__),'),
        ("    source = PARENT/'source'",
         "    cost_pins, cost_record = cpu.cycle_cost_diagnostic(Path(before['directed_core']))\n"
         "    assert before['cycle_cost'] == cost_record\n"
         "    pins.update(cost_pins)\n"
         "    controls = load(PARENT/'coremark-r1/audit.json')\n"
         "    check_control_costs(controls)\n"
         "    pins.update(controls['artifact_pins'])\n"
         "    pins[str(PARENT/'coremark-r1/audit.json')] = sha(PARENT/'coremark-r1/audit.json')\n"
         "    source = PARENT/'source'"),
        ('processor_rtl_changes=[],added_defines=[],',
         "processor_rtl_changes=[],added_defines=[],cycle_cost=cost_record,\n"
         "        parent_coremark_cost=controls['measurements'],"),
        ('Latest timing CPU unchanged; exact retained controller and already-tested native input host.',
         'Boundary-stage CPU unchanged; retained input only. Original measured cycle costs and canonical FAIL retained.'),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    return text


def prepare(root):
    scope = dict(template.__dict__, __file__=__file__, template=template, cpu=cpu,
                 ROOT=ROOT, PARENT=PARENT, PARENT_MODEL=PARENT_MODEL,
                 check_control_costs=check_control_costs)
    exec(compile(prepare_source(), __file__, 'exec'), scope)
    return scope['prepare'](root)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('prepare', 'build'))
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert root.parent == ROOT and scratch.stat().st_dev != cpu.REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        prepare(root)
        print('Boundary/input composition prepared; no compiler or guest launched.', flush=True)
        return 0
    # This is deliberately NOT cpu.base.build: the boundary parent has a
    # measured +21-clock branch fixture, preserved by its diagnostic builder.
    return cpu.build(root)


if __name__ == '__main__':
    raise SystemExit(main())
