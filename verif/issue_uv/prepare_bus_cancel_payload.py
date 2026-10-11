"""Keep memory request cancellation independent of unused request payload.

Exact-source experiment only. No permit, fault, fragment, ACK or denied-read
equation is removed. Full downstream/whole-core tests remain mandatory.
"""
import hashlib

PARENT = '6bfa6c0e5f2e4e4e71535dd32c4334796e19facb60f7f97e488a617079587f8b'
PAGING_OLD = '''      if (xlate_miss || fe_xlate_pend || perm_fault) begin
        bd_req =1'b0; bd_we =1'b0; bd_addr =32'd0; bd_wdata =32'd0; bd_wstrb =4'd0;
      end else if (bd_req) begin
        bd_addr = mem_xlate(bd_addr, cur_is_d);
      end'''
PAGING_NEW = '''      // Payload may be prepared while the request is cancelled. Only
      // bd_req authorizes a beat; retain every miss/permission guard below.
      // Do not put those guards in front of the address/data selection cone.
      if (bd_req) bd_addr = mem_xlate(bd_addr, cur_is_d);
      if (xlate_miss || fe_xlate_pend || perm_fault) bd_req = 1'b0;'''
ACCESS_OLD = '''    if (sync_access_fault || rep_stos_stream_preissue_block ||
        rep_movs_stream_preissue_block) begin
      bd_req =1'b0; bd_we =1'b0; bd_addr =32'd0; bd_wdata =32'd0; bd_wstrb =4'd0;
    end'''
ACCESS_NEW = '''    if (sync_access_fault || rep_stos_stream_preissue_block ||
        rep_movs_stream_preissue_block) begin
      // A cancelled beat has no valid payload. Keep cancellation on VALID,
      // not on the shared direction/address/data/strobe muxes. This does NOT
      // authorize a faulting load/store or change the pre-squash observation.
      bd_req = 1'b0;
    end'''
A20_OLD = "    if (bd_req && !a20_on) bd_addr[20] = 1'b0;"
A20_NEW = "    if (!a20_on) bd_addr[20] = 1'b0;  // physical payload, even when invalid"
EDITS = ((PAGING_OLD, PAGING_NEW), (ACCESS_OLD, ACCESS_NEW), (A20_OLD, A20_NEW))
START = '    if (fe_translatable) bd_addr = cur_lin;'
END = "    if (fp_async_hold) bd_req = 1'b0;"


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('bus-driver parent drift')
    result = source
    for before, after in EDITS:
        if result.count(before) != 1:
            raise ValueError('missing/ambiguous cancellation anchor')
        result = result.replace(before, after)
    original = result
    for before, after in reversed(EDITS):
        original = original.replace(after, before)
    if original != source:
        raise ValueError('non-reversible payload edit')
    return result


def tail(source):
    if source.count(START) != 1 or source.count(END) != 1:
        raise ValueError('missing/ambiguous bus tail')
    begin = source.index(START)
    end = source.index(END, begin)+len(END)
    return source[begin:end]
