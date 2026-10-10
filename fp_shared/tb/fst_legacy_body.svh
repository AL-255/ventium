// Included by a generated shell declaring the actual writeback port types.
// Unit inputs are architectural readback, not full-core debugger deposits.
int checks = 0;
int failures = 0;
task automatic check_case(input bit fast, input int top, input int index,
                          input bit pop, input bit empty_source,
                          input bit empty_destination, input bit masked,
                          input bit seed);
  bit commit_ok;
  logic [15:0] want_status;
  logic [15:0] observed_status;
  logic [79:0] want_data;
  bit bad;
  state = fast ? S_PIPE : S_FEXEC;
  pipe_fp_live_arm = fast;
  u_d = '0;
  u_d.is_fp = fast;
  u_d.fp_kind = FK_FSTP0;
  q_fxop = FX_FST_STI;
  q_f_sti = 3'(index);
  q_f_pop = pop;
  ftop = 3'(top);
  fctrl = masked ? 16'h037f : 16'h037e;
  fstat = 16'h4520 | (seed ? 16'h0200 : 16'h0000);
  fptag = 0;
  fptag[top] = empty_source;
  fptag[(top+index)&7] = empty_destination;
  // fp_st[] is the real module's TOP-relative read port, fptag is physical.
  for (int i=0; i<8; i++) fp_st[i] = {16'h4002,64'h8000000000000000+64'(i)};
  #1;
  commit_ok = !empty_source || masked;
  want_status = 16'h4520 | (empty_source ? 16'h0041 : 16'h0000);
  want_data = empty_source ? 80'hffffc000000000000000 : fp_st[0];
  // fpu_top only consumes fp_fstat_wval when fp_we_fstat is asserted.
  // An unchanged architectural status need not generate a redundant write;
  // never compare an unselected port's default-zero payload with the state.
  observed_status = fp_we_fstat ? fp_fstat_wval : fstat;
  bad = fp_stk_ovf || (fp_stk_unf != empty_source) ||
        observed_status != want_status ||
        fp_we_pop != (pop && commit_ok) || fp_we_pop2 ||
        fp_we_sti != (!fast && commit_ok) || fp_we_top || fp_we_push ||
        fp_we_fxch || fp_we_wabs || fp_we_envregs || fp_we_envld || fp_we_fninit;
  if (!fast && commit_ok)
    bad |= fp_wsti_idx != 3'(index) || fp_wsti_data != want_data || !fp_wsti_clr_tag;
  checks++;
  if (bad) begin
    failures++;
    if (failures <= 8)
      $display("FST_LEGACY_MISMATCH fast=%0d top=%0d i=%0d pop=%0d src=%0d dst=%0d mask=%0d seed=%0d sw=%04x want=%04x we_sw=%0d unf=%0d sti=%0d popout=%0d",
               fast,top,index,pop,empty_source,empty_destination,masked,seed,
               observed_status,want_status,fp_we_fstat,fp_stk_unf,fp_we_sti,fp_we_pop);
  end
endtask

initial begin
  // GENERATED_INPUT_DEFAULTS
  for (int top=0; top<8; top++)
    for (int index=0; index<8; index++)
      for (int pop=0; pop<2; pop++)
        for (int src=0; src<2; src++)
          for (int dst=0; dst<2; dst++)
            for (int mask=0; mask<2; mask++)
              for (int seed=0; seed<2; seed++)
                if (index!=0 || src==dst)
                  check_case(0,top,index,1'(pop),1'(src),1'(dst),1'(mask),1'(seed));
  for (int top=0; top<8; top++)
    for (int src=0; src<2; src++)
      for (int mask=0; mask<2; mask++)
        for (int seed=0; seed<2; seed++)
          check_case(1,top,0,1,1'(src),1'(src),1'(mask),1'(seed));
  // The same fast instruction must have no architectural writes when the
  // real spine does not admit its fast arm (interrupt/debug/frontend diversion).
  state=S_PIPE; pipe_fp_live_arm=0; #1;
  if (fp_we_pop || fp_we_sti || fp_we_fstat || fp_we_top || fp_we_push)
    $fatal(1,"unadmitted fast instruction changed architectural ports");
  assert(checks==1984) else $fatal(1,"matrix coverage");
  $display("FST_LEGACY_RESULTS cases=%0d failures=%0d",checks,failures);
  if (failures) $fatal(1,"FST legacy mismatches");
  $display("FST_LEGACY_OK");
  $finish;
end
