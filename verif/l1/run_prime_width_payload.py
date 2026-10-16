"""Extract actual descriptor/payload selection and compare offered widths.

The source identity check covers widths before their unchanged extent
arithmetic. Returned-byte ownership is an abstract mask; this is not a cache,
whole-core, timing or full-system proof.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import inspect
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import prepare_prime_width_payload as recipe
import run_branch_address_shape as earlier

MODES = ('positive','drop-held','drop-fp','never-branch','force-byte','force-dword')


def sha(path):
    with Path(path).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def fixture(source, mode='positive'):
    assert mode in MODES
    header = (source/'core_mem_chain.svh').read_text()
    assert 'assign pipe_v_eff    = pipe_mem_active_q ? pipe_mem_v_q    : v_d;' in (source/'core.sv').read_text()
    changed = recipe.transform(header)
    assert header.count(earlier.recipe.PAYLOAD_NEW) == 1
    assert sha(earlier.__file__) == '2c8675cb9cb31afd2cece85b51d5c8497191ba218db776757b75993c4ce17db6'
    function = inspect.getsource(earlier.fixture)
    function = recipe.once(function,'    recipe.transform(header)','    width.transform(header)')
    scope = dict(earlier.__dict__, width=recipe)
    exec(compile(function,__file__,'exec'),scope)
    base = scope['fixture'](source,mode if mode in ('drop-held','drop-fp','never-branch') else None)
    base = recipe.once(base,'  assign flin=seg_base[SG_CS]+eip;', '''
  logic [3:0] old_strobe,new_strobe,ref_prime_strb;
  logic [2:0] agi_prime_width;
  fpd_t mc_u_q;
  integer width_checks=0,strobe_checks=0,bytes_seen=0,dwords_seen=0,fp64_denied=0;
  // Independent returned-byte ownership abstraction, not deposited cache state.
  function automatic logic ic_res_buffered_offset(input logic [5:0] offset);
    return offset < 16 && returned_mask[offset];
  endfunction
  function automatic logic ic_res_buffered_end(input logic [5:0] finish);
    return finish > 0 && finish <= 16 && returned_mask[finish-1];
  endfunction
  assign flin=seg_base[SG_CS]+eip;
'''+recipe.strobe_block(header).replace('mem_next_wstrb','old_strobe')+'\n'+
       recipe.strobe_block(changed).replace('mem_next_wstrb','new_strobe'))
    if mode in ('force-byte','force-dword'):
        anchor = '    if (mc_held_read_prime) mc_address_payload = pipe_mem_v_q;'
        base = recipe.once(base,anchor,anchor+f"\n    mc_address_payload.w8 = 1'b{int(mode=='force-byte')};")
    base = recipe.once(base,'      agi_prime_select=(n%17)==0;', '''      mc_u_q=random_descriptor();
      agi_prime_width=3'(n%8); ref_prime_strb=4'(n%16);
      // Two-beat FP forms must keep their original self-prime rejection.
      if(n%4==1 && (n/1024)%2) begin pipe_u_eff.fp_sti[0]=1; u_d=pipe_u_eff; end
      agi_prime_select=(n%17)==0;''')
    anchor = '      samples++;'
    checks = '''      if(mc_query_u.len!=0 && (mc_query_u.is_mem || mc_query_u.is_fp) &&
         !agi_prime_select && !ref_prime_select) begin
        if({mc_query_u.w8,mc_query_u.fp_sti[0]} !==
           {mc_address_payload.w8,mc_address_payload.fp_sti[0]})
          $fatal(1,"PRIME_WIDTH_MISMATCH sample=%0d mode=%0d",n,n%4);
        width_checks++;
        if(mc_query_u.w8) bytes_seen++; else dwords_seen++;
      end
      if(agi_prime_select || ref_prime_select || mc_valid_q ||
         (mc_query_u.len!=0 && (mc_query_u.is_mem || mc_query_u.is_fp))) begin
        if(old_strobe !== new_strobe)
          $fatal(1,"PRIME_WIDTH_STROBE_MISMATCH sample=%0d old=%h new=%h",n,old_strobe,new_strobe);
        strobe_checks++;
      end
      if(n%4==1 && pipe_u_eff.fp_sti[0]) begin
        if(mc_fp_self_prime) $fatal(1,"PRIME_WIDTH_FP64_ADMISSION_CHANGED");
        fp64_denied++;
      end
'''
    base = recipe.once(base,anchor,checks+anchor)
    base = recipe.once(base,'    $finish;', '''    if(width_checks==0 || strobe_checks==0 || bytes_seen==0 || dwords_seen==0 || fp64_denied==0)
      $fatal(1,"PRIME_WIDTH_VACUOUS");
    $display("PRIME-WIDTH-OK width_checks=%0d strobe_checks=%0d bytes=%0d dwords=%0d fp64_denied=%0d",
             width_checks,strobe_checks,bytes_seen,dwords_seen,fp64_denied);
    $finish;''')
    return base


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args(); source=a.source.resolve(strict=True); out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert out.parent==source.parents[3] and not out.exists()
    assert out.is_relative_to(scratch) and scratch.stat().st_dev!=Path(__file__).stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3
    assert os.environ['INVOCATION_ID'] and os.sched_getaffinity(0)=={18,19,20,21}
    group=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((group/'memory.max').read_text())<=1024**3
    assert (group/'memory.swap.max').read_text().strip()=='0'
    files=[Path(__file__),Path(recipe.__file__),Path(earlier.__file__),Path(earlier.recipe.__file__),
           Path(__file__).with_name('prepare_mc_address_payload.py'),
           Path(__file__).with_name('mc_address_payload_stim.svh'),
           *[source/name for name in ('core.sv','core_mem_chain.svh','core_raw_held_prime.svh',
                                     'core_raw_branch_mov.svh','ventium_decode_pkg.sv')],
           Path('/usr/bin/iverilog'),Path('/usr/bin/vvp')]
    pins={str(p.resolve()):sha(p) for p in files}
    out.mkdir(mode=0o700)
    def save(name,value):
        with (out/name).open('x') as stream: json.dump(value,stream,indent=2)
    with (out/'core_mem_chain.svh').open('x') as stream:
        stream.write(recipe.transform((source/'core_mem_chain.svh').read_text()))
    jobs=[(False,'positive')]+[(True,m) for m in MODES]
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],jobs=jobs))
    begin=time.monotonic(); rows=[]; errors=[]
    def execute(job):
        span,mode=job; work=out/(('span-' if span else 'legacy-')+mode); work.mkdir()
        sv,exe=work/'tb.sv',work/'test.vvp'
        with sv.open('x') as stream: stream.write(fixture(source,mode))
        argv=['/usr/bin/iverilog','-g2012','-Wall','-s','tb','-DVEN_RAW_V_READ_PRIME',
              '-DVEN_RAW_BRANCH_FALLTHROUGH_PRIME','-DVEN_FAST_XCHG_R',
              *(['-DVEN_IC_RESIDENCY_SPAN'] if span else []),'-o',str(exe),str(sv)]
        with (work/'build.log').open('x') as stream:
            compiled=subprocess.run(argv,stdout=stream,stderr=subprocess.STDOUT,timeout=30)
        assert compiled.returncode==0,(mode,'compile failed')
        with (work/'native.log').open('x') as stream:
            child=subprocess.Popen(['/usr/bin/vvp',str(exe)],stdout=stream,stderr=subprocess.STDOUT)
            try:
                affinity=sorted(os.sched_getaffinity(child.pid)); assert affinity==[18,19,20,21]
                code=child.wait(timeout=60)
            except BaseException: child.kill(); child.wait(); raise
        log=(work/'native.log').read_text()
        positive=code==0 and 'PRIME-WIDTH-OK' in log and 'samples=65536' in log and 'FATAL' not in log
        negative=code==1 and any(marker in log for marker in
                    ('PRIME_WIDTH_MISMATCH','PRIME_WIDTH_STROBE_MISMATCH','MC_ADDRESS_PAYLOAD_MISMATCH'))
        return dict(span=span,mode=mode,passed=positive if mode=='positive' else negative,
                    native_exit=code,compile_exit=compiled.returncode,argv=argv,pid=child.pid,
                    affinity=affinity,waited=True,proc_gone=not Path('/proc',str(child.pid)).exists())
    try:
        with ThreadPoolExecutor(max_workers=4) as pool: rows=list(pool.map(execute,jobs))
    except Exception as exc: errors.append(repr(exc))
    events={k:int(v) for k,v in (line.split() for line in (group/'memory.events').read_text().splitlines())}
    stable=all(sha(p)==h for p,h in pins.items())
    passed=stable and not errors and len(rows)==len(jobs) and all(r['passed'] and r['proc_gone'] for r in rows)
    passed &= not any(events[k] for k in ('oom','oom_kill','oom_group_kill'))
    result=dict(passed=passed,pins_unchanged=stable,rows=rows,errors=errors,memory_events=events,
                memory_peak=int((group/'memory.peak').read_text()),seconds=time.monotonic()-begin,
                derivative_sha256=sha(out/'core_mem_chain.svh'),
                artifacts={str(p):sha(p) for p in out.rglob('*') if p.is_file()},
                whole_core=False,standard_suite=False,physical_fpga=False,gameplay_ipc=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','artifacts')}),flush=True)
    return 0 if passed else 1


if __name__=='__main__': raise SystemExit(main())
