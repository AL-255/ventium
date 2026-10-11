"""Isolated paired-response read-commit cut on the exact raw-prime core.

Never change architectural pipe_int_commit. Preserve the original consumer
for profiles whose different V-owner invariant has not been established.
"""
import hashlib
import re

CORE = '8ef0079de0a0f9eba1f48533f590e0908b96fbaea9ff64030183a5e3e0416ec0'


def assignment(source, name, contains):
    rows = [row for row in re.findall(r'  assign '+name+r' = .*?;\n', source, re.S)
            if contains in row]
    if len(rows) != 1:
        raise ValueError('ambiguous assignment '+name)
    return rows[0]


def replacement(core):
    old = assignment(core, 'mem_pair_rsp_ready', '!pipe_mem_v_hit_q')
    commit = assignment(core, 'pipe_int_commit', 'fsm_case_enabled')
    if commit.count('!pipe_mem_wait') != 1 or old.count('pipe_int_commit') != 1:
        raise ValueError('paired-response guard drift')
    read = commit.replace('pipe_int_commit =', 'pair_readonly_int_commit =').replace(
        '!pipe_mem_wait', '!pipe_store_req && (!pipe_load_req || mem_read_ack)')
    changed = old.replace('pipe_int_commit', 'pair_readonly_int_commit')
    witness = '''`ifndef SYNTHESIS
  logic [1:0] pair_rsp_ready_before_read_cut;
'''+old.replace('mem_pair_rsp_ready =', 'pair_rsp_ready_before_read_cut =')+'''
  always_ff @(posedge clk) if (rst_n) begin
    assert (!pipe_mem_v_hit_q || (pipe_mem_active_q && !pipe_mem_we_q))
      else $fatal(1,"PAIR-RESPONSE-COMMIT: V lost its read-only U owner");
    assert (mem_pair_rsp_ready === pair_rsp_ready_before_read_cut)
      else $fatal(1,"PAIR-RESPONSE-COMMIT: response consumption changed");
  end
`endif
'''
    return '''`ifdef VEN_RAW_V_READ_PRIME
`ifndef VEN_P54_DUAL_LOAD_PRIME
  // In this profile only a fresh U/V read creates a V owner. It is held
  // alongside that admitted read, never an unrelated store. Keep orphan
  // draining independent of commit, and keep the final-fragment qualifier.
  // Architectural retirement and all response-slot state remain unchanged.
  logic pair_readonly_int_commit;
'''+read+changed+witness+'''`else
  // Dual-load/register-memory priming has a different owner contract.
'''+old+'''`endif
`else
'''+old+'''`endif
'''


def transform(core):
    if hashlib.sha256(core.encode()).hexdigest() != CORE:
        raise ValueError('paired-response predecessor drift')
    old = assignment(core, 'mem_pair_rsp_ready', '!pipe_mem_v_hit_q')
    return core.replace(old, replacement(core))
