"""Remove the legacy write-ACK cone from read-bank ownership qualification.

This prepares only a private derivative of the pinned readiness candidate.
The actual ACK, bank arbitration and response-owner state are unchanged.
"""
import hashlib
import re

PARENT = '1d8a499aff0093a0861b20ec9faefee0820672cefe42d47504cd53f9ef71277b'
LOOKUP_PATTERN = r'  assign pair_lookup_active = .*?;\n'
OVERLAP_START = '`ifdef VEN_L1D_COMB_ACK\n  // The cosim-only'
OVERLAP_END = '  assign pair_lookup_active = '

OWNED = """  // This predicate is used only below the idle, non-stream, non-flush,
  // non-snoop bank-lookup guard. A cacheable current read with rd_match
  // necessarily ACKs there. Do not route the unrelated backing-write ACK
  // mux back into read-bank arbitration. The real c_ack is unchanged.
  logic pair_legacy_bank_owned;
`ifdef VEN_L1D_COMB_ACK
  assign pair_legacy_bank_owned = 1'b0;
`else
  assign pair_legacy_bank_owned = c_req && !c_we && rd_match && cacheable
`ifdef VEN_P54_DUAL_LOAD_PAIR
      // A V-only request behind an already-ACKing U has no retained U owner.
      && (pair_req_valid != 2'b10)
`endif
      ;
`endif
"""


def extract_lookup(source):
    matches = re.findall(LOOKUP_PATTERN, source, re.S)
    if len(matches) != 1:
        raise ValueError('ambiguous paired bank lookup')
    return matches[0]


def witness(original):
    return ("`ifndef SYNTHESIS\n  logic pair_lookup_before_ack_cut;\n" +
            original.replace('assign pair_lookup_active =',
                             'assign pair_lookup_before_ack_cut =') +
            '  always_ff @(posedge clk) if (rst_n)\n' +
            '    assert (pair_lookup_active === pair_lookup_before_ack_cut)\n' +
            '      else $fatal(1, "PAIR-OVERLAP-ACK: changed bank ownership");\n' +
            '`endif\n')


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('paired-overlap predecessor drift')
    original = extract_lookup(source)
    if original.count('pair_legacy_overlap') != 1:
        raise ValueError('legacy overlap consumer drift')
    for guard in ('(st == L1_IDLE)', '!stream_path', '!flush_all',
                  '!snoop_inv_valid', '!golden'):
        if guard not in original:
            raise ValueError('bank-ownership guard drift')
    updated = original.replace('pair_legacy_overlap', 'pair_legacy_bank_owned')
    return source.replace(original, OWNED + updated + witness(original))
