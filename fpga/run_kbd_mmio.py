"""Bounded AXI-Lite keyboard transport test using the real three RTL blocks.

The frozen management slave is unchanged. This extends the endpoint test
through management transactions, not through CPU execution or the full wrapper.
"""
import inspect
import itertools

import run_kbd_controller_inhibit as template

ROOT, REPO, sha = template.ROOT, template.REPO, template.sha
MGMT = ROOT/'prime-width-fpga-r1/flow/src/ven_mgmt_axil.v'
MGMT_SHA = '1373aa5cd3a97e9007555858827c066174ad1746e927ed8f4a7f6d0c32f58736'


def cases():
    return list(itertools.product(('candidate','parent'), (3125000,40000000), range(3), (0,1)))


def grade(case, code, text):
    label,hz,order,inhibit = case
    if label == 'parent' and inhibit:
        return code == 1 and f'KBD-MMIO-EARLY-READY hz={hz} order={order}' in text and 'KBD-MMIO-OK' not in text
    return code == 0 and text.splitlines()[0] == (
        f'KBD-MMIO-OK hz={hz} order={order} inhibit={inhibit} submits=2 irq1=1') and 'FATAL' not in text


def derive():
    assert sha(template.__file__) == 'a0ebf93dea5c586e74031ae8913e8a56fa1ef068939599c523ed3c5aafb3c2ce'
    text = inspect.getsource(template.main)
    for old,new in (
        ('(CONTROLLER,CONTROLLER_SHA),(FIFO,FIFO_SHA),(FIXED,FIXED_SHA),',
         '(MGMT,MGMT_SHA),(CONTROLLER,CONTROLLER_SHA),(FIFO,FIFO_SHA),(FIXED,FIXED_SHA),'),
        ("files={'controller.v':CONTROLLER,", "files={'mgmt.v':MGMT,'controller.v':CONTROLLER,"),
        ('tb_kbd_controller_inhibit', 'tb_kbd_mmio'),
        ('Path(recipe.__file__).resolve(),Path(witness.__file__).resolve()',
         'Path(recipe.__file__).resolve(),Path(witness.__file__).resolve(),Path(template.__file__).resolve()'),
        ("('controller.v','simple_fifo.v',label+'.v','tb_kbd_mmio.sv')",
         "('mgmt.v','controller.v','simple_fifo.v',label+'.v','tb_kbd_mmio.sv')"),
        ('f\'+phase={phase}\',f\'+reset={reset}\'', "f'+order={phase}',f'+inhibit={reset}'"),
        ('debug_mmio_tested=False', 'debug_mmio_tested=True,full_wrapper=False'),
    ):
        assert old in text, old
        text = text.replace(old,new)
    compile(text,__file__,'exec')
    return text


def main():
    scope = dict(template.__dict__, __file__=__file__, template=template,
                 MGMT=MGMT, MGMT_SHA=MGMT_SHA, cases=cases, grade=grade)
    exec(compile(derive(),__file__,'exec'),scope)
    return scope['main']()


if __name__ == '__main__':
    raise SystemExit(main())
