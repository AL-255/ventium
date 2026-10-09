#!/usr/bin/env python3
"""Actual early CPU handshakes, not a fixed post-reset wait before stimulus."""
from concurrent.futures import ThreadPoolExecutor
import argparse,hashlib,json,os,re,shutil,subprocess
from pathlib import Path
from prepare_l2_init_backpressure import transform

REPO=Path(__file__).resolve().parents[2]
def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def save(p,v):
    with p.open('x') as f:json.dump(v,f,indent=2)

EARLY=r'''
  int delay_cycles=0, first_write=0;
  task automatic early_request(input int word_idx,input bit writing);
    int accepted,deadline,got,before_writes;
    @(negedge CLK);CPU_ADDR=30'(BASE/4+word_idx);CPU_RD=!writing;CPU_WE=writing;
    CPU_BURSTCNT=1;CPU_DIN=32'h5318da72;CPU_BE=4'h5;
    accepted=0;deadline=cyc+SETS+256;before_writes=writes;
    while(!accepted) begin
      @(posedge CLK);
      if(!CPU_BUSY) begin
        if(dut.state!=1 || RESET || dut.RESET_1)
          $fatal(1,"command accepted before initialization completed");
        accepted=1;
      end
      @(negedge CLK);
      if(cyc>deadline) $fatal(1,"early request handshake timeout");
    end
    CPU_RD=0;CPU_WE=0;CPU_ADDR=30'hfffffff;CPU_DIN=32'hdeadbeef;CPU_BE=15;
    if(writing) begin
      expected[word_idx][7:0]=8'h72;expected[word_idx][23:16]=8'h18;
      while(writes==before_writes) begin
        @(negedge CLK);if(cyc>deadline) $fatal(1,"early store lost");
      end
      if(writes!=before_writes+1) $fatal(1,"early store duplicated");
    end else begin
      got=0;
      while(!got) begin
        if(CPU_DOUT_READY) begin
          if(CPU_DOUT!==expected[word_idx]) $fatal(1,"early read data mismatch");
          got=1;
        end
        if(!got) @(negedge CLK);
        if(cyc>deadline) $fatal(1,"early read lost");
      end
    end
    idle();read_words(word_idx,1);idle();
  endtask
  initial begin
    if(!$value$plusargs("DELAY=%d",delay_cycles)) delay_cycles=0;
    if(!$value$plusargs("WRITE=%d",first_write)) first_write=0;
    if(delay_cycles<0 || delay_cycles>1024 || first_write<0 || first_write>1) $fatal(1,"bad probe parameters");
    foreach(ram[i]) begin ram[i]=32'hb57e0000^(32'(i)*32'h9e3779b9);expected[i]=ram[i];end
    repeat(3) @(negedge CLK);RESET=1;
    repeat(5) @(negedge CLK);RESET=0;started=1;
    repeat(delay_cycles) @(negedge CLK);
    early_request((4*SETS-1)*16+1,first_write!=0);
    // Repeat on a genuinely populated cache with changed backing memory.
    // The new reset must invalidate all old tags before its first command.
    @(negedge CLK);RESET=1;
    repeat(5) @(negedge CLK);RESET=0;
    ram[(4*SETS-1)*16+1]^=32'h65f719a3;
    expected[(4*SETS-1)*16+1]^=32'h65f719a3;
    repeat(delay_cycles) @(negedge CLK);
    early_request((4*SETS-1)*16+1,first_write==0);
    foreach(ram[i]) if(ram[i]!==expected[i]) $fatal(1,"backing corruption after early request");
    $display("L2-INIT-EARLY-OK sets=%0d delay=%0d first_write=%0d",SETS,delay_cycles,first_write);
    $finish;
  end
endmodule
'''

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--stores',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();prior=args.stores.resolve(strict=True);out=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and Path(os.environ['TMPDIR']).resolve()==scratch
    assert shutil.disk_usage(scratch).free>2*1024**3
    result=json.loads((prior/'closed.json').read_text());assert result['passed']
    assert all(sha(p)==h for p,h in json.loads((prior/'pins.json').read_text()).items())
    fds=tuple(int(p.name) for p in Path('/proc/self/fd').iterdir() if p.name.isdigit() and p.exists() and p.resolve()==Path('/tmp/ventium-heavy-build.lock'))
    assert fds,'launch under build_scope.sh'
    out.mkdir()
    pins={str(p):sha(p) for p in (Path(__file__).resolve(),REPO/'verif/l1/prepare_l2_init_backpressure.py',prior/'closed.json',prior/'pins.json')}
    for name in ('candidate.v','prims.sv','tb.sv'):
        source=prior/name;target=out/name;shutil.copyfile(source,target);pins[str(source)]=sha(source)
    (out/'fixed.v').write_text(transform((out/'candidate.v').read_text()))
    text=(out/'tb.sv').read_text();assert text.count('  initial begin\n')==1
    (out/'early.sv').write_text(text.split('  initial begin\n')[0]+EARLY)
    for name in ('candidate.v','fixed.v','prims.sv','tb.sv','early.sv'):pins[str(out/name)]=sha(out/name)
    save(out/'pins.json',pins)
    jobs=[(s,p,m) for s in (128,1024) for p in ('old','fixed') for m in ('legacy','lower','any')]
    def build(job):
        sets,profile,mode=job;dst=out/f'{sets}-{profile}-{mode}';dst.mkdir()
        defs=['VEN_ALTSYNCRAM_XPM','L2_CAPACITY_PARAM']
        if mode!='legacy':defs+=['VEN_L2_STREAM_CWF']
        if mode=='any':defs+=['VEN_L2_STREAM_ANY']
        command=['/tools/verilator/v5.046/bin/verilator','--binary','--timing','--assert','-sv','-j','8',
            '-Wall','-Wno-fatal','-Wno-UNUSED',*['-Werror-'+k for k in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
            *['-D'+k for k in defs],'--top-module','tb_l2_capacity_stores',f'-GSETS={sets}',
            '--Mdir',str(dst/'obj'),'-o','test',str(out/'early.sv'),str(out/('candidate.v' if profile=='old' else 'fixed.v')),str(out/'prims.sv')]
        save(dst/'command.json',command)
        with (dst/'build.log').open('x') as log:
            rc=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=180,pass_fds=fds).returncode
        assert rc==0,(job,rc)
        return job
    closed=dict(passed=False,rows=[],gameplay_ipc=None,standard_suite=False)
    try:
        with ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(build,jobs))
        runs=[(*job,d,w,s) for job in jobs for d in (0,1,64,127,128,512,1023,1024)
              for w in (0,1) for s in (1,7,101)]
        def run(job):
            sets,profile,mode,delay,writing,seed=job;dst=out/f'{sets}-{profile}-{mode}'
            path=dst/f'run-{delay}-{writing}-{seed}.log'
            with path.open('x') as log:
                rc=subprocess.run([dst/'obj/test',f'+DELAY={delay}',f'+WRITE={writing}',
                    '+verilator+rand+reset+2',f'+verilator+seed+{seed}'],stdout=log,stderr=subprocess.STDOUT,timeout=30).returncode
            text=path.read_text()
            bad=profile=='old' and delay<sets-2
            if bad:ok=rc!=0 and 'command accepted before initialization completed' in text
            else:ok=rc==0 and f'L2-INIT-EARLY-OK sets={sets} delay={delay} first_write={writing}' in text
            return dict(sets=sets,profile=profile,mode=mode,delay=delay,writing=writing,seed=seed,
                negative_expected=bad,native_exit=rc,passed=ok)
        with ThreadPoolExecutor(max_workers=32) as pool:closed['rows']=list(pool.map(run,runs))
        assert all(r['passed'] for r in closed['rows']),[r for r in closed['rows'] if not r['passed']][:10]
        closed['passed']=True
    except Exception as exc:closed['error']=repr(exc)
    finally:
        closed['stable_inputs']=all(sha(p)==h for p,h in pins.items());closed['passed'] &= closed['stable_inputs']
        save(out/'closed.json',closed)
    print(json.dumps(dict(passed=closed['passed'],cases=len(closed['rows']),error=closed.get('error'))))
    assert closed['passed'],closed.get('error')

if __name__=='__main__':main()
