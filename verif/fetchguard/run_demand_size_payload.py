"""Exercise actual old/new demand-width RTL with both demand-fetch profiles.

This is a combinational payload microgate, not whole-core/fault qualification.
The old guarded expression is also a required negative control for payload
independence; it is not labelled an architectural error.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time
import traceback

import prepare_demand_size_payload as recipe

MODES = ('positive', 'widen', 'drop-clip', 'late-control')
CASES = 32*32*32*7
CLIP = '''      if ((sfetch_demand_addr[11:0] > 12'hffc) &&
          (sfetch_demand_size > 3'(13'h1000 - {1'b0,sfetch_demand_addr[11:0]})))
        sfetch_demand_size = 3'(13'h1000 - {1'b0,sfetch_demand_addr[11:0]});'''


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def function(text, name):
    body = text.split('  always_comb begin\n', 1)[1]
    assert body.endswith('  end\n')
    return ('  function automatic [2:0] '+name+'();\n    logic [2:0] sfetch_demand_size;\n'
            +body[:-len('  end\n')]+'    return sfetch_demand_size;\n  endfunction\n')


def fixture(source, mode):
    old = recipe.block(source)
    new = old.replace(recipe.OLD, recipe.NEW)
    assert old.count(CLIP) == new.count(CLIP) == 1
    if mode == 'widen':
        expression = "(d_fetch_need - sfetch_valid_q >= 5'd4)\n                        ? 3'd4 : 3'(d_fetch_need - sfetch_valid_q)"
        assert new.count(expression) == 1
        new = new.replace(expression, "3'd4")
    elif mode == 'drop-clip':
        new = new.replace(CLIP, '')
    elif mode == 'late-control':
        new = old
    else:
        assert mode == 'positive'
    request = source[source.index('  assign sfetch_demand_req = '):]
    request = request[:request.index(';')+1]
    result = '''`timescale 1ns/1ps
module tb;
  localparam S_FETCH=0;
  logic state, sfetch_boundary, sfetch_early_nm, sfetch_early_gp;
  logic sfetch_interior16, sfetch_demand_req;
  logic [4:0] d_fetch_need, sfetch_valid_q;
  logic [31:0] sfetch_demand_addr;
  logic [2:0] a,b;
  integer checks=0, beats=0, idle_changes=0, clipped=0;
  integer expected_width, remaining, difference;
'''+request+'\n'+function(old,'reference_size')+function(new,'candidate_size')+'''
  initial begin
    for(integer valid=0;valid<32;valid++)
    for(integer need=0;need<32;need++)
    for(integer control=0;control<32;control++)
    for(integer offset=0;offset<7;offset++) begin
      sfetch_valid_q=5'(valid); d_fetch_need=5'(need);
      {state,sfetch_boundary,sfetch_early_nm,sfetch_early_gp}=4'(control);
      sfetch_interior16=control[4] && state==S_FETCH && sfetch_boundary;
      case(offset)
        0:sfetch_demand_addr=32'hffffffff;
        1:sfetch_demand_addr=32'h00000ffe;
        2:sfetch_demand_addr=32'h12345ffd;
        3:sfetch_demand_addr=32'h00000ffc;
        4:sfetch_demand_addr=32'habcdeffb;
        5:sfetch_demand_addr=32'h00000001;
        6:sfetch_demand_addr=32'h00000000;
      endcase
      #1; a=reference_size(); b=candidate_size(); checks++;
      // Independent integer equation; include inactive unsigned underflow.
      difference=(need-valid)&31;
      expected_width=(difference>=4)?4:difference;
`ifdef VEN_SFETCH16_DEMAND
      if(sfetch_interior16) expected_width=4;
`endif
      remaining=4096-int'(sfetch_demand_addr[11:0]);
      if(expected_width>remaining) expected_width=remaining;
      if(sfetch_demand_req) begin
        beats++;
        if(a!==b || b<1 || b>4 || int'(b)>remaining)
          $fatal(1,"DEMAND-SIZE-MISMATCH issued parent=%d candidate=%d need=%d valid=%d",a,b,need,valid);
      end
      if(b!==3'(expected_width))
        $fatal(1,"DEMAND-SIZE-PAYLOAD-DEPENDENCE expected=%d actual=%d req=%b",expected_width,b,sfetch_demand_req);
      if(a!=b) begin
        if(sfetch_demand_req) $fatal(1,"DEMAND-SIZE-MISMATCH active difference");
        idle_changes++;
      end
      if(sfetch_demand_req && remaining<4 && int'(b)==remaining) clipped++;
    end
    if(!beats || !idle_changes || !clipped) $fatal(1,"DEMAND-SIZE-COVERAGE");
    $display("DEMAND-SIZE-OK checks=%0d beats=%0d idle=%0d clipped=%0d",checks,beats,idle_changes,clipped);
    $finish;
  end
endmodule
'''
    if mode in ('widen', 'drop-clip'):
        # These must be rejected on a real issued byte extent, not just an
        # intentionally unconstrained inactive-payload difference.
        result = result.replace("if(b!==3'(expected_width))",
                                "if(sfetch_demand_req && b!==3'(expected_width))")
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'out'):
        ap.add_argument('--'+name, type=Path, required=True)
    args = ap.parse_args()
    source, out = args.parent.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and os.sched_getaffinity(0) == {13}
    assert shutil.disk_usage(scratch).free > 5*1024**3 and os.environ['INVOCATION_ID']
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    subprocess.run([Path(__file__).resolve().parents[2]/'tools/build_scope.sh', '--is-active'],
                   check=True, pass_fds=(9,))
    unit = os.environ['VENTIUM_BUILD_SCOPE_UNIT']+'.scope'
    assert unit == 'ventium-demand-size-leaf-oct15-r1.scope'
    subprocess.run(['systemctl','--user','set-property','--runtime',unit,
                    'MemoryMax=512M','MemorySwapMax=0','TasksMax=64'], check=True)
    group = Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().strip().split('::',1)[1].lstrip('/')
    limits = {n:(group/n).read_text().strip() for n in ('memory.max','memory.swap.max','pids.max')}
    assert limits == {'memory.max':str(512*1024**2),'memory.swap.max':'0','pids.max':'64'}
    original = (source/recipe.FILE).read_text()
    changed = recipe.transform(original)
    pins = {str(p.resolve()):sha(p) for p in (source/recipe.FILE, Path(__file__),
            Path(recipe.__file__), *(Path(shutil.which(n)) for n in ('iverilog','vvp')))}
    out.mkdir()
    def save(name, value):
        with (out/name).open('x') as f:
            json.dump(value, f, indent=2)
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'], cpu=13,
                             cgroup=str(group), limits=limits))
    (out/'core.sv').write_text(changed)
    rows, errors, start = [], [], time.monotonic()
    try:
        for profile in (False, True):
            for mode in MODES:
                name = str(int(profile))+'-'+mode
                sv, binary = out/(name+'.sv'), out/(name+'.vvp')
                sv.write_text(fixture(original, mode))
                command = ['iverilog','-g2012','-s','tb','-o',str(binary),str(sv)]
                if profile:
                    command.insert(1, '-DVEN_SFETCH16_DEMAND')
                results = {}
                for label, cmd in (('compile',command),('native',['vvp',str(binary)])):
                    child = subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                             text=True,start_new_session=True)
                    try:
                        affinity = sorted(os.sched_getaffinity(child.pid))
                        assert affinity == [13]
                        stdout, stderr = child.communicate(timeout=90)
                    except BaseException:
                        if child.poll() is None:
                            os.killpg(child.pid,signal.SIGKILL)
                        child.wait()
                        raise
                    run = subprocess.CompletedProcess(cmd,child.returncode,stdout,stderr)
                    log = out/(name+'.'+label+'.log')
                    log.write_text(run.stdout+run.stderr)
                    results[label] = dict(command=cmd, native_exit=run.returncode,
                                         actual_wait=True, affinity=affinity, pid=child.pid,
                                         log_sha256=sha(log))
                    if label == 'compile':
                        assert run.returncode == 0, run.stderr
                    elif mode == 'positive':
                        m = re.search(r'DEMAND-SIZE-OK checks=(\d+) beats=(\d+) idle=(\d+) clipped=(\d+)',run.stdout)
                        assert run.returncode == 0 and m
                        coverage = dict(zip(('checks','beats','idle','clipped'),map(int,m.groups())))
                        assert coverage['checks'] == CASES and all(coverage.values())
                        results[label]['coverage'] = coverage
                    else:
                        marker = ('DEMAND-SIZE-PAYLOAD-DEPENDENCE' if mode == 'late-control'
                                  else 'DEMAND-SIZE-MISMATCH')
                        assert run.returncode == 1 and marker in run.stdout
                rows.append(dict(profile=profile,mode=mode,results=results))
    except Exception as error:
        errors.append(dict(error=repr(error),traceback=traceback.format_exc()))
    stable = all(sha(p)==h for p,h in pins.items())
    events = dict(line.split() for line in (group/'memory.events').read_text().splitlines())
    no_oom = all(events[k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    result = dict(passed=stable and len(rows)==8 and not errors and no_oom, rows=rows, errors=errors,
        pins_unchanged=stable, seconds=time.monotonic()-start, whole_core=False, gameplay_ipc=None,
        memory_events=events, memory_peak=int((group/'memory.peak').read_text()),
        artifacts={str(p):sha(p) for p in out.iterdir() if p.is_file()})
    save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','artifacts')}),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
