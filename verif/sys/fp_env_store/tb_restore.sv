`timescale 1ns/1ps
`default_nettype none
module tb_restore;
  import ventium_decode_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic valid=0, ready, accept_retire, alu_retire, busy, rsp, unsupported, stack_fault;
  fxop_e op=FX_NONE;
  logic [2:0] sti=0;
  logic env16=0, real_format=0, update_ip=0, update_dp=0;
  logic [863:0] env_image=0, store_data;
  logic [79:0] mem=0;
  logic [31:0] in_ip=0, in_dp=0, ip, dp;
  logic [15:0] in_cs=0, in_ds=0, cs, ds, sw, cw, ax;
  logic [2:0] top;
  logic [7:0] tag, store_bytes;
  logic [639:0] phys, st;
  logic [84:0] arith;
  logic store_valid, ax_valid;
  int checked=0, stores=0;
  ven_fp_top dut (
    .clk(clk), .rst_n(rst_n), .cmd_valid(valid), .cmd_ready(ready),
    .cmd_accept_retire(accept_retire), .alu_commit_retire(alu_retire),
    .cmd_op(op), .cmd_aluop(3'd0), .cmd_sti(sti), .cmd_pop(1'b0),
    .cmd_constant(3'd0), .cmd_mem(mem), .cmd_mem_bytes(4'd10),
    .cmd_fdiv_bug(1'b0), .cmd_fist_bug(1'b0), .cmd_env16(env16),
    .cmd_real_mode(real_format), .cmd_env_image(env_image),
    .cmd_update_fip(update_ip), .cmd_fip(in_ip), .cmd_fcs(in_cs),
    .cmd_update_fdp(update_dp), .cmd_fdp(in_dp), .cmd_fds(in_ds),
    .busy(busy), .rsp_valid(rsp), .rsp_unsupported(unsupported),
    .rsp_stack_fault(stack_fault), .rsp_arith(arith),
    .rsp_store_valid(store_valid), .rsp_store_data(store_data),
    .rsp_store_bytes(store_bytes), .rsp_ax_valid(ax_valid), .rsp_ax(ax),
    .ftop_o(top), .fstat_o(sw), .fctrl_o(cw), .fptag_o(tag),
    .fpr_phys_flat_o(phys), .st_flat_o(st),
    .fip_o(ip), .fcs_o(cs), .fdp_o(dp), .fds_o(ds)
  );
  task automatic command(input fxop_e next_op);
    int waited;
    while (!ready) @(negedge clk);
    @(negedge clk); op=next_op; valid=1;
    @(negedge clk); valid=0;
    waited=0;
    while (!rsp && waited<100) begin @(negedge clk); waited++; end
    if (!rsp || unsupported || stack_fault) $fatal(1,"ENV-HANDSHAKE op=%0d",next_op);
  endtask
  task automatic put16(input int byte_offset, input logic [15:0] value);
    env_image[byte_offset*8 +: 16]=value;
  endtask
  task automatic put32(input int byte_offset, input logic [31:0] value);
    env_image[byte_offset*8 +: 32]=value;
  endtask
  initial begin
    logic [31:0] want_ip, want_dp;
    logic [15:0] want_cs, want_ds, want_cw, want_sw, ftw;
    logic [2:0] want_top;
    logic [7:0] want_tag;
    logic [639:0] before_phys, want_phys, want_st;
    logic [79:0] slot;
    logic [778:0] saved_state;
    logic [863:0] captured;
    logic [15:0] saved_ftw;
    logic [31:0] word16, word24;
    repeat (3) @(negedge clk); rst_n=1;
    for (int mode=0; mode<4; mode++) begin
      for (int full=0; full<2; full++) begin
        for (int sample=0; sample<128; sample++) begin
          update_ip=0; update_dp=0;
          command(FX_FNINIT);
          in_ip=32'h92713579; in_dp=32'habc24680; in_cs=16'h1357; in_ds=16'h2468;
          update_ip=1; update_dp=1; mem=80'h3fff8000000000000000;
          command(FX_FLD_M80);
          mem=80'h4000c000000000000000; command(FX_FLD_M80);
          if ({ip,dp,cs,ds} !== {in_ip,in_dp,in_cs,in_ds})
            $fatal(1,"ENV-NORMAL-POINTER regression");
          update_ip=0; update_dp=0; sti=1; command(FX_FXCH);
          before_phys=phys;
          env16=(mode&1)!=0; real_format=(mode&2)!=0;
          for (int word_index=0; word_index<27; word_index++)
            env_image[word_index*32 +: 32]=$urandom;
          want_ip=$urandom; want_dp=$urandom;
          want_cs=16'($urandom); want_ds=16'($urandom);
          if (env16) begin
            want_ip &= real_format ? 32'hfffff : 32'hffff;
            want_dp &= real_format ? 32'hfffff : 32'hffff;
          end
          want_top=3'(sample); want_tag=8'(sample*53);
          want_cw=16'h037f | (16'(sample&3)<<10);
          want_sw=(16'(want_top)<<11) | (16'($urandom)&16'h4700);
          ftw=0;
          for (int p=0; p<8; p++) ftw[p*2 +: 2]=want_tag[p] ? 2'b11 : 2'b00;
          put16(0,want_cw); put16(env16 ? 2 : 4,want_sw); put16(env16 ? 4 : 8,ftw);
          if (real_format) begin
            want_cs=0; want_ds=0;
            put16(env16 ? 6 : 12,want_ip[15:0]);
            put16(env16 ? 10 : 20,want_dp[15:0]);
            if (env16) begin
              put16(8,{want_ip[19:16],12'ha5b});
              put16(12,{want_dp[19:16],12'h876});
            end else begin
              put32(16,{4'hf,want_ip[31:16],12'ha5b});
              put32(24,{4'he,want_dp[31:16],12'h876});
            end
          end else if (env16) begin
            put16(6,want_ip[15:0]); put16(8,want_cs);
            put16(10,want_dp[15:0]); put16(12,want_ds);
          end else begin
            put32(12,want_ip); put16(16,want_cs);
            put32(20,want_dp); put16(24,want_ds);
          end
          want_phys=before_phys;
          for (int i=0; i<8; i++) begin
            slot={16'h4000,32'h80000000,32'(i*1009+sample)};
            env_image[(env16 ? 112 : 224)+i*80 +: 80]=slot;
            if (full!=0) want_phys[((i+int'(want_top))&7)*80 +: 80]=slot;
          end
          for (int i=0; i<8; i++)
            want_st[i*80 +: 80]=want_phys[((i+int'(want_top))&7)*80 +: 80];
          // No unaccepted command may change state. Live current-command
          // pointers are deliberately different from the saved environment.
          in_ip=~want_ip; in_dp=~want_dp; in_cs=~want_cs; in_ds=~want_ds;
          saved_state={ip,dp,cs,ds,top,sw,cw,tag,phys};
          op=full!=0 ? FX_FRSTOR : FX_FLDENV;
          repeat (3) begin
            @(negedge clk);
            if ({ip,dp,cs,ds,top,sw,cw,tag,phys}!==saved_state)
              $fatal(1,"ENV-EARLY-COMMIT");
          end
          command(full!=0 ? FX_FRSTOR : FX_FLDENV);
          if ({ip,dp,cs,ds} !== {want_ip,want_dp,want_cs,want_ds})
            $fatal(1,"ENV-POINTER mode=%0d full=%0d sample=%0d got=%h/%h/%h/%h want=%h/%h/%h/%h",
              mode,full,sample,ip,dp,cs,ds,want_ip,want_dp,want_cs,want_ds);
          if (top!==want_top || cw!==want_cw || tag!==want_tag ||
              sw!==(want_sw&16'hc7ff) || phys!==want_phys || st!==want_st)
            $fatal(1,"ENV-STATE mode=%0d full=%0d sample=%0d",mode,full,sample);
          // Decode and encode are checked independently. Exercise all four
          // input/output size combinations, both stores, and both loads.
          for (int out16=0; out16<2; out16++) begin
            for (int savefull=0; savefull<2; savefull++) begin
              env16=(mode&1)!=0;
              command(full!=0 ? FX_FRSTOR : FX_FLDENV);
              // FLDENV preserves registers; FNSAVE in the previous iteration
              // need not preserve them, so sample the defined current stack.
              want_st=st;
              saved_ftw=0;
              for (int p=0; p<8; p++) begin
                slot=phys[p*80 +: 80];
                if (tag[p]) saved_ftw[p*2 +: 2]=2'b11;
                else if (slot[78:0]==0) saved_ftw[p*2 +: 2]=2'b01;
                else if (slot[78:64]==0 || slot[78:64]==15'h7fff || !slot[63])
                  saved_ftw[p*2 +: 2]=2'b10;
                else saved_ftw[p*2 +: 2]=2'b00;
              end
              env16=(out16!=0);
              command(savefull!=0 ? FX_FNSAVE : FX_FNSTENV);
              captured=store_data;
              if (!store_valid || store_bytes!=
                  (savefull!=0 ? (out16!=0 ? 94 : 108) : (out16!=0 ? 14 : 28)))
                $fatal(1,"ENV-STORE handshake/extent");
              if (out16!=0) begin
                if (captured[15:0]!==want_cw || captured[31:16]!==want_sw ||
                    captured[47:32]!==saved_ftw || captured[63:48]!==want_ip[15:0] ||
                    captured[95:80]!==want_dp[15:0] ||
                    captured[79:64] !== (real_format ? {want_ip[19:16],12'd0} : want_cs) ||
                    captured[111:96] !== (real_format ? {want_dp[19:16],12'd0} : want_ds))
                  $fatal(1,"ENV-STORE16 mode=%0d full=%0d sample=%0d",mode,full,sample);
              end else begin
                word16=real_format ? {4'd0,want_ip[31:16],12'd0} : {16'd0,want_cs};
                word24=real_format ? {4'd0,want_dp[31:16],12'd0} : {16'd0,want_ds};
                if (captured[15:0]!==want_cw || captured[47:32]!==want_sw ||
                    captured[79:64]!==saved_ftw ||
                    captured[127:96] !== (real_format ? {16'd0,want_ip[15:0]} : want_ip) ||
                    captured[159:128]!==word16 ||
                    captured[191:160] !== (real_format ? {16'd0,want_dp[15:0]} : want_dp) ||
                    captured[223:192]!==word24)
                  $fatal(1,"ENV-STORE32 mode=%0d full=%0d sample=%0d",mode,full,sample);
              end
              if (savefull!=0 && captured[(out16!=0 ? 112 : 224) +: 640]!==want_st)
                $fatal(1,"ENV-STORE stack serialization");
              if (savefull==0 && {ip,dp,cs,ds} !== {want_ip,want_dp,want_cs,want_ds})
                $fatal(1,"ENV-STORE pointer side effect");
              // Registered payload must not follow changed live format inputs.
              env16=~env16; real_format=~real_format;
              @(negedge clk);
              if (store_data!==captured) $fatal(1,"ENV-STORE live output");
              real_format=~real_format;
              stores++;
            end
          end
          saved_state={ip,dp,cs,ds,top,sw,cw,tag,phys};
          env_image=~env_image; env16=~env16; real_format=~real_format;
          repeat (3) begin
            @(negedge clk);
            if ({ip,dp,cs,ds,top,sw,cw,tag,phys}!==saved_state)
              $fatal(1,"ENV-LIVE-BUS changed restored state");
          end
          checked++;
        end
      end
    end
    $display("FP-ENV-STORE-OK cases=%0d stores=%0d",checked,stores); $finish;
  end
  initial begin #20000000; $fatal(1,"ENV-TIMEOUT"); end
endmodule
`default_nettype wire
