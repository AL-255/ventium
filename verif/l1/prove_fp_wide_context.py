"""Check source guards, then prove the FP-only next-port exclusion contract.

This is a source-checked Boolean over-approximation, not an automatic formal
elaboration of the complete SystemVerilog or a sequential ISA proof. Every
nonessential conjunct is unconstrained. The native leaf executes the actual
cache, seam and consumer expressions; native whole-core tests remain required.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

import prepare_fp_wide_context as recipe
import run_fp_wide_context_leaf as leaf_gate
from test_fp_high_valid_cofactor import sha


def clean(source):
    source = re.sub(r'/\*.*?\*/', '', source, flags=re.S)
    source = re.sub(r'//[^\n]*', '', source)
    return re.sub(r'^\s*`[^\n]*', '', source, flags=re.M)


def conjuncts(expression):
    """Split only top-level &&; reject unbalanced nesting and top-level OR."""
    depth = 0
    start = 0
    result = []
    i = 0
    while i < len(expression):
        char = expression[i]
        if char in '({[':
            depth += 1
        elif char in ')}]':
            depth -= 1
            assert depth >= 0
        if depth == 0:
            assert expression[i:i+2] != '||', 'top-level OR breaks domination'
            if expression[i:i+2] == '&&':
                result.append(expression[start:i].strip())
                i += 2
                start = i
                continue
        i += 1
    assert depth == 0
    result.append(expression[start:].strip())
    assert all(result)
    return result


def rhs(source, name):
    return [s.strip() for s in re.findall(r'\b'+name+r'\s*=\s*(.*?);', clean(source), re.S)]


def audit_guards(inputs):
    chain = inputs['rtl/core/core_mem_chain.svh']
    guards = {}
    for name, expected in (
        ('mc_boundary_ok', '(state == S_PIPE)'),
        ('mc_offer', 'mc_boundary_ok'), ('mc_prime_offer', 'mc_prepare_ok'),
    ):
        rows = rhs(chain, name)
        assert len(rows) == 1 and expected in conjuncts(rows[0]), name
        guards[name] = rows
    prepares = rhs(chain, 'mc_prepare_ok')
    assert len(prepares) == 3
    assert 'mc_boundary_ok' in conjuncts(prepares[0])
    assert conjuncts(prepares[1])[0] == 'mc_prepare_ok'
    assert prepares[2] == "1'b0"
    guards['mc_prepare_ok'] = prepares
    for name, path in (
        ('agi_prime_offer', 'rtl/core/core_agi_resident_prime.svh'),
        ('ref_prime_offer', 'rtl/core/core_ref_operand_prime.svh'),
    ):
        rows = rhs(inputs[path], name)
        assert len(rows) == 2 and rows[1] == "1'b0"
        assert 'mc_boundary_ok' in conjuncts(rows[0])
        guards[name] = rows
    offers = rhs(chain, 'mem_next_req')
    assert len(offers) == 1 and re.sub(r'\s', '', offers[0]) == (
        'agi_prime_offer||ref_prime_offer||mc_offer||mc_prime_offer')
    guards['mem_next_req'] = offers
    core = clean(inputs['rtl/core/core.sv'])
    enums = re.findall(r'typedef enum logic \[6:0\]\s*\{(.*?)\}', core, re.S)
    assert len(enums) == 1 and '=' not in enums[0]
    names = [s.strip() for s in enums[0].split(',') if s.strip()]
    assert len(names) == len(set(names)) <= 128
    assert all(re.fullmatch('S_[A-Z0-9_]+', n) for n in names)
    assert names.count('S_FLOAD') == names.count('S_PIPE') == 1
    guards['enum_states'] = names
    return guards


def formal(bypass=None):
    text = '(set-logic QF_BV)\n(declare-const state (_ BitVec 7))\n'
    for name in ('boundary_rest prepare_rest sys_allow prime_base offer_rest agi_rest ref_rest '
                 'chain pair_enabled pair_intent rd wide_common seam_common take_common '
                 'command_common narrow_ack').split():
        text += '(declare-const '+name+' Bool)\n'
    def term(name, value):
        nonlocal text
        text += '(define-fun '+name+' () Bool '+value+')\n'
    # Codes stand for two distinct enum elements, not their profile-specific
    # numeric encodings. All 128 states are otherwise unconstrained.
    term('fload', '(= state #b0000000)')
    term('pipe', '(= state #b0000001)')
    term('boundary', '(and pipe boundary_rest)')
    term('prepare', '(and boundary prepare_rest sys_allow)')
    for name, expression in (
        ('agi', '(and boundary agi_rest)'), ('ref', '(and boundary ref_rest)'),
        ('offer', '(and boundary offer_rest)'), ('prime', '(and prepare prime_base)'),
    ):
        term(name, 'true' if name == bypass else expression)
    term('next', '(and chain (or agi ref offer prime))')
    term('old_hi', '(and wide_common (or (and pair_enabled pair_intent) (not (and next rd))))')
    term('new_hi', 'wide_common')
    term('old_seam', '(and seam_common old_hi)')
    term('new_seam', '(and seam_common new_hi)')
    term('old_take', '(and fload take_common old_seam)')
    term('new_take', '(and fload take_common new_seam)')
    term('old_cmd', '(and fload command_common (or narrow_ack old_take))')
    term('new_cmd', '(and fload command_common (or narrow_ack new_take))')
    return text


def admit_leaf(root):
    prior = json.loads((root/'closed.json').read_text())
    assert prior['passed'] and prior['pins_unchanged'] and not prior['whole_core']
    assert not prior['hardware_acceptance'] and prior['assumes_consumer_state_exclusion']
    assert [(r['label'], r['native_exit']) for r in prior['rows']] == (
        [(name, 0) for name in leaf_gate.PROFILES]+[(name, 1) for name in leaf_gate.MUTANTS])
    pins = dict(prior['pins'])
    for row in prior['rows']:
        pins.update(row['artifacts'])
        assert (root/row['label']/'run.log').read_text() == row['log']
    pins[str(root/'closed.json')] = sha(root/'closed.json')
    assert all(sha(p) == h for p, h in pins.items())
    return pins


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for key in ('parent', 'leaf', 'out'):
        ap.add_argument('--'+key, type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root, parent = args.out.resolve(), args.parent.resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    pins = admit_leaf(args.leaf.resolve(strict=True))
    inputs = {p: (parent/p).read_text() for p in recipe.PARENTS | recipe.OFFER_PINS}
    recipe.validate_sources(inputs)
    guards = audit_guards(inputs)
    # Test the proof's source connection, not merely its Boolean solver.
    negative = []
    mutations = [('rtl/core/core_mem_chain.svh', '(state == S_PIPE)', "1'b1"),
                 ('rtl/core/core_mem_chain.svh', 'mc_valid_q && mc_boundary_ok', 'mc_valid_q'),
                 ('rtl/core/core_mem_chain.svh', 'mc_prime_base && mc_prepare_ok', 'mc_prime_base'),
                 ('rtl/core/core_mem_chain.svh', '!ref_prime_select && mc_boundary_ok', '!ref_prime_select'),
                 ('rtl/core/core_ref_operand_prime.svh', 'ref_prime_select && mc_boundary_ok', 'ref_prime_select'),
                 ('rtl/core/core_agi_resident_prime.svh', 'agi_prime_select && mc_boundary_ok', 'agi_prime_select')]
    for path, old, new in mutations:
        modified = dict(inputs)
        assert old in inputs[path]
        modified[path] = inputs[path].replace(old, new)
        try:
            audit_guards(modified)
        except AssertionError:
            negative.append(dict(path=path, removed=old, rejected=True))
        else:
            raise AssertionError('accepted lost state guard: '+old)
    for p in (Path(__file__).resolve(), Path(leaf_gate.__file__).resolve(),
              Path(recipe.__file__).resolve(), Path('/usr/bin/z3'),
              *(parent/p for p in inputs)):
        pins[str(p)] = sha(p)
    root.mkdir()
    (root/'guards.json').write_text(json.dumps(dict(guards=guards, negative=negative), indent=2)+'\n')
    pins[str(root/'guards.json')] = sha(root/'guards.json')
    cases = [
        ('fload-excludes-next', '(and fload next)', 'unsat', None),
        ('fload-wide-equivalence', '(and fload (not (= old_hi new_hi)))', 'unsat', None),
        ('fload-seam-equivalence', '(and fload (not (= old_seam new_seam)))', 'unsat', None),
        ('take-equivalence', '(not (= old_take new_take))', 'unsat', None),
        ('command-equivalence', '(not (= old_cmd new_cmd))', 'unsat', None),
        ('not-a-general-grant', '(and pipe (not (= old_hi new_hi)))', 'sat', None),
    ] + [('unguarded-'+offer, '(not (= old_take new_take))', 'sat', offer)
         for offer in ('agi', 'ref', 'offer', 'prime')]
    rows = []
    for name, assertion, expected, bypass in cases:
        query = root/(name+'.smt2')
        query.write_text(formal(bypass)+'(assert '+assertion+')\n(check-sat)\n')
        run = subprocess.run(['/usr/bin/z3', str(query)], text=True, capture_output=True, timeout=20)
        log = root/(name+'.log')
        log.write_text(run.stdout+run.stderr)
        assert run.returncode == 0 and run.stdout.strip() == expected, (name, run.stdout, run.stderr)
        rows.append(dict(name=name, answer=expected, native_exit=run.returncode,
                         artifacts={str(p): sha(p) for p in (query, log)}))
    assert all(sha(p) == h for p, h in pins.items())
    result = dict(passed=True, pins=pins, pins_unchanged=True, rows=rows,
                  source_guard_mutants=len(negative), abstract_combinational_contract=True,
                  whole_core=False, hardware_acceptance=False, gameplay_ipc=None, fmax_mhz=None)
    (root/'closed.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'pins'}), flush=True)


if __name__ == '__main__':
    main()
