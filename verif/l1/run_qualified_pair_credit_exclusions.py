"""Native non-pairing default and CDC exclusion controls, never UV acceptance.

Run unchanged legacy cache/AXI scenarios on exact parent and candidate memory
sources. Candidate-only observation verifies the new contract parameter stays
zero. Default uses no feature defines; CDC adds only VEN_AXI_CDC. Neither is a
processor performance profile or replacement for the paired hardware tests.
"""
import inspect
from pathlib import Path

import run_qualified_pair_credit_wrapper as base

HERE = Path(__file__).resolve().parent
PROFILES = {'default': ('tb_l1_axi', 'L1AXI-GATE-OK'),
            'cdc': ('tb_l1axi_cdc', 'L1AXICDC-GATE-OK')}


def fixture(profile):
    top, _ = PROFILES[profile]
    source = (HERE/(top+'.sv')).read_text()
    source = base.recipe.once(source, 'module '+top+';', 'module tb_qualified_pair_wrapper;')
    return base.recipe.once(source, '  ventium_l1_axi #(', '''
`ifdef PAIR_CREDIT_CANDIDATE_OBSERVE
  initial begin
    if(dut.u_axi.PAIR_REQ_CREDIT_QUALIFIED !== 1'b0)
      $fatal(1,"PAIR-EXCLUSION incorrectly enabled qualified credit");
  end
`endif
  ventium_l1_axi #(''')


def derive():
    assert base.sha(base.__file__) == 'ed920b3712213b952f03a0ee9e9c14423de74a8aa81f04a8153124b94fc20418'
    source = inspect.getsource(base.main)
    for old, new in (
        ('    args=ap.parse_args()',
         "    ap.add_argument('--profile',choices=PROFILES,required=True)\n    args=ap.parse_args()\n    marker=PROFILES[args.profile][1]"),
        ("defines=[flag for flag in hardware if flag!='SYNTHESIS']+['AXI_BFM_MON']",
         "defines=[] if args.profile=='default' else ['VEN_AXI_CDC']"),
        ("'tb_qualified_pair_wrapper.sv':fixture()", "'tb_qualified_pair_wrapper.sv':fixture(args.profile)"),
        ('Path(__file__).resolve(),HERE/',
         "Path(__file__).resolve(),Path(base.__file__).resolve(),HERE/(PROFILES[args.profile][0]+'.sv'),HERE/"),
        ('invocation=os.environ', 'profile=args.profile,diagnostic_control=True,invocation=os.environ'),
        ("*['+define+'+flag for flag in defines]",
         "*['+define+'+flag for flag in defines],*(['+define+PAIR_CREDIT_CANDIDATE_OBSERVE'] if candidate else [])"),
    ):
        source = base.recipe.once(source, old, new)
    source = source.replace("'PAIR-CREDIT-WRAPPER-OK'", 'marker')
    return source


if __name__ == '__main__':
    scope = dict(base.__dict__, __file__=__file__, base=base, PROFILES=PROFILES, fixture=fixture)
    exec(compile(derive(), __file__, 'exec'), scope)
    raise SystemExit(scope['main']())
