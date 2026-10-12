"""Prepare/run full-cache state/data checks for the private intent-ready cut.

Uses the existing guarded native lifecycle. It refuses a live Vivado and never
changes its frozen inputs. Six positive configurations retain full P5 geometry;
two deliberately broken implementations must fail natively.
"""
import ast
import hashlib
import itertools
import json
from pathlib import Path
import re

import run_parallel_tag_pairs as pair
import prove_pair_intent_ready as leaf
from run_parallel_tag_cache import sha

HERE = Path(__file__).resolve().parent
LIFECYCLE_SHA256 = '4b042e9f37202e1a8332f40dbba65ddcf17dd996e640cf529563fca5e1905ff8'


def admit_proof(proof):
    """Recheck native vectors and exact symbolic inputs/results, not just flags."""
    before=json.loads((proof/'started.json').read_text())
    done=json.loads((proof/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and done['checks']==3145728
    assert not done['candidate_rtl_changed'] and not done['hardware_acceptance']
    pins=dict(before['pins'])
    assert str(Path(leaf.__file__).resolve()) in pins
    assert all(sha(p)==h for p,h in pins.items())
    assert [r['profile'] for r in done['profiles']]==[
        ''.join(map(str,bits)) for bits in itertools.product((0,1),repeat=3)]
    for row in done['profiles']:
        assert [(r['phase'],r['native_exit']) for r in row['native']]==[
            ('compile',0),('simulate',0)]
        assert row['counts']['checks']==393216 and row['counts']['qualified']==327680
        assert row['counts']['ready']>0
        log=(proof/row['profile']/'simulate.log').read_text()
        expected='INTENT-READY-OK '+ ' '.join(f'{k}={row["counts"][k]}' for k in (
            'checks','qualified','ready','outside_difference'))
        assert expected in log and not re.search(r'FATAL|ERROR',log)
        pins.update(row['artifact_pins'])
    assignments=[n for n in ast.walk(ast.parse(Path(leaf.__file__).read_text()))
        if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='queries' for t in n.targets)]
    assert len(assignments)==1
    queries=ast.literal_eval(assignments[0].value)
    assert len(queries)==8 and len(done['queries'])==8
    for (name,formula,expected),row in zip(queries,done['queries']):
        assert row==dict(name=name,native_exit=0,result=expected)
        files=[proof/(name+suffix) for suffix in ('.smt2','.stdout','.stderr')]
        assert files[0].read_text()==leaf.symbolic()+'(assert '+formula+')\n(check-sat)\n'
        assert files[1].read_text().strip()==expected and not files[2].read_text()
        pins.update({str(p):sha(p) for p in files})
    for path in (proof/'started.json',proof/'closed.json'):
        pins[str(path)]=sha(path)
    assert all(sha(p)==h for p,h in pins.items())
    return pins


def replace(text, old, new, count=1):
    assert text.count(old) == count, old
    return text.replace(old, new)


def fixture(flat):
    text = pair.fixture((HERE/'tb_l1d_pair_store.sv').read_text(), flat)
    text = replace(text, '  ven_l1d #(.L1_SETS(128)) dut (',
        '''  ven_l1d #(.L1_SETS(128)) dut (
      .c_pair_intent(c_pair_req || explicit_intent),
      .c_pair_intent_ready(intent_only_ready),''')
    text = replace(text, '  control_l1d #(.L1_SETS(128)) control (',
        '''  control_l1d #(.L1_SETS(128)) control (
      .c_pair_intent(c_pair_req || explicit_intent),''')
    text = replace(text, "  logic clk = 1'b0, rst_n = 1'b0;", """  logic clk = 1'b0, rst_n = 1'b0;
  logic explicit_intent=0, next_hint=0, next_commit=0;
  logic [31:0] next_address=0;
  logic intent_only_ready;
  integer intent_qualified_samples=0;
""")
    text = replace(text, ".c_next_req(c_we), .c_next_commit(1'b1)",
        '.c_next_req(c_we || next_hint), .c_next_commit(next_commit)',2)
    text = replace(text, ".c_next_addr(c_addr ^ 32'h12345020)",
        ".c_next_addr(next_hint ? next_address : (c_addr ^ 32'h12345020))",2)
    extra='''    if (rst_n && (c_pair_req || explicit_intent)) begin
      intent_qualified_samples++;
      if (intent_only_ready !== control.c_pair_ready)
        $fatal(1,"INTENT-READY-MITER: qualified readiness changed");
    end
'''
    # Strengthen the inherited both-edge checks with every fill/response
    # payload owner and both saved lines. No hierarchical state writes.
    for name in ('fw','fset','fway','ftag','fbase','bypass_q',
                 'rd_window_q','rd_full_line_q'):
        extra += f'    if (dut.{name} !== control.{name}) $fatal(1,"INTENT-READY-MITER: state {name}");\n'
    extra += '''`ifdef VEN_L1D_TWO_WINDOW_REUSE
    if (dut.shadow_valid_q !== control.shadow_valid_q ||
        dut.shadow_line_addr_q !== control.shadow_line_addr_q ||
        dut.shadow_line_q !== control.shadow_line_q)
      $fatal(1,"INTENT-READY-MITER: shadow state");
`endif
'''
    text=replace(text,'    parallel_pair_checks++;',extra+'    parallel_pair_checks++;')
    cases=(HERE/'pair_intent_cases.svh').read_text()
    cases=replace(cases,"    compare_parent = 1'b0;",
        '    // Both models already implement intent arbitration: keep all A/B checks active.')
    anchor='      fail("dropping intent did not restore the existing hint arbitration");'
    cases=replace(cases,anchor,anchor+'''
    if (!intent_only_ready || c_pair_ack || m_req)
      fail("unqualified fast readiness was mistaken for an actual store grant");''')
    text=replace(text,'    if (errors == 0) $display("L1D-PAIR-STORE-GATE-OK");',
        cases+'''\n    if (intent_qualified_samples < 10)
      $fatal(1,"INTENT-READY-MITER: insufficient real intent traffic");
    $display("INTENT-READY-PAIRS-OK qualified_samples=%0d",intent_qualified_samples);
    if (errors == 0) $display("L1D-PAIR-STORE-GATE-OK");''')
    text=replace(text,'    $finish;',
        '    if (errors != 0) $fatal(1,"INTENT-READY-PAIRS-FAIL");\n    $finish;')
    assert 'compare_parent' not in text and not re.search(r'(?:force|release)\s+|dut\.\w+\s*<=',text)
    return text


def derive():
    original=HERE/'run_pair_intent_cache.py'
    text=original.read_text()
    if hashlib.sha256(text.encode()).hexdigest() != LIFECYCLE_SHA256:
        raise ValueError('intent-ready native lifecycle drift')
    # This import has no main side effects. The native lifecycle remains the
    # checked predecessor's; only source admission, fixtures and mutants vary.
    text=replace(text,'import prepare_pair_intent as recipe','import prepare_intent_ready_cut as recipe')
    start,end=text.index('def fixture(flat):'),text.index('def main():')
    text=text[:start]+text[end:]
    text=replace(text,"    ap.add_argument('--out', type=Path, required=True)",
        "    ap.add_argument('--out', type=Path, required=True)\n    ap.add_argument('--proof', type=Path, required=True)")
    anchor="    changed = recipe.transform(source,'rtl/mem/ven_l1d.sv')"
    text=replace(text,anchor,"""    core=parent.parent.parent/'core/core.sv'; seam=parent.with_name('ventium_l1_axi.sv')
    recipe.caller_contract(core.read_text(),seam.read_text())
    proof=args.proof.resolve(strict=True)
    proof_pins=admit_proof(proof)
    for path in (core,seam,original,REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh'):
        proof_pins[str(path)]=sha(path)
    assert all(sha(p)==h for p,h in proof_pins.items())
"""+anchor)
    text=replace(text,"    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID']))",
        "    pins.update(proof_pins)\n    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID']))")
    text=replace(text,"cases = [(f,w,False) for f in (False,True) for w in range(3)] + [(True,2,True)]",
        "cases = [(f,w,'') for f in (False,True) for w in range(3)] + [(True,2,'lookup'),(True,2,'credit')]")
    text=replace(text,'f\'{"wrong" if mutant else "positive"}-lut{int(flat)}-windows{windows}\'',
        'f\'{"wrong-"+mutant if mutant else "positive"}-lut{int(flat)}-windows{windows}\'')
    text=replace(text,"            if mutant:\n                assert actual.count('      !c_pair_intent &&') == 2",
        "            if mutant == 'lookup':\n                assert actual.count('      !c_pair_intent &&') == 2")
    anchor="                actual = actual.replace('      !c_pair_intent &&', \"      1'b1 &&\")"
    text=replace(text,anchor,anchor+'''
            elif mutant == 'credit':
                bodies=re.findall(r'  assign c_pair_intent_ready = .*?;\\n',actual,re.S)
                assert len(bodies)==1 and bodies[0].count('m_pair_ready')==2
                actual=actual.replace(bodies[0],bodies[0].replace('m_pair_ready',"1'b1"))''')
    text=replace(text,'import resource\n','import resource\nimport re\n')
    text=replace(text,"or 'PAIR-INTENT' in log)","or 'PAIR-INTENT' in log or 'INTENT-READY' in log)")
    text=replace(text,"                assert 'PARALLEL-PAIR-MITER checks=' in log",
        "                assert 'PARALLEL-PAIR-MITER checks=' in log\n                assert 'INTENT-READY-PAIRS-OK qualified_samples=' in log")
    ast.parse(text)
    return original,text


if __name__=='__main__':
    original,program=derive()
    exec(compile(program,str(__file__),'exec'),globals())
