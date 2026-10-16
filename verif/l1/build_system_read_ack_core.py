"""Build nine-file system-read ACK derivative, preserving the full UV closure."""
import inspect
from pathlib import Path
import sys

import prepare_system_read_ack as recipe
import run_system_read_ack_leaf as leaf_runner

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'fetchguard'))
import build_decode_bus_core as previous

MODEL = leaf_runner.MODEL
native = previous.native
CHANGES = sorted(recipe.PREFIX+n for n in recipe.PARENTS)


def check_leaf(leaf):
    pins = leaf_runner.check_receipt(leaf)
    # Do not accept a green JSON emitted by a still-live controller.
    import subprocess
    props = dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show','ventium-system-read-ack-leaf-oct16-r2.service',
        '-p','MainPID','-p','Result','-p','ExecMainStatus','-p','InvocationID'],text=True,timeout=10).splitlines())
    assert props['MainPID']=='0' and props['Result']=='success' and props['ExecMainStatus']=='0'
    # The scope has its own invocation ID; it is not the outer service ID.
    assert props['InvocationID']=='ec9b47f2a7db496e9a57429acb8c689d'
    import json
    scope_invocation=native.load(leaf/'started.json')['invocation']
    records=[json.loads(s) for s in subprocess.check_output([
        'journalctl','--user','_SYSTEMD_INVOCATION_ID='+scope_invocation,
        '-o','json','--no-pager'],text=True,timeout=10).splitlines()]
    closures=[r for r in records if r.get('_SYSTEMD_USER_UNIT')=='ventium-ipc-parallel32.scope'
              and r.get('MESSAGE','').startswith('{"passed": true,')]
    assert len(closures)==1 and not Path('/proc',closures[0]['_PID']).exists()
    closed=native.load(leaf/'closed.json')
    assert all(not Path('/proc',str(r['pid'])).exists() for r in
               [*closed['rows'],*closed['builds'].values()])
    for p in (Path(leaf_runner.__file__),Path(previous.__file__)):
        pins[str(p.resolve())]=native.sha(p)
    return pins


def adapted_main():
    assert native.sha(previous.__file__)=='8fa9b0f1db1225b6feeb6aa2e9c73262657bbc24651530bc128724d49c3132e6'
    source=inspect.getsource(previous.main)
    substitutions=[
      ("replacement = recipe.transform((source/recipe.FILE).read_text())\n    assert replacement == (leaf/'core_bus_driver.svh').read_text()",
       "replacements = {recipe.PREFIX+n:recipe.transform((source/recipe.PREFIX/n).read_text(),n) for n in recipe.PARENTS}\n"
       "    for n in recipe.PARENTS: assert replacements[recipe.PREFIX+n] == (leaf/n).read_text()"),
      ("(root/'candidate'/recipe.FILE).write_text(replacement)",
       "for name,text in replacements.items(): (root/'candidate'/name).write_text(text)"),
      ("[recipe.FILE]", "CHANGES"),
      ("'tb_decode_bus_'", "'tb_system_read_ack_'"),
      ('Only no-request DECODE address payload; MMU/fault/request authority unchanged',
       'Read-only system ACK consumers and walk read/write guards; no request, latency, fault or commit change'),
    ]
    for old,new in substitutions:
        assert source.count(old)==(3 if old=='[recipe.FILE]' else 1),old
        source=source.replace(old,new)
    return source


def main():
    namespace=dict(previous.__dict__,__file__=__file__,recipe=recipe,MODEL=MODEL,
                   CHANGES=CHANGES,check_leaf=check_leaf)
    exec(compile(adapted_main(),__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__': raise SystemExit(main())
