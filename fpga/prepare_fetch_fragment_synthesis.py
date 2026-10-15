"""Bind unchanged guarded timing controllers to the proved fetch cofactor.

Prepare only. No route/deployment, no reference waiver, no resource-limit
relaxation. Parent and candidate remain comparable unplaced synthesis probes.
"""
import ast
import hashlib
from pathlib import Path

original_recipe = Path(__file__).with_name('prepare_prefix_opcode_synthesis.py')
source = original_recipe.read_text()
assert hashlib.sha256(source.encode()).hexdigest() == '54aab0238933c7614dfb6d8e86a56bbe1b542ca9259855b2df60144f30003480'
source = source.replace('prefix_opcode', 'fetch_fragment').replace('prefix-opcode', 'fetch-fragment')
leaf = '''leaf=load_proof('fetch-fragment-leaf-r5/closed.json')
assert sha(proof/'fetch-fragment-leaf-r5/closed.json')=='c521a2ef21d288398b6b70b3015a284b5e54615b4232ff366ba2fc1fcd07c11e'
assert leaf['passed'] and leaf['pins_unchanged'] and not leaf['errors']
assert leaf['profiles']==[dict(demand16=d,checks=8529920,mutants_failed=2) for d in (False,True)]
assert [r['result'] for r in leaf['proofs']]==['unsat','sat','sat','sat']
assert not leaf['whole_core'] and not leaf['hardware_acceptance'] and not leaf['standard_suite']
assert len(leaf['native'])==12
assert all(r['affinity']==[13,14,15,16] and r['actual_wait'] and r['reaped'] for r in leaf['native'])
pins.update(leaf['pins'])
for row in leaf['native']:
    assert sha(row['log'])==row['sha256']
    pins[row['log']]=row['sha256']
# Historical finite-CS failures remain open; this is not a repair or deployment.
boundary=load_proof('prefix-payload-boundary-r1/closed.json')
assert sha(proof/'prefix-payload-boundary-r1/closed.json')=='cae9437414fa4e47d43ea0081129838b5a3d085030ffbf0e77735a55628924a3'
assert not boundary['passed'] and boundary['errors']
'''
values = dict(
    MANIFEST='daa75aa75147262bef5001122ed533c74747fa6647e6d80fe4233a78939a3239',
    MODEL='a97035b6138624e3ccd89c7ce0eabac8d069e3957e71e430144aae770629d06d',
    CHANGES={'ventium/rtl/core/core.sv': '3a097b2e48a177c0e8b2155f6933ae5475e429c96d92da4b4bac5f84f31d6d67'},
    LEAF_PROOF=leaf)
tree = ast.parse(source)
lines = source.splitlines(keepends=True)
replaced = set()
for node in reversed(tree.body):
    if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
        name = node.targets[0].id
        if name in values:
            lines[node.lineno-1:node.end_lineno] = [name+' = '+repr(values[name])+'\n']
            replaced.add(name)
assert replaced == set(values)
source = ''.join(lines)
for old, new in (
    ('1f80a208437fd359c5c8dd078f68f1a632fa8df539043a0c646fb5d88f967c92',
     '3f7c8b21b0e4023f721413cbdb70d7e243a244d360e90081dc494eee42949131'),
    ('9e7be15bcf2f3771d82109bfafd398f2fe6e9ccf494f61a5e33a58c573511bc7',
     '30e322e3787563d693d223155e6294cf356a73e08b99bbfb8494f664bac41eee'),
    ('def derive(original):', 'def derive_templates(original):'),
    ('for path in (Path(__file__), Path(native.__file__),',
     'for path in (original_recipe, Path(__file__), Path(native.__file__),')):
    assert source.count(old) == 1, old
    source = source.replace(old, new)

WRAPPER = '''def derive(original):
    outputs=derive_templates(original)
    key='fetch-fragment-synthesis-r1/run.py'
    text=outputs[key]
    text=replace(text,"pc=load_proof('fetch-fragment-soc-r1/build-closed.json')",
        "tooling_deltas=native.tooling.qualify_tooling(pins)\\npc=load_proof('fetch-fragment-soc-r1/build-closed.json')")
    text=replace(text,"cmroot=root.parent/'fetch-fragment-soc-r1/coremark'",
        "cmroot=root.parent/'fetch-fragment-soc-r1/coremark-r2'")
    text=replace(text,"    candidate_gameplay_ipc=None,baseline_gameplay_ipc=",
        "    tooling_deltas=tooling_deltas, candidate_gameplay_ipc=None,baseline_gameplay_ipc=")
    text=span(text,'    rationale=','    generic_gate=',
        "    rationale='Boundary-fetch extent cofactor: page-clamped read-only beats cannot cross a page. Exact one-file core change; no cycle, register, request, strobe, address, cache or define change. Target the 36.591166892 MHz parent late fetch-size/fragment path. SMT inequality UNSAT, three SAT mutants, 17059840 source-extracted RTL vectors, full architectural/cycle replay, system/fetch/environment-fault checks and short CoreMark CRC clocks retained. Canonical and historical finite-CS failures remain open; diagnostic synthesis only.',\\n")
    text=replace(text,'Measure parallel prefix endpoint opcode selection; no route or deployment.',
        'Measure boundary-fetch fragment extent isolation; no route or deployment.')
    guarded(text,original['prefix-payload-synthesis-r1/run.py'])
    outputs[key]=text
    for name,text in outputs.items():
        if name.endswith('.py'): ast.parse(text,filename=name)
    return outputs


'''
assert source.count('def main():') == 1
source = source.replace('def main():', WRAPPER+'def main():')
exec(compile(source, str(__file__), 'exec'), globals())
