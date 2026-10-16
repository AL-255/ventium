"""Two concurrent cold CoreMark controls with the retained-input host disabled.

Unchanged CRC/tick expectations and native lifecycle; one actual CPU per seed.
Not full standard seeds, duration-valid scores, gameplay or FPGA acceptance.
"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
from pathlib import Path
import textwrap

import native_observation

ORIGINAL=Path(__file__).with_name('run_v_carry_payload_coremark.py')
SOURCE_SHA='3993be119f225953cc0a94448cd737e898f203ad867fc0358adc6fe71b833a12'
MODEL='0e25af3b6831e0acc44a0f0faba224f66316be2a499127165a66534893983779'
PARENT_MODEL='b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e'
CONTROLLER='9c9d62149a25a5e3f97683ca269b77d01dcf4034517c02a225a5bce0bd2dc405'


def once(text,old,new):
    assert text.count(old)==1,old
    return text.replace(old,new)


def derive():
    assert hashlib.sha256(ORIGINAL.read_bytes()).hexdigest()==SOURCE_SHA
    text=ORIGINAL.read_text()
    first='                deadline=time.monotonic()+3\n'
    last='                rc=child.wait(timeout=600)\n'
    assert text.count(first)==text.count(last)==1
    text=text[:text.index(first)]+'''                observed=native_observation.observe_owned_native(
                    child,model,argv,env['AO486_BIOS_DIR'],cpu,parse_cmdline)
                save(work/'native-observed.json',observed)
                save(work/'native.json',observed)
'''+text[text.index(last):]
    for old,new in (
        ('ventium-v-carry-cm10-','ventium-retained-ui-cm10-'),
        ("root=soc/'coremark';root.mkdir()","root=soc/'coremark-ui-disabled-r1';root.mkdir()"),
        ('os.sched_getaffinity(0)=={11}','os.sched_getaffinity(0)=={12,13}'),
        ("pins=dict(json.loads((soc/'build-started.json').read_text())['pins'])",
         "started=json.loads((soc/'build-started.json').read_text())\n"
         "assert b['native_exit']==0 and b['binary_sha256']==MODEL\n"
         "assert started['parent_model']==PARENT_MODEL and started['controller_sha256']==CONTROLLER\n"
         "assert started['processor_rtl_changes']==[] and started['added_defines']==[]\n"
         "assert started['binding_read_wire']=='kb_fifo_rdreq'\n"
         "assert 'pc_keyboard_retained.h' in started['host_headers']\n"
         "pins=dict(started['pins'])"),
        ("for p in (Path(__file__).resolve(),model,",
         "for p in (ORIGINAL,Path(native_observation.__file__),soc/'build-started.json',Path(__file__).resolve(),model,"),
        ("    core_hz=40000000,cold_reset=True,standard_suite=False,gameplay_ipc=None,score_eligible=False))",
         "    core_hz=40000000,cold_reset=True,ui_disabled=True,standard_suite=False,gameplay_ipc=None,score_eligible=False))"),
        ("results=[];error=None",
         "assert 0<int((cg/'memory.max').read_text())<=2*1024**3\n"
         "assert (cg/'memory.swap.max').read_text().strip()=='0'\n"
         "assert 128<=int((cg/'pids.max').read_text())<=192\n"
         "results=[];error=None"),
        ('child=subprocess.Popen(argv,cwd=work,',
         "child=subprocess.Popen(['/usr/bin/taskset','-c',str(cpu)]+argv,cwd=work,"),
        ("        text=(work/'run.log').read_text()",
         "        text=(work/'run.log').read_text()\n"
         "        assert '[UI-' not in text and '--ui-fifo' not in argv"),
        ("'V carry payload cofactor changed benchmark clocks'",
         "'retained-input controller changed short kernel clocks'"),
    ):
        text=once(text,old,new)
    first="try:\n    for seed in ('performance','validation'):\n"
    last='except BaseException as exc:\n'
    assert text.count(first)==text.count(last)==1
    a=text.index(first);b=text.index(last)
    body=textwrap.dedent(text[a+len(first):b])
    body=once(body,'results.append(result);','')
    body+='return result\n'
    text=text[:a]+"def run_seed(seed):\n    cpu=12 if seed=='performance' else 13\n"+textwrap.indent(body,'    ')+'''
try:
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(run_seed,('performance','validation')))
'''+text[b:]
    compile(text,__file__,'exec')
    return text


if __name__=='__main__':exec(compile(derive(),__file__,'exec'),globals())
