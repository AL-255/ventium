"""Strict shared system-state comparison for the x87 event test drivers."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'diff'))
import compare
import tracefmt


def compare_complete(gold, actual, log):
    """Mandatory CR payload plus the comparator's shared hidden-field scope."""
    for label, trace in (('QEMU', gold), ('RTL', actual)):
        assert trace.hdr.get('sys') is True and trace.hdr.get('x87') is True, label
        for record in trace.records:
            assert all(key in record for key in tracefmt.SYS_CR), (label, record.get('n'), 'missing CR field')
    common_hidden = [key for key in tracefmt.SYS_SEG_HIDDEN
                     if gold.records and actual.records and
                     key in gold.records[0] and key in actual.records[0]]
    print('System scope: mandatory CR0/CR2/CR3/CR4; shared hidden fields: ' +
          (','.join(common_hidden) or 'none'), file=log)
    return compare.compare_func(gold, actual, True, 0xffffffff, False, 20, log,
                                sys_both=True)
