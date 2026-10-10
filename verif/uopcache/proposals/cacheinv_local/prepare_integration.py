"""Prepare a default-off core fragment from the very same tested leaf body.

No live source is changed by importing this recipe. A caller must use a fresh
private source tree and qualify its full-core/fetch/cache behavior separately.
"""
import re

from audit_source_contract import audit

FLAG = 'VEN_CACHEINV_LOCAL'
OLD = '  assign cache_inv_go = d_cacheinv && (state == S_DECODE) && !d_unknown;'


def transform(core, leaf, defines):
    audit(core, defines)
    if FLAG in core or 'core_cacheinv_local.svh' in core or core.count(OLD) != 1:
        raise ValueError('already applied or invalidation caller drift')
    prefix = '''module ven_cacheinv_local
  import ventium_decode_pkg::*;
(
    input logic [7:0] ibuf [16],
    input logic cosim_en, soc_en,
    output logic recognized
);
'''
    if leaf.count(prefix) != 1 or leaf.count('endmodule') != 1:
        raise ValueError('leaf ports/module shape changed')
    body = leaf.split(prefix)[1]
    if not body.endswith('endmodule\n'):
        raise ValueError('unexpected leaf trailer')
    body = body[:-len('endmodule\n')]
    if re.search(r'\b(always_ff|always_latch|initial|posedge|negedge)\b', body):
        raise ValueError('only a stateless combinational projection is admitted')
    # Mechanical local-symbol rename only; the tested expressions remain intact.
    rename = {'allowed_prefix': 'cinv_allowed_prefix', 'header_match': 'cinv_header_match',
              'recognized': 'cache_inv_local', 'g_header': 'g_cacheinv_local_header'}
    body = re.sub(r'\b(?:' + '|'.join(rename) + r')\b', lambda m: rename[m[0]], body)
    fragment = '// Generated from the same ven_cacheinv_local leaf body; no new state.\n'
    fragment += '  logic cache_inv_local;\n' + body
    new = ('`ifdef ' + FLAG + '\n'
           '  `include "core_cacheinv_local.svh"\n'
           '  assign cache_inv_go = cache_inv_local && (state == S_DECODE);\n'
           '`else\n' + OLD + '\n`endif')
    return core.replace(OLD, new), fragment
