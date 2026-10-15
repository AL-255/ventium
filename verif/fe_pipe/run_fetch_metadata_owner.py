"""Exercise the extracted core wiring, all semantic outputs and metadata owner.

The decoder implementation is unchanged. Actual parent/candidate wiring is
extracted; an independent buffered decoder checks metadata even in inactive
states. Two bad connection variants must fail without comparison masks.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import time

import prepare_fetch_metadata_owner as recipe
from run_prefix_opcode import PACKAGES

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fixture(core, decoder):
    header = decoder[:decoder.index('\n);')]
    ports = re.findall(r'^\s*(input|output)\s+(.+?)\s+(\w+)(\s*\[[^\]]+\])?\s*,?\s*(?://.*)?$', header, re.M)
    assert len(ports) == len(re.findall(r'^\s*(?:input|output)\s+', header, re.M))
    assert len({p[2] for p in ports}) == len(ports)
    imports = header[header.index('  import '):header.index('\n(')]
    aliases = dict(gpr='gpr_o', ibuf_valid='refdecode_valid')
    defs = [f'{d} {t} {aliases.get(n,n)}{a}' for d,t,n,a in ports]
    extra = ['input logic [1:0] state', 'input logic [7:0] ic_front_bytes [16]',
             'input logic [7:0] ic_prefix_bytes [16]', 'input logic clk, rst_n']
    body = recipe.region(recipe.transform(core))
    # Core assertions intentionally run only with a clock. The combinational
    # leaf checks all outputs directly; the full-core build exercises assertions.
    variants = {'parent':recipe.region(core), 'candidate':body,
        'bad_live':body.replace('decode_stages u_fetch_metadata (\n',
                               'decode_stages u_fetch_metadata (\n').replace(
            '    .ibuf          (ibuf),\n    .ibuf_valid',
            '    .ibuf          (refdecode_ibuf),\n    .ibuf_valid'),
        'bad_valid':body.replace('    .ibuf_valid    (refdecode_valid),',
                                '    .ibuf_valid    (5\'d16),')}
    out = []
    for label, text in variants.items():
        assert text != body if label.startswith('bad_') else True
        out += [f'module owner_{label}', imports, '(\n'+',\n'.join(defs+extra)+'\n);',
                "localparam S_FETCH=2'd0, S_DECODE=2'd1, S_PIPE=2'd2, S_EXEC=2'd3;",
                'localparam IWORDS=4;', text, 'endmodule']
    out += ['module tb_fetch_metadata_owner;', imports, 'logic [1:0] state;',
            'logic [7:0] ic_front_bytes[16], ic_prefix_bytes[16];',
            "logic clk=0, rst_n=0;", 'integer checks=0, mutant=0, inactive_differences=0;']
    for direction, typ, name, array in ports:
        for prefix in ('',) if direction=='input' else ('p_','f_','b_','v_','e_'):
            out.append(f'{typ} {prefix}{aliases.get(name,name)}{array};')
    for label,prefix in (('parent','p_'),('candidate','f_'),('bad_live','b_'),('bad_valid','v_')):
        conns = [f'.{aliases.get(n,n)}({("" if d=="input" else prefix)+aliases.get(n,n)})' for d,_,n,_ in ports]
        conns += [f'.{n}({n})' for n in ('state','ic_front_bytes','ic_prefix_bytes','clk','rst_n')]
        out.append(f'owner_{label} {label}(\n'+',\n'.join(conns)+');')
    conns = [f'.{n}({("" if d=="input" else "e_")+aliases.get(n,n)})' for d,_,n,_ in ports]
    out.append('decode_stages buffered_reference(\n'+',\n'.join(conns)+');')
    out.append('task automatic check_outputs();')
    for direction, _, name, _ in ports:
        if direction != 'output': continue
        expected = 'e_' if name in recipe.FIELDS else 'p_'
        out.append(f'if ({expected}{name} !== ((mutant==1)?b_{name}:((mutant==2)?v_{name}:f_{name}))) '
                   f'$fatal(1,"FETCH-METADATA-MISMATCH {name} state=%0d valid=%0d checks=%0d mutant=%0d",'
                   'state,refdecode_valid,checks,mutant);')
        if name in recipe.FIELDS:
            out.append(f'if (state<2 && p_{name} !== f_{name}) $fatal(1,"FETCH-METADATA-CONSUMER {name}");')
    out.append('if (state>=2 && p_d_fetch_need != f_d_fetch_need) inactive_differences++;\nendtask')
    out.append('''
logic [31:0] rng=32'h513a728d;
function automatic logic [31:0] rnd();
  rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5); return rng;
endfunction
initial begin
  if ($value$plusargs("mutant=%d",mutant)) begin end
  for (int n=0;n<524288;n++) begin
    for (int i=0;i<16;i++) begin
      ibuf[i]=8'(rnd()); ic_front_bytes[i]=8'(rnd()); ic_prefix_bytes[i]=8'(rnd());
    end
    for (int i=0;i<NUM_GPR;i++) gpr_o[i]=rnd();
    eflags=rnd(); {sys_mode,def16,seg_real,smm_active,paging_on,cosim_en,soc_en}=7'(rnd());
    // Exhaust every opcode/ModR/M pair, rotating owner/valid count, with a
    // second half containing two-byte opcodes and arbitrary SIB/immediates.
    if (n<262144) begin ibuf[0]=8'(n>>8); ibuf[1]=8'(n); end
    else begin ibuf[0]=8'h0f; ibuf[1]=8'(n>>8); ibuf[2]=8'(n); end
    state=2'(n>>16); refdecode_valid=5'((n>>8)^n);
    #1; check_outputs(); checks++;
  end
  if (inactive_differences==0) $fatal(1,"no live/buffered separation exercised");
  $display("FETCH-METADATA-OK checks=%0d inactive_differences=%0d mutant=%0d",checks,inactive_differences,mutant);
  $finish;
end
endmodule
''')
    return '\n'.join(out), len([p for p in ports if p[0]=='output'])


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','out'): ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args(); root=a.out.resolve(); parent=a.parent.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.sched_getaffinity(0)=={14}
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    subprocess.run([REPO/'tools/verilator_serial.sh','--version'],check=True,timeout=10)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    source=parent/'candidate'; core=(source/recipe.FILE).read_text()
    decoder=source/'rtl/core/decode_stages.sv'; assert sha(decoder)==recipe.DECODER
    generated,outputs=fixture(core,decoder.read_text())
    definitions=json.loads((parent/'prepared.json').read_text())['definitions']
    assert len(set(definitions))==len(definitions)==152
    assert {'VEN_PIPE_SDISPATCH','VEN_IC_BRAM','VEN_IC_PREFIX_SPAN','VEN_P54_PREFIX_EX_CHAIN'}<=set(definitions)
    pins={str(p.resolve()):sha(p) for p in [source/n for n in (*PACKAGES,recipe.FILE)]+[
        decoder,parent/'prepared.json',Path(__file__),Path(recipe.__file__),HERE/'run_prefix_opcode.py',
        HERE/'test_fetch_metadata_owner.py',REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',
        Path(os.environ['VENTIUM_VERILATOR_BIN'])]}
    root.mkdir()
    def save(path,text):
        with path.open('x') as f:f.write(text)
        return path
    def emit(name,text):
        p=save(root/name,text);pins[str(p)]=sha(p);return p
    sources=[emit(Path(n).name,(source/n).read_text()) for n in PACKAGES]
    enum=re.findall(r'typedef enum logic \[4:0\] \{.*?\} sysop_e;',core,re.S);assert len(enum)==1
    sources += [emit('sysop_type.sv',enum[0]),emit('decode_stages.sv',decoder.read_text()),
                emit('tb_fetch_metadata_owner.sv',generated)]
    emit('core.sv',recipe.transform(core))
    result=dict(passed=False,errors=[],native=[],pins=pins,outputs=outputs,definitions=definitions,
        invocation=os.environ['INVOCATION_ID'],scope=os.environ['VENTIUM_BUILD_SCOPE_UNIT'],
        gameplay_ipc=None,fmax_mhz=None,standard_suite=False,hardware_acceptance=False)
    save(root/'started.json',json.dumps(result,indent=2)+'\n'); began=time.monotonic()
    def run(cmd,name,limit):
        start=time.monotonic();path=root/name
        with path.open('x') as log:
            proc=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT,pass_fds=(9,),start_new_session=True)
            assert os.sched_getaffinity(proc.pid)=={14}
            try:
                while proc.poll() is None:
                    assert shutil.disk_usage(scratch).free>4*1024**3
                    assert time.monotonic()-began<580 and time.monotonic()-start<limit
                    time.sleep(.2)
                code=proc.wait()
            except BaseException:
                os.killpg(proc.pid,signal.SIGKILL);proc.wait();raise
        result['native'].append(dict(command=list(map(str,cmd)),exit=code,seconds=time.monotonic()-start,
            affinity=[14],actual_wait=True,reaped=True,log=str(path),sha256=sha(path)))
        return code,path.read_text()
    try:
        cmd=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv','-j','1','--threads','1',
            '-Wall','-Wno-UNUSED','-Wno-fatal',*['-Werror-'+w for w in
            ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
            *['+define+'+d for d in definitions],'--top-module','tb_fetch_metadata_owner',
            '--Mdir',root/'obj','-o','test',*sources]
        code,_=run(cmd,'build.log',240);assert code==0,'build.log'
        model=root/'obj/test';result['model_sha256']=sha(model)
        code,log=run([model],'run.log',200)
        assert code==0 and 'FETCH-METADATA-OK checks=524288 ' in log,'run.log'
        for mutant in (1,2):
            code,log=run([model,f'+mutant={mutant}'],f'mutant-{mutant}.log',30)
            assert code in (-6,1,134) and 'FETCH-METADATA-MISMATCH' in log
        result['passed']=True
    except Exception as exc:result['errors'].append(repr(exc))
    cg=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    events=dict(s.split() for s in (cg/'memory.events').read_text().splitlines())
    result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-began,
                  memory_events=events,memory_peak=int((cg/'memory.peak').read_text()))
    result['passed'] &= result['pins_unchanged'] and all(events[k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    save(root/'closed.json',json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','native','definitions')},indent=2))
    return int(not result['passed'])


if __name__=='__main__':raise SystemExit(main())
