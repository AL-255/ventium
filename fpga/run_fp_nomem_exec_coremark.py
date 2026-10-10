"""Fresh cold boot of both unchanged short disks; not duration-valid scores."""
import argparse,hashlib,json,os,re,shutil,signal,subprocess,sys,time
from pathlib import Path
def parse_cmdline(data):
    separator = bytes([0])
    assert data and data.endswith(separator), 'incomplete proc argv'
    return [os.fsdecode(arg) for arg in data.split(separator)[:-1]]

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--soc',type=Path,required=True)
parser.add_argument('--unit',required=True)
args=parser.parse_args()
soc=args.soc.resolve(strict=True)
assert soc.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
assert re.fullmatch(r'ventium-fp-exec-cm10-[a-z0-9-]+\.service',args.unit)
root=soc/'coremark';root.mkdir()
assert os.sched_getaffinity(0)=={11}, 'explicit taskset affinity required'
repo=Path('/home/yukidama/github/ventium')
sys.path.insert(0,str(repo/'verif/bench/coremark_boot'))
from check_result import check
boot=Path('/home/yukidama/external/tmp/ventium-coremark-boot.z4ICVy4Y/smoke-r2')
rom=Path('/home/yukidama/external/tmp/ventium-sfetch16-soc.p8u2t1lA/quake-cold-sfetch16-oct10.1/run/rom')
model=soc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted'
def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def save(p,v):
    with p.open('x') as f:json.dump(v,f,indent=2)
assert __debug__ and os.environ['TMPDIR']=='/home/yukidama/external/tmp'
assert shutil.disk_usage(root).free>4*1024**3
assert os.environ['INVOCATION_ID'] == subprocess.check_output(['systemctl','--user','show',
    args.unit,'-p','InvocationID','--value'],text=True).strip()
b=json.loads((soc/'build-closed.json').read_text());assert b['passed'] and b['inputs_unchanged']
assert sha(model)==b['binary_sha256']
pins=dict(json.loads((soc/'build-started.json').read_text())['pins'])
pins.update(json.loads((boot/'started.json').read_text())['pins'])
assert json.loads((boot/'closed.json').read_text())['passed']
defs=set((soc/'defines.txt').read_text().split())
assert {'VEN_P54_PREFIX66_SYSTEM','VEN_P54_PREFIX66_REG','VEN_FE_PIPE','VEN_SYS_FASTPATH',
    'VEN_SYS_FASTPATH_RELOC','VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT'}<=defs
assert not {'VEN_UOPCACHE','VEN_SYS_FASTPATH_ALL'}&defs
assert re.search(r'\.cycle_mode\s*\(1\x27b1\)',(soc/'source/ao486-sim/ven/ven_ao486_shim.sv').read_text())
for p in (Path(__file__).resolve(),model,soc/'build-closed.json',soc/'defines.txt',boot/'closed.json',
    repo/'verif/bench/coremark_boot/check_result.py',rom/'boot0.rom',rom/'boot1.rom'):
    pins[str(p)]=sha(p)
for seed in ('performance','validation'):
    for name in ('coremark.img','qemu-debug.log'):pins[str(boot/seed/name)]=sha(boot/seed/name)
assert all(sha(p)==h for p,h in pins.items())
save(root/'started.json',dict(pins=pins,model=b['binary_sha256'],invocation=os.environ.get('INVOCATION_ID'),
    core_hz=40000000,cold_reset=True,standard_suite=False,gameplay_ipc=None,score_eligible=False))
