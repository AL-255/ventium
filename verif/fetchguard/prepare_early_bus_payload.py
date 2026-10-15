"""Select the canonical linear payload before physical-state overrides.

Exact-parent experiment. Remove the late translation-authority mux entirely;
do not change request authorization, translation, fault checks, or A20 order.
A simulation-only copy of the complete predecessor bus driver checks every
issued beat and every translated probe against the original equations.
"""
import hashlib
import re

import prepare_decode_bus_payload as predecessor

FILE = predecessor.FILE
PARENT = '4bb63e3a106284c1c1e07aa91f35bd72a8ac25475bd402c5eeb2b0f30a7d9426'
INITIAL = "    bd_req =1'b0; bd_we =1'b0; bd_addr =32'd0; bd_wdata =32'd0; bd_wstrb =4'd0;"
EARLY = INITIAL.replace("bd_addr =32'd0", 'bd_addr =cur_lin')
COMMENT = '''    // The default address is the canonical linear payload. Only the six
    // physical-by-definition states above override it. Translation authority
    // must NOT select this payload: its late DECODE probe qualification would
    // otherwise feed shared cache/AXI/writeback logic even without a request.
    // All request, page/segment fault, translation and A20 checks are unchanged.
'''
PHYSICAL = ('S_RMINT_RD', 'S_RMINT_PUSH', 'S_RMIRET', 'S_WALK', 'S_SMI_SAVE', 'S_RSM')
OUTPUTS = ('bd_req', 'bd_we', 'bd_addr', 'bd_wdata', 'bd_wstrb',
           'mem_addr_pre', 'mem_req_pre_sq', 'c02_xpage_hits')


def driver(source):
    marker = '  always_comb begin\n'+INITIAL
    if source.count(marker) != 1:
        raise ValueError('ambiguous complete bus driver')
    return source[source.index(marker):]


def physical_arms(source):
    """Audit the actual state arms containing an address assignment."""
    text = re.sub(r'//[^\n]*', '', driver(source))
    case = text.split('    unique case (state)\n', 1)[1].split('\n    endcase', 1)[0]
    arms = re.split(r'^      (?=S_[A-Z0-9_]+\s*:)', case, flags=re.M)[1:]
    return tuple(re.match(r'(S_\w+)\s*:', arm)[1] for arm in arms
                 if re.search(r'\bbd_addr\s*=', arm))


def shadow(source):
    body = driver(source)
    for name in OUTPUTS:
        body = re.sub(r'\b'+name+r'\b', 'bus_payload_ref_'+name, body)
    return '''
`ifndef SYNTHESIS
  // Verification only: retain the entire predecessor driver, not a hand-coded
  // approximation of its state/request table. No synthesized hardware added.
  logic bus_payload_ref_bd_req, bus_payload_ref_bd_we;
  logic bus_payload_ref_mem_req_pre_sq, bus_payload_ref_c02_xpage_hits;
  logic [31:0] bus_payload_ref_bd_addr, bus_payload_ref_bd_wdata;
  logic [31:0] bus_payload_ref_mem_addr_pre;
  logic [3:0] bus_payload_ref_bd_wstrb;
'''+body+'''
  always_ff @(posedge clk) if (rst_n) begin
    assert ({bd_req, bd_we, bd_wdata, bd_wstrb, mem_req_pre_sq, c02_xpage_hits}
            === {bus_payload_ref_bd_req, bus_payload_ref_bd_we,
                 bus_payload_ref_bd_wdata, bus_payload_ref_bd_wstrb,
                 bus_payload_ref_mem_req_pre_sq, bus_payload_ref_c02_xpage_hits})
      else $fatal(1, "EARLY-BUS-PAYLOAD: request/control changed state=%0d", state);
    if (bd_req || bus_payload_ref_bd_req || fe_translatable) begin
      assert (bd_addr === bus_payload_ref_bd_addr &&
              mem_addr_pre === bus_payload_ref_mem_addr_pre)
        else $fatal(1, "EARLY-BUS-PAYLOAD: consumed address changed state=%0d old=%h new=%h",
                    state, bus_payload_ref_bd_addr, bd_addr);
    end
  end
`endif
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('early-bus predecessor drift/reapplication')
    if physical_arms(source) != PHYSICAL:
        raise ValueError('physical address ownership changed')
    if source.count(INITIAL) != 1 or source.count(predecessor.NEW) != 1:
        raise ValueError('ambiguous payload cut')
    changed = source.replace(INITIAL, EARLY).replace(predecessor.NEW, COMMENT)
    # Audit the synthesized portion separately from the retained debug reference.
    if 'if (fe_translatable || state == S_DECODE) bd_addr = cur_lin;' in changed:
        raise ValueError('late selector survived')
    return changed+shadow(source)
