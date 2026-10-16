"""Relink the retained-input PC with its actual named FIFO read wire.

The failed model and every earlier proof stay immutable. Only the private
read-only host binding changes; no controller/CPU/clock/define changes.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil

import build_retained_ui_soc as prior

sha, load, save, stable = prior.sha, prior.load, prior.save, prior.stable
HEADER_SHA = '0611ad83d4d7d35863fcc3eb29352f3c0d542d146260f51cf9ae378577e3a96e'
GENERATED_SHA = 'ce6d0bf1c93bd64badbe4f2938f6183197f434bd3f3dbf8e016a8ff38af63c55'


def binding(text):
    assert hashlib.sha256(text.encode()).hexdigest() == HEADER_SHA
    old = '    p.read_request=K(__Vcellinp__keyb_fifo__rdreq);'
    new = '    p.read_request=K(kb_fifo_rdreq);'
    assert text.count(old) == 1
    return text.replace(old, new)


def prepare(failed, root):
    assert not root.exists() and not root.is_relative_to(failed)
    before, closed = load(failed/'build-started.json'), load(failed/'build-closed.json')
    assert not closed['passed'] and closed['native_exit'] == 2 and closed['inputs_unchanged']
    assert stable(before['pins'])
    log = (failed/'build.log').read_text()
    errors = [s for s in log.splitlines() if 'error:' in s]
    assert len(errors) == 1 and 'no member named' in errors[0]
    assert 'system__DOT__ps2__DOT____Vcellinp__keyb_fifo__rdreq' in errors[0]
    generated = failed/'obj1-speed-q16-parentpolicy/Vsystem___024root.h'
    assert sha(generated) == GENERATED_SHA
    assert 'CData/*0:0*/ system__DOT__ps2__DOT__kb_fifo_rdreq;' in generated.read_text()
    controller = failed/'source'/prior.PS2
    assert sha(controller) == prior.PS2_SHA
    rtl = controller.read_text()
    assert '.rdreq      (kb_fifo_rdreq)' in rtl
    assert ('wire kb_fifo_rdreq = io_read_valid && io_address[2:0] == 3\'d0 &&\n'
            '                     status_outputbufferfull && !status_mousebufferfull;') in rtl
    source = failed/'source'
    files = [p for p in source.rglob('*') if p.is_file()]
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p) == before['pins'][str(p)] for p in files)
    root.mkdir(); shutil.copytree(source, root/'source')
    header = root/'source/ao486-sim/ven/pc_keyboard_retained.h'
    header.write_text(binding(header.read_text()))
    changed = [str(p.relative_to(source)) for p in files
               if sha(p) != sha(root/'source'/p.relative_to(source))]
    assert changed == ['ao486-sim/ven/pc_keyboard_retained.h']
    old_host = Path(before['host'])
    host = header.parent/('sim_retained_bound_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old_host, host)
    command = [s.replace(str(failed), str(root)) for s in before['command']]
    command = [str(host) if s == str(root/old_host.relative_to(failed)) else s for s in command]
    assert command.count(str(host)) == 1
    shutil.copyfile(failed/'defines.txt', root/'defines.txt')
    prior.parent_builder.check_definitions(command, (root/'defines.txt').read_text().splitlines())
    pins = dict(before['pins'])
    for p in (Path(__file__), Path(prior.__file__), generated, controller,
              failed/'build-started.json', failed/'build-closed.json', failed/'build.log',
              root/'defines.txt', *(p for p in (root/'source').rglob('*') if p.is_file())):
        pins[str(p.resolve())] = sha(p)
    assert stable(pins)
    before.update(command=command, pins=pins, host=str(host), failed_build=str(failed),
        binding_delta=changed, binding_read_wire='kb_fifo_rdreq',
        binding_semantics_changed=False, full_pc_input_qualified=False)
    before.pop('invocation', None)
    save(root/'prepared.json', before)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('prepare','build'))
    ap.add_argument('--failed', type=Path)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args(); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = a.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert root != scratch and root.is_relative_to(scratch)
    assert scratch.stat().st_dev != prior.REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if a.action == 'prepare':
        prepare(a.failed.resolve(strict=True), root)
        print('Prepared named-wire binding; all RTL unchanged.'); return 0
    return prior.base.build(root)


if __name__ == '__main__':
    raise SystemExit(main())
