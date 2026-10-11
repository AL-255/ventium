"""Remove the general write ACK from read-only successor-hint commit.

Private exact-parent recipe. Architectural pipe_int_commit is untouched;
only the existing read-lookahead side effect uses its read-only cofactor.
"""
import hashlib
import re

CORE = '8ef0079de0a0f9eba1f48533f590e0908b96fbaea9ff64030183a5e3e0416ec0'
HEADER = 'e044fcd954b5c2a0f0151e5e83198833faeffa875a776f17bb388fb2e21614cc'


def assignment(source, name):
    matches = re.findall(r'  assign '+name+r' = .*?;\n', source, re.S)
    if len(matches) != 1:
        raise ValueError('ambiguous assignment '+name)
    return matches[0]


def transform(core, header):
    for text, expected in ((core, CORE), (header, HEADER)):
        if hashlib.sha256(text.encode()).hexdigest() != expected:
            raise ValueError('read-only commit predecessor drift')
    commit = assignment(core, 'pipe_int_commit')
    old = assignment(header, 'mem_next_commit')
    if commit.count('!pipe_mem_wait') != 1 or old.count('pipe_int_commit') != 1:
        raise ValueError('commit guard drift')
    # No writes can use read ACK. The hint's integer producers are either
    # unpaired reads or a non-memory packet; an FP self-prime instead uses
    # fp_shared_mem_admit. Keep every original issue/fault/stall predicate.
    cofactor = commit.replace('pipe_int_commit =', 'mc_readonly_int_commit =').replace(
        '!pipe_mem_wait', '!pipe_store_req && (!pipe_load_req || mem_read_ack)')
    prefix = '''  // Read-only hint commit: avoid the unrelated backing-store ACK mux.
  // No architectural retirement, actual ACK, cache owner or cycle changes.
  logic mc_readonly_int_commit;
'''
    changed = old.replace('pipe_int_commit', 'mc_readonly_int_commit')
    witness = '''`ifndef SYNTHESIS
  logic mc_commit_before_read_cut;
'''+old.replace('mem_next_commit =', 'mc_commit_before_read_cut =')+'''
  always_ff @(posedge clk) if (rst_n)
    assert (mem_next_commit === mc_commit_before_read_cut)
      else $fatal(1,"MC-READ-COMMIT: hint commit changed");
`endif
'''
    return header.replace(old, prefix+cofactor+changed+witness)
