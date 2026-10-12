"""Prepare a private early fetch-probe payload; retain all probe authority."""
import hashlib

PAYLOAD = 'rtl/core/core.sv'
PARENT = '552ad08f48da2833f7d299c37c9f73455f5cd08eafdbbc1fa129ccc10906c985'
OLD_KIND = '      S_DECODE: cur_is_d = !fetch_overlength_probe;\n'
NEW_KIND = '''      // DECODE has no data beat. Its optional translation is an I-side
      // overlength probe; fe_translatable retains the complete issue guard.
      S_DECODE: cur_is_d = 1'b0;
'''
OLD_ADDRESS = '''      S_DECODE: begin
        if (fetch_overlength_probe) begin
          cur_lin_nat = fetch_fault_page;
          cur_size = 4'd1;
        end
      end
'''
NEW_ADDRESS = '''      S_DECODE: begin
        // The first overrun endpoint is 16..31 bytes from flin. If its
        // page differs, it can only be the next page (including wrap).
        // Prepare that payload without decode/event qualification. The
        // original first-field crossing test still owns translation/faults.
        cur_lin_nat = {flin[31:12] + 20'd1, 12'd0};
        cur_size = 4'd1;
      end
'''
WITNESS = '''`ifndef SYNTHESIS
  // Idle DECODE payloads may differ; no bus/translation side effect may.
  always_ff @(posedge clk) if (rst_n && state == S_DECODE) begin
    assert (!bd_req && !cur_seg_rel && !cur_is_d)
      else $fatal(1, "FETCH-PROBE-PAYLOAD: unexpected DECODE access owner");
    assert (d_fetch_fault_len >= 5'd16)
      else $fatal(1, "FETCH-PROBE-PAYLOAD: endpoint range changed");
    if (fetch_overlength_probe) begin
      assert (cur_lin_nat === fetch_fault_page && cur_size == 4'd1)
        else $fatal(1, "FETCH-PROBE-PAYLOAD: active probe payload changed");
      if ($test$plusargs("ven_fetch_probe_payload_witness"))
        $display("[FETCH-PROBE-PAYLOAD] pc=%08x linear=%08x endpoint=%0d page=%08x",
                 eip, flin, d_fetch_fault_len, cur_lin_nat);
    end else begin
      assert (!fe_translatable && !xlate_miss && !perm_fault && !fe_xlate_pend)
        else $fatal(1, "FETCH-PROBE-PAYLOAD: inactive probe side effect");
    end
  end
`endif

'''
ANCHOR = '  // M2S.4 — byte offset into the 32-bit TSS of the privilege-N stack pointer pair\n'


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('fetch-probe predecessor drift/reapplication')
    for old in (OLD_KIND, OLD_ADDRESS, ANCHOR):
        if source.count(old) != 1:
            raise ValueError('fetch-probe ambiguous source anchor')
    return source.replace(OLD_KIND, NEW_KIND).replace(OLD_ADDRESS, NEW_ADDRESS).replace(
        ANCHOR, WITNESS + ANCHOR)
