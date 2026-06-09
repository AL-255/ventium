// Auto-generated from qemu-8.2.2 fpu_helper.c fpatan_table[9] + coeffs. DO NOT EDIT.
// floatx80 = {se[15:0], frac[63:0]}. atan c-table high/low + 7 odd coeffs + pi consts.
localparam logic [79:0] FA_HI [0:8] = '{
  {16'h0000,64'h0000000000000000},
  {16'h3ffb,64'hfeadd4d5617b6e33},
  {16'h3ffc,64'hfadbafc96406eb15},
  {16'h3ffd,64'hb7b0ca0f26f78474},
  {16'h3ffd,64'hed63382b0dda7b45},
  {16'h3ffe,64'h8f005d5ef7f59f9b},
  {16'h3ffe,64'ha4bc7d1934f70924},
  {16'h3ffe,64'hb8053e2bc2319e74},
  {16'h3ffe,64'hc90fdaa22168c235}
};
localparam logic [79:0] FA_LO [0:8] = '{
  {16'h0000,64'h0000000000000000},
  {16'hbfb9,64'hdda19d8305ddc420},
  {16'h3fbb,64'hdb8f3debef442fcc},
  {16'hbfbc,64'heab9bdba460376fa},
  {16'h3fbc,64'hdfc88bd978751a06},
  {16'h3fbd,64'hb906bc2ccb886e90},
  {16'h3fbb,64'hcd43f9522bed64f8},
  {16'hbfbc,64'hd3496ab7bd6eef0c},
  {16'hbfbc,64'hece675d1fc8f8cbc}
};
localparam logic [79:0] FA_C0 = {16'h3fff,64'h8000000000000000};
localparam logic [79:0] FA_C1 = {16'hbffd,64'haaaaaaaaaaaaaa43};
localparam logic [79:0] FA_C2 = {16'h3ffc,64'hccccccccccbfe4f8};
localparam logic [79:0] FA_C3 = {16'hbffc,64'h92492491fbab2e66};
localparam logic [79:0] FA_C4 = {16'h3ffb,64'he38e372881ea1e0b};
localparam logic [79:0] FA_C5 = {16'hbffb,64'hba2c0104bbdd0615};
localparam logic [79:0] FA_C6 = {16'h3ffb,64'h9baf7ebf898b42ef};
localparam logic [14:0] FA_PI_EXP = 15'h4000;
localparam logic [63:0] FA_PI_H = 64'hc90fdaa22168c234;
localparam logic [63:0] FA_PI_L = 64'hc4c6628b80dc1cd1;
localparam logic [14:0] FA_PI2_EXP = 15'h3fff;
localparam logic [63:0] FA_PI2_H = 64'hc90fdaa22168c234;
localparam logic [63:0] FA_PI2_L = 64'hc4c6628b80dc1cd1;
localparam logic [14:0] FA_PI4_EXP = 15'h3ffe;
localparam logic [63:0] FA_PI4_H = 64'hc90fdaa22168c234;
localparam logic [63:0] FA_PI4_L = 64'hc4c6628b80dc1cd1;
localparam logic [14:0] FA_PI34_EXP = 15'h4000;
localparam logic [63:0] FA_PI34_H = 64'h96cbe3f9990e91a7;
localparam logic [63:0] FA_PI34_L = 64'h9394c9e8a0a5159d;
