"""Shorten the late fetch-fault page calculation, without changing its value.

Private follow-on to the descriptor-width candidate. No request, state,
permission, exception priority, cycle, or decoder-width change. Even unused
zero-length inputs retain the original modulo-32-bit subtraction behavior.
"""
import hashlib

PARENT = '8ef0079de0a0f9eba1f48533f590e0908b96fbaea9ff64030183a5e3e0416ec0'
OLD = "  assign fetch_fault_page = {fetch_fault_linear[31:12],12'd0};"
NEW = '''  // The late decoded length affects only a 13-bit page-offset sum.
  // Prepare both neighbouring page numbers in parallel, including 32-bit
  // wrap and the zero-length/offset-zero underflow of the original expression.
  logic [12:0] fetch_fault_end;
  logic [19:0] fetch_fault_next_page, fetch_fault_prev_page;
  logic fetch_fault_before_page, fetch_fault_after_page;
  assign fetch_fault_end = {1'b0,flin[11:0]} + {8'd0,d_fetch_fault_len};
  assign fetch_fault_next_page = flin[31:12] + 20'd1;
  assign fetch_fault_prev_page = flin[31:12] - 20'd1;
  assign fetch_fault_before_page = (fetch_fault_end == 13'd0);
  assign fetch_fault_after_page = (fetch_fault_end > 13'd4096);
  assign fetch_fault_page = {fetch_fault_before_page ? fetch_fault_prev_page :
                            fetch_fault_after_page ? fetch_fault_next_page :
                            flin[31:12],12'd0};'''
PROBE_OLD = '(fetch_fault_page[31:12] != flin[31:12]);'
PROBE_NEW = '(fetch_fault_before_page || fetch_fault_after_page);'


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('fetch page predecessor drift')
    if source.count(OLD) != 1 or source.count(PROBE_OLD) != 1:
        raise ValueError('fetch page anchor drift')
    changed = source.replace(OLD, NEW).replace(PROBE_OLD, PROBE_NEW)
    if changed.replace(NEW, OLD).replace(PROBE_NEW, PROBE_OLD) != source:
        raise ValueError('non-reversible fetch page delta')
    return changed
