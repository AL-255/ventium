#!/usr/bin/env python3
"""Check full architectural state and actual prefix/pair spacing; no score."""
import json
import pathlib
import sys

out, case = pathlib.Path(sys.argv[1]), int(sys.argv[2])
symbols = {p[2]: int(p[0], 16) for line in (out / 'test.sym').read_text().splitlines()
           if len(p := line.split()) == 3}
keys = ('eax','ebx','ecx','edx','esi','edi','esp','ebp',
        'eflags','cs','ss','ds','es','fs','gs')
def rows(mode):
    return [r for line in (out/f'test.{mode}.vtrace').read_text().splitlines()
            if 'pc' in (r := json.loads(line))]
gold, cycle, state = [rows(mode) for mode in ('qemu','cycle','cycle-func')]
for trace in (cycle,state):
    assert len(trace)==len(gold)+1, ('incomplete fixture',len(trace),len(gold))
    assert int(trace[-1]['pc'],0)==symbols['exit_syscall']
    trace.pop()
assert [r['pc'] for r in gold]==[r['pc'] for r in cycle]==[r['pc'] for r in state]
for i in range(len(gold)):
    if i+1<len(gold) and cycle[i]['cyc']==cycle[i+1]['cyc']:
        continue
    for key in keys:
        assert gold[i][key]==state[i][key], (case,i,key,gold[i],state[i])
indices=[i for i,r in enumerate(cycle) if int(r['pc'],0)==symbols['tested_op']]
assert len(indices)==1000
gaps=[cycle[i]['cyc']-cycle[i-1]['cyc'] for i in indices[100:]]
assert min(gaps)>=2, ('missing actual prefix D1+EX clocks',case,min(gaps))
if case==9:
    assert min(gaps)>=3, ('duplicate ordinary prefix clocks undercharged',min(gaps))
if case in (0,1,4,5,8):
    pair_count=sum(i+1<len(cycle) and cycle[i]['cyc']==cycle[i+1]['cyc']
                   for i in indices[100:])
    assert pair_count>0, ('no legal prefix U/V pairing witnessed',case)
elif case in (2,3,6,11):
    assert all(cycle[i]['cyc']!=cycle[i+1]['cyc'] for i in indices[100:]), \
        ('illegal RAW/WAW/prefix-V pairing',case)
if case==8:
    assert symbols['tested_op']==0x0804fffe
    assert all(int(cycle[i+1]['pc'],0)==0x08050001 for i in indices)
print(f'P54-PREFIX66-REG-CASE-OK case={case} QEMU-state=PASS '
      f'warm_D1_EX_gaps={min(gaps)}..{max(gaps)}')
