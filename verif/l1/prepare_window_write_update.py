#!/usr/bin/env python3
"""Private coherent saved-window updates using the existing bank write masks."""
import argparse,hashlib,json
from pathlib import Path

FLAG='VEN_L1D_WINDOW_WRITE_UPDATE'
TARGET='rtl/mem/ven_l1d.sv'
DECLS='''
`ifdef VEN_L1D_WINDOW_WRITE_UPDATE
  // Reuse the ACTUAL bank writer's already rotated byte mask/data, including
  // its ordered U/V arbitration. These are wires, not another cache/port.
  logic [WORDS-1:0][3:0] window_store_mask;
  logic [WORDS-1:0][31:0] window_store_data;
  logic window_update_u_safe, window_update_v_safe;
  assign window_update_u_safe = cacheable && !golden && !stream_path &&
      !mc_lookup_next && (st == L1_IDLE) && hit && !xline &&
      !store_policy_drop_first;
  assign window_update_v_safe = cacheable && !golden && !stream_path &&
      !mc_lookup_next && (st == L1_IDLE) && store_pair_hit &&
      !store_pair_policy_drop;
`else
  wire window_update_u_safe = 1'b0;
  wire window_update_v_safe = 1'b0;
`endif
'''
BANK_WIRES='''
`ifdef VEN_L1D_WINDOW_WRITE_UPDATE
    assign window_store_mask[bank] = wr_mask;
    assign window_store_data[bank] = wr_data;
`endif
'''
UPDATE='''`ifdef VEN_L1D_WINDOW_WRITE_UPDATE
      // Preserve only existing full-line owners. A stalled/withdrawn store
      // never changes a byte: bank_*_store_we already includes actual ACK.
      // Cross-line, noncacheable, skipped-update and missed-tag stores keep
      // the old invalidation. Global poison above still wins VALID priority.
      for (int bank=0; bank<WORDS; bank++) begin
        for (int byte_lane=0; byte_lane<4; byte_lane++) begin
          if (window_store_mask[bank][byte_lane]) begin
            if (window_valid_q &&
                ((bank_pair_store_we && window_update_v_safe &&
                  c_pair_addr[4:2] == 3'(bank) &&
                  c_pair_addr[31:5] == rd_addr_q[31:5]) ||
                 (bank_store_we && window_update_u_safe &&
                  !(bank_pair_store_we && c_pair_addr[4:2] == 3'(bank)) &&
                  c_addr[31:5] == rd_addr_q[31:5])))
              rd_window_q[32*bank+8*byte_lane +: 8] <=
                  window_store_data[bank][8*byte_lane +: 8];
            if (shadow_valid_q &&
                ((bank_pair_store_we && window_update_v_safe &&
                  c_pair_addr[4:2] == 3'(bank) &&
                  c_pair_addr[31:5] == shadow_line_addr_q) ||
                 (bank_store_we && window_update_u_safe &&
                  !(bank_pair_store_we && c_pair_addr[4:2] == 3'(bank)) &&
                  c_addr[31:5] == shadow_line_addr_q)))
              shadow_line_q[32*bank+8*byte_lane +: 8] <=
                  window_store_data[bank][8*byte_lane +: 8];
          end
        end
      end
`ifndef SYNTHESIS
      if ((bank_store_we || bank_pair_store_we) && do_rd_cap)
        $fatal(1,"window store update collided with a new read owner");
`endif
`endif
'''

def transform(text):
    if FLAG in text or 'VEN_L1D_INDEPENDENT_WINDOW_INVALIDATE' not in text:
        raise ValueError('requires independent-window parent, not already applied')
    for anchor,replacement in (
        ('  logic window_valid_q;', '  logic window_valid_q;'+DECLS),
        ('    logic [IDXW:0] wr_row;\n    logic [4:0] line_byte;',
         '    logic [IDXW:0] wr_row;\n    logic [4:0] line_byte;'+BANK_WIRES),
        ('      rd_armed <= (do_rd_cap && !flush_all) ||',
         UPDATE+'      rd_armed <= (do_rd_cap && !flush_all) ||')):
        if text.count(anchor)!=1:raise ValueError('missing/ambiguous anchor: '+anchor)
        text=text.replace(anchor,replacement)
    begin=text.index('      // An unrelated store need not discard either complete resident window.')
    end=text.index('      rd_armed <=',begin)
    block=text[begin:end]
    # Match ONLY the invalidation comparisons, not demand reuse/owner queries.
    for expr,safe,count in (
        ('(c_addr[31:5] == shadow_line_addr_q)','window_update_u_safe',1),
        ('(c_pair_addr[31:5] == shadow_line_addr_q)','window_update_v_safe',2),
        ('(c_addr[31:5] == rd_addr_q[31:5])','window_update_u_safe',1),
        ('(c_pair_addr[31:5] == rd_addr_q[31:5])','window_update_v_safe',2)):
        if block.count(expr)!=count:raise ValueError('changed invalidation owner: '+expr)
        block=block.replace(expr,'('+expr+' && !'+safe+')')
    text=text[:begin]+block+text[end:]
    guards='`ifdef '+FLAG+'\n'
    for needed in ('VEN_L1D_BANKED_DATA','VEN_L1D_STORE_POLICY','VEN_P54_DUAL_STORE_PAIR',
                   'VEN_L1D_WINDOW_REUSE','VEN_L1D_TWO_WINDOW_REUSE',
                   'VEN_L1D_WINDOW_KEEP_STORE','VEN_L1D_TWO_WINDOW_KEEP_STORE',
                   'VEN_L1D_INDEPENDENT_WINDOW_INVALIDATE'):
        guards+='`ifndef '+needed+'\n  initial $fatal(1,"window write update requires '+needed+'");\n`endif\n'
    guards+='`endif\n'
    if text.count('endmodule')!=1:raise ValueError('ambiguous module end')
    return text.replace('endmodule',guards+'endmodule')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();src=a.source.resolve(strict=True);out=a.out.resolve()
    assert src!=out
    original=src.read_bytes();changed=transform(original.decode()).encode()
    with out.open('xb') as f:f.write(changed)
    assert src.read_bytes()==original
    print(json.dumps(dict(source=str(src),source_sha256=hashlib.sha256(original).hexdigest(),
        candidate=str(out),candidate_sha256=hashlib.sha256(changed).hexdigest(),
        gameplay_ipc=None,standard_suite=False,production_changed=False),indent=2))
