"""Private integration-only next-read/pair arbitration cofactor.

Unlike CURRENT_U_ONLY, preserve the idle-port V admission used while the
logical U owner is waiting for its physical translation. Generic clients
retain the original next-read priority. The optimized client must never
offer a pair while the next-read lookup owns the cache port.
"""
import hashlib

from prepare_current_u_pair import PARENTS, OLD_LOOKUP, once

GUARDS = ('VEN_P54_DUAL_LOAD_PAIR', 'VEN_RAW_V_READ_PRIME')
EXCLUDES = ('VEN_P54_DUAL_LOAD_PRIME', 'VEN_P54_STORE_LOAD_PAIR')


def transform(source, name):
    if hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('pair/next disjoint predecessor drift/reapplication')
    if name == 'rtl/mem/ven_l1d.sv':
        source = once(source, '    parameter int L1_SETS = 128,',
            "    // Static client contract; generic arbitration is the default.\n"
            "    parameter bit PAIR_NEXT_DISJOINT = 1'b0,\n"
            '    parameter int L1_SETS = 128,')
        changed = OLD_LOOKUP.replace('!mc_lookup_next',
                                    '(PAIR_NEXT_DISJOINT || !mc_lookup_next)')
        source = once(source, OLD_LOOKUP,
            '  // The selected core cannot request a V load and a next-read\n'
            '  // lookup together. Keep idle admission: U may be in translation.\n'
            + changed)
        # Keep the previous exact old/new predicate assertion unconditional.
        # This extra assertion catches even a latent violation hidden by a
        # full response slot, a flush, or another admission veto.
        source = once(source, '  assign pair_bank_ready = pair_lookup_active ?\n',
            '''`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && PAIR_NEXT_DISJOINT && |pair_req_valid)
    assert (!mc_lookup_next)
      else $fatal(1, "PAIR-NEXT-DISJOINT: conflicting lookup clients");
`endif
  assign pair_bank_ready = pair_lookup_active ?
''')
        guard = '  initial begin\n    if (PAIR_NEXT_DISJOINT) begin\n'
        for flag in GUARDS:
            guard += f'`ifndef {flag}\n      $fatal(1, "PAIR-NEXT-DISJOINT requires {flag}");\n`endif\n'
        for flag in EXCLUDES:
            guard += f'`ifdef {flag}\n      $fatal(1, "PAIR-NEXT-DISJOINT excludes {flag}");\n`endif\n'
        guard += '    end\n  end\n'
        source = once(source, '  // REVIEW2 M-04: this module ADVERTISED',
                      guard + '  // REVIEW2 M-04: this module ADVERTISED')
    elif name == 'rtl/mem/ventium_l1_axi.sv':
        source = once(source, 'module ventium_l1_axi #(\n',
            "module ventium_l1_axi #(\n    parameter bit PAIR_NEXT_DISJOINT = 1'b0,\n")
        source = once(source,
            '  ven_l1d #(.L1_SETS(L1_SETS), .L1_LINE(L1_LINE)) u_l1d (',
            '  ven_l1d #(.L1_SETS(L1_SETS), .L1_LINE(L1_LINE),\n'
            '            .PAIR_NEXT_DISJOINT(PAIR_NEXT_DISJOINT)) u_l1d (')
    else:
        select = ''.join(f'`ifdef {flag}\n' for flag in GUARDS)
        select += ''.join(f'`ifndef {flag}\n' for flag in EXCLUDES)
        select += "                   .PAIR_NEXT_DISJOINT(1'b1),\n"
        select += '`endif\n' * (len(GUARDS) + len(EXCLUDES))
        source = once(source, '                   .LINE_REPLAY(AXI_LINE_REPLAY),\n',
            '                   .LINE_REPLAY(AXI_LINE_REPLAY),\n' + select)
    return source
