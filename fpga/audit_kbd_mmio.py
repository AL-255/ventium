"""Independently regrade closed AXI-Lite keyboard tests and exact source pins."""
import inspect

import audit_kbd_controller_inhibit as template
import run_kbd_mmio as run


def derive():
    assert run.sha(template.__file__) == 'a3bed672e61619970f365a3f659990aef70740b072fabac1ec055176453bd894'
    text = inspect.getsource(template.main)
    old = """    expected=[['candidate',hz,phase,reset] for hz,phase,reset in
              itertools.product((3125000,40000000),range(26),(0,1))]+[
                  ['parent',hz,20,0] for hz in (3125000,40000000)]"""
    new = """    expected=[list(c) for c in itertools.product(
        ('candidate','parent'),(3125000,40000000),range(3),(0,1))]"""
    edits = (
        (old,new),
        ("not done['debug_mmio_tested']", "done['debug_mmio_tested'] and not done['full_wrapper']"),
        ('tb_kbd_controller_inhibit','tb_kbd_mmio'),
        ("('controller.v','simple_fifo.v',label+'.v','tb_kbd_mmio.sv')",
         "('mgmt.v','controller.v','simple_fifo.v',label+'.v','tb_kbd_mmio.sv')"),
        ("red=label=='parent'", "red=label=='parent' and reset==1"),
        ("[f'+phase={phase}',f'+reset={reset}']", "[f'+order={phase}',f'+inhibit={reset}']"),
        ('KBD-CONTROLLER-EARLY-READY ', 'KBD-MMIO-EARLY-READY '),
        ("+f'hz={hz} phase={phase}'", "+f'hz={hz} order={phase}'"),
        ('            retry=int(reset==0 and (phase<21 or phase in (23,24)))\n',''),
        ("f'KBD-CONTROLLER-OK hz={hz} phase={phase} reset={reset} retry={retry} irq1=1'",
         "f'KBD-MMIO-OK hz={hz} order={phase} inhibit={reset} submits=2 irq1=1'"),
        ("Path(__file__).resolve()):", "Path(__file__).resolve(),Path(template.__file__).resolve()):"),
        ('candidate_positive_cases=104,original_endpoint_red_witnesses=2,',
         'candidate_positive_cases=12,original_endpoint_positive_controls=6,original_endpoint_red_witnesses=6,'),
        ('shared_reset=True,', 'guest_release_through_management=True,'),
        ('debug_mmio_tested=False', 'debug_mmio_tested=True,full_wrapper=False'),
        ('controller_sha256=run.CONTROLLER_SHA,endpoint_sha256=run.FIXED_SHA,',
         'controller_sha256=run.template.CONTROLLER_SHA,endpoint_sha256=run.template.FIXED_SHA,management_sha256=run.MGMT_SHA,'),
    )
    for old,new in edits:
        assert old in text, old
        text = text.replace(old,new)
    compile(text,__file__,'exec')
    return text


def main():
    scope = dict(template.__dict__, __file__=__file__, template=template, run=run)
    exec(compile(derive(),__file__,'exec'),scope)
    return scope['main']()


if __name__ == '__main__':
    main()
