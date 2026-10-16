"""Measure boundary-stage cost with two unchanged short cold CoreMark guests.

Preserve CRC, mode, ownership and native-exit policy. Unlike the earlier
combinational experiments, report actual cycle cost rather than requiring zero.
This is not a duration-valid score, standard-suite pass or gameplay result.
"""
import inspect
from pathlib import Path

import build_sfetch_boundary_soc as builder
import native_observation

original = Path(__file__).with_name('run_v_carry_payload_coremark.py')
SOURCE_SHA = '3993be119f225953cc0a94448cd737e898f203ad867fc0358adc6fe71b833a12'
PARENT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/v-result-carry-soc-r1').resolve()
TICKS = {'performance':4767218, 'validation':4753406}


def cost(seed, ticks):
    assert isinstance(ticks,int) and ticks>0
    old = TICKS[seed]
    return dict(parent_ticks=old, added_clocks=ticks-old,
                clock_cost_percent=100*(ticks-old)/old,
                throughput_gain_percent=100*(old/ticks-1))


def derive():
    assert builder.sha(original)==SOURCE_SHA
    text = original.read_text()
    first = '                deadline=time.monotonic()+3\n'
    last = '                rc=child.wait(timeout=600)\n'
    assert text.count(first)==text.count(last)==1
    text = text[:text.index(first)] + '''                observed=native_observation.observe_owned_native(
                    child,model,argv,env['AO486_BIOS_DIR'],12,parse_cmdline)
                save(work/'native-observed.json',observed)
                save(work/'native.json',observed)
''' + text[text.index(last):]
    for old,new in (
        ('ventium-v-carry-cm10-', 'ventium-sfetch-boundary-cm10-'),
        ("root=soc/'coremark';root.mkdir()", "root=soc/'coremark-r1';root.mkdir()"),
        ('os.sched_getaffinity(0)=={11}', 'os.sched_getaffinity(0)=={12}'),
        ("pins=dict(json.loads((soc/'build-started.json').read_text())['pins'])",
         "started=json.loads((soc/'build-started.json').read_text())\n"
         "assert started['parent_model']==builder.PARENT_MODEL and started['directed_model']==builder.CORE_MODEL\n"
         "assert started['changes']==builder.CHANGES and started['cycle_cost']['diagnostic_only']\n"
         "assert not started['canonical_gate_passed']\n"
         "prior=json.loads((PARENT/'coremark-r1/closed.json').read_text())\n"
         "assert prior['passed'] and json.loads((PARENT/'coremark-r1/audit.json').read_text())['passed']\n"
         "assert {r['seed']:r['ticks'] for r in prior['results']}==TICKS\n"
         "pins=dict(started['pins'])"),
        ('for p in (Path(__file__).resolve(),model,',
         "for p in (original,Path(native_observation.__file__),Path(builder.__file__),"
         "PARENT/'coremark-r1/closed.json',PARENT/'coremark-r1/audit.json',Path(__file__).resolve(),model,"),
        ("assert result['ticks']=={'performance':4767218,'validation':4753406}[seed], 'V carry payload cofactor changed benchmark clocks'",
         "result.update(cost(seed,result['ticks']))"),
    ):
        text = builder.recipe.replace_once(text,old,new)
    compile(text,__file__,'exec')
    return text


if __name__=='__main__': exec(compile(derive(),__file__,'exec'),globals())
