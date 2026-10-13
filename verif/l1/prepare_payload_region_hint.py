"""Private two-file payload-only cache-map cofactor of INTENT-READY.

The aligned code-word predicate cannot cross a cache-map region. Keep the
complete access-extent query for every control consumer. Do not weaken a
saved response owner, change a clock, or add a latency/feature profile.
"""
import hashlib

PARENTS = {
    'rtl/mem/ven_l1d.sv': 'df7a426143baf6571d233a450fdc7c1eac17c946bd208b5334846b8fb255a29d',
    'rtl/mem/ventium_l1_axi.sv': '806e4392b97b983097278dbad3efa9f9dfae61bb6d9488955632e18e797c2b38',
}
CACHEMAP = 'de1c3037470d72f3a4422aa58b4fd12b9dd9ef329682d8480037f76950bd8aba'


def edits(name):
    if name == 'rtl/mem/ven_l1d.sv':
        port = '    input  logic        c_payload_code, // early kind; valid only on an acknowledged read'
        expr = '  wire code_payload_access = c_payload_code && cacheable && !golden &&'
        return [(port, port + '''
    // Equals cacheable on aligned word accesses; payload classification only.
    input  logic        c_payload_cacheable,'''),
            (expr, '''  // Alignment below confines every enabled byte to one map region.
  // The seam supplies its first-byte query; all ACK/capture/backing control
  // still consumes the original first-AND-last-byte cacheable input.
  wire code_payload_access = c_payload_code && c_payload_cacheable && !golden &&''')]
    if name == 'rtl/mem/ventium_l1_axi.sv':
        anchor = '  logic l1d_cacheable;'
        added = '''
`ifdef VEN_L1D_PAYLOAD_CODE_HINT
  logic l1d_payload_cacheable;
`ifdef VEN_L1_IGNORE_CD
  assign l1d_payload_cacheable = l1d_cacheable;
`else
  // Code payload selection already requires an aligned dword. Its last
  // byte is in the same 430FX map region as its first, for every strobe mask.
  // Do not route late read strobes through core_d_last and another map decode
  // merely to select already saved bytes. This is NOT read permission.
  // Preserve the separate L2 integration policy rather than guessing it.
  assign l1d_payload_cacheable = EN_L2 ? l1d_cacheable : (core_d_l1c && !cr0_cd);
`ifndef SYNTHESIS
  always_ff @(posedge core_clk) if (seam_core_rst_n && core_req &&
                                   (core_addr[1:0] == 2'b00))
    assert (l1d_payload_cacheable === l1d_cacheable)
      else $fatal(1,"PAYLOAD-REGION: aligned access changed cacheability");
`endif
`endif
`endif
'''
        port = '      .c_payload_code(core_payload_code),'
        return [(anchor, anchor + added),
                (port, port + '\n      .c_payload_cacheable(l1d_payload_cacheable),')]
    raise ValueError(name)


def transform(source, name):
    if name not in PARENTS or hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('payload-region source drift/reapplication: ' + name)
    result = source
    for old, new in edits(name):
        if result.count(old) != 1:
            raise ValueError('payload-region anchor drift: ' + old)
        result = result.replace(old, new)
    return result
