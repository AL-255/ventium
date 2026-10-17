"""Freeze the tested clock fix for strict replacement of the optimized clock leaf.

Vivado pruned constant mailbox bits and packed the live status outputs in the
existing checkpoint. This adapter restores exactly that observed boundary; it
does not ingest or synthesize any processor/cache sources.
"""
import json
import os
from pathlib import Path
import shutil

from prepare_programmable_clock import REPO, ROOT, sha, once
from audit_clock_reuse import validate

DEST = ROOT/'programmable-clock-power-repair-r5'
PRIOR = ROOT/'programmable-clock-power-repair-r4'
AUDIT = ROOT/'programmable-clock-netlist-audit-r3'
BASE = ROOT/'programmable-clock-reuse-r2'
TEST = Path('/home/yukidama/external/tmp/ventium-programmable-clock.AkDdO8')


def adapt(text):
    text = once(text, 'input wire [94:0] ps_gpio_o,', 'input wire [15:0] ps_gpio_o,')
    text = once(text, 'output wire [94:0] ps_gpio_i,',
                'output wire [7:0] ps_gpio_i,\n    output wire [5:0] mmcm_reset_reg,')
    text = once(text, "assign ps_gpio_i = {status[30:0], 64'd0};",
                '// Exact optimized boundary, witnessed by the routed leaf export.\n'
                '    assign ps_gpio_i = {status[10], status[6:0]};\n'
                '    assign mmcm_reset_reg = {status[13:11], status[9:7]};')
    return once(text, '.command_async(ps_gpio_o[47:32])', '.command_async(ps_gpio_o)')


def main():
    assert __debug__ and os.environ['TMPDIR'] == '/home/yukidama/external/tmp'
    assert ROOT.stat().st_dev != REPO.stat().st_dev and not DEST.exists()
    assert shutil.disk_usage(ROOT).free > 6*1024**3
    audit = json.loads((AUDIT/'closed.json').read_text())
    prior = json.loads((BASE/'closed.json').read_text())
    assert audit['passed'] and audit['inputs_unchanged'] and audit['native_exit'] == 0
    assert prior['passed'] and prior['inputs_unchanged'] and prior['native_exit'] == 0
    pins = {str(AUDIT/'reports'/n): h for n,h in audit['products'].items()}
    pins[str(BASE/'build/routed.dcp')] = prior['products']['routed.dcp']
    assert all(sha(Path(p)) == h for p,h in pins.items())
    # Resume the closed replacement after the report-format-only failure.
    # That run did not save placed.dcp, so repeat placement, not synthesis.
    stopped=json.loads((PRIOR/'closed.json').read_text())
    assert stopped['native_exit']==1 and stopped['inputs_unchanged'] and not stopped['passed']
    assert 'missing/ambiguous canonical Cells reuse row' in (PRIOR/'native.log').read_text()
    assert all(sha(PRIOR/'build'/n)==h for n,h in stopped['products'].items())
    for stage in ('initial','placed'):
        validate((PRIOR/'build'/(stage+'-reuse.rpt')).read_text())
        raw=json.loads((PRIOR/'build'/(stage+'-reuse.json')).read_text())
        assert raw['matched_pct']>=95 and raw['reused_pct']>=99
    old_prepared=json.loads((PRIOR/'prepared.json').read_text())
    assert all(sha(Path(p))==h for p,h in old_prepared['source_pins'].items())
    for p in (PRIOR/'closed.json',PRIOR/'prepared.json',PRIOR/'native.log'):
        pins[str(p)]=sha(p)
    pins.update({str(PRIOR/'build'/n):h for n,h in stopped['products'].items()})
    pins.update(old_prepared['source_pins'])
    for line in (TEST/'sources.sha256').read_text().splitlines():
        h, p = line.split(maxsplit=1)
        assert sha(Path(p)) == h
        pins[p] = h
    assert 'PLL-CTRL-OK' in (TEST/'controller.log').read_text()
    assert 'PROGRAMMABLE-CLOCK-UNISIM-OK' in (TEST/'unisim.log').read_text()
    assert 'power group must remain enabled through relock' in (TEST/'old-power-mutant.log').read_text()
    for p in (AUDIT/'closed.json', BASE/'closed.json', Path(__file__).resolve(),
              TEST/'controller.log', TEST/'unisim.log', TEST/'old-power-mutant.log'):
        pins[str(p)] = sha(p)
    DEST.mkdir()
    source = DEST/'source'
    source.mkdir()
    controller = REPO/'fpga/ven_pll_ctrl.sv'
    wrapper = REPO/'fpga/ven_programmable_clock.v'
    shutil.copy2(controller, source/controller.name)
    (source/'ven_programmable_clock.v').write_text(adapt(wrapper.read_text()))
    assert all(sha(p)==sha(PRIOR/'source'/p.name) for p in source.iterdir())
    result = dict(parent_checkpoint=str(BASE/'build/routed.dcp'), pins=pins,
        resume_checkpoint=str(PRIOR/'build/replaced.dcp'),
        resume_soc_before=str(PRIOR/'build/soc-before.v'),
        source_pins={str(p):sha(p) for p in source.iterdir()},
        replacement_cell='rk_ao486_bd_i/u_clkdiv/inst', processor_rtl_changed=False,
        synthesis_scope='none; resume verified clock replacement', constraint_core_mhz=40, constraint_axi_mhz=100,
        boundary_map=dict(ps_gpio_i='status[10],status[6:0]',
                          mmcm_reset_reg='status[13:11],status[9:7]', ps_gpio_o='command[15:0]'),
        hardware_acceptance=False, gameplay_ipc=None)
    (DEST/'prepared.json').write_text(json.dumps(result, indent=2)+'\n')
    print(DEST)


if __name__ == '__main__': main()
