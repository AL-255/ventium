"""Bounded native proofs for parallel write admission, not core acceptance.

The equation stage enumerates arbitrary binary controls (no credit assumption)
and real address/strobe boundary vectors. Integration reuses the complete cache
miter, wrapper/reset/shutdown and AXI-fault fixtures, unchanged in stimulus.
"""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time
import traceback

import prepare_parallel_write_admission as recipe
import run_qualified_pair_credit_cache as cache
import run_qualified_pair_credit_wrapper as wrapper
import run_qualified_pair_credit_corners as corners
import run_qualified_pair_credit_faults as faults
from run_parallel_tag_cache import archive_products, control_source, sha

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent


def control_fixture(old, mutant='none'):
    early = recipe.admission(recipe.enqueue(old))
    early = early[early.index('    (* keep'):early.index('`ifndef SYNTHESIS')]
    early = early.replace('pair_write_alias_bad', 'v_bad').replace('write_alias_bad', 'u_bad')
    if mutant != 'none':
        before, after = {
            'u_alias': ('!u_bad', "1'b1"),
            'v_alias': ('!v_bad', "1'b1"),
            'fatal': ('!fatal_now', "1'b1"),
            'credit': ("((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release)", "1'b1"),
            'request': ('m_req && m_we &&', 'm_we &&'),
            'pair_credit': ('(wr_can_pair', "(1'b1"),
        }[mutant]
        assert before in early
        early = early.replace(before, after)
    early = early.replace('wr_enq =', 'new_enq =')
    original = recipe.enqueue(old).replace('wr_enq ', 'old_enq ')
    return '''module tb;
  localparam integer WBUF_CNTW=2, P5_WBUF_DEPTH=2;
  localparam bit R_IDLE=0;
  reg [1:0] wq_count;
  reg rst, m_req, m_we, m_pair_req, shutdown, m_idle, fatal_now;
  reg u_bad,v_bad,wq_head_release,pair_quad_ok,rd_deliver;
  wire alias_bad=m_req && (u_bad || (m_we && m_pair_req && v_bad));
  wire wr_can_pair=(wq_count==0) || ((wq_count==1) && wq_head_release);
  wire old_enq,new_enq;
  wire old_ack=!fatal_now && (rd_deliver || old_enq || (shutdown && m_idle && m_req));
  wire new_ack=!fatal_now && (rd_deliver || new_enq || (shutdown && m_idle && m_req));
  wire old_pair_ack=!fatal_now && ((old_enq && m_pair_req) ||
                                  (shutdown && m_idle && m_req && m_we && m_pair_req));
  wire new_pair_ack=!fatal_now && ((new_enq && m_pair_req) ||
                                  (shutdown && m_idle && m_req && m_we && m_pair_req));
'''+original+'\n'+early+'''
  integer total=0;
  initial begin
    for(integer count=0;count<4;count++)
      for(integer rs=0;rs<2;rs++)
        for(integer bits=0;bits<2048;bits++) begin
          wq_count=2'(count);rst=1'(rs);
          {m_req,m_we,m_pair_req,shutdown,m_idle,fatal_now,u_bad,v_bad,
           wq_head_release,pair_quad_ok,rd_deliver}=11'(bits);
          #1;total++;
          if ({new_enq,new_ack,new_pair_ack} !== {old_enq,old_ack,old_pair_ack})
            $fatal(1,"PARALLEL-WRITE-EQUATION-MISMATCH count=%0d rst=%0d bits=%0d",count,rs,bits);
        end
    if(total!=16384) $fatal(1,"equation coverage");
    $display("PARALLEL-WRITE-EQUATION-OK checked=%0d excluded=0",total);
    $finish;
  end
endmodule
'''


