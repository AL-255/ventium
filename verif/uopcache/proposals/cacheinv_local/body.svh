  logic [7:0] reference_bytes [16], live_front [16], live_prefix [16];
  logic [4:0] fetch_valid;
  state_e state;
  logic recognized, original_go, proposed_go;
  longint unsigned cases=0, positives=0;
  logic [31:0] rng=32'h681fd527;
  localparam logic [7:0] PREFIXES[11]='{8'h66,8'h67,8'hf3,8'hf2,8'hf0,
      8'h2e,8'h36,8'h3e,8'h26,8'h64,8'h65};
  // Abstract each existing combinational gather by independent arbitrary
  // bytes. The full decoder remains the actual source under test. These are
  // the production mux's three mutually exclusive FSM selections; S_DECODE
  // always uses registered ibuf and all 16 bytes are valid in that state.
  always_comb begin
    for (int i=0;i<16;i++)
      reference_bytes[i]=(state==S_EXEC)?live_prefix[i]:
                         ((state==S_PIPE)?live_front[i]:ibuf[i]);
    ibuf_valid=(state==S_FETCH)?fetch_valid:5'd16;
  end
  ven_cacheinv_local candidate(.ibuf,.cosim_en,.soc_en,.recognized);
  assign original_go=d_cacheinv && (state==S_DECODE) && !d_unknown;
  assign proposed_go=recognized && (state==S_DECODE);

  function automatic logic [31:0] random32();
    rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
    return rng;
  endfunction
  task automatic check();
    #1;
    if (original_go !== proposed_go)
      $fatal(1,"CACHEINV-MISMATCH n=%0d state=%0d orig=%b new=%b bytes=%p mode=%b%b",
             cases,state,original_go,proposed_go,ibuf,cosim_en,soc_en);
    cases++;
    if (original_go) positives++;
  endtask
  task automatic flags(input int mode);
    cosim_en=1'(mode); soc_en=1'(mode>>1);
    sys_mode=1'(random32()); def16=1'(random32()); seg_real=1'(random32());
    smm_active=1'(random32()); paging_on=1'(random32()); eflags=random32();
    foreach (gpr[i]) gpr[i]=random32();
  endtask
  initial begin
    // GENERATED_INPUT_DEFAULTS
    state=S_DECODE; fetch_valid=0;
    foreach (live_front[i]) begin live_front[i]=8'(random32()); live_prefix[i]=8'(random32()); end
    // Every two-byte pattern, all platform enables. Bytes after the header
    // contain another INVD: it must not invalidate after a different opcode.
    for (int mode=0;mode<4;mode++) begin
      flags(mode);
      for (int word0=0;word0<65536;word0++) begin
        foreach (ibuf[i]) ibuf[i]=8'h90;
        ibuf[0]=8'(word0); ibuf[1]=8'(word0>>8); ibuf[2]=8'h0f; ibuf[3]=8'h08;
        check();
      end
    end
    // Every accepted prefix kind at every header offset, including byte16,
    // every second opcode, and all cosim/SoC combinations.
    for (int mode=0;mode<4;mode++) for (int n=0;n<15;n++)
      for (int prefix_kind=0;prefix_kind<11;prefix_kind++) begin
        flags(mode);
        foreach (ibuf[i]) ibuf[i]=((i<n)?PREFIXES[prefix_kind]:8'h90);
        ibuf[n]=8'h0f;
        for (int op=0;op<256;op++) begin ibuf[n+1]=8'(op); check(); end
      end
    // Mixed repeated prefixes; LOCK at each position. Qualify every possible
    // encoded state, including invalid state codes, against live cache bytes
    // that independently decode as valid invalidations.
    foreach (live_front[i]) begin live_front[i]=8'h66; live_prefix[i]=8'h67; end
    live_front[14]=8'h0f; live_front[15]=8'h08;
    live_prefix[14]=8'h0f; live_prefix[15]=8'h09;
    for (int n=0;n<15;n++) for (int lock_at=-1;lock_at<n;lock_at++)
      for (int op=8;op<=9;op++) for (int mode=0;mode<4;mode++) begin
        flags(mode);
        foreach (ibuf[i]) ibuf[i]=(i<n)?PREFIXES[(i+n)%11]:8'h90;
        for (int i=0;i<n;i++) if (ibuf[i]==8'hf0) ibuf[i]=8'hf3;
        if (lock_at>=0) ibuf[lock_at]=8'hf0;
        ibuf[n]=8'h0f; ibuf[n+1]=8'(op);
        for (int s=0;s<128;s++) begin
          state=state_e'(s); fetch_valid=5'(random32()); check();
        end
      end
    // Random complete windows and modes; intentionally bias half toward an
    // invalidation so positive coverage is not lost in uniform noise.
    for (int iteration=0;iteration<100000;iteration++) begin
      int n;
      flags(int'(random32())); state=(iteration%2==0)?S_DECODE:state_e'(7'(random32()));
      foreach (ibuf[i]) begin
        ibuf[i]=8'(random32()); live_front[i]=8'(random32()); live_prefix[i]=8'(random32());
      end
      if (iteration%2==0) begin
        n=int'(random32()%15);
        for (int i=0;i<n;i++) ibuf[i]=PREFIXES[random32()%11];
        ibuf[n]=8'h0f; ibuf[n+1]=(iteration%4==0)?8'h08:8'h09;
      end
      check();
    end
    if (cases<650000 || positives<1000) $fatal(1,"insufficient exercised cases");
    $display("CACHEINV-LOCAL-OK cases=%0d positives=%0d",cases,positives);
    $finish;
  end