cg=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
results=[];error=None
try:
    for seed in ('performance','validation'):
        work=root/seed;work.mkdir();shutil.copytree(rom,work/'rom')
        shutil.copyfile(boot/seed/'coremark.img',work/'coremark.img')
        argv=[str(model),'--ide',str(work/'coremark.img'),'--rate','40000000',
            '--rate-rtc','40000000','--rate-vga','80000000','--mem','16',
            '--cycles','13000000','--ven-perf-every','1000000','--vgatext-every','1000000']
        env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','AO486_','AXI_','TB_'))}
        env.update(AO486_BIOS_DIR=str(work/'rom'),TMPDIR=str(root))
        start=time.monotonic()
        with (work/'run.log').open('x') as log:
            child=subprocess.Popen(argv,cwd=work,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            proc=Path('/proc')/str(child.pid)
            try:
                deadline=time.monotonic()+3
                while (proc/'exe').resolve()!=model:
                    assert child.poll() is None and time.monotonic()<deadline, 'native exec admission timeout'
                    time.sleep(.01)
                observed=dict(pid=child.pid,argv=parse_cmdline((proc/'cmdline').read_bytes()),
                    exe=str((proc/'exe').resolve()),
                    starttime=int((proc/'stat').read_text().rsplit(')',1)[1].split()[19]),
                    cgroup=(proc/'cgroup').read_text(),affinity=sorted(os.sched_getaffinity(child.pid)),
                    bios_dir=env['AO486_BIOS_DIR'])
                save(work/'native-observed.json',observed)
                assert observed['affinity']==[11], ('native affinity',observed)
                assert observed['argv']==argv, ('native argv',observed,argv)
                assert observed['cgroup']==Path('/proc/self/cgroup').read_text(), ('native cgroup',observed)
                save(work/'native.json',observed)
                rc=child.wait(timeout=600)
            finally:
                if child.poll() is None:
                    os.killpg(child.pid,signal.SIGTERM)
                    try:child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid,signal.SIGKILL);child.wait()
                else:
                    child.wait()
                save(work/'native-closure.json',dict(native_exit=child.returncode,
                    actual_wait=True,pid=child.pid,proc_gone=not proc.exists()))
        assert rc==0 and not proc.exists()
        text=(work/'run.log').read_text()
        assert not re.search(r'cannot open|%Error|%Fatal|Assertion failed|CPU HUNG|UNIMPLEMENTED',text)
        assert all('BIOS: '+str(work/'rom'/n) in text for n in ('boot0.rom','boot1.rom'))
        assert '[BOARD_AXI] real RTL profile=1 slots=16 B-delay=20 R-first=21 gap=1' in text
        screens=[]
        for chunk in re.split(r'\[VGATEXT @',text)[1:]:
            screen='\n'.join(s[3:] for s in chunk.splitlines() if s.startswith('  |'))
            if 'PORT-END' in screen:screens.append(screen)
        assert screens and all(x==screens[0] for x in screens),'missing/inconsistent completed console'
        crcs={'performance':['e9f5','e714','1fd7','8e3a','fcaf'],
              'validation':['18f2','e3c1','0747','8d84','c64e']}[seed]
        result=check(screens[0],reference_crcs=crcs,iterations=10,require_valid_duration=False)
        assert result['ticks']=={'performance':4767218,'validation':4753406}[seed], 'FP admission cofactor changed benchmark clocks'
        reference=check((boot/seed/'qemu-debug.log').read_text(),reference_crcs=crcs,
                        iterations=10,require_valid_duration=False)
        assert result['crcs']==reference['crcs']
        samples=re.findall(r'\[VEN-PERF\] cycle=(\d+) retires=(\d+) clocks=(\d+) u=(\d+) v=(\d+)',text)
        assert samples and int(samples[-1][4])>0
        assert sha(work/'coremark.img')==sha(boot/seed/'coremark.img')
        assert all(sha(work/'rom'/n)==sha(rom/n) for n in ('boot0.rom','boot1.rom'))
        result.update(seed=seed,native_exit=rc,seconds=time.monotonic()-start,
            last_u=int(samples[-1][3]),last_v=int(samples[-1][4]),log_sha256=sha(work/'run.log'))
        save(work/'result.json',result);results.append(result);print(json.dumps(result),flush=True)
except BaseException as exc:
    import traceback
    error=repr(exc)
    save(root/'failure.json',dict(error=error,traceback=traceback.format_exc()))
events=dict(x.split() for x in (cg/'memory.events').read_text().splitlines())
stable=all(sha(p)==h for p,h in pins.items())
passed=error is None and len(results)==2 and stable and events['oom']==events['oom_kill']=='0'
save(root/'closed.json',dict(passed=passed,error=error,results=results,pins_unchanged=stable,
    memory_events=events,all_children_reaped=True,standard_suite=False,score_eligible=False,gameplay_ipc=None))
raise SystemExit(0 if passed else 1)
