"""Extend the precise-store witness with ordinary guest #PF repair and IRET.

Preserve all pre-repair checks. No snapshot, debugger write or waived field.
"""
import hashlib

PARENT='2ac173e57ce939b22db28c8587f668dd8544966f5b8287fafa718cb3a7be5d9c'
REPAIR='''#if CASE >= 4 && CASE <= 7
    cmpl $0, %es:0x4a0
    jne fail
    incl %es:0x4a0
    movl $0x180003, %es:0x13000
    movl $0x1a0003, %es:0x13004
    invlpg %es:0x400fff
    invlpg %es:0x401000
    popal
    addl $4, %esp
    iretl
    jmp fail
#endif
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest()!=PARENT:
        raise ValueError('precise-store fixture drift or repeated transformation')
    start=source.index('    /* Validate the untouched pre-fault register state')
    end=source.index('    cmpl $0x8fd0, %esp\n',start)
    gprs=source[start:end]
    after='''smsw_after:
    pushfl
    pushal
'''+gprs+'''    cmpl $0x8fdc, %esp
    jne fail
    movl 32(%esp), %eax
    andl $0xfd7, %eax
    cmpl $0x8d7, %eax
    jne fail
#if CASE == 8
    cmpl $0, %es:0x4a0
#else
    cmpl $1, %es:0x4a0
#endif
    jne fail
    cmpl $0x001ba5a5, %es:ALIAS+0xffd
    jne fail
    cmpl $0xa5a5a500, %es:ALIAS+0x1000
    jne fail
    jmp success
'''
    old=source[source.index('smsw_after:\n'):source.index('ud_handler:\n')]
    assert source.count(old)==source.count('    .macro gate vector, target\n')==source.count('success:\n')==1
    result=source.replace(old,after)
    result=result.replace('    .macro gate vector, target\n',
                          '    movl $0, 0x4a0\n    .macro gate vector, target\n')
    result=result.replace('success:\n',REPAIR+'success:\n')
    assert result[result.index('fault_handler:\n'):result.index(REPAIR)]==source[
        source.index('fault_handler:\n'):source.index('success:\n')]
    return result
