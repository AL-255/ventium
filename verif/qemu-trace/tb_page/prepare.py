"""Backport QEMU upstream 3b279f73's two-page TB bookkeeping correction.

Upstream: https://github.com/qemu/qemu/commit/3b279f73fa37bec8d3ba04a15f5153d6491cffaf
Only tb_record/tb_remove's second-page index changes; no guest, debugger,
instruction, exception, trace or comparison policy is altered.
"""
import hashlib

SOURCE_SHA = '74759be530fcc681f732c52f2492a86d3b6eb2d432169779be5bb31e58b8dae7'
FILE = 'accel/tcg/tb-maint.c'
OLD = '    tb_page_addr_t pindex1 = paddr0 >> TARGET_PAGE_BITS;'
NEW = '    tb_page_addr_t pindex1 = paddr1 >> TARGET_PAGE_BITS;'


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != SOURCE_SHA:
        raise ValueError('QEMU TB-page parent drift or reapplication')
    if source.count(OLD) != 2:
        raise ValueError('TB-page index anchors missing or ambiguous')
    result = source
    for name in ('tb_record','tb_remove'):
        # The final definition is the system-mode implementation.  The whole
        # file hash above fixes its context; do not invent a comment anchor or
        # accidentally select the earlier CONFIG_USER_ONLY definition.
        start = result.rindex('static void '+name+'(TranslationBlock *tb)\n{')
        end = result.index('\n}',start)+2
        body = result[start:end]
        if body.count(OLD) != 1:
            raise ValueError(name+' second-page anchor')
        result = result[:start]+body.replace(OLD,NEW)+result[end:]
    if OLD in result:
        raise ValueError('unrepaired TB-page index')
    return result