def extent_fixture(old):
    first = old.index('  logic [7:0]  alias_ssh;')
    last = old.index('  always_ff @(posedge core_clk', first)
    aliases = old[first:last]
    early = recipe.admission(recipe.enqueue(old))
    early = early[early.index('    logic [31:0] write_alias_last;'):early.index('    // Preserve these two')]
    return '''module tb;
  reg [31:0] ADDR_MASK,m_addr,m_pair_addr;
  reg [3:0] m_wstrb,m_pair_wstrb;
  reg m_req,m_we,m_pair_req,m_rd_narrow;
  reg [1:0] m_rd_size;
'''+aliases+early+'''
  function automatic [31:0] addr(input integer n);
    case(n/4)
      0:addr=32'h00000000+32'(n%4);
      1:addr=32'h0000fffc+32'(n%4);
      2:addr=32'h00010000+32'(n%4);
      3:addr=32'h0ffffffc+32'(n%4);
      4:addr=32'h10000000+32'(n%4);
      5:addr=32'hfffdfffc+32'(n%4);
      6:addr=32'hfffe0000+32'(n%4);
      7:addr=32'hfffffffc+32'(n%4);
      8:addr=32'h0000000c+32'(n%4);
      default:addr=32'h80000000+32'(n%4);
    endcase
  endfunction
  integer total=0;
  initial begin
    for(integer mask=0;mask<6;mask++) begin
      case(mask)
        0:ADDR_MASK=32'hffffffff;
        1:ADDR_MASK=32'h0fffffff;
        2:ADDR_MASK=32'h0000ffff;
        3:ADDR_MASK=32'h00000000;
        4:ADDR_MASK=32'hffffffed;
        5:ADDR_MASK=32'h7fffffff;
      endcase
      for(integer a=0;a<40;a++)
        for(integer b=0;b<40;b++)
          for(integer s=0;s<16;s++)
            for(integer k=0;k<8;k++) begin
              m_addr=addr(a);m_pair_addr=addr(b);
              m_wstrb=4'(s);m_pair_wstrb=4'(15-s);
              m_req=1;m_we=1;m_pair_req=1'(k);
              m_rd_narrow=1'(k>>1);m_rd_size=2'(k>>1);
              #1;total++;
              if(alias_bad !== (write_alias_bad || (m_pair_req && pair_write_alias_bad)))
                $fatal(1,"PARALLEL-WRITE-EXTENT-MISMATCH mask=%08h u=%08h v=%08h s=%x k=%0d",
                       ADDR_MASK,m_addr,m_pair_addr,s,k);
            end
    end
    if(total!=1228800) $fatal(1,"extent coverage");
    $display("PARALLEL-WRITE-EXTENT-OK checked=%0d",total);$finish;
  end
endmodule
'''


def cache_fixture():
    return recipe.once(cache.fixture(), 'PAIR_REQ_CREDIT_QUALIFIED', 'PARALLEL_WRITE_ADMISSION')


