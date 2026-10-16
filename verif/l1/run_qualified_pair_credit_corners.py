"""Exact parent/candidate wrapper at simultaneous release, error and shutdown.

Only external requests, AXI response pins and reset/shutdown are driven. The
existing bounded wrapper supervisor, compiler policy and source checks remain.
This is directed integration coverage, not processor or FPGA acceptance.
"""
import inspect
from pathlib import Path

import run_qualified_pair_credit_wrapper as base

HERE = Path(__file__).resolve().parent


def check_templates():
    assert base.sha(base.__file__) == 'ed920b3712213b952f03a0ee9e9c14423de74a8aa81f04a8153124b94fc20418'
    assert base.sha(HERE/'qualified_pair_credit_wrapper.svh') == '2dba5b541d2101a105219b73c16edd59ddf24a38626a620cdedf4169f1655c17'


def fixture():
    check_templates()
    text = base.fixture()
    for old, new in (
        ('logic axi_only_reset=0, allow_ar=1;',
         'logic axi_only_reset=0, allow_ar=1, shutdown=0, inject_b_error=0;'),
        (".shutdown(1'b0)", '.shutdown(shutdown)'),
        ('.m_axi_bresp(bresp)', ".m_axi_bresp(inject_b_error ? 2'b10 : bresp)"),
        ('qualified_pair_credit_wrapper.svh', 'qualified_pair_credit_corners.svh'),
    ):
        text = base.recipe.once(text, old, new)
    return text


def leaf():
    check_templates()
    source = (HERE/'qualified_pair_credit_wrapper.svh').read_text()
    # Keep the prior port-driving tasks and independent byte-RAM scoreboard.
    return source[:source.index('initial begin : wrapper_test')]+(HERE/'qualified_pair_credit_corners.svh').read_text()


def derive():
    check_templates()
    source = inspect.getsource(base.main)
    source = source.replace('qualified_pair_credit_wrapper.svh', 'qualified_pair_credit_corners.svh')
    source = base.recipe.once(source,
        "(HERE/'qualified_pair_credit_corners.svh').read_text()", 'leaf()')
    source = base.recipe.once(source, "['AXI_BFM_MON']",
        "['AXI_BFM_MON','VEN_AXI_RESP_FAULT_INJECT']")
    source = base.recipe.once(source, 'Path(__file__).resolve(),HERE/',
        "Path(__file__).resolve(),Path(base.__file__).resolve(),HERE/'qualified_pair_credit_wrapper.svh',HERE/")
    source = source.replace('PAIR-CREDIT-WRAPPER-OK', 'PAIR-CREDIT-CORNERS-OK')
    return source


if __name__ == '__main__':
    scope = dict(base.__dict__, __file__=__file__, base=base, fixture=fixture, leaf=leaf)
    exec(compile(derive(), __file__, 'exec'), scope)
    raise SystemExit(scope['main']())
