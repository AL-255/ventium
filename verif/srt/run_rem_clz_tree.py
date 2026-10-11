#!/usr/bin/env python3
"""Compare the actual old/new SRT CLZ functions; not a complete SRT unit gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from prepare_rem_clz_tree import OLD, NEW, transform
from test_rem_clz_tree import proof


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


STIM = '''
  integer count=0, seed, discarded;
  logic [63:0] sample;
  task automatic check(input logic [63:0] x);
    if (old_clz64(x) !== rem_clz64(x))
      $fatal(1,"REM_CLZ_TREE_MISMATCH x=%h old=%0d new=%0d",x,old_clz64(x),rem_clz64(x));
    count++;
  endtask
  initial begin
    seed=32'h19690403; discarded=$urandom(seed);
    check(64'd0); check(64'hffffffffffffffff);
    for(integer i=0;i<64;i++) begin
      check(64'd1 << i);
      check((64'd1 << i) | ((64'd1 << i)-64'd1));
      check(~(64'd1 << i));
    end
    for(integer i=0;i<131072;i++) begin
      sample={$urandom,$urandom};
      check(sample >> (i%64));
    end
    // All 16-bit patterns in each quarter, including zero subwords.
    for(integer quarter=0;quarter<4;quarter++)
      for(integer i=0;i<65536;i++) check(64'(i) << (quarter*16));
    if(count != 393410) $fatal(1,"REM_CLZ_TREE_VACUOUS count=%0d",count);
    $display("REM-CLZ-TREE-OK samples=%0d",count);
    $finish;
  end
'''


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',required=True,type=Path)
    ap.add_argument('--out',required=True,type=Path)
    a=ap.parse_args()
    source,out=a.source.resolve(strict=True),a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    repo=Path(__file__).resolve().parents[2]
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert shutil.disk_usage(scratch).free>4*1024**3
    subprocess.run([str(repo/'tools/build_scope.sh'),'--is-active'],pass_fds=(9,),check=True)
    transform(source.read_text())
    pins={str(p):sha(p) for p in (source,Path(__file__),
        Path(__file__).with_name('prepare_rem_clz_tree.py'),Path(__file__).with_name('test_rem_clz_tree.py'),
        repo/'tools/build_scope.sh',Path('/usr/bin/iverilog').resolve(),Path('/usr/bin/vvp').resolve(),
        Path('/usr/bin/z3').resolve())}
    out.mkdir()
    def save(name,value):
        with (out/name).open('x') as f:json.dump(value,f,indent=2)
    variants=[('positive',NEW,None,0),
        ('wrong-zero',NEW.replace("(x == 64'd0) ? 7'd64 : {1'b0, n}","{1'b0, n}"),'zero',1),
        ('wrong-half',NEW.replace("w32 = n[5] ? x[31:0] : x[63:32];",
                                "w32 = n[5] ? x[63:32] : x[31:0];"),'half',1)]
    for name,body,mutation,expected in variants:
        assert not expected or body!=NEW
        path=out/(name+'.sv')
        with path.open('x') as f:f.write('module tb;\n'+OLD.replace('rem_clz64','old_clz64')+body+STIM+'endmodule\n')
        pins[str(path)]=sha(path)
        query=out/(name+'.smt2')
        with query.open('x') as f:f.write(proof(mutation))
        pins[str(query)]=sha(query)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0))))
    runs,error,began=[],None,time.monotonic()
    try:
        for name,_,_,expected in variants:
            commands=[('proof-'+name,['/usr/bin/z3','-smt2',str(out/(name+'.smt2'))],0),
                ('build-'+name,['/usr/bin/iverilog','-g2012','-s','tb','-o',str(out/(name+'.vvp')),str(out/(name+'.sv'))],0),
                (name,['/usr/bin/vvp',str(out/(name+'.vvp'))],expected)]
            for label,command,code in commands:
                save(label+'.command.json',command)
                with (out/(label+'.log')).open('x') as f:
                    p=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=90)
                runs.append(dict(label=label,native_exit=p.returncode,log_sha256=sha(out/(label+'.log'))))
                assert p.returncode==code,runs[-1]
            assert (out/('proof-'+name+'.log')).read_text().strip()==('sat' if expected else 'unsat')
            assert ('REM_CLZ_TREE_MISMATCH' if expected else 'REM-CLZ-TREE-OK samples=393410') in (out/(name+'.log')).read_text()
            pins[str(out/(name+'.vvp'))]=sha(out/(name+'.vvp'))
    except BaseException as exc:
        import traceback
        error=dict(error=repr(exc),traceback=traceback.format_exc())
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=error is None and stable,pins=pins,pins_unchanged=stable,runs=runs,error=error,
        seconds=time.monotonic()-began,whole_srt=False,whole_core=False,timing_mhz=None,gameplay_ipc=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
