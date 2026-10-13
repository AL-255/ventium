"""Reject missing stores, missing IRET and dirty pre-fault destination bytes."""
import ast
import hashlib
from pathlib import Path

template=Path(__file__).with_name('run_fault_mutants.py')
text=template.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='ab137ae322be274bc3ef9d26892b315bf5809835deadf58f12c571cbbf39d2cd'


def change(old,new):
    global text
    assert text.count(old)==1,old
    text=text.replace(old,new)


change('"""'+ast.get_docstring(ast.parse(text),clean=False)+'"""',repr(__doc__))
change("assert audited['audit_passed'] and audited['differential_cases']==85 and audited['intel_spec_only_cases']==20",
       "assert audited['passed'] and audited['differential_cases']==75 and audited['retries']==60 and audited['controls']==15")
change("assert len(done['rows'])==45 and not done['passed']", "assert len(done['rows'])==25 and done['passed']")
change("(Path(__file__),HERE/'run_probe.py',args.audit,model)",
       "(Path(__file__),template,HERE/'run_probe.py',args.audit,model)")
change('        for label,altered in mutations:\n', '''        if c['CASE']<8:
            disassembly=subprocess.check_output(['objdump','-d',fault/name/'probe.elf'],text=True)
            returns=re.findall(r'^\\s*([0-9a-f]+):\\s+cf\\s+iret\\s*$',disassembly,re.M)
            assert len(returns)==1,(name,returns)
            offset=int(returns[0],16)-0xf0000
            assert data[offset]==0xcf and symbols['fault_handler']<=offset+0xf0000<symbols['success']
            mutations.append(('no-iret',data[:offset]+bytes([0x90])+data[offset+1:]))
        for label,altered in mutations:
''')
change('assert len(jobs)==125','assert len(jobs)==85')
change("len(result['rows'])==125","len(result['rows'])==85")
exec(compile(text,str(Path(__file__)),'exec'),globals())
