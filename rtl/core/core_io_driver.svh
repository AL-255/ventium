// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_io_driver.svh — RAW MODULE-SCOPE text `included by core.sv (R2
// modularization). NOT a standalone unit (no module wrapper): it is the M7.3b
// port-I/O bus-request driver `always_comb (io_req/io_we/io_addr/io_size/
// io_wdata for S_IO and S_INS), pasted verbatim at module scope at its original
// site, so the netlist is identical. Active only in S_IO/S_INS (cosim_en).
  // M7.3b port-I/O bus driver (separate combinational driver, mirrors mem_*).
  // Active ONLY in S_IO (which is only ever entered under cosim_en — see the
  // S_DECODE dispatch), so io_req is 0 every clock in every non-cosim run and the
  // bus is fully inert there. For an IN (q_io_write=0) the TB returns the golden
  // dev_in value on io_rdata; for an OUT (q_io_write=1) we drive AL/AX/eAX out on
  // io_wdata (width per q_io_w). The port is q_io_port (a physical I/O port — NOT
  // a linear address, so it is never translated).
  // ===========================================================================
  always_comb begin
    io_req   = 1'b0;
    io_we    = 1'b0;
    io_addr  = 16'd0;
    io_size  = 3'd1;
    io_wdata = 32'd0;
    if (state==S_IO) begin
      io_req   = 1'b1;
      io_we    = q_io_write;
      io_addr  = q_io_port;
      io_size  = q_io_w;
      // OUT drives the source eAX masked to the access width (the CPU's own datum).
      // OUTS (K_STR ST_OUTS per-element handshake) drives the [SI] element captured
      // in S_EXEC (ins_data, already width-masked) instead of eAX.
      io_wdata = (q_kind==K_STR)  ? ins_data :
                 (q_io_w==3'd1) ? {24'd0, gpr_o[R_EAX][7:0]}  :
                 (q_io_w==3'd2) ? {16'd0, gpr_o[R_EAX][15:0]} : gpr_o[R_EAX];
    end
    // M7.3c INS: each element issues an IN (read) from port DX (q_io_port). Suppress
    // the request on a degenerate REP INS with a zero count (no element -> no port read).
    //
    // REVIEW_Jul29 M-09: this used to test the FULL ECX, while the S_INS FSM
    // (core_io.svh:56-68) correctly counts in CX for address-size-16. With CX==0 but
    // ECX[31:16]!=0 the FSM recognised the degenerate instruction and performed no
    // store, yet io_req was still asserted — so a device saw a READ STROBE and could
    // consume FIFO/status state for an instruction that architecturally transfers
    // nothing. An input port read is a side effect that cannot be taken back.
    // Use the SAME predicate as the FSM.
    else if (state==S_INS &&
             !((q_rep||q_repne) &&
               (q_cnt16 ? (gpr_o[R_ECX][15:0]==16'd0) : (gpr_o[R_ECX]==32'd0)))) begin
      io_req   = 1'b1;
      io_we    = 1'b0;            // INS is always a port READ
      io_addr  = q_io_port;
      io_size  = q_io_w;
    end
  end
