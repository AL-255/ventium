"""Unpromoted fast-memory CS-extent cofactor of the frozen timing core.

The request already requires S_PIPE, no retained packet and every integer
pre-issue condition. At that consumer the global slow-DECODE fault arm cannot
contribute, eligibility is true, and the effective length is the live U length.
Keep the complete global fault/exception signal unchanged. No cycle or define
change; native RTL/core qualification and measured timing are still required.
"""
import hashlib
import re

PARENT = '7b6dcfe3c35b07bca3016c178cf81ebfb7cf104ea30d17e10b6f40b4c8a4506f'
# PRIME-COHERENCE retains the exact pre-issue, fault and request expressions.
# Its only core.sv delta from the original parent is the separately qualified
# FLOAD high-valid port/cofactor and its assertions (15 added / 1 removed lines).
# The three commit-cofactor headers are outside this file and remain unchanged.
PRIME_PARENT = '3d8aebbdf338a63ab86bb58a6fab2ebb43f0f280bdbd3626ff4710941a5983c6'
PARENTS = frozenset((PARENT, PRIME_PARENT))
DECL = '  logic        pipe_cs_issue_eligible;'
ANCHOR = '  // A CS-extent fault is a pre-issue check, not a second frontend consumer.'
ADDED = '''  // Payload-independent CS limit check for a NEW integer memory request.
  // Its consumer already implies S_PIPE, no held packet and all integer
  // pre-issue guards. Do not pull the unrelated S_DECODE length/fault cone
  // back through cache request qualification. The global fault signal below
  // remains unchanged and continues to own precise exception delivery.
`ifdef VEN_SEG_ENFORCE
  assign pipe_new_mem_cs_extent_fault = sys_mode && !real_mode && !v86
                  && seg_attr[SG_CS][7]
                  && (({1'b0, eip} + {28'd0, u_d.len} - 33'd1) >
                      {1'b0, seg_limit[SG_CS]});
`else
  assign pipe_new_mem_cs_extent_fault = 1'b0;
`endif

'''


def request(source, name):
    rows = re.findall(r'^    '+name+r'\s*=.*?;\n', source, re.M | re.S)
    if len(rows) != 1 or rows[0].count('!cs_extent_fault') != 1:
        raise ValueError('new-memory request anchor drift: '+name)
    return rows[0]


def edits(source):
    result = [(DECL, DECL+'\n  logic        pipe_new_mem_cs_extent_fault;'),
              (ANCHOR, ADDED+ANCHOR)]
    for name in ('pipe_new_load_req','pipe_new_store_req'):
        old = request(source, name)
        result.append((old, old.replace('!cs_extent_fault','!pipe_new_mem_cs_extent_fault')))
    # Simulation-only complete request comparisons, including rejected requests.
    # These do not merely check equality when the new request happens to fire.
    monitor = '`ifndef SYNTHESIS\n'
    for name in ('pipe_new_load_req','pipe_new_store_req'):
        ref = 'cs_reference_'+name
        monitor += '  wire '+ref+';\n'
        monitor += request(source,name).replace('    '+name, '  assign '+ref,1)
    monitor += '''  always_ff @(posedge clk) if (rst_n) begin
    assert (pipe_new_load_req === cs_reference_pipe_new_load_req)
      else $fatal(1,"PIPE-CS-EXTENT: new load admission changed");
    assert (pipe_new_store_req === cs_reference_pipe_new_store_req)
      else $fatal(1,"PIPE-CS-EXTENT: new store admission changed");
  end
`endif

'''
    result[1] = (ANCHOR, ADDED+monitor+ANCHOR)
    return result


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() not in PARENTS:
        raise ValueError('CS-extent source drift or reapplication')
    result = source
    for old,new in edits(source):
        if result.count(old) != 1:
            raise ValueError('CS-extent ambiguous/missing anchor')
        result = result.replace(old,new)
    return result
