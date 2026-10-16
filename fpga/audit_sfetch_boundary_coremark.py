"""Independently regrade short CoreMark completion and measured stage cost."""
from pathlib import Path

import run_sfetch_boundary_coremark as runner

original = Path(__file__).with_name('audit_v_carry_payload_coremark.py')
SOURCE_SHA = 'c674a2804c03d6bf97724a3eff620fffea4cdd253b38aca0a12a9adda0d23103'


def derive():
    assert runner.builder.sha(original)==SOURCE_SHA
    text = original.read_text()
    for old,new in (
        ("root = soc / 'coremark'", "root = soc / 'coremark-r1'"),
        ("parent = scratch / 'ventium-fp-exec-cut.MNkzxfBO/soc'", "parent = runner.PARENT"),
        ("native['affinity'] == [11]", "native['affinity'] == [12]"),
        ("assert start['model'] == load(soc/'build-closed.json')['binary_sha256']",
         "assert start['model'] == load(soc/'build-closed.json')['binary_sha256']\n"
         "build=load(soc/'build-started.json')\n"
         "assert build['parent_model']==runner.builder.PARENT_MODEL and build['directed_model']==runner.builder.CORE_MODEL\n"
         "assert build['changes']==runner.builder.CHANGES and not build['canonical_gate_passed']"),
        ("assert old['ticks'] == result['ticks'] == item['ticks']",
         "assert old['ticks']==runner.TICKS[seed] and result['ticks']==item['ticks']\n"
         "    measured=runner.cost(seed,result['ticks'])\n"
         "    assert all(item[k]==v for k,v in measured.items())"),
        ('throughput_gain_percent=0,actual_v=', '**measured,actual_v='),
        ("rows.append(dict(seed=seed,crcs=crcs,parent_ticks=old['ticks'],candidate_ticks=result['ticks'],",
         "rows.append(dict(seed=seed,crcs=crcs,candidate_ticks=result['ticks'],"),
        ("for p in (Path(__file__),root/'started.json'",
         "for p in (original,Path(runner.__file__),Path(runner.builder.__file__),Path(__file__),root/'started.json'"),
    ):
        text = runner.builder.recipe.replace_once(text,old,new)
    assert text.count("parent/'coremark/")==4
    text = text.replace("parent/'coremark/", "parent/'coremark-r1/")
    compile(text,__file__,'exec')
    return text


if __name__=='__main__': exec(compile(derive(),__file__,'exec'),globals())
