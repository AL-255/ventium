"""Fail closed if the actual core no longer has the miter's mux/state contract."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def canonical(text):
    return re.sub(r'\s+', '', re.sub(r'//[^\n]*', '', text))


def select_defines(text, defines):
    enabled, stack, result = True, [], []
    for line in text.splitlines():
        directive = re.fullmatch(r'\s*`(ifdef|ifndef|else|endif)(?:\s+(\w+))?\s*', line)
        if not directive:
            if line.lstrip().startswith('`'): raise ValueError('unreviewed preprocessor operation')
            if enabled: result.append(line)
            continue
        op, name = directive.groups()
        if op in {'ifdef', 'ifndef'}:
            if not name: raise ValueError('missing macro')
            condition = name in defines
            if op == 'ifndef': condition = not condition
            stack.append((enabled, condition, False)); enabled = enabled and condition
        elif op == 'else':
            if not stack or stack[-1][2]: raise ValueError('unmatched/repeated else')
            parent, condition, _ = stack[-1]
            stack[-1] = parent, condition, True; enabled = parent and not condition
        else:
            if not stack: raise ValueError('unmatched endif')
            enabled = stack.pop()[0]
    if stack: raise ValueError('unclosed conditional')
    return '\n'.join(result)


def audit(core, defines):
    required = {'VEN_PIPE_SDISPATCH', 'VEN_P54_PREFIX_EX_CHAIN', 'VEN_IC_PREFIX_SPAN', 'VEN_IC_BRAM'}
    if not required <= defines: raise ValueError('only the reviewed complete shared-gather profile')
    start = '  logic [7:0] refdecode_ibuf [IWORDS*4];'
    stop = '  decode_stages u_decode_stages ('
    if core.count(start) != 1 or core.count(stop) != 1:
        raise ValueError('ambiguous decoder mux')
    fragment = core.split(start)[1].split(stop)[0]
    # Include the enclosing VEN_PIPE_SDISPATCH condition omitted by the slice.
    actual = canonical(select_defines('`ifdef VEN_PIPE_SDISPATCH\n' + fragment, defines))
    expected = canonical('''
      always_comb begin
        for (int i=0; i<IWORDS*4; i++) begin
          if (state == S_EXEC) refdecode_ibuf[i] = ic_prefix_bytes[i];
          else refdecode_ibuf[i] = (state == S_PIPE) ? ic_front_bytes[i] : ibuf[i];
        end
      end
    ''')
    if actual != expected: raise ValueError('reference input mux differs from tested abstraction')
    patterns = [
        r'refdecode_valid\s*=\s*\(\(state == S_FETCH\) && sfetch_boundary\)\s*\? sfetch_valid_q : 5\'d16;',
        r'assign cache_inv_go = d_cacheinv && \(state == S_DECODE\) && !d_unknown;',
        r'localparam int IWORDS = 4;',
        r'logic \[7:0\]\s+ibuf \[16\];',
    ]
    for pattern in patterns:
        if len(re.findall(pattern, core)) != 1: raise ValueError('state/window/predicate contract drift')
    return dict(actual_state_mux_verified=True, decode_state_uses_registered_bytes=True,
                decode_state_valid_bytes=16, old_predicate_verified=True,
                two_state_equivalence_test_only=True, production_changed=False)


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--core', type=Path, required=True)
    p.add_argument('--defines', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    result = audit(a.core.read_text(), set(a.defines.read_text().split()))
    result['pins'] = {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in (a.core, a.defines, Path(__file__))}
    with a.out.open('x') as f: json.dump(result, f, indent=2)
    print(json.dumps(result))
