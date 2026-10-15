"""Cold paged U-load/V-store wait tests, full QEMU state and parent clocks.

Reuse the existing memory corpus without weakening its checks. Every store is
read back immediately and compared with its changing signature. Same-bank and
unaligned stores must fall back, while aligned different-bank stores must
actually retire on V. No debugger step, snapshot or forced internal state.
"""
import inspect
from pathlib import Path

import run_l1_capture_cut_system as original

PATTERNS = (
    ('wide', 'movl (%eax),%edx', 'movl %esi,4(%edi)'),
    ('same-bank', 'movl (%eax),%edx', 'movl %esi,(%edi)'),
    ('split', 'movl (%eax),%edx', 'movl %esi,31(%edi)'),
)


def adapted_main():
    text = inspect.getsource(original.main)
    edits = [
        ("    for label,u,v in PATTERNS:\n", "    for label,u,v in PATTERNS:\n"
         "        operand = v.split(',', 1)[1]\n"
         "        readback = '    movl '+operand+',%ebx\\n    cmpl %esi,%ebx\\n    jne fail\\n'\n"),
        ("+'\\n'+text[b:])", "+'\\n'+readback+text[b:])"),
        ("'--quiesce','4096','+ven_faultlog'", "'--quiesce','4096','+ven_faultlog',\n"
         "                        '+ven_pipe_wait_read_ack_witness'"),
        ("        with socket.socket() as sock: sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]",
         "        port = 26000 + 100*[p[0] for p in PATTERNS].index(label) + 32*reloc + offset"),
        ("                measures.append(dict(case=case,model=name,latency=latency,clocks=clocks['cycle'],",
         "                if label=='wide' and offset==0:\n"
         "                    assert memory_v>0,(case,name,'mixed V store not exercised')\n"
         "                witnesses=re.findall(r'\\[PIPE-WAIT-READ-ACK\\] pc=[0-9a-f]+ held=(\\d) paired=(\\d)',stdout)\n"
         "                measures.append(dict(wait_reads=len(witnesses),\n"
         "                    wait_held=sum(h=='1' for h,p in witnesses),\n"
         "                    wait_paired=sum(p=='1' for h,p in witnesses),\n"
         "                    case=case,model=name,latency=latency,clocks=clocks['cycle'],"),
        ("    result['pins_unchanged']=", "    result['wait_held']=sum(r['wait_held'] for r in rows if r['model']=='candidate')\n"
         "    result['wait_paired']=sum(r['wait_paired'] for r in rows if r['model']=='candidate')\n"
         "    result['pins_unchanged']="),
        ("and result['memory_v_retirements']>0", "and result['memory_v_retirements']>0 and result['wait_held']>0 and result['wait_paired']>0"),
        ("for p in (Path(__file__),scaffold", "for p in (Path(__file__),Path(original.__file__),scaffold"),
    ]
    for old, new in edits:
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    restored = text
    for old, new in reversed(edits):
        assert restored.count(new) == 1, new
        restored = restored.replace(new, old)
    assert restored == inspect.getsource(original.main)
    return text


def main():
    namespace = dict(original.__dict__)
    namespace.update(__file__=__file__, PATTERNS=PATTERNS, original=original)
    exec(compile(adapted_main(), __file__, 'exec'), namespace)
    return namespace['main']()


if __name__ == '__main__':
    raise SystemExit(main())
