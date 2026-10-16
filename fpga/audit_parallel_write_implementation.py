"""Independently audit closed native products, preserving wrapper metadata FAIL.

This authorizes only the requested empirical clock experiment, not STA, CPU
correctness or standard-suite acceptance. No Vivado or board access occurs.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve()
RUN = ROOT/'parallel-write-implementation-r1'
OLD = ROOT/'parallel-write-synthesis-r1/native-synthesis/rk_ao486_system'
NEW = RUN/'project'


def sha(p):
    with Path(p).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()


def canonical(node):
    return (node.tag, tuple(sorted(node.attrib.items())), (node.text or '').strip(),
            tuple(canonical(n) for n in node))


def tree(path, project):
    root = ET.parse(path).getroot()
    for n in root.iter():
        for key,value in list(n.attrib.items()):
            if '$PPRDIR/' in value:
                value = value.replace('$PPRDIR/../../../parallel-write-fpga-r1/', '$FREEZE/')
                value = value.replace('$PPRDIR/../../parallel-write-fpga-r1/', '$FREEZE/')
            n.attrib[key] = value.replace(str(project), '$PROJECT')
    for parent in root.iter():
        for child in list(parent):
            if parent.tag == 'StratHandle' and child.tag == 'Desc':
                assert child.text in ('Vivado Synthesis Defaults','Default settings for Implementation.')
                parent.remove(child)
    return root


def main():
    owner = dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',
        'ventium-parallel-write-implementation-oct16-r1.service', '-p','MainPID',
        '-p','InvocationID','-p','ExecMainStatus','-p','ActiveState'],text=True).splitlines())
    assert owner == dict(MainPID='0',InvocationID='5520853d3c3d402995c4828400de51e0',
                         ExecMainStatus='1',ActiveState='failed'), owner
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    closed = json.loads((RUN/'implementation-closed.json').read_text())
    assert closed['native_exit'] == 0 and closed['native_success_marker']
    assert closed['resource_stop'] is None and closed['controller_failure'] is None
    pins = json.loads((RUN/'implementation-inputs.json').read_text())
    changed = {p:dict(before=h,after=sha(p)) for p,h in pins.items() if sha(p) != h}
    expected = {str(NEW/p) for p in ('rk_ao486_system.xpr',
        'rk_ao486_system.cache/wt/project.wpc','rk_ao486_system.runs/synth_1/gen_run.xml')}
    assert set(changed) == expected, changed
    wpc = 'rk_ao486_system.cache/wt/project.wpc'
    assert (NEW/wpc).read_text() == (OLD/wpc).read_text().replace(
        '6d6f64655f636f756e7465727c42617463684d6f6465:2\n',
        '6d6f64655f636f756e7465727c42617463684d6f6465:3\n')
    xml = 'rk_ao486_system.runs/synth_1/gen_run.xml'
    before, after = tree(OLD/xml,OLD), tree(NEW/xml,NEW)
    reports = [{(n.attrib['Type'],n.attrib['Name']) for n in root.findall('./File')}
               for root in (before,after)]
    assert reports[0]-reports[1] == {
        ('VDS-TIMINGSUMMARY','rk_ao486_bd_wrapper_timing_summary_synth.rpt'),
        ('VDS-TIMING-PB','rk_ao486_bd_wrapper_timing_summary_synth.pb'),
        ('RDS-PROPCONSTRS','rk_ao486_bd_wrapper_drc_synth.rpt')}
    assert not reports[1]-reports[0]
    for root in (before,after):
        for n in root.findall('./File'): root.remove(n)
    assert canonical(before) == canonical(after), 'synthesis metadata differs beyond explicit report/path changes'
    before, after = tree(OLD/'rk_ao486_system.xpr',OLD), tree(NEW/'rk_ao486_system.xpr',NEW)
    simulation = after.find("./FileSets/FileSet[@Name='sim_1']")
    added = simulation.find('./Filter')
    assert added.attrib == {'Type':'Srcs'}
    simulation.remove(added)
    impl = after.find("./Runs/Run[@Id='impl_1']")
    assert impl.attrib.pop('Dir') == '$PRUNDIR/impl_1'
    assert impl.attrib.pop('LaunchOptions') == '-jobs 1 '
    added = impl.find('./GeneratedRun')
    assert added.attrib == {'Dir':'$PRUNDIR','File':'gen_run.xml'}
    impl.remove(added)
    opt = impl.find("./Strategy/Step[@Id='opt_design']")
    assert len(opt) == 1 and opt[0].attrib == {'Id':'Directive'} and opt[0].text == '4'
    opt.remove(opt[0])
    assert canonical(before) == canonical(after), 'project changed beyond relocation/approved implementation metadata'
    log = (RUN/'implementation.log').read_text()
    assert '\n## IMPL OK\n' in log and 'RuntimeOptimized' in log
    assert not re.search(r'^ERROR:',log,re.M)
    implementation = NEW/'rk_ao486_system.runs/impl_1'
    route = (implementation/'rk_ao486_bd_wrapper_route_status.rpt').read_text()
    for name,count in [('routable nets',223765),('fully routed nets',223765),('nets with routing errors',0)]:
        assert re.search(r'# of '+name+r'\.+\s*:\s*'+str(count)+r'\s*:', route), name
    drc = (implementation/'rk_ao486_bd_wrapper_drc_routed.rpt').read_text()
    assert 'Design State : Fully Routed' in drc
    assert not re.search(r'\|\s*(?:Error|Critical Warning)\s*\|',drc)
    timing = (implementation/'post_impl_timing_summary.rpt').read_text()
    assert re.search(r'mmcm_clk\s+\{0.000 12.500\}\s+25.000\s+40.000',timing)
    assert re.search(r'clk_pl_0\s+\{0.000 5.000\}\s+10.000\s+100.000',timing)
    assert 'Worst Slack       -9.841ns' in timing
    for p,item in closed['artifacts'].items():
        assert sha(p) == item['sha256'] and Path(p).stat().st_size == item['bytes']
    binary = implementation/'rk_ao486_bd_wrapper.bin'
    with binary.open('rb') as stream:
        header = stream.read(84)
    assert header[0x50:0x54] == bytes.fromhex('aa995566')
    samples = [json.loads(s) for s in (RUN/'implementation-watch.jsonl').read_text().splitlines()]
    assert samples and not any(s['events']['oom'] or s['events']['oom_kill'] for s in samples)
    result = dict(native_product_audit_pass=True, original_wrapper_exit=1,
        original_wrapper_metadata_failure_preserved=True, checked_input_count=len(pins),
        only_changed_pins=changed, metadata_semantics_audited=True,
        native_exit=0, terminal_owner=owner, artifacts=closed['artifacts'],
        fully_routed_nets=223765, routing_errors=0, drc_errors=0,
        constraint_core_mhz=40, constraint_axi_mhz=100,
        setup_wns_ns=-9.841, hold_whs_ns=.004,
        conditional_same_clock_path_estimate_mhz=1000/(25+9.841),
        no_oom=True, duration_seconds=closed['elapsed_seconds'],
        timing_signoff=False, hardware_acceptance=False, gameplay_ipc=None,
        user_authorized_empirical_overclock_experiment_only=True,
        auditor_sha256=sha(__file__))
    with (RUN/'independent-product-audit-r1.json').open('x') as stream: json.dump(result,stream,indent=2)
    print(json.dumps(result,indent=2))


if __name__ == '__main__': main()
