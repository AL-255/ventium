// Source-extracted payload muxes, actual unmodified 430FX decoders.
// Arbitrary saved data/owners: equivalence here does not assume cache reachability.
module tb;
  logic c_req,c_we,c_code,c_payload_code,golden,stream_path;
  logic rd_armed,rd_code_q,early_armed,early_code_q,shadow_valid_q;
  logic [31:0] c_addr,rd_addr_q,early_addr_q,fbase,early_rdata_q;
  logic [31:5] shadow_line_addr_q;
  logic [3:0] c_wstrb,early_wstrb_q;
  logic [1:0] st;
  logic [511:0] rd_window_q;
  logic [255:0] shadow_line_q,code_line_q;
  logic [287:0] bp_line_x;
  logic [55:0] pam;
  logic [7:0] dramc,cc,tom_mb4,smram;
  logic smm_active,cr0_cd,snapshot,passthrough,ignore_cd;
  logic [2:0] hi;
  logic [31:0] last_addr;
  logic [1:0] first_l1,last_l1;
  wire cacheable = ignore_cd || (first_l1[snapshot] && last_l1[snapshot] && !cr0_cd);
  wire c_payload_cacheable = (ignore_cd || passthrough) ? cacheable :
      (first_l1[snapshot] && !cr0_cd);
  // The runner replaces this with the exact seam assignments, not a model.
  EXTENT_ASSIGNMENTS
  for (genvar snap=0;snap<2;snap++) begin : g_maps
    ven_cachemap #(.SNAPSHOT_USER_HIGHMEM(snap != 0)) first_byte (
        .addr(c_addr),.is_write(c_we),.is_code(1'b0),.smm_active,
        .pam,.dramc,.cc,.tom_mb4,.smram,.l1_cacheable(first_l1[snap]),
        .to_dram(),.l2_cacheable(),.region());
    ven_cachemap #(.SNAPSHOT_USER_HIGHMEM(snap != 0)) last_byte (
        .addr(last_addr),.is_write(c_we),.is_code(1'b0),.smm_active,
        .pam,.dramc,.cc,.tom_mb4,.smram,.l1_cacheable(last_l1[snap]),
        .to_dram(),.l2_cacheable(),.region());
  end
  wire [31:0] data[2],high[2];
  wire access_bit[2],rd[2],early[2],code_sel[2],shadow_sel[2],high_sel[2];
  INSTANCES

  function automatic logic [31:0] boundary(input int which);
    case (which % 12)
      0: return 32'h0008_0000;
      1: return 32'h000a_0000;
      2: return 32'h000c_0000;
      3: return 32'h000c_0000 + 32'((which/12)%16)*32'h4000;
      4: return 32'h000f_0000;
      5: return 32'h0010_0000;
      6: return 32'h00f0_0000;
      7: return 32'h0100_0000;
      8: return {2'd0,tom_mb4,22'd0};
      9: return 32'h4000_0000;
      10:return 32'hc000_0000;
      default:return 32'd0;
    endcase
  endfunction

  int differing_hint=0,code_n=0,shadow_n=0,early_n=0,stream_n=0,bypass_n=0,primary_n=0;
  initial begin
    for (int i=0;i<262144;i++) begin
      pam={$random,$random}; dramc=$random; cc=$random; smram=$random;
      tom_mb4=8'(i>>8);
      {c_req,c_we,c_code,c_payload_code,golden,stream_path,smm_active,
       rd_armed,rd_code_q,early_armed,early_code_q,shadow_valid_q}=$random;
      cr0_cd=i[6]; snapshot=i[7]; passthrough=(i[13:8]==6'h3f);
      ignore_cd=(i[13:8]==6'h3e);
      c_wstrb=i[3:0]; st=2'($random);
      c_addr=boundary(i>>8)-32'd4+{30'd0,i[5:4]};
      if (i[14]) c_addr=boundary(i>>8)+{30'd0,i[5:4]};
      if (i[15:14]==2'b11) c_addr=$random;
      rd_addr_q=i[16] ? c_addr : c_addr^32'h40;
      early_addr_q=i[17] ? c_addr : c_addr^32'h20;
      early_wstrb_q=i[11] ? c_wstrb : c_wstrb^4'hf;
      shadow_line_addr_q=i[12] ? c_addr[31:5] : c_addr[31:5]^27'h1;
      fbase=$random; early_rdata_q=$random;
      for (int b=0;b<16;b++) rd_window_q[b*32+:32]=$random;
      for (int b=0;b<8;b++) begin shadow_line_q[b*32+:32]=$random; code_line_q[b*32+:32]=$random; end
      for (int b=0;b<9;b++) bp_line_x[b*32+:32]=$random;
      #1;
      if ({access_bit[0],rd[0],early[0]} !== {access_bit[1],rd[1],early[1]})
        $fatal(1,"PAYLOAD-REGION-CONTROL i=%0d",i);
      // All clocks, not just ACK: no sequential ownership lemma is required.
      if (data[0] !== data[1] || high[0] !== high[1] ||
          {code_sel[0],shadow_sel[0],high_sel[0]} !== {code_sel[1],shadow_sel[1],high_sel[1]})
        $fatal(1,"PAYLOAD-REGION-DATA i=%0d addr=%h mask=%h cd=%b",i,c_addr,c_wstrb,cr0_cd);
      if (cacheable != c_payload_cacheable) differing_hint++;
      if (stream_path) stream_n++;
      else if (st==3) bypass_n++;
      else if (early[0]) early_n++;
      else if (code_sel[0]) code_n++;
      else if (shadow_sel[0]) shadow_n++;
      else primary_n++;
    end
    if (!(differing_hint>0 && code_n>0 && shadow_n>0 && early_n>0 &&
          stream_n>0 && bypass_n>0 && primary_n>0)) $fatal(1,"PAYLOAD-REGION-COVERAGE");
    $display("PAYLOAD-REGION-OK vectors=262144 differing_hint=%0d code=%0d shadow=%0d early=%0d stream=%0d bypass=%0d primary=%0d",
        differing_hint,code_n,shadow_n,early_n,stream_n,bypass_n,primary_n);
    $finish;
  end
endmodule
