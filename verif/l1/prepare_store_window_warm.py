#!/usr/bin/env python3
"""Warm existing read storage from a committed resident single-store line."""
import argparse,hashlib,json
from pathlib import Path
FLAG='VEN_L1D_STORE_WINDOW_WARM'
TARGET='rtl/mem/ven_l1d.sv'
DECL='''
`ifdef VEN_L1D_STORE_WINDOW_WARM
  // One ordinary U store, already ACKed. Its existing asynchronous bank
  // read addresses select exactly the written resident set/way. Do not steal
  // a dual-read bank, follow a speculative lookup, or allocate on a miss.
  wire store_window_warm = bank_store_we && window_update_u_safe &&
      (|c_wstrb) && !c_pair_req && !early_armed &&
      !flush_all && !snoop_inv_valid && !code_access &&
      !(|pair_req_ready) &&
      (!window_valid_q || c_addr[31:5] != rd_addr_q[31:5]) &&
      (!shadow_valid_q || c_addr[31:5] != shadow_line_addr_q);
`endif
'''
WARM='''`ifdef VEN_L1D_STORE_WINDOW_WARM
      // The RAM is read-before-write. Merge exactly the actual committed
      // bank bytes so the newly saved line is the architectural AFTER image.
      // No extra storage or cache/RAM port; this replaces an existing owner.
      if (store_window_warm) begin
        if (window_valid_q) begin
          shadow_line_q <= rd_window_q[LW-1:0];
          shadow_line_addr_q <= rd_addr_q[31:5];
          shadow_valid_q <= 1'b1;
        end
        rd_window_q[LW-1:0] <= rd_line_raw;
        for (int bank=0; bank<WORDS; bank++)
          for (int byte_lane=0; byte_lane<4; byte_lane++)
            if (window_store_mask[bank][byte_lane])
              rd_window_q[32*bank+8*byte_lane +: 8] <=
                  window_store_data[bank][8*byte_lane +: 8];
        rd_addr_q <= c_addr;
        rd_code_q <= 1'b0;
        window_valid_q <= 1'b1;
        // rd_armed is NOT set. This is not an accepted read/response owner.
      end
`ifndef SYNTHESIS
      if (store_window_warm)
        assert (!do_rd_cap && !mc_capture_next && !bank_fill_we && !bank_pair_store_we)
          else $fatal(1,"store warm collided with another RAM/read owner");
`endif
`endif
'''
def transform(text):
    if FLAG in text or 'VEN_L1D_WINDOW_WRITE_UPDATE' not in text:
        raise ValueError('requires coherent-write parent, not already applied')
    for old,new in (
        ('  logic window_valid_q;','  logic window_valid_q;'+DECL),
        ('      // All window writers participate; invalidation wins over capture.',
         WARM+'      // All window writers participate; invalidation wins over capture.')):
        assert text.count(old)==1,old
        text=text.replace(old,new)
    guard='`ifdef '+FLAG+'\n'
    for flag in ('VEN_L1D_WINDOW_WRITE_UPDATE','VEN_P54_DUAL_HIT','VEN_L1D_CODE_BUFFER'):
        guard+='`ifndef '+flag+'\n  initial $fatal(1,"store warm requires '+flag+'");\n`endif\n'
    guard+='`endif\n'
    assert text.count('endmodule')==1
    return text.replace('endmodule',guard+'endmodule')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();raw=a.source.read_bytes();changed=transform(raw.decode()).encode()
    assert a.source.resolve()!=a.out.resolve()
    with a.out.open('xb') as f:f.write(changed)
    assert a.source.read_bytes()==raw
    print(json.dumps(dict(source_sha256=hashlib.sha256(raw).hexdigest(),
        candidate_sha256=hashlib.sha256(changed).hexdigest(),production_changed=False)))
