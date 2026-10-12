"""Independently close the exact read-only DSP/constraint diagnostic."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI/next-pair-cofactor-coverage-r1').resolve(strict=True)


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    before = json.loads((ROOT/'started.json').read_text())
    done = json.loads((ROOT/'closed.json').read_text())
    state = dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show','ventium-next-pair-cofactor-coverage-oct12.service',
        '-pInvocationID','-pSubState','-pMainPID','-pExecMainStatus'],text=True).splitlines())
    assert state == dict(InvocationID='2e03e96eb656406aae991d7a63d193ae',
                         SubState='exited',MainPID='0',ExecMainStatus='0'),state
    assert before['controller_invocation'] == state['InvocationID']
    assert done['native_exit'] == 0 and done['inputs_unchanged']
    assert done['owner'] and done['resource_stop'] is None and done['controller_failure'] is None
    assert all(sha(p) == h for p,h in before['pins'].items())
    watch = [json.loads(line) for line in (ROOT/'watch.jsonl').read_text().splitlines()]
    assert watch and all(not r['reason'] and not r['events']['oom'] and not r['events']['oom_kill'] for r in watch)
    log = (ROOT/'native.log').read_text()
    assert not re.search(r'^ERROR:',log,re.M)
    assert '\nRK_TIMING_COVERAGE_COLLECTED timing_closed=false hardware_accepted=false\n' in log
    reports = ROOT/'reports'
    timing = (reports/'check_timing_verbose.rpt').read_text()
    block = timing.split('There are 8 register/latch pins with no clock (HIGH)')[1].split('2. checking constant_clock')[0]
    unclocked = [line for line in block.splitlines() if line.startswith('rk_')]
    suffixes = ['EMIOENET'+str(i)+'MDIOMDC' for i in range(4)] + [
        'EMIOSDIO0CLKOUT','EMIOSDIO1CLKOUT','EMIOSPI0SCLKO','EMIOSPI1SCLKO']
    assert unclocked == ['rk_ao486_bd_i/ps8/inst/PS8_i/'+s for s in suffixes]
    assert 'There are 0 pins that are not constrained for maximum delay.' in timing
    assert 'There are 0 combinational loops in the design.' in timing
    assert re.findall(r'^led\[\d\]$',timing,re.M) == [f'led[{i}]' for i in range(4)]
    dsps = (reports/'integer_multiplier_dsp.rpt').read_text()
    dsp_rows = []
    for suffix in ('__1','__2'):
        cell = 'rk_ao486_bd_i/u_soc/inst/u_soc/u_cpu/u_core/u_core/ex_mul_p0'+suffix+'/DSP_A_B_DATA_INST'
        block = dsps.split('CELL '+cell+'\n')[1].split('\nCELL ')[0]
        props = {p:re.search(r'^PROPERTY '+p+r' (\d+)$',block,re.M).group(1) for p in ('AREG','BREG')}
        assert props['BREG'] == '0'
        assert 'PIN '+cell+'/CLK DIRECTION IN NETS '+cell.rsplit('/',1)[0]+'/CLK\n' in block
        dsp_rows.append(dict(cell=cell,**props,clock_connected=True))
    exceptions = (reports/'exceptions_summary.rpt').read_text()
    assert re.search(r'^Multicycle Path\s+0\s+0\s+0$',exceptions,re.M)
    result = dict(passed=True,inputs_unchanged=True,no_oom=True,native_seconds=done['seconds'],
        no_clock_pins=unclocked,no_output_delay_ports=[f'led[{i}]' for i in range(4)],
        representative_dsp_properties=dsp_rows,multicycle_constraints=0,
        # Do not turn connected clocks/BREG=0 into a blanket path waiver.
        dsp_primitive_arc_interpretation='B stage bypassed; not an absent core clock',
        routed_timing_closed=False,hardware_acceptance=False,
        pins={str(p):sha(p) for p in (Path(__file__),ROOT/'started.json',ROOT/'closed.json',ROOT/'native.log',
              ROOT/'watch.jsonl',*sorted(reports.glob('*.rpt')))})
    with (ROOT/'audit.json').open('x') as f: json.dump(result,f,indent=2)
    print({k:v for k,v in result.items() if k != 'pins'})


if __name__ == '__main__': main()
