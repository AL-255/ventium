"""CDC diagnostic with edge-correct ACK sampling and accepted-store witnesses.

The old control remains failed. Do not alter RTL, expected data, reset timing,
clock ratios or queue sizes. Hold each request through the edge that consumes
its ACK rather than mistaking a newly visible post-edge ACK for consumption.
"""
from pathlib import Path

import run_qualified_pair_credit_exclusions as previous

HERE = Path(__file__).resolve().parent


def fixture(profile):
    assert profile == 'cdc'
    assert previous.base.sha(HERE/'tb_l1axi_cdc.sv') == '21b152a6f429e20b58bf5c0aec72ece9a956e32dd48491e3fa40592ea4447c4f'
    source = previous.fixture(profile)
    old = '@(posedge core_clk); #1;'
    assert source.count(old) == 3
    source = source.replace(old, '@(posedge core_clk);')
    source = previous.base.recipe.once(source, '  logic [31:0] d;', '''
  integer accepted_writes=0, first_write_commits=0;
  always @(posedge core_clk) if(core_rst_n && c_req && c_we && c_ack) begin
    accepted_writes++;
    if(c_addr==32'h1008 && c_wdata==32'hdeadbeef) first_write_commits++;
  end
  logic [31:0] d;''')
    return previous.base.recipe.once(source,
        '    if (errs==0) $display("  ok  [%s] all CDC checks pass", TAG);', '''
    if(accepted_writes!=41 || first_write_commits!=1)
      $fatal(1,"CDC-EDGE wrong accepted store count [%s] total=%0d first=%0d",TAG,accepted_writes,first_write_commits);
    $display("CDC-EDGE [%s] accepted_stores=%0d first_store=%0d",TAG,accepted_writes,first_write_commits);
    if (errs==0) $display("  ok  [%s] all CDC checks pass", TAG);''')


def derive():
    assert previous.base.sha(previous.__file__) == '17d82e81c1c249a2de7b8472e87aba1251832d5ffbde967649361aa15e1c0b63'
    text = previous.derive()
    return previous.base.recipe.once(text, 'Path(__file__).resolve(),Path(base.__file__).resolve(),',
        'Path(__file__).resolve(),Path(previous.__file__).resolve(),Path(base.__file__).resolve(),')


if __name__ == '__main__':
    scope = dict(previous.base.__dict__, __file__=__file__, base=previous.base,
                 previous=previous, PROFILES={'cdc': previous.PROFILES['cdc']}, fixture=fixture)
    exec(compile(derive(), __file__, 'exec'), scope)
    raise SystemExit(scope['main']())
