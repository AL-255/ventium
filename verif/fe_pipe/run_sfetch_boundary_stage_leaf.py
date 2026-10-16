"""Exercise both boundary-only profiles with original lifecycle/negative tests."""
import inspect
from pathlib import Path
import sys

import prepare_sfetch_boundary_stage as recipe
import run_sfetch_beat_stage_leaf as previous

BASE_SHA = 'ed1354ce817b8d74111123e246c5d0f2b6e7de5af31223a663d6d48a9c55a4a8'
sha = previous.sha

INTERIOR_TEST = """
`ifdef VEN_SFETCH16_DEMAND
    // The common interior path must not acquire a bubble or stale boundary
    // ownership. This is a throughput contract, not just old/new equality.
    for (int i=0; i<4096; i++) begin
      state=S_FETCH; sfetch_boundary=1; sfetch_interior16=1;
      sfetch_want_req=1; sfetch_want_size=4; mem_req=1; mem_ack=1;
      #1;
      if (sfetch_demand_req!==1'b1 || sfetch_demand_size!==3'd4)
        $fatal(1,"SFETCH-BEAT-MISMATCH interior bubble/width");
      tick(); sfetch_want_req=0; #1;
      if (sfetch_demand_req!==1'b0)
        $fatal(1,"SFETCH-BEAT-MISMATCH interior stale owner");
      tick(); sfetch_interior16=0; mem_req=0; mem_ack=0; #1;
      if (sfetch_demand_req!==1'b0)
        $fatal(1,"SFETCH-BEAT-MISMATCH interior polluted boundary owner");
    end
    $display("SFETCH-INTERIOR-OK checks=12288 no_extra_clock=4096");
`endif
"""


def fixture(mode):
    namespace = dict(previous.__dict__, recipe=recipe)
    exec(compile(inspect.getsource(previous.fixture), previous.__file__, 'exec'), namespace)
    text = namespace['fixture'](mode)
    text = recipe.replace_once(text, '  reg clk=0, rst_n=0;',
                               '  reg clk=0, rst_n=0;\n  reg sfetch_interior16=0;')
    return recipe.replace_once(text, '    if (beats!=4096', INTERIOR_TEST+'    if (beats!=4096')


def main():
    assert sha(previous.__file__) == BASE_SHA
    # Remove our explicit profile selector before invoking the original parser.
    profile = sys.argv.pop(1)
    assert profile in ('default','interior16')
    text = inspect.getsource(previous.main)
    text = recipe.replace_once(text, "Path(__file__), Path(recipe.__file__), HERE/'tb_sfetch_beat_stage.sv',",
        "Path(__file__), Path(recipe.__file__), Path(recipe.base.__file__), Path(previous.__file__), HERE/'tb_sfetch_beat_stage.sv',")
    text = recipe.replace_once(text,
        "command = ['/usr/bin/iverilog', '-g2012', '-s', 'tb', '-o', str(exe), str(sv)]",
        "command = ['/usr/bin/iverilog', '-g2012', '-s', 'tb', '-o', str(exe), *profile_defines, str(sv)]")
    text = recipe.replace_once(text, "assert passed, (mode, log)",
        "assert passed, (mode, log)\n            if profile_defines and mode == 'positive':\n                assert 'SFETCH-INTERIOR-OK checks=12288 no_extra_clock=4096' in log")
    namespace = dict(previous.__dict__, __file__=__file__, previous=previous, recipe=recipe,
                     fixture=fixture, profile_defines=['-DVEN_SFETCH16_DEMAND'] if profile=='interior16' else [])
    exec(compile(text,__file__,'exec'),namespace)
    return namespace['main']()


if __name__ == '__main__':
    raise SystemExit(main())
