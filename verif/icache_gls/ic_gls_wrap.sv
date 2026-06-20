// verif/icache_gls/ic_gls_wrap.sv — scalar-port wrapper around icache so the OOC
// funcsim netlist keeps a clean, non-flattened interface (the raw icache has 2D/3D
// array outputs ic_tag_o/ic_val_o/ic_victim_o that synth flattens/optimizes, breaking
// TB instantiation). Touch/snoop ports tied off; the array mirrors are XOR-folded into
// one `mirror_keep` output so synth can't optimize the line store away.
module ic_gls_wrap (
  input  logic        clk, rst_n,
  input  logic [6:0]  rd_setA, input logic rd_wayA, output logic [255:0] rd_lineA,
  input  logic [6:0]  rd_setB, input logic rd_wayB, output logic [255:0] rd_lineB,
  output logic        rd_collA, rd_collB,
  input  logic        fill_en, input logic [6:0] fill_set, input logic fill_way,
  input  logic [4:0]  fill_off, input logic [31:0] fill_data,
  input  logic        fill_done, input logic [19:0] fill_tag,
  output logic        mirror_keep
);
  logic [19:0] tag_o [128][2];
  logic        val_o [128][2];
  logic        vic_o [128];
  icache dut(.clk,.rst_n,.rd_setA,.rd_wayA,.rd_lineA,.rd_setB,.rd_wayB,.rd_lineB,
    .rd_collA,.rd_collB,.ic_tag_o(tag_o),.ic_val_o(val_o),.ic_victim_o(vic_o),
    .fill_en,.fill_set,.fill_way,.fill_off,.fill_data,.fill_done,.fill_tag,
    .tch0_en(1'b0),.tch0_set('0),.tch0_tag('0),
    .tch1_en(1'b0),.tch1_set('0),.tch1_tag('0),
    .tch2_en(1'b0),.tch2_set('0),.tch2_tag('0),
    .snoop_inv_valid(1'b0),.snoop_inv_addr('0));
  always_comb begin
    mirror_keep = 1'b0;
    for (int s=0;s<128;s++) begin
      mirror_keep ^= vic_o[s];
      for (int w=0;w<2;w++) mirror_keep ^= (^tag_o[s][w]) ^ val_o[s][w];
    end
  end
endmodule
