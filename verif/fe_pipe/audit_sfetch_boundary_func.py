"""Independently regrade every functional record under the original policy."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/issue_uv'))
import audit_v_result_carry_func as previous
from prepare_sfetch_beat_stage import replace_once


def confirm_terminal_invocation(owner, unit, start, closed, root):
    if owner['InvocationID']:
        assert owner['InvocationID']==start['invocation']
        return
    # A non-RemainAfterExit transient service loses InvocationID when collected.
    # Do not equate an empty ID with the desired owner: recover the native final
    # receipt from journal fields bound to that exact invocation, and reject a
    # subsequent invocation of the same unit name.
    assert (owner['ActiveState'],owner['SubState'],owner['MainPID'])==('inactive','dead','0')
    raw = subprocess.check_output(['journalctl','--user','-u',unit,'--no-pager','-o','json'])
    rows = [json.loads(line) for line in raw.splitlines()]
    managers = [r for r in rows if r.get('USER_INVOCATION_ID')]
    assert managers and managers[-1]['USER_INVOCATION_ID']==start['invocation']
    messages = [r for r in rows if r.get('_SYSTEMD_USER_UNIT')==unit and
                r.get('_SYSTEMD_INVOCATION_ID')==start['invocation']]
    assert messages and len({r['_PID'] for r in messages})==1
    native = json.loads('\n'.join(r['MESSAGE'] for r in messages))
    assert native==dict(closed,rows=[r for r in closed['rows'] if not r['passed']])
    wrapper = json.loads(root.with_suffix('.driver-closed.json').read_text())
    assert wrapper==dict(native_exit=0,pins_unchanged=True)
    owner.update(journal_invocation=start['invocation'],native_journal_receipt_equal=True,
                 journal_sha256=hashlib.sha256(raw).hexdigest())


def derive():
    text = previous.derive()
    for old,new in (
        ('import run_v_result_carry_func as runner',
         'import run_sfetch_boundary_func as runner\nrunner.REFERENCE=runner.previous.REFERENCE\nrunner.SOURCE=runner.previous.SOURCE'),
        ('v-result-carry-func-r1','sfetch-boundary-func-r1'),
        ('v-result-carry-core-r1','sfetch-boundary-core-r1'),
        ('ventium-v-result-carry-func-oct16-r1.service','ventium-sfetch-boundary-func-oct16-r1.service'),
        ('cpu in range(12,16)','cpu in range(20,24)'),
        ("assert owner['InvocationID'] == start['invocation']",
         "confirm_terminal_invocation(owner,unit,start,closed,root)"),
        ("assert owner['ActiveState']=='active' and owner['SubState']=='exited' and owner['MainPID']=='0'",
         "assert (owner['ActiveState'],owner['SubState']) in (('active','exited'),('inactive','dead')) and owner['MainPID']=='0'"),
        ('runner.SOURCE, Path(', 'runner.SOURCE, Path('+repr(str(Path(previous.__file__)))+'), Path('),
    ):
        text = replace_once(text,old,new)
    compile(text,__file__,'exec')
    return text


if __name__=='__main__':
    exec(compile(derive(),__file__,'exec'),globals())
