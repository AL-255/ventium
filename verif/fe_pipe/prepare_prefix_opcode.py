"""Exact-source opcode selector factoring; no opcode/fetch-policy changes."""
import hashlib

FILE = 'rtl/core/decode_stages.sv'
PARENT = 'e961f42125090b880ec06cddd1c9d2414af2f0a458e3fb008d39325b2b085292'
OLD = """    op0=ibuf_known[pfx_len];
    two_byte=(op0==8'h0F);
    op1=ibuf_known[pfx_len+5'd1];
"""
ANCHOR = '  // M2S.1: EFFECTIVE operand/address size (moved VERBATIM from core.sv).'
NEW = """  // Select the opcode bytes directly from the contiguous-prefix endpoint.
  // Avoid encoding pfx_len before two variable byte muxes. The one-hot endpoint
  // includes 15: byte16 remains an opcode candidate, never a 16th prefix.
  // Keep ibuf_known masking, including invalid counts and the zero byte17.
  logic [15:0] prefix_opcode_end;
  assign prefix_opcode_end[0] = !prefix_contig_mask[0];
  for (genvar n=1; n<15; n++) begin : g_opcode_endpoint
    assign prefix_opcode_end[n] = prefix_contig_mask[n-1] && !prefix_contig_mask[n];
  end
  assign prefix_opcode_end[15] = prefix_contig_mask[14];
  for (genvar bitno=0; bitno<8; bitno++) begin : g_opcode_bit
    wire [15:0] first_byte, second_byte;
    for (genvar n=0; n<16; n++) begin : g_opcode_byte
      assign first_byte[n] = prefix_opcode_end[n] && ibuf_known[n][bitno];
      assign second_byte[n] = prefix_opcode_end[n] && ibuf_known[n+1][bitno];
    end
    assign op0[bitno] = |first_byte;
    assign op1[bitno] = |second_byte;
  end
  assign two_byte = (op0==8'h0F);

"""


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('decoder source drift or reapplication')
    if source.count(OLD) != 1 or source.count(ANCHOR) != 1:
        raise ValueError('opcode selector anchors changed')
    return source.replace(OLD, '').replace(ANCHOR, NEW + ANCHOR)


def identity_smt(mutant=False):
    """All 16 input bytes and all 32 valid counts, two-state selector proof."""
    lines = ['(set-logic QF_BV)', '(declare-const valid (_ BitVec 5))']
    prefixes = (0x66, 0x67, 0x2e, 0x36, 0x3e, 0x26, 0x64, 0x65, 0xf0, 0xf2, 0xf3)
    for i in range(16):
        lines += [f'(declare-const b{i} (_ BitVec 8))',
                  f'(define-fun k{i} () (_ BitVec 8) (ite (and (bvule valid #b10000) '
                  f'(bvugt valid (_ bv{i} 5))) b{i} #x00))']
        if i < 15:
            is_prefix = '(or ' + ' '.join(f'(= b{i} #x{x:02x})' for x in prefixes) + ')'
            previous = 'true' if i == 0 else f'c{i-1}'
            lines.append(f'(define-fun c{i} () Bool (and {previous} '
                         f'(bvule valid #b10000) (bvugt valid (_ bv{i} 5)) {is_prefix}))')
    lines.append('(define-fun k16 () (_ BitVec 8) #x00)')
    for i in range(16):
        end = '(not c0)' if i == 0 else 'c14' if i == 15 else f'(and c{i-1} (not c{i}))'
        if mutant and i == 15:
            end = 'false'
        lines.append(f'(define-fun e{i} () Bool {end})')
    diffs = []
    for offset in (0, 1):
        old = f'k{offset}'
        for i in range(1, 16):
            old = f'(ite c{i-1} k{i+offset} {old})'
        terms = [f'(ite e{i} k{i+offset} #x00)' for i in range(16)]
        new = terms[0]
        for term in terms[1:]:
            new = f'(bvor {new} {term})'
        diffs.append(f'(not (= {old} {new}))')
    lines += ['(assert (or ' + ' '.join(diffs) + '))', '(check-sat)']
    return '\n'.join(lines) + '\n'
