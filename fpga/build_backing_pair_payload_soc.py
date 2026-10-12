"""Transfer the checked L1 payload cut and DMA repair into the frozen PC parent.

Preparation remains gated on the complete directed regressions, canonical
status and exact shared-source comparison. No compiler runs on import.
"""
import hashlib
from pathlib import Path

original=Path(__file__).with_name('build_fp_high_valid_soc.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='b108da0a9ca84038e7e40392760f54528485541d99d44e2f7b72621d7d2bb895'


def change(old,new):
    global text
    assert text.count(old)==1,old
    text=text.replace(old,new)


change('import prepare_fp_high_valid_cofactor as recipe',
       'import build_backing_pair_payload_core as staged\nrecipe=staged.recipe')
change("PARENT_MODEL='45dc4daf68980bba3ca36f9b8d2c6c4ec4464a07657f70669f00e085478893f5'",
       "PARENT_MODEL='07b59e2059a985764fe7bc9ce99ebde0530acf96e8d6dfed1e83258db1178541'")
change("CORE_MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'",
       "CORE_MODEL='4c410b962f602cbb52d402c2072413ec74bc4d2fb020d392511d4637db24ec15'")
change("    assert len(shared)==102 and [p for p in shared if sha(source/p)!=sha(core/'candidate'/p)]==CHANGES",
       """    assert len(shared)==102 and [p for p in shared if sha(source/p)!=sha(core/'candidate'/p)]==[staged.TARGET]
    assert sha(source/staged.DMA)==staged.dma_recipe.PARENT""")
change("    assert all(sha(root/'source'/name)==sha(core/'candidate'/name) for name in shared)",
       """    assert all(sha(root/'source'/name)==sha(core/'candidate'/name) for name in [*shared,staged.DMA])
    assert sorted(str(p.relative_to(source)) for p in files
        if sha(p)!=sha(root/'source'/p.relative_to(source)))==CHANGES""")
change("'sim_fp_high_valid_'","'sim_backing_payload_'")
change("    assert stable(pins)\n    save(root/'prepared.json'", """    for p in (Path(__file__).with_name('build_fp_high_valid_soc.py'),
              Path(staged.__file__),Path(staged.dma_recipe.__file__)):
        pins[str(p)]=sha(p)
    assert stable(pins)
    save(root/'prepared.json'""")
change('Prepared source-matched FP high-valid PC candidate; compiler not started.',
       'Prepared source-matched backing-payload + DMA PC candidate; compiler not started.')

exec(compile(text,str(Path(__file__)),'exec'),globals())