def fault_fixture(source, candidate):
    text = faults.fixture(source, False)
    if candidate:
        text = text.replace('ven_axi_master #(', "ven_axi_master #(.PARALLEL_WRITE_ADMISSION(1'b1),")
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'out'):
        ap.add_argument('--'+name, type=Path, required=True)
    ap.add_argument('--stage', choices=('leaf','cache','wrapper','corners','faults'), required=True)
    ap.add_argument('--proof', type=Path)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent, out = args.parent.resolve(strict=True), args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert out.is_relative_to(scratch) and not out.exists()
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode == 1
    if args.stage != 'leaf':
        subprocess.run([REPO/'tools/build_scope.sh','--is-active'], pass_fds=(9,), check=True)
    resource.setrlimit(resource.RLIMIT_CORE, (0,0))
    mem = parent/'ventium/rtl/mem'
    original = {name:(mem/name).read_text() for name in recipe.PINS}
    changed = recipe.transform(original)
    manifest = parent/'input-manifest.json'
    hardware = json.loads(manifest.read_text())['hardware_defines']
    assert len(hardware) == 159 and hardware.count('SYNTHESIS') == 1
    defines = [flag for flag in hardware if flag != 'SYNTHESIS']
    assert 'VEN_AXI_CDC' not in defines
    pins = {}
    if args.stage != 'leaf':
        assert args.proof is not None
        proof = args.proof.resolve(strict=True)
        previous = json.loads((proof/'closed.json').read_text())
        assert previous['passed'] and previous['pins_unchanged']
        assert previous['stage'] == ('leaf' if args.stage == 'cache' else 'cache')
        pins.update(previous['pins'])
        for row in previous['rows']: pins.update(row['artifacts'])
        pins[str(proof/'closed.json')] = sha(proof/'closed.json')
        assert all(sha(path)==value for path,value in pins.items())
        assert all((proof/name).read_text() == text for name,text in changed.items())
    out.mkdir()
    def save(name, data):
        with (out/name).open('x') as stream: json.dump(data, stream, indent=2)
    def source(name, text):
        path = out/name
        with path.open('x') as stream: stream.write(text)
        pins[str(path)] = sha(path)
        return path
    for name,text in changed.items(): source(name,text)
    # Freeze every local imported driver/helper rather than just the top-level.
    local_modules = ('prepare_parallel_write_admission.py','prepare_qualified_pair_credit.py',
        'run_parallel_write_admission.py','run_qualified_pair_credit_cache.py',
        'run_qualified_pair_credit_wrapper.py','run_qualified_pair_credit_corners.py',
        'run_qualified_pair_credit_faults.py','run_backing_pair_payload_axi.py',
        'prepare_backing_pair_payload.py','test_backing_pair_payload.py',
        'run_parallel_tag_cache.py','prepare_parallel_tag_lookup.py')
    for name in local_modules:
        path = HERE/name; pins[str(path)] = sha(path); source('observed-'+name,path.read_text())
    for path in (manifest, *(mem/name for name in recipe.PINS),
                 REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh'):
        pins[str(path)] = sha(path)
    for name in ('tb_l1d_mem_chain.sv','backing_pair_axi_leaf.svh','tb_l1axi_pair_hit.sv',
                 'qualified_pair_credit_wrapper.svh','qualified_pair_credit_corners.svh',
                 'axi_slave_bfm.sv',*(top+'.sv' for _,top,_,_ in faults.CASES)):
        pins[str(HERE/name)] = sha(HERE/name)
    save('started.json', dict(stage=args.stage,pins=pins,defines=defines,hardware_defines=hardware,
                             invocation=os.environ.get('INVOCATION_ID'),affinity=sorted(os.sched_getaffinity(0))))
    result = dict(stage=args.stage,passed=False,rows=[],errors=[],whole_core=False,
                  standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    start = time.monotonic()
    def run(label, top, text, modules, extra=(), marker='', expected_failure=False, leaf=False):
        assert shutil.disk_usage(scratch).free > 4*1024**3
        folder = out/label; folder.mkdir()
        bench = source(label+'/'+top+'.sv',text)
        for path in modules: pins[str(path)] = sha(path)
        if leaf:
            binary = folder/'test.vvp'
            command = ['/usr/bin/iverilog','-g2012','-s',top,'-o',str(binary),
                       *['-D'+flag for flag in extra],str(bench)]
        else:
            binary = folder/'obj/test'
            command = [str(REPO/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv',
                '-j','32','--output-split','20000','--output-split-cfuncs','2000','-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+flag for flag in (*defines,*extra)],'-I'+str(out),
                '--top-module',top,'--Mdir',str(folder/'obj'),'-o','test',*map(str,modules),str(bench)]
        row = dict(label=label,command=command,expected_failure=expected_failure)
        result['rows'].append(row)
        with (folder/'build.log').open('x') as stream:
            build = subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=180,
                                   env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=() if leaf else (9,))
        row['build_exit'] = build.returncode
        assert build.returncode == 0, ('build failed',label)
        argv = ['taskset','-c','8',*(['/usr/bin/vvp'] if leaf else []),str(binary)]
        row['native_command'] = argv
        with (folder/'run.log').open('x') as stream:
            proc = subprocess.Popen(argv,stdout=stream,stderr=subprocess.STDOUT)
            row['pid'] = proc.pid
            try:
                # taskset may not have executed yet; observe until actual confinement.
                deadline = time.monotonic()+2
                while os.sched_getaffinity(proc.pid) != {8} and time.monotonic()<deadline:
                    time.sleep(.001)
                row['native_affinity'] = sorted(os.sched_getaffinity(proc.pid))
                assert row['native_affinity'] == [8]
                row['native_exit'] = proc.wait(timeout=40)
            finally:
                if proc.poll() is None: proc.kill();proc.wait()
        log = (folder/'run.log').read_text(); row['log'] = log
        row['artifacts'] = {str(path):sha(path) for path in (bench,binary,folder/'build.log',folder/'run.log')}
        if expected_failure:
            assert row['native_exit'] in (1,-6,134) and marker in log, (label,log)
        else:
            assert row['native_exit'] == 0 and marker in log, (label,log)
            assert not re.search(r'\bFAIL\b|%Fatal|%Error|FATAL:',log), (label,log)
        if not leaf: row['compiler_archive'] = archive_products(folder,top)
        save(label+'/closed.json',row)
        print(label,log.strip()[-800:],flush=True)
    try:
        if args.stage == 'leaf':
            for quad in (False,True):
                extra = ('VEN_P54_WBUF_QUAD_COMBINE',) if quad else ()
                run('controls-quad'+str(int(quad)),'tb',control_fixture(original['ven_axi_master.sv']),[],extra,
                    'PARALLEL-WRITE-EQUATION-OK checked=16384 excluded=0',leaf=True)
            run('extents','tb',extent_fixture(original['ven_axi_master.sv']),[],('VEN_P54_DUAL_STORE_PAIR',),
                'PARALLEL-WRITE-EXTENT-OK checked=1228800',leaf=True)
            for mutant in ('u_alias','v_alias','fatal','credit','request','pair_credit'):
                run('mutant-'+mutant,'tb',control_fixture(original['ven_axi_master.sv'],mutant),[],
                    ('VEN_P54_WBUF_QUAD_COMBINE',),'PARALLEL-WRITE-EQUATION-MISMATCH',True,True)
        elif args.stage == 'cache':
            source('control_l1d.sv',control_source(original['ven_l1d.sv']))
            leaf = recipe.once((HERE/'backing_pair_axi_leaf.svh').read_text(),
                              'idle_credit_changes==0 || full_queue==0','idle_credit_changes!=0 || full_queue==0')
            source('qualified_pair_credit_cache_leaf.svh',leaf)
            modules = [mem/name for name in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
            modules += [out/'ven_axi_master.sv',HERE/'axi_slave_bfm.sv',out/'control_l1d.sv',mem/'ven_l1d.sv']
            run('miter','tb_l1d_mem_chain',cache_fixture(),modules,marker='BACKING-AXI-OK')
            assert 'PARALLEL-CACHE-MITER' in result['rows'][0]['log']
        elif args.stage in ('wrapper','corners'):
            top = 'tb_qualified_pair_wrapper'
            stem = 'qualified_pair_credit_'+args.stage
            source(stem+'.svh',corners.leaf() if args.stage=='corners' else (HERE/(stem+'.svh')).read_text())
            text = corners.fixture() if args.stage=='corners' else wrapper.fixture()
            common = [mem/name for name in ('ven_cdc_afifo.sv','ven_reset_sync.sv','ven_axi_cdc.sv',
                      'ven_p54_bank_arb.sv','ven_p54_hit_return.sv','ven_l1d.sv')]
            common += [parent/'ventium/rtl/northbridge/ven_cachemap.sv',HERE/'axi_slave_bfm.sv']
            extra = ('AXI_BFM_MON','VEN_AXI_RESP_FAULT_INJECT') if args.stage=='corners' else ('AXI_BFM_MON',)
            marker = 'PAIR-CREDIT-'+args.stage.upper()+'-OK'
            for candidate in (False,True):
                src = out if candidate else mem
                run('candidate' if candidate else 'parent',top,text,
                    common+[src/'ven_axi_master.sv',src/'ventium_l1_axi.sv'],extra,marker)
            coverage = [next(line for line in row['log'].splitlines() if line.startswith(marker)) for row in result['rows']]
            assert coverage[0] == coverage[1]
        else:
            for label,top,extra,marker in faults.CASES:
                for candidate in (False,True):
                    src = out if candidate else mem
                    # Unlike qualified-credit, the new branch MUST handle the
                    # raw held, uncredited split-pair fixture with opt-in on.
                    run(label+('-candidate' if candidate else '-parent'),top,
                        fault_fixture((HERE/(top+'.sv')).read_text(),candidate),
                        [src/'ven_axi_master.sv'],extra,marker)
        result['passed'] = True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start,pins=pins,
                  pins_unchanged=all(sha(path)==value for path,value in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
