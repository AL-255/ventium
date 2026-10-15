  integer checks=0, mutant=0;
  logic [31:0] rng=32'hc4381a7d;
  function automatic logic [31:0] random_word();
    rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
    return rng;
  endfunction
  function automatic logic [7:0] prefix(input integer n);
    case (n%11)
      0:return 8'h66; 1:return 8'h67; 2:return 8'h2e;
      3:return 8'h36; 4:return 8'h3e; 5:return 8'h26;
      6:return 8'h64; 7:return 8'h65; 8:return 8'hf0;
      9:return 8'hf2; default:return 8'hf3;
    endcase
  endfunction
  task automatic fill(input integer count);
    logic [31:0] r;
    for (int n=0;n<16;n++) begin
      r=random_word();
      ibuf[n]=(n<count)?prefix(int'(r%11)):r[7:0];
    end
    for (int n=0;n<NUM_GPR;n++) gpr[n]=random_word();
    eflags=random_word(); r=random_word();
    {sys_mode,def16,seg_real,smm_active,paging_on,cosim_en,soc_en}=r[6:0];
  endtask
  task automatic sample();
    #1;
    check_outputs();
    checks++;
  endtask
  initial begin
    if ($value$plusargs("mutant=%d",mutant)) begin end
    // All prefix extents, each repeated prefix class, every opcode and all
    // valid counts (including fail-closed 17..31); input tails remain nonzero.
    for (int p=0;p<16;p++)
      for (int kind=0;kind<11;kind++)
        for (int op=0;op<256;op++) begin
          fill(p);
          for (int n=0;n<p;n++) ibuf[n]=prefix(kind);
          ibuf[p]=8'(op);
          for (int v=0;v<32;v++) begin
            ibuf_valid=5'(v); sample();
          end
        end
    // Every one-/two-byte opcode and ModR/M, both default sizes. Mixed prefixes
    // exercise last-REP/last-segment priority, though neither policy is changed.
    for (int two=0;two<2;two++)
      for (int mode16=0;mode16<2;mode16++)
        for (int op=0;op<256;op++)
          for (int m=0;m<256;m++) begin
            automatic integer p=(op+m)%13;
            fill(p); def16=1'(mode16); ibuf_valid=16;
            ibuf[p]=two?8'h0f:8'(op);
            if (two) ibuf[p+1]=8'(op);
            ibuf[p+1+two]=8'(m);
            sample();
          end
    // Random GPRs, mode combinations, SIB/displacements, permission extents,
    // missing metadata and long mixed prefix sequences.
    for (int n=0;n<1048576;n++) begin
      automatic logic [31:0] r=random_word();
      fill(int'(r[3:0])); ibuf_valid=r[8:4]; sample();
    end
    if (checks!=2752512) $fatal(1,"coverage count %0d",checks);
    $display("PREFIX-OPCODE-OK checks=%0d mutant=%0d",checks,mutant);
    $finish;
  end
