"""Private next-step experiment: separate read-fragment payload from admission.

Apply only after the bus-cancellation payload change. No request, fault, walk,
sequencer or acknowledgement equation is changed. Whole-core qualification is
still required; a valid-request cofactor is not a complete system proof.
"""
import hashlib

CORE_PARENT = '43161919331feafca3ac1472d45b162ae54271a3be5a2d41237dc6220aec2174'
BUS_PARENT = 'e892403371c601c2e2c2660565fb8d4bf8ed7408efe3c0bf271015da63bf7ba1'
OLD = '  assign fx_rdfrag1_e = (fx_act && !fx_walk_hold && !fx_abort_q && !fx_wr && (fx_ph == 2\'d0)) || (fx_start && !bd_we);'
NEW = '''  // Payload-only start cofactor. On an issued read the unchanged bus
  // driver has already established mem_req_pre_sq and all late fault guards.
  // Invalid strobes need not wait for those guards. This does NOT engage the
  // engine: fx_start still exclusively owns its sequencer and ACK suppression.
  assign fx_rdfrag1_e = (fx_act && !fx_walk_hold && !fx_abort_q && !fx_wr && (fx_ph == 2'd0)) ||
      (fx_state_ok && paging_on && (!fx_act || fx_abort_q) && fx_cross && !bd_we);'''
STATE_START = '  logic fx_state_ok;'
STATE_END = '  // engine phase controls'
OUTPUT_START = '  logic        fx_eng, fx_wr_e;'
OUTPUT_END = '  assign fx_probing = fx_probe_e;'


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def transform(core, bus):
    if digest(core) != CORE_PARENT or digest(bus) != BUS_PARENT:
        raise ValueError('fragment payload source drift or missing bus predecessor')
    if core.count(OLD) != 1 or core.count('fx_rdfrag1_e') != 3:
        raise ValueError('read-fragment selector gained another consumer')
    candidate = core.replace(OLD, NEW)
    if candidate.replace(NEW, OLD) != core:
        raise ValueError('non-reversible fragment payload edit')
    return candidate


def blocks(core):
    """Exact combinational source used by the leaf; sequencer remains outside it."""
    for anchor in (STATE_START, STATE_END, OUTPUT_START, OUTPUT_END):
        if core.count(anchor) != 1:
            raise ValueError('missing/ambiguous fragment extraction anchor')
    return (core[core.index(STATE_START):core.index(STATE_END)],
            core[core.index(OUTPUT_START):core.index(OUTPUT_END)+len(OUTPUT_END)])
