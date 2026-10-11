  localparam [1:0] L1_IDLE = 2'd0, L1_BYP = 2'd1;
  logic [1:0] st;
  logic c_req, c_we, rd_hit, flush_all, snoop_inv_valid, BYPASS_RD_EN;
  logic cacheable, window_reuse, shadow_reuse, code_word_reuse;
  logic early_match, rd_match, byp_match, stream_path;
  logic c_hit_stream, c_rsp_valid, c_rsp_ready;
  logic m_ack, c_pair_req, c_pair_ready, m_pair_ack;
  logic c_ack, c_read_ack, observed;
  bit mutant_write;
  integer checked = 0;

  // SOURCE_EXTRACTED_ACK_BLOCKS

  initial begin
    mutant_write = $test$plusargs("mutant_write");
    for (integer control = 0; control < (1 << 19); control++) begin
      {st, c_req, c_we, rd_hit, flush_all, snoop_inv_valid, BYPASS_RD_EN,
       cacheable, window_reuse, shadow_reuse, code_word_reuse, early_match,
       rd_match, byp_match, stream_path, c_hit_stream, c_rsp_valid,
       c_rsp_ready} = 19'(control);
      // Exhaust all read controls, under both extremal store-credit inputs.
      // The separate syntax test also rejects any store-credit dependency in
      // the read cofactor; these symbolic read-owner inputs are independent.
      for (integer backing = 0; backing < 2; backing++) begin
        {m_ack, c_pair_req, c_pair_ready, m_pair_ack} = backing ? 4'hf : 4'h0;
        #1;
        observed = mutant_write ? (c_read_ack || m_ack) : c_read_ack;
        if (!c_we && observed !== c_ack)
          $fatal(1, "FP_READ_ACK_EQ control=%0d backing=%0d old=%b new=%b",
                 control, backing, c_ack, observed);
        checked++;
      end
    end
    if (checked != 1048576) $fatal(1, "wrong sample count");
    $display("FP-READ-ACK-OK samples=%0d read_checked=524288", checked);
    $finish;
  end
