#!/usr/bin/env python3
"""Do not let primary-only store invalidation discard an unrelated shadow."""
import argparse,hashlib,json
from pathlib import Path

FLAG='VEN_L1D_INDEPENDENT_WINDOW_INVALIDATE'
OLD='''`ifdef VEN_L1D_TWO_WINDOW_REUSE
          shadow_valid_q <= 1'b0;
`endif
        end
`endif
      rd_armed <='''
NEW='''`ifdef VEN_L1D_TWO_WINDOW_REUSE
`ifdef VEN_L1D_INDEPENDENT_WINDOW_INVALIDATE
          // This outer block includes PRIMARY-only write overlap. The shadow
          // has its own U/V store-overlap checks above: do not erase an
          // unrelated physical line merely because the primary was written.
          // Global poison/read-miss conditions still cancel BOTH windows.
          if (flush_all || snoop_inv_valid || golden || stream_path ||
              (st != L1_IDLE) ||
              (c_req && (!cacheable || (!c_we && !rd_hit))))
            shadow_valid_q <= 1'b0;
`else
          shadow_valid_q <= 1'b0;
`endif
`endif
        end
`endif
      rd_armed <='''


def transform(text):
    if FLAG in text or text.count(OLD)!=1:
        raise ValueError('already applied or missing/ambiguous invalidation anchor')
    # Refuse variants lacking the independent shadow writer guards on which
    # this reduction relies. No store acceptance or data writer is changed.
    for anchor in ('`ifdef VEN_L1D_TWO_WINDOW_KEEP_STORE',
                   '(xline && (addr_n[31:5] == shadow_line_addr_q))',
                   '(c_pair_addr[31:5] == shadow_line_addr_q)',
                   '// All window writers participate; invalidation wins over capture.'):
        if anchor not in text:raise ValueError('missing existing shadow guard: '+anchor)
    text=text.replace(OLD,NEW)
    guard='''`ifdef VEN_L1D_INDEPENDENT_WINDOW_INVALIDATE
`ifndef VEN_L1D_WINDOW_KEEP_STORE
  initial $fatal(1,"independent window invalidation requires primary store guards");
`endif
`ifndef VEN_L1D_TWO_WINDOW_KEEP_STORE
  initial $fatal(1,"independent window invalidation requires shadow store guards");
`endif
`ifndef VEN_L1D_TWO_WINDOW_REUSE
  initial $fatal(1,"independent window invalidation requires both window owners");
`endif
`endif
'''
    # Prerequisite checks belong at module scope, never inside the sequential
    # invalidation block. The module's end marker is unique in the source.
    end='endmodule'
    if text.count(end)!=1:raise ValueError('ambiguous module end')
    return text.replace(end,guard+end)


def prepare(source,out):
    source=source.resolve(strict=True);out=out.resolve()
    if source==out:raise ValueError('private output must differ')
    original=source.read_bytes();changed=transform(original.decode()).encode()
    with out.open('xb') as f:f.write(changed)
    assert source.read_bytes()==original
    return dict(source=str(source),source_sha256=hashlib.sha256(original).hexdigest(),
                candidate=str(out),candidate_sha256=hashlib.sha256(changed).hexdigest(),
                gameplay_ipc=None,standard_suite=False,production_changed=False)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();print(json.dumps(prepare(a.source,a.out),indent=2))
