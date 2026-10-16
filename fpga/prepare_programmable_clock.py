"""Freeze a clock-only derivative of the physical parallel-write candidate.

Never ingest the dirty CPU checkout. Preserve the parent's entire source closure
and 159 defines, with exactly three integration edits and two new clock files.
Preparation does not launch synthesis or claim CPU/FPGA qualification.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil

REPO = Path(__file__).resolve().parent.parent
ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4')
PARENT = ROOT/'parallel-write-fpga-r1'
DEST = ROOT/'programmable-clock-r2'
PARENT_MANIFEST = 'e745cf4cffcf5143298293e021b678803204fa18dbd32328b2079c481743143f'


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'expected exactly one integration anchor: {old}')
    return text.replace(old, new)


def transform(files):
    result = dict(files)
    name = 'ventium/fpga/create_project_3mhz_wrapper.tcl'
    result[name] = once(result[name], 'lappend files "$VEN/fpga/clk_div32_40mhz.v"',
                       'lappend files "$VEN/fpga/ven_programmable_clock.v" "$VEN/fpga/ven_pll_ctrl.sv"')
    name = 'flow/src/rk_ao486_system_pl.v'
    text = once(result[name], '    output wire [3:0]   led ',
                '    output wire clock_change_safe,\n    output wire [3:0]   led ')
    result[name] = once(text, '    wire ddr_posted_drained, ddr_posted_fault;',
        '    wire ddr_posted_drained, ddr_posted_fault;\n'
        '    // Observability only: CPU reset and real outer AXI drain interlock.\n'
        '    assign clock_change_safe = ~core_reset_n & ddr_posted_drained & ~ddr_posted_fault;')
    name = 'flow/hw/create_project.tcl'
    text = once(result[name], '-reference clk_div32 u_clkdiv', '-reference ven_programmable_clock u_clkdiv')
    text = once(text, '# SINGLE PS clock pl_clk0',
        '# EMIO32..47 command / EMIO64..94 status; always-on PS GPIO control.\n'
        'set_property -dict [list CONFIG.PSU__GPIO_EMIO__PERIPHERAL__ENABLE {1} '
        'CONFIG.PSU__GPIO_EMIO_WIDTH {95}] $ps\n# SINGLE PS clock pl_clk0')
    text = once(text, 'set soc [create_bd_cell -type module -reference rk_ao486_system_pl u_soc]',
        'set soc [create_bd_cell -type module -reference rk_ao486_system_pl u_soc]\n'
        'connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $clkdiv/resetn]\n'
        'connect_bd_net [get_bd_pins $ps/emio_gpio_o] [get_bd_pins $clkdiv/ps_gpio_o]\n'
        'connect_bd_net [get_bd_pins $clkdiv/ps_gpio_i] [get_bd_pins $ps/emio_gpio_i]\n'
        'connect_bd_net [get_bd_pins $soc/clock_change_safe] [get_bd_pins $clkdiv/safe_change]')
    # Keep the last successful implementation's crash-avoidance directive.
    result[name] = once(text, 'if {$MODE eq "all"} {',
        'if {$MODE eq "all"} {\n'
        '    set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE RuntimeOptimized [get_runs impl_1]')
    return result


def main():
    assert __debug__ and os.environ['TMPDIR'] == '/home/yukidama/external/tmp'
    assert sha(PARENT/'input-manifest.json') == PARENT_MANIFEST
    manifest = json.loads((PARENT/'input-manifest.json').read_text())
    assert len(manifest['hardware_defines']) == 159
    assert manifest['hardware_defines'] == (PARENT/'defines.txt').read_text().splitlines()
    assert all(sha(PARENT/r['frozen']) == r['sha256'] for r in manifest['files'])
    # All materialized auxiliary/filelist/header payloads, not just active RTL.
    assert not any(p.is_symlink() for p in PARENT.rglob('*'))
    before = {str(p.relative_to(PARENT)): sha(p) for p in PARENT.rglob('*') if p.is_file()}
    names = ['ventium/fpga/create_project_3mhz_wrapper.tcl',
             'flow/src/rk_ao486_system_pl.v', 'flow/hw/create_project.tcl']
    edits = transform({n:(PARENT/n).read_text() for n in names})
    assert not DEST.exists()
    DEST.mkdir()
    source = DEST/'source'
    shutil.copytree(PARENT, source)
    for n, text in edits.items():
        (source/n).write_text(text)
    for name in ('ven_pll_ctrl.sv', 'ven_programmable_clock.v'):
        shutil.copy2(REPO/'fpga'/name, source/'ventium/fpga'/name)
    after = {str(p.relative_to(source)): sha(p) for p in source.rglob('*') if p.is_file()}
    changed = sorted(n for n in before if before[n] != after[n])
    assert changed == sorted(names)
    assert set(after)-set(before) == {'ventium/fpga/ven_pll_ctrl.sv', 'ventium/fpga/ven_programmable_clock.v'}
    assert before.keys() <= after.keys()
    # Parent metadata is retained as ancestry, NOT relabelled a new simulation.
    result = dict(source=str(source), parent=str(PARENT), parent_manifest_sha256=PARENT_MANIFEST,
        parent_pins=before, source_pins=after, changed=changed,
        added=sorted(set(after)-set(before)), hardware_defines=manifest['hardware_defines'],
        core_cache_rtl_byte_identical=True, constrained_core_mhz=40, axi_mhz=100,
        full_wrapper_elaborated=False, hardware_acceptance=False, gameplay_ipc=None,
        note='One runtime-programmable image. Parent input-manifest inside source is ancestry only; this receipt owns the derivative.')
    (DEST/'prepared.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(dict(prepared=str(DEST), source_files=len(after), changed=changed)))


if __name__ == '__main__':
    main()
