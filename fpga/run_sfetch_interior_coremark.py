"""Two concurrent short cold CRC/cycle controls, never accepted CM/MHz scores."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import textwrap

import build_sfetch_interior_soc as builder
import run_next_ready_coremark as previous
import native_observation

original=previous.original
PARENT=builder.ROOT/'sfetch-boundary-soc-r1'
TICKS={'performance':4771298,'validation':4755366}


def cost(seed,ticks):
    assert isinstance(ticks,int) and ticks==TICKS[seed],'fetch-size cofactor changed CoreMark clocks'
    return dict(parent_ticks=TICKS[seed],added_clocks=0,
                clock_cost_percent=0.0,throughput_gain_percent=0.0)


def once(text,old,new):
    assert text.count(old)==1,old
    return text.replace(old,new)


def derive():
    text=previous.derive()
    for old,new in (
        ('ventium-next-ready-cm10-','ventium-sfetch-interior-cm10-'),
        ('for p in (Path(previous.__file__),original,',
         'for p in (Path(previous.__file__),Path(previous.previous.__file__),original,'),
        ('os.sched_getaffinity(0)=={12}','os.sched_getaffinity(0)=={12,13}'),
        ("results=[];error=None",
         "assert 0<int((cg/'memory.max').read_text())<=2*1024**3\n"
         "assert (cg/'memory.swap.max').read_text().strip()=='0'\n"
         "assert 128<=int((cg/'pids.max').read_text())<=192\nresults=[];error=None"),
        ('child=subprocess.Popen(argv,cwd=work,',
         "child=subprocess.Popen(['/usr/bin/taskset','-c',str(cpu)]+argv,cwd=work,"),
        ("child,model,argv,env['AO486_BIOS_DIR'],12,parse_cmdline)",
         "child,model,argv,env['AO486_BIOS_DIR'],cpu,parse_cmdline)"),
    ):
        text=once(text,old,new)
    first="try:\n    for seed in ('performance','validation'):\n"
    last='except BaseException as exc:\n'
    assert text.count(first)==text.count(last)==1
    a=text.index(first);b=text.index(last)
    body=textwrap.dedent(text[a+len(first):b])
    body=once(body,'results.append(result);','')+'return result\n'
    text=text[:a]+"def run_seed(seed):\n    cpu=12 if seed=='performance' else 13\n"+textwrap.indent(body,'    ')+'''
try:
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(run_seed,('performance','validation')))
'''+text[b:]
    compile(text,__file__,'exec')
    return text


if __name__=='__main__':exec(compile(derive(),__file__,'exec'),globals())
