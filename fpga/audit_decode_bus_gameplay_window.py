"""Read-only audit of the latest observed older-model gameplay window.

This is post-hoc window selection (samples 11/12), not a predeclared A/B trial,
full timedemo completion, current-candidate performance or FPGA acceptance.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import prepare_gameplay_window as window

MODEL='7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68'


def main():
    assert __debug__
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    root=scratch/'ventium-fprem-sequence.iSZ9BAj4'
    build=root/'decode-bus-soc-r1'; case=build/'quake-cold-decode-bus-oct15.1'; run=case/'run'
    load=lambda p:json.loads(p.read_text())
    native=load(case/'native-admission.json'); before=load(case/'receipt-before.json')
    started=load(build/'build-started.json'); closed=load(build/'build-closed.json')
    inputs=load(run/'inputs.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    assert closed['binary_sha256']==native['exe_sha256']==inputs['binary_sha256']==MODEL
    pins=dict(started['pins']); pins.update(before['input_sha256_before'])
    assert all(window.sha(p)==h for p,h in pins.items())
    proc=Path('/proc')/str(native['pid'])
    assert (proc/'exe').resolve()==Path(native['exe']) and window.sha(native['exe'])==MODEL
    assert int((proc/'stat').read_text().rsplit(')',1)[1].split()[19])==native['starttime']
    command=(proc/'cmdline').read_bytes().rstrip(b'\0').decode().split('\0')
    assert command==native['argv']==inputs['command'][3:]
    assert os.sched_getaffinity(native['pid'])=={11}
    assert inputs['cold_reset'] and not inputs['snapshots'] and not inputs['guest_modifications']
    assert not any(arg.startswith(('--restore','--step','--break','--kb')) for arg in command)
    for option,value in (('--rate','40000000'),('--rate-rtc','40000000'),('--rate-vga','80000000')):
        assert command[command.index(option)+1]==value
    owner=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',
        'ventium-decode-bus-quake-oct15-r1.service','-p','SubState','-p','MainPID','-p','InvocationID'],text=True).splitlines())
    assert owner==dict(SubState='running',MainPID=str(native['ppid']),InvocationID=before['invocation_id'])
    group=Path('/sys/fs/cgroup'+native['cgroup'].split('::',1)[1])
    events=dict(s.split() for s in (group/'memory.events').read_text().splitlines())
    assert all(events[k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    definitions=(build/'defines.txt').read_text().splitlines()
    assert len(definitions)==157
    assert {'VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_L1_AXI'}<=set(definitions)
    assert not {'VEN_CACHE_HALF','VEN_SYS_FASTPATH_ALL'}&set(definitions)
    shim=build/'source/ao486-sim/ven/ven_ao486_shim.sv'
    assert re.search(r'\.cycle_mode\s*\(1\x27b1\)',shim.read_text())
    with (run/'run.log').open('rb') as stream:
        data=stream.read(os.fstat(stream.fileno()).st_size)
    data=data[:data.rfind(b'\n')+1]; text=data.decode(); lines=text.splitlines()
    assert not re.search(r'%Error|%Fatal|Assertion failed|RETIRE-STOP-FAIL|SNAPSHOT-ERROR',text)
    # The generic predeclared-window helper intentionally rejects this log:
    # startup PS service delayed sample 4 by 65,247 clocks. The pinned host
    # reports in its outer loop and sets last=main_time, while ps_clock_tick()
    # advances real DUT clocks inside PS service. Do NOT round/rewrite samples
    # or weaken that helper. Audit actual counters, including every early
    # interval, and retain the observed schedule explicitly in this record.
    host=Path(started['host']).read_text()
    assert 'if (g_ven_perf_every && main_time - g_ven_perf_last >= g_ven_perf_every)' in host
    assert 'g_ven_perf_last = main_time;' in host
    assert 'void ps_clock_tick() { tick(); }' in host
    observed_cycles=[int(m[1]) for line in lines
                     if (m:=re.match(r'^\[VEN-PERF\] cycle=(\d+)\b',line))]
    assert observed_cycles[:12]==[100000000,200000000,300000000]+[
        n*100000000+65247 for n in range(4,13)]
    first,last=window.cpi.samples(lines,1100065247,1200065247)
    delta=window.cpi.delta(first,last)
    window.cpi.validate_profile(delta,is_delta=True)
    assert (first['cycle'],last['cycle'])==(1100065247,1200065247)
    assert delta['retires']==delta['u']+delta['v']==48146083
    assert delta['u']==37609117 and delta['v']==10536966 and delta['clocks']==100000000
    frames=[]
    for index,counter,observation in ((6,first,'Weapon firing in stone room with enemy and HUD'),
                                     (7,last,'Weapon in stone corridor with HUD; different view')):
        ppm,actual,bounds=window.frame_at_cycle(lines,run,counter['cycle'])
        assert actual==index
        png=root/f'quake-decode-frame{index}-oct16.png'
        def pixels(path):
            return subprocess.check_output(['ffmpeg','-nostdin','-v','error','-i',str(path),
                 '-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','-'],timeout=10)
        assert pixels(ppm)==pixels(png)
        frames.append(dict(ppm=str(ppm),png=str(png),ppm_sha256=window.sha(ppm),
            png_sha256=window.sha(png),bounds=bounds,cycle=counter['cycle'],visual_review=observation))
        for path in (ppm,png): pins[str(path)]=window.sha(path)
    for path in (Path(__file__),Path(window.__file__),Path(window.cpi.__file__),
                 build/'defines.txt',build/'build-started.json',build/'build-closed.json',
                 case/'native-admission.json',case/'receipt-before.json',run/'inputs.json'):
        pins[str(path)]=window.sha(path)
    assert all(window.sha(p)==h for p,h in pins.items())
    result=dict(passed=True,owner=owner,model_sha256=MODEL,first=first,last=last,delta=delta,
        gameplay_uv_ipc=delta['retires']/delta['clocks'],u_only_ipc=delta['u']/delta['clocks'],
        frames=frames,pins=pins,source_and_runtime_pins_checked=len(pins),
        no_oom=True,raw_pixels_preserved=True,visual_reviewed_as_gameplay=True,
        sample_indices=[11,12],window_selection='post-hoc latest completed periodic window, not predeclared A/B',
        observed_sample_cycles=observed_cycles,early_sample4_report_delay_clocks=65247,
        log_prefix_bytes=len(data),log_prefix_sha256=hashlib.sha256(data).hexdigest(),
        current_timing_candidate=False,current_candidate_gameplay_ipc=None,
        whole_timedemo=False,standard_suite=False,physical_fpga=False)
    with (root/'decode-bus-gameplay-window-oct16-r1.json').open('x') as stream:
        json.dump(result,stream,indent=2)
    print(json.dumps({k:result[k] for k in ('passed','model_sha256','gameplay_uv_ipc','u_only_ipc',
                    'source_and_runtime_pins_checked','window_selection','whole_timedemo','physical_fpga')},indent=2))


if __name__=='__main__':main()
