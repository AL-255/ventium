#!/usr/bin/env python3
"""Preserve complete resident-line provenance across an unrelated fill."""
FLAG = 'VEN_FP_LOAD64_UNDER_FILL'
OWNER = '  logic            rd_full_line_q;'
CONTEXT = '''  logic            load64_resident_context;
  // No new data path or RAM port: the captured window already contains this
  // entire resident D line. Never widen a partial forward or the fill owner.
  assign load64_resident_context = (st == L1_IDLE)
`ifdef VEN_FP_LOAD64_UNDER_FILL
      || (fill_independent_hit && !fill_poison && !bypass_q
`ifdef VEN_L1D_CODE_BUFFER
          && !code_access
`endif
         )
`endif
      ;
`ifdef VEN_FP_LOAD64_UNDER_FILL
`ifndef VEN_L1D_HIT_UNDER_FILL
  initial $fatal(1, "wide resident responses require hit-under-fill");
`endif
`endif'''
SERVE = '      (st == L1_IDLE) && hit &&\n      ((rd_full_line_q'
CAPTURE = 'rd_full_line_q <= (st == L1_IDLE) && hit && !fill_forward_hit && !stream_path &&'


def transform(text):
    if FLAG in text:
        raise ValueError('already prepared wide-under-fill source')
    for anchor in (OWNER, SERVE, CAPTURE):
        if text.count(anchor) != 1:
            raise ValueError('missing or ambiguous wide-response anchor')
    return (text.replace(OWNER, OWNER + '\n' + CONTEXT)
            .replace(SERVE, '      load64_resident_context && hit &&\n      ((rd_full_line_q')
            .replace(CAPTURE, 'rd_full_line_q <= load64_resident_context && hit && !fill_forward_hit && !stream_path &&'))
