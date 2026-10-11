"""Correct generic crossing-read masks on the private BUS timing predecessor.

Keep the payload-only timing cofactor, materialize legacy zero read strobes
using the architectural beat size, and select the current fragment owner.
No new state, latency, request permission, or write-strobe change is introduced.
Unfragmented legacy reads are deliberately unchanged by this correction.
"""
import prepare_fragment_read_payload as payload

DECL_OLD = '  logic [3:0]  fx_wstrb_q;'
DECL_NEW = '''  logic [3:0]  fx_wstrb_q;
  // Legacy generic producers leave read strobes zero (whole-word convention).
  // A page fragment MUST have explicit architectural byte enables; zero AND
  // a fragment mask remains zero and makes the L1 overread the next page.
  // Materialize before both first-fragment shaping and second-fragment capture.
  // Writes, including real zero-strobe writes, retain their original enables.
  logic [3:0]  fx_read_strb;
  assign fx_read_strb = (bd_wstrb == 4'd0)
                     ? ((4'b1 << cur_size) - 4'b1) : bd_wstrb;'''
SAVE_OLD = '      fx_wstrb_q <= bd_wstrb;'
SAVE_NEW = '      fx_wstrb_q <= bd_we ? bd_wstrb : fx_read_strb;'
MASK_OLD = '                   : fx_rdfrag1_e ? (bd_wstrb & ((4\'b1 << (fx_act ? fx_first : fx_first_nat)) - 4\'b1))'
MASK_NEW = '''                   // An aborted owner cannot supply the new beat's count.
                   : fx_rdfrag1_e ? (fx_read_strb & ((4'b1 << (fx_eng ? fx_first : fx_first_nat)) - 4'b1))'''
EDITS = ((DECL_OLD, DECL_NEW), (SAVE_OLD, SAVE_NEW), (MASK_OLD, MASK_NEW))
SEQ_START = '  // the engine sequencer.'
SEQ_END = '  // Architectural crossing test for the CURRENT S_LOAD access'
L1_START = '  logic [2:0]  byp_sz;'
L1_END = '  logic          bypass_q;'


def transform(core, bus):
    changed = payload.transform(core, bus)
    for before, after in EDITS:
        if changed.count(before) != 1:
            raise ValueError('fragment exact-read anchor drift')
        changed = changed.replace(before, after)
    restored = changed
    for before, after in reversed(EDITS):
        restored = restored.replace(after, before)
    if restored.replace(payload.NEW, payload.OLD) != core:
        raise ValueError('non-reversible exact-read correction')
    return changed


def between(source, start, end):
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError('ambiguous source extraction')
    return source[source.index(start):source.index(end)]


def engine(core):
    state, output = payload.blocks(core)
    decl = between(core, '  logic        fx_act;', '  // the states with their own')
    # Abort belongs to the producer FSM, represented by a test input here.
    decl = decl.replace('  logic        fx_abort_q;', '')
    merge = between(core, '  logic [31:0] fx_merged;', SEQ_START)
    return decl+state+'  logic fx_probing;\n'+merge+between(core, SEQ_START, SEQ_END)+output
