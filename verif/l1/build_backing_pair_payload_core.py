"""Build the checked backing-payload cut and retain the committed DMA repair.

Reuse the exact bounded builder with unchanged profile and native-header checks.
This is a frozen derivative, not the current checkout or an acceptance result.
"""
import hashlib
from pathlib import Path

original=Path(__file__).with_name('build_fp_high_valid_core.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='8decde5e455fd686dbdc0079489bd5ccd4eb12cbc82f573d2a170884e3907448'


def change(old,new):
    global text
    assert text.count(old)==1,old
    text=text.replace(old,new)


change('import prepare_fp_high_valid_cofactor as recipe', '''import sys
import types
import prepare_backing_pair_payload as payload_recipe
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'fpga'))
import prepare_dma_declaration_order as dma_recipe
TARGET='rtl/mem/ven_l1d.sv'
DMA='3rd-party/ao486_MiSTer/rtl/soc/dma.v'
def transform(source,path):
    if path==TARGET:return payload_recipe.transform(source)
    if path==DMA:return dma_recipe.transform(source)
    raise ValueError('unreviewed backing-payload file: '+path)
recipe=types.SimpleNamespace(__file__=payload_recipe.__file__,
    PARENTS={TARGET:payload_recipe.PARENT,DMA:dma_recipe.PARENT},transform=transform)''')
change('MODEL=cache_gate.MODEL',"MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'")
change("    pins={**before['pins'],**checked['pins']}",'''    axi=args.axi.resolve(strict=True); dma=args.dma.resolve(strict=True)
    ax=load(axi/'closed.json'); dm=load(dma/'closed.json')
    assert ax['passed'] and ax['pins_unchanged'] and ax['full_cache'] and ax['real_axi_master']
    assert [(r['mutant'],r['build_exit'],r['native_exit']) for r in ax['rows']]==[(False,0,0),(True,0,1)]
    assert ax['rows'][0]['coverage']==[
        'BACKING-AXI-OK checks=2387 stores=68 pairs=3 load_stores=1 quad=1 blocked=30 idle_credit_changes=4 full_queue=84',
        'PARALLEL-CACHE-MITER checks=4781 next=0']
    assert dm['passed'] and dm['pins_unchanged']
    assert [(r['name'],r['native_exit']) for r in dm['variants']]==[
        ('parent',1),('fixed',0),('only-selector',1),('only-reset',1)]
    pins={**before['pins'],**checked['pins'],**ax['pins'],**load(dma/'started.json')['pins']}
    for row in ax['rows']:pins.update(row['artifacts'])
    for p in (Path(__file__).with_name('build_fp_high_valid_core.py'),
              Path(__file__).with_name('run_backing_pair_payload_cache.py'),
              Path(dma_recipe.__file__),axi/'closed.json',dma/'closed.json',dma/'started.json'):
        pins[str(p)]=sha(p)''')
change("    assert changes['rtl/mem/ven_l1d.sv']==(cache/'positive/ven_l1d.sv').read_text()",
       """    assert changes[TARGET]==(cache/'positive/ven_l1d.sv').read_text()==(axi/'positive/ven_l1d.sv').read_text()
    assert hashlib.sha256(changes[DMA].encode()).hexdigest()==dm['variants'][1]['source_sha256']""")
change("'tb_fp_high_valid_'","'tb_backing_payload_'")
change("'FP-HIGH-VALID-CORE-PREPARED '","'BACKING-PAYLOAD-CORE-PREPARED '")
change("for key in ('parent','cache'):","for key in ('parent','cache','axi','dma'):")
change('assert args.parent and args.cache and not root.exists()',
       'assert args.parent and args.cache and args.axi and args.dma and not root.exists()')

exec(compile(text,str(Path(__file__)),'exec'),globals())
