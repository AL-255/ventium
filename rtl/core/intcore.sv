// core/intcore.sv — M1 single-issue, in-order, multi-cycle functional integer
// core (PLAN.md §7, docs/m1-core-spec.md).
//
// This replaces the M0 NOP stub with a REAL core that fetches IA-32 bytes from
// memory over the mem_* bus, decodes the M1 integer subset, executes one
// instruction at a time, and reports post-commit architectural state through
// the single vtm_retire DPI point in ventium_top.
//
// Structure (a coherent functional FSM, one instruction at a time):
//   S_RESET   -> latch init_eip / init_esp / reset arch state
//   S_FETCH   -> read a 16-byte instruction window at EIP (4 word reads over
//                the single-beat mem_* bus), assemble into ibuf[0..15]
//   S_DECODE  -> combinational length+operand decode of ibuf (see decode block)
//   S_LOAD    -> (if the instruction reads a memory source: pop / mov r32,r/m32
//                with a memory ModR/M) one word read of the effective address
//   S_EXEC    -> ALU / address / control evaluation, compute result + EFLAGS
//   S_STORE   -> (if the instruction writes memory: push / mov r/m32,r32 with a
//                memory ModR/M) one word write to the effective address
//   S_RETIRE  -> commit GPR/EFLAGS/EIP, raise retire_valid for one cycle so the
//                top-level DPI point fires with the POST-commit state
//   S_HALT    -> reached on int $0x80; stop retiring (TB stops on quiescence)
//
// Notes on scope: all operands are 32-bit (no operand-size prefix in the M1
// corpus). The decoder recognises 0x66/0x67/seg/F2/F3/0F prefixes structurally
// (it skips a single 0x0F for the two-byte Jcc form) but only fully executes the
// 32-bit forms in docs/m1-core-spec.md "Instruction set to implement".

module intcore
  import ventium_pkg::*;
#(
    // Segment selectors + EFLAGS reset value are constants in the M1 corpus
    // (docs/m1-core-spec.md "Initial architectural state"): the segments never
    // change, so the core just reports them. init_eip/init_esp arrive as ports.
    parameter logic [31:0] EFLAGS_RESET = 32'h0000_0202, // bit1 reserved-1 + IF
    parameter logic [15:0] SEG_CS = 16'h0023,
    parameter logic [15:0] SEG_SS = 16'h002b,
    parameter logic [15:0] SEG_DS = 16'h002b,
    parameter logic [15:0] SEG_ES = 16'h002b,
    parameter logic [15:0] SEG_FS = 16'h0000,
    parameter logic [15:0] SEG_GS = 16'h002b
) (
    input  logic        clk,
    input  logic        rst_n,         // active-low synchronous reset

    // Reset-time architectural init (driven by the TB during reset, §init).
    input  logic [31:0] init_eip,
    input  logic [31:0] init_esp,

    // Bus-functional-model port group (docs/rtl-interface.md §3).
    output logic        mem_req,
    output logic        mem_we,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wstrb,
    input  logic [31:0] mem_rdata,
    input  logic        mem_ack,

    // Retire interface to the top-level DPI point. retire_valid pulses for one
    // clock with the POST-commit architectural state of the just-committed insn.
    output logic        retire_valid,
    output logic [31:0] retire_pc,
    output arch_state_t retire_state
);

  // ===========================================================================
  // Architectural state
  // ===========================================================================
  logic [31:0] eip;
  logic [31:0] eflags;
  logic [31:0] gpr [NUM_GPR];   // eax ecx edx ebx esp ebp esi edi

  // ===========================================================================
  // FSM
  // ===========================================================================
  typedef enum logic [3:0] {
    S_RESET, S_FETCH, S_DECODE, S_LOAD, S_EXEC, S_STORE, S_RETIRE, S_HALT
  } state_e;
  state_e state;

  // Instruction window: 16 bytes fetched at EIP.
  localparam int IWORDS = 4;             // 4 * 4 = 16 bytes
  logic [7:0]  ibuf [16];
  logic [2:0]  fetch_word;               // which of the 4 words we are reading

  // ===========================================================================
  // Combinational decode of ibuf (only meaningful in S_DECODE and onward; the
  // decoded fields are latched into *_q at the DECODE->next transition).
  // ===========================================================================
  // Raw byte views.
  logic [7:0] b0, b1, b2, b3, b4, b5;
  assign b0 = ibuf[0];
  assign b1 = ibuf[1];
  assign b2 = ibuf[2];
  assign b3 = ibuf[3];
  assign b4 = ibuf[4];
  assign b5 = ibuf[5];

  // Decoder outputs (combinational).
  logic [3:0]  d_len;          // instruction length in bytes
  logic        d_halt;         // int $0x80 -> halt
  logic        d_unknown;      // opcode outside the implemented M1 subset
  logic        d_is_branch;    // Jcc / JMP
  logic        d_branch_taken; // condition satisfied (for Jcc) / always (JMP)
  logic [31:0] d_rel;          // sign-extended branch displacement
  logic [3:0]  d_alu_op;       // ALU operation selector (see ALU_* below)
  logic        d_writes_reg;   // result goes to a register
  logic        d_writes_flags; // updates EFLAGS
  logic        d_mem_read;     // EXEC needs a memory load (S_LOAD): mem operand
  logic        d_mem_write;    // EXEC needs a memory store (S_STORE)
  logic        d_mem_dst;      // the memory operand is the DESTINATION (RMW /
                               // store target), not an ALU source. Distinguishes
                               // `ALU r/m,r` (mem=dst) from `ALU r,r/m` (mem=src)
                               // so the EXEC operand mux never collapses both ALU
                               // inputs onto mem_load_data.
  logic [2:0]  d_dst_reg;      // destination GPR index
  logic [2:0]  d_src_reg;      // source GPR index (reg operand)
  logic [31:0] d_imm;          // immediate / displacement value
  logic        d_use_imm;      // ALU second source is immediate
  logic        d_is_push;      // PUSH r32
  logic        d_is_pop;       // POP r32
  logic        d_is_lea;       // LEA r32, m
  logic        d_is_mov;       // plain MOV (no flags, no ALU)
  logic        d_is_nop;       // 0x90
  logic [31:0] d_ea;           // effective address for memory operand / LEA

  // ALU op encoding (low 3 bits mirror the x86 ALU group order 0..7).
  localparam logic [3:0] ALU_ADD = 4'd0;
  localparam logic [3:0] ALU_OR  = 4'd1;
  localparam logic [3:0] ALU_ADC = 4'd2;
  localparam logic [3:0] ALU_SBB = 4'd3;
  localparam logic [3:0] ALU_AND = 4'd4;
  localparam logic [3:0] ALU_SUB = 4'd5;
  localparam logic [3:0] ALU_XOR = 4'd6;
  localparam logic [3:0] ALU_CMP = 4'd7;   // SUB, flags only
  localparam logic [3:0] ALU_INC = 4'd8;   // ADD 1, CF preserved
  localparam logic [3:0] ALU_DEC = 4'd9;   // SUB 1, CF preserved
  localparam logic [3:0] ALU_TEST= 4'd10;  // AND, flags only
  localparam logic [3:0] ALU_MOV = 4'd11;  // pass src (no flags)

  // ModR/M / SIB decode helpers (combinational).
  logic [1:0]  modrm_mod;
  logic [2:0]  modrm_reg;
  logic [2:0]  modrm_rm;
  logic        has_sib;
  logic [1:0]  sib_scale;
  logic [2:0]  sib_index;
  logic [2:0]  sib_base;

  // ---------------------------------------------------------------------------
  // Effective-address + ModR/M operand-length computation.
  // Returns the number of bytes the ModR/M (+SIB+disp) field occupies, starting
  // at the ModR/M byte, and the effective address (for memory forms).
  // disp_off = index of the first displacement byte within ibuf, or 0 if none.
  // ---------------------------------------------------------------------------
  // We decode a ModR/M located at ibuf[modrm_idx]. For the M1 corpus the opcode
  // is always one byte (no 0F for the r/m group ops), so modrm_idx is fixed by
  // the opcode form. We compute everything for a ModR/M at ibuf[1].
  function automatic logic [3:0] modrm_field_len(input logic [1:0] mod,
                                                 input logic [2:0] rm,
                                                 input logic       sib,
                                                 input logic [2:0] base);
    // bytes occupied by ModR/M (+ optional SIB + optional disp)
    logic [3:0] len;
    logic [3:0] disp;
    begin
      // displacement size
      if (mod == 2'b01)                       disp = 4'd1;   // disp8
      else if (mod == 2'b10)                  disp = 4'd4;   // disp32
      else if (mod == 2'b00 && rm == 3'b101)  disp = 4'd4;   // [disp32] (no SIB)
      else if (mod == 2'b00 && sib &&
               base == 3'b101)                disp = 4'd4;   // SIB base-less disp32
      else                                    disp = 4'd0;
      len = 4'd1 + (sib ? 4'd1 : 4'd0) + disp;  // ModR/M + SIB + disp
      return len;
    end
  endfunction

  // ===========================================================================
  // Combinational decoder
  // ===========================================================================
  // Branch condition evaluation (tttn) using *current* EFLAGS.
  function automatic logic cond_true(input logic [3:0] tttn,
                                     input logic [31:0] fl);
    logic cf, pf, zf, sf, of;
    logic res;
    begin
      cf = fl[0]; pf = fl[2]; zf = fl[6]; sf = fl[7]; of = fl[11];
      unique case (tttn[3:1])
        3'b000: res = of;                 // O / NO
        3'b001: res = cf;                 // B / AE
        3'b010: res = zf;                 // E / NE
        3'b011: res = cf | zf;            // BE / A
        3'b100: res = sf;                 // S / NS
        3'b101: res = pf;                 // P / NP
        3'b110: res = (sf ^ of);          // L / GE
        3'b111: res = (zf | (sf ^ of));   // LE / G
        default: res = 1'b0;
      endcase
      return tttn[0] ? ~res : res;        // tttn[0] = negate
    end
  endfunction

  always_comb begin
    // defaults
    d_len          = 4'd1;
    d_halt         = 1'b0;
    d_unknown      = 1'b0;
    d_is_branch    = 1'b0;
    d_branch_taken = 1'b0;
    d_rel          = 32'd0;
    d_alu_op       = ALU_ADD;
    d_writes_reg   = 1'b0;
    d_writes_flags = 1'b0;
    d_mem_read     = 1'b0;
    d_mem_write    = 1'b0;
    d_mem_dst      = 1'b0;
    d_dst_reg      = 3'd0;
    d_src_reg      = 3'd0;
    d_imm          = 32'd0;
    d_use_imm      = 1'b0;
    d_is_push      = 1'b0;
    d_is_pop       = 1'b0;
    d_is_lea       = 1'b0;
    d_is_mov       = 1'b0;
    d_is_nop       = 1'b0;
    d_ea           = 32'd0;

    // ModR/M at ibuf[1]
    modrm_mod   = b1[7:6];
    modrm_reg   = b1[5:3];
    modrm_rm    = b1[2:0];
    has_sib     = (modrm_mod != 2'b11) && (modrm_rm == 3'b100);
    sib_scale   = b2[7:6];
    sib_index   = b2[5:3];
    sib_base    = b2[2:0];

    // Effective address for a memory ModR/M (mod != 11). Computed from current
    // GPRs + displacement. disp bytes start after ModR/M(+SIB).
    begin
      logic [31:0] base_val;
      logic [31:0] index_val;
      logic [31:0] disp_val;
      logic [3:0]  disp_idx;   // ibuf index of first disp byte
      logic        no_base;
      logic        no_index;

      no_base   = 1'b0;
      no_index  = 1'b0;
      base_val  = 32'd0;
      index_val = 32'd0;
      disp_val  = 32'd0;
      disp_idx  = 4'd2;        // after ModR/M (no SIB) by default

      if (has_sib) begin
        disp_idx = 4'd3;       // after ModR/M + SIB
        // base
        if (sib_base == 3'b101 && modrm_mod == 2'b00) no_base = 1'b1;
        else                                          base_val = gpr[sib_base];
        // index (index==100 -> none)
        if (sib_index == 3'b100) no_index = 1'b1;
        else index_val = gpr[sib_index] << sib_scale;
      end else begin
        // no SIB
        if (modrm_mod == 2'b00 && modrm_rm == 3'b101) begin
          no_base = 1'b1;       // [disp32]
        end else begin
          base_val = gpr[modrm_rm];
        end
      end

      // displacement
      if (modrm_mod == 2'b01) begin
        // disp8 sign-extended
        disp_val = {{24{ibuf[disp_idx][7]}}, ibuf[disp_idx]};
      end else if (modrm_mod == 2'b10 ||
                   (modrm_mod == 2'b00 && !has_sib && modrm_rm == 3'b101) ||
                   (modrm_mod == 2'b00 && has_sib && sib_base == 3'b101)) begin
        disp_val = {ibuf[disp_idx+3], ibuf[disp_idx+2],
                    ibuf[disp_idx+1], ibuf[disp_idx]};
      end

      d_ea = (no_base ? 32'd0 : base_val)
           + (no_index ? 32'd0 : index_val)
           + disp_val;
    end

    unique casez (b0)
      // ---- MOV r32, imm32 (B8+rd) -----------------------------------------
      8'b1011_1???: begin
        d_len        = 4'd5;
        d_is_mov     = 1'b1;
        d_writes_reg = 1'b1;
        d_dst_reg    = b0[2:0];
        d_alu_op     = ALU_MOV;
        d_use_imm    = 1'b1;
        d_imm        = {b4, b3, b2, b1};
      end

      // ---- INC r32 (40+rd) -------------------------------------------------
      8'b0100_0???: begin
        d_len          = 4'd1;
        d_writes_reg   = 1'b1;
        d_writes_flags = 1'b1;
        d_dst_reg      = b0[2:0];
        d_src_reg      = b0[2:0];
        d_alu_op       = ALU_INC;
      end
      // ---- DEC r32 (48+rd) -------------------------------------------------
      8'b0100_1???: begin
        d_len          = 4'd1;
        d_writes_reg   = 1'b1;
        d_writes_flags = 1'b1;
        d_dst_reg      = b0[2:0];
        d_src_reg      = b0[2:0];
        d_alu_op       = ALU_DEC;
      end

      // ---- PUSH r32 (50+rd) -----------------------------------------------
      8'b0101_0???: begin
        d_len       = 4'd1;
        d_is_push   = 1'b1;
        d_mem_write = 1'b1;
        d_src_reg   = b0[2:0];
      end
      // ---- POP r32 (58+rd) ------------------------------------------------
      8'b0101_1???: begin
        d_len        = 4'd1;
        d_is_pop     = 1'b1;
        d_mem_read   = 1'b1;
        d_writes_reg = 1'b1;
        d_dst_reg    = b0[2:0];
      end

      // ---- ALU r/m32, r32 (01 09 11 19 21 29 31 39) -----------------------
      // opcode pattern 00_xxx_001 with xxx = ALU op (low bits), direction=0
      8'b00??_?001: begin
        // bits [5:3] select ALU op (ADD..CMP) when bit2..0 = 001.
        d_alu_op       = {1'b0, b0[5:3]};
        d_len          = 4'd2 + (modrm_mod==2'b11 ? 4'd0 :
                                 modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base) - 4'd1);
        d_writes_flags = 1'b1;
        d_src_reg      = modrm_reg;
        if (modrm_mod == 2'b11) begin
          d_writes_reg = (b0[5:3] != 3'b111); // CMP: flags only
          d_dst_reg    = modrm_rm;
        end else begin
          // memory destination: read-modify-write. The register (modrm_reg) is
          // the ALU SOURCE; the loaded memory word is the destination operand.
          d_mem_read   = 1'b1;
          d_mem_write  = (b0[5:3] != 3'b111);
          d_mem_dst    = 1'b1;
          d_dst_reg    = modrm_reg;  // (unused for mem dst, but keep consistent)
        end
      end
      // ---- ALU r32, r/m32 (03 0B 13 1B 23 2B 33 3B) -----------------------
      8'b00??_?011: begin
        d_alu_op       = {1'b0, b0[5:3]};
        d_len          = 4'd2 + (modrm_mod==2'b11 ? 4'd0 :
                                 modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base) - 4'd1);
        d_writes_flags = 1'b1;
        d_writes_reg   = (b0[5:3] != 3'b111);
        d_dst_reg      = modrm_reg;
        if (modrm_mod == 2'b11) begin
          d_src_reg    = modrm_rm;
        end else begin
          d_mem_read   = 1'b1;
        end
      end
      // ---- ALU eAX, imm32 (05 0D 15 1D 25 2D 35 3D) -----------------------
      8'b00??_?101: begin
        d_alu_op       = {1'b0, b0[5:3]};
        d_len          = 4'd5;
        d_writes_flags = 1'b1;
        d_writes_reg   = (b0[5:3] != 3'b111);
        d_dst_reg      = R_EAX;
        d_src_reg      = R_EAX;
        d_use_imm      = 1'b1;
        d_imm          = {b4, b3, b2, b1};
      end

      // ---- ALU r/m32, imm32 (81 /digit id) --------------------------------
      8'h81: begin
        d_alu_op       = {1'b0, modrm_reg};
        d_writes_flags = 1'b1;
        if (modrm_mod == 2'b11) begin
          d_writes_reg = (modrm_reg != 3'b111); // CMP
          d_dst_reg    = modrm_rm;
          d_src_reg    = modrm_rm;
          d_use_imm    = 1'b1;
          d_imm        = {b5, b4, b3, b2};
          d_len        = 4'd6;
        end else begin
          d_mem_read   = 1'b1;
          d_mem_write  = (modrm_reg != 3'b111);
          d_mem_dst    = 1'b1;
          d_use_imm    = 1'b1;
          // imm32 follows ModR/M(+SIB+disp)
          d_len        = 4'd1 + modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base) + 4'd4;
        end
      end
      // ---- ALU r/m32, imm8 (sign-ext) (83 /digit ib) ----------------------
      8'h83: begin
        d_alu_op       = {1'b0, modrm_reg};
        d_writes_flags = 1'b1;
        if (modrm_mod == 2'b11) begin
          d_writes_reg = (modrm_reg != 3'b111); // CMP
          d_dst_reg    = modrm_rm;
          d_src_reg    = modrm_rm;
          d_use_imm    = 1'b1;
          d_imm        = {{24{b2[7]}}, b2};
          d_len        = 4'd3;
        end else begin
          d_mem_read   = 1'b1;
          d_mem_write  = (modrm_reg != 3'b111);
          d_mem_dst    = 1'b1;
          d_use_imm    = 1'b1;
          d_len        = 4'd1 + modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base) + 4'd1;
        end
      end

      // ---- MOV r/m32, r32 (89 /r) -----------------------------------------
      8'h89: begin
        d_is_mov  = 1'b1;
        d_alu_op  = ALU_MOV;
        d_src_reg = modrm_reg;
        if (modrm_mod == 2'b11) begin
          d_writes_reg = 1'b1;
          d_dst_reg    = modrm_rm;
          d_len        = 4'd2;
        end else begin
          d_mem_write  = 1'b1;
          d_len        = 4'd1 + modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base);
        end
      end
      // ---- MOV r32, r/m32 (8B /r) -----------------------------------------
      8'h8b: begin
        d_is_mov     = 1'b1;
        d_alu_op     = ALU_MOV;
        d_writes_reg = 1'b1;
        d_dst_reg    = modrm_reg;
        if (modrm_mod == 2'b11) begin
          d_src_reg = modrm_rm;
          d_len     = 4'd2;
        end else begin
          d_mem_read = 1'b1;
          d_len      = 4'd1 + modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base);
        end
      end
      // ---- MOV r/m32, imm32 (C7 /0 id) ------------------------------------
      8'hc7: begin
        d_is_mov  = 1'b1;
        d_alu_op  = ALU_MOV;
        d_use_imm = 1'b1;
        if (modrm_mod == 2'b11) begin
          d_writes_reg = 1'b1;
          d_dst_reg    = modrm_rm;
          d_imm        = {b5, b4, b3, b2};
          d_len        = 4'd6;
        end else begin
          d_mem_write  = 1'b1;
          d_len        = 4'd1 + modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base) + 4'd4;
          // imm bytes follow ModR/M(+SIB+disp); captured in EXEC via d_imm below
          d_imm        = {ibuf[1+modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base)+3],
                          ibuf[1+modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base)+2],
                          ibuf[1+modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base)+1],
                          ibuf[1+modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base)+0]};
        end
      end

      // ---- MOV EAX, moffs32 (A1 moffs32) ----------------------------------
      // Load EAX from the absolute 32-bit address encoded in the 4 bytes after
      // the opcode. GAS emits this for `movl <abs32>,%eax`.
      8'ha1: begin
        d_is_mov     = 1'b1;
        d_alu_op     = ALU_MOV;
        d_writes_reg = 1'b1;
        d_dst_reg    = R_EAX;
        d_mem_read   = 1'b1;
        d_ea         = {b4, b3, b2, b1};
        d_len        = 4'd5;
      end
      // ---- MOV moffs32, EAX (A3 moffs32) ----------------------------------
      // Store EAX to the absolute 32-bit address. GAS emits this for
      // `movl %eax,<abs32>` (the t_mem corpus uses it).
      8'ha3: begin
        d_is_mov     = 1'b1;
        d_alu_op     = ALU_MOV;
        d_mem_write  = 1'b1;
        d_mem_dst    = 1'b1;
        d_src_reg    = R_EAX;
        d_ea         = {b4, b3, b2, b1};
        d_len        = 4'd5;
      end

      // ---- LEA r32, m (8D /r) ---------------------------------------------
      8'h8d: begin
        d_is_lea     = 1'b1;
        d_writes_reg = 1'b1;
        d_dst_reg    = modrm_reg;
        d_len        = 4'd1 + modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base);
      end

      // ---- TEST r/m32, r32 (85 /r) ----------------------------------------
      8'h85: begin
        d_alu_op       = ALU_TEST;
        d_writes_flags = 1'b1;
        d_src_reg      = modrm_reg;
        if (modrm_mod == 2'b11) begin
          d_dst_reg = modrm_rm;
          d_len     = 4'd2;
        end else begin
          d_mem_read = 1'b1;
          d_len      = 4'd1 + modrm_field_len(modrm_mod, modrm_rm, has_sib, sib_base);
        end
      end
      // ---- TEST eAX, imm32 (A9 id) ----------------------------------------
      8'ha9: begin
        d_alu_op       = ALU_TEST;
        d_writes_flags = 1'b1;
        d_dst_reg      = R_EAX;
        d_use_imm      = 1'b1;
        d_imm          = {b4, b3, b2, b1};
        d_len          = 4'd5;
      end

      // ---- NOP / XCHG eax,eax (90) ----------------------------------------
      8'h90: begin
        d_is_nop = 1'b1;
        d_len    = 4'd1;
      end

      // ---- JMP rel8 (EB cb) -----------------------------------------------
      8'heb: begin
        d_len          = 4'd2;
        d_is_branch    = 1'b1;
        d_branch_taken = 1'b1;
        d_rel          = {{24{b1[7]}}, b1};
      end
      // ---- JMP rel32 (E9 cd) ----------------------------------------------
      8'he9: begin
        d_len          = 4'd5;
        d_is_branch    = 1'b1;
        d_branch_taken = 1'b1;
        d_rel          = {b4, b3, b2, b1};
      end
      // ---- Jcc rel8 (70+cc cb) --------------------------------------------
      8'b0111_????: begin
        d_len          = 4'd2;
        d_is_branch    = 1'b1;
        d_branch_taken = cond_true(b0[3:0], eflags);
        d_rel          = {{24{b1[7]}}, b1};
      end

      // ---- 0F two-byte: Jcc rel32 (0F 80+cc cd) ---------------------------
      8'h0f: begin
        if (b1[7:4] == 4'h8) begin
          d_len          = 4'd6;
          d_is_branch    = 1'b1;
          d_branch_taken = cond_true(b1[3:0], eflags);
          d_rel          = {ibuf[5], ibuf[4], ibuf[3], ibuf[2]};
        end else begin
          // 0F-prefixed op other than the two-byte Jcc — outside the M1 subset.
          d_len     = 4'd2;
          d_unknown = 1'b1;
        end
      end

      // ---- INT imm8 (CD ib) : int $0x80 halts -----------------------------
      8'hcd: begin
        d_len  = 4'd2;
        d_halt = (b1 == 8'h80);
      end

      default: begin
        // Opcode outside the implemented M1 integer subset. Rather than
        // silently mis-length the byte (which would desync the whole fetch
        // stream), flag it; the FSM halts on d_unknown so a stray/unsupported
        // opcode is a LOUD stop, not silent corruption. (M1 scope per
        // docs/m1-core-spec.md "Instruction set to implement".)
        d_len     = 4'd1;
        d_unknown = 1'b1;
      end
    endcase
  end

  // ===========================================================================
  // Latched decoded fields (captured at S_DECODE)
  // ===========================================================================
  logic [3:0]  q_len;
  logic        q_halt;
  logic        q_is_branch;
  logic        q_branch_taken;
  logic [31:0] q_rel;
  logic [3:0]  q_alu_op;
  logic        q_writes_reg;
  logic        q_writes_flags;
  logic        q_mem_read;
  logic        q_mem_write;
  logic        q_mem_dst;
  logic [2:0]  q_dst_reg;
  logic [2:0]  q_src_reg;
  logic [31:0] q_imm;
  logic        q_use_imm;
  logic        q_is_push;
  logic        q_is_pop;
  logic        q_is_lea;
  logic        q_is_mov;
  logic        q_is_nop;
  logic [31:0] q_ea;
  logic [31:0] q_pc;            // fetch PC of the instruction in flight

  logic [31:0] mem_load_data;   // captured memory read result for S_EXEC

  // ===========================================================================
  // ALU + EFLAGS computation (combinational, used in S_EXEC)
  // ===========================================================================
  // src_a = destination's current value (or memory load result for r/m dst);
  // src_b = second source (register / immediate / memory load / 1 for inc/dec).
  function automatic logic [31:0] alu_result(input logic [3:0]  op,
                                             input logic [31:0] a,
                                             input logic [31:0] b,
                                             input logic        cfin);
    begin
      unique case (op)
        ALU_ADD, ALU_INC: alu_result = a + b;
        ALU_SUB, ALU_CMP, ALU_DEC: alu_result = a - b;
        ALU_AND, ALU_TEST: alu_result = a & b;
        ALU_OR:  alu_result = a | b;
        ALU_XOR: alu_result = a ^ b;
        ALU_MOV: alu_result = b;
        ALU_ADC: alu_result = a + b + {31'd0, cfin};
        ALU_SBB: alu_result = a - b - {31'd0, cfin};
        default: alu_result = a;
      endcase
    end
  endfunction

  // Parity of low 8 bits.
  function automatic logic parity8(input logic [7:0] v);
    return ~^v;   // 1 if even number of set bits
  endfunction

  // Compute next EFLAGS for an ALU op given operands + result.
  function automatic logic [31:0] flags_next(input logic [3:0]  op,
                                             input logic [31:0] a,
                                             input logic [31:0] b,
                                             input logic [31:0] res,
                                             input logic [31:0] cur);
    logic cf, pf, af, zf, sf, of;
    logic [31:0] fl;
    logic [32:0] uadd, usub, uadc, usbb;
    begin
      fl  = cur;
      zf  = (res == 32'd0);
      sf  = res[31];
      pf  = parity8(res[7:0]);

      // unsigned add/sub with carry chains for CF/AF/OF
      uadd = {1'b0, a} + {1'b0, b};
      usub = {1'b0, a} - {1'b0, b};
      uadc = {1'b0, a} + {1'b0, b} + {32'd0, cur[0]};
      usbb = {1'b0, a} - {1'b0, b} - {32'd0, cur[0]};

      // sensible default so every bit is always assigned
      cf = cur[0]; af = cur[4]; of = cur[11];

      unique case (op)
        // AF is the carry/borrow OUT of bit 3 (= carry INTO bit 4). By the
        // ripple-carry identity, the carry into bit k of (a +/- b) equals
        // a[k]^b[k]^res[k], so the carry OUT of bit 3 is a[4]^b[4]^res[4].
        // (a[3]^b[3]^res[3] would be the carry INTO bit 3 — off by one.)
        ALU_ADD: begin
          cf = uadd[32];
          af = (a[4] ^ b[4] ^ res[4]);
          of = (~(a[31]^b[31]) & (a[31]^res[31]));
        end
        ALU_ADC: begin
          cf = uadc[32];
          af = (a[4] ^ b[4] ^ res[4]);
          of = (~(a[31]^b[31]) & (a[31]^res[31]));
        end
        ALU_SUB, ALU_CMP: begin
          cf = usub[32];
          af = (a[4] ^ b[4] ^ res[4]);
          of = ((a[31]^b[31]) & (a[31]^res[31]));
        end
        ALU_SBB: begin
          cf = usbb[32];
          af = (a[4] ^ b[4] ^ res[4]);
          of = ((a[31]^b[31]) & (a[31]^res[31]));
        end
        ALU_INC: begin
          cf = cur[0];                   // CF preserved
          af = (a[4] ^ b[4] ^ res[4]);   // b == 1
          of = (res == 32'h8000_0000);
        end
        ALU_DEC: begin
          cf = cur[0];                   // CF preserved
          af = (a[4] ^ b[4] ^ res[4]);   // b == 1
          of = (res == 32'h7fff_ffff);
        end
        ALU_AND, ALU_OR, ALU_XOR, ALU_TEST: begin
          cf = 1'b0; af = 1'b0; of = 1'b0;
        end
        default: begin
          cf = cur[0]; af = cur[4]; of = cur[11];
        end
      endcase

      // assemble: keep system bits, drop the six status bits, reinsert.
      // mask = ~0x8D5 = clear CF(0),PF(2),AF(4),ZF(6),SF(7),OF(11)
      fl = cur & 32'hFFFF_F72A;
      fl[0]  = cf;
      fl[2]  = pf;
      fl[4]  = af;
      fl[6]  = zf;
      fl[7]  = sf;
      fl[11] = of;
      fl[1]  = 1'b1;                      // reserved-1 reads 1
      return fl;
    end
  endfunction

  // ===========================================================================
  // EXEC operand selection (combinational, valid in S_EXEC)
  // ===========================================================================
  logic [31:0] src_a;    // first ALU source / dst current value
  logic [31:0] src_b;    // second ALU source
  logic [31:0] alu_out;  // ALU result
  logic [31:0] flags_out;

  always_comb begin
    // src_a = the destination operand's current value (first ALU input).
    //   * memory-destination RMW (ALU r/m,r ; ALU r/m,imm) -> the loaded word
    //   * pop -> unused (pop writes the loaded word directly, not via the ALU)
    //   * otherwise -> the destination register
    if (q_mem_read && q_mem_dst)
      src_a = mem_load_data;             // memory is the destination (RMW)
    else if (q_is_pop)
      src_a = 32'd0;
    else
      src_a = gpr[q_dst_reg];

    // src_b = the second ALU source.
    //   * immediate first (covers all *,imm forms incl. mem-dst RMW)
    //   * a MEMORY SOURCE operand (mov r32,[m] ; ALU r32,[m]) -> loaded word.
    //     Guard with !q_mem_dst so an RMW (memory is the destination) takes its
    //     source from the register, not a second copy of the loaded word.
    //   * inc/dec implicit 1
    //   * otherwise the source register
    if (q_use_imm)
      src_b = q_imm;
    else if (q_mem_read && !q_mem_dst)
      src_b = mem_load_data;             // mov r32,[m] / ALU r32,[m]
    else if (q_alu_op == ALU_INC || q_alu_op == ALU_DEC)
      src_b = 32'd1;
    else
      src_b = gpr[q_src_reg];

    alu_out   = alu_result(q_alu_op, src_a, src_b, eflags[0]);
    flags_out = flags_next(q_alu_op, src_a, src_b, alu_out, eflags);
  end

  // ===========================================================================
  // Main sequential FSM
  // ===========================================================================
  // Next-EIP (fall-through) and branch target.
  logic [31:0] next_eip;
  assign next_eip = q_pc + {28'd0, q_len};

  // The packed retire snapshot.
  arch_state_t snap;
  always_comb begin
    snap.eflags = eflags;
    snap.eax = gpr[0]; snap.ecx = gpr[1]; snap.edx = gpr[2]; snap.ebx = gpr[3];
    snap.esp = gpr[4]; snap.ebp = gpr[5]; snap.esi = gpr[6]; snap.edi = gpr[7];
    snap.cs = SEG_CS; snap.ss = SEG_SS; snap.ds = SEG_DS;
    snap.es = SEG_ES; snap.fs = SEG_FS; snap.gs = SEG_GS;
  end

  assign retire_state = snap;
  assign retire_pc    = q_pc;

  // ---------------------------------------------------------------------------
  // Bus outputs are driven COMBINATIONALLY from the current state/counters.
  // The TB's mem_* protocol is single-beat with combinational ack: the request
  // (addr/we/wdata) must fully reflect the current intent in the same delta the
  // TB services the bus, otherwise a registered address lags the ack by a cycle
  // and corrupts the captured read data. So we present the request directly and
  // capture the response on the clock edge that sees mem_ack.
  // ---------------------------------------------------------------------------
  always_comb begin
    mem_req   = 1'b0;
    mem_we    = 1'b0;
    mem_addr  = 32'd0;
    mem_wdata = 32'd0;
    mem_wstrb = 4'd0;
    unique case (state)
      S_FETCH: begin
        mem_req  = 1'b1;
        mem_we   = 1'b0;
        mem_addr = eip + {27'd0, fetch_word, 2'b00};
      end
      S_LOAD: begin
        mem_req  = 1'b1;
        mem_we   = 1'b0;
        mem_addr = q_is_pop ? gpr[R_ESP] : q_ea;
      end
      S_STORE: begin
        mem_req   = 1'b1;
        mem_we    = 1'b1;
        mem_wstrb = 4'hf;
        if (q_is_push) begin
          mem_addr  = gpr[R_ESP] - 32'd4;
          mem_wdata = gpr[q_src_reg];
        end else begin
          mem_addr  = q_ea;
          mem_wdata = q_is_mov ? (q_use_imm ? q_imm : gpr[q_src_reg]) : alu_out;
        end
      end
      default: ; // no bus activity
    endcase
  end

  // Sequential FSM: state, arch regs, instruction buffer, captured read data.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state        <= S_RESET;
      eip          <= init_eip;
      eflags       <= EFLAGS_RESET;
      gpr[0] <= 32'd0; gpr[1] <= 32'd0; gpr[2] <= 32'd0; gpr[3] <= 32'd0;
      gpr[4] <= init_esp; gpr[5] <= 32'd0; gpr[6] <= 32'd0; gpr[7] <= 32'd0;
      fetch_word   <= 3'd0;
      retire_valid <= 1'b0;
    end else begin
      retire_valid <= 1'b0;   // default: pulse for exactly one clock

      unique case (state)
        // -------------------------------------------------------------------
        S_RESET: begin
          // init_eip/init_esp were latched at reset. Begin fetching.
          fetch_word <= 3'd0;
          state      <= S_FETCH;
        end

        // -------------------------------------------------------------------
        // FETCH: read 4 consecutive words (16 bytes) at EIP into ibuf. The
        // request address is driven combinationally above from fetch_word.
        S_FETCH: begin
          if (mem_ack) begin
            // store the 4 bytes of this word into ibuf
            ibuf[{fetch_word, 2'b00} + 0] <= mem_rdata[7:0];
            ibuf[{fetch_word, 2'b00} + 1] <= mem_rdata[15:8];
            ibuf[{fetch_word, 2'b00} + 2] <= mem_rdata[23:16];
            ibuf[{fetch_word, 2'b00} + 3] <= mem_rdata[31:24];
            if (fetch_word == 3'(IWORDS-1)) begin
              fetch_word <= 3'd0;
              state      <= S_DECODE;
            end else begin
              fetch_word <= fetch_word + 3'd1;
            end
          end
        end

        // -------------------------------------------------------------------
        // DECODE: latch combinational decode of ibuf, then route.
        S_DECODE: begin
          q_len          <= d_len;
          q_halt         <= d_halt;
          q_is_branch    <= d_is_branch;
          q_branch_taken <= d_branch_taken;
          q_rel          <= d_rel;
          q_alu_op       <= d_alu_op;
          q_writes_reg   <= d_writes_reg;
          q_writes_flags <= d_writes_flags;
          q_mem_read     <= d_mem_read;
          q_mem_write    <= d_mem_write;
          q_mem_dst      <= d_mem_dst;
          q_dst_reg      <= d_dst_reg;
          q_src_reg      <= d_src_reg;
          q_imm          <= d_imm;
          q_use_imm      <= d_use_imm;
          q_is_push      <= d_is_push;
          q_is_pop       <= d_is_pop;
          q_is_lea       <= d_is_lea;
          q_is_mov       <= d_is_mov;
          q_is_nop       <= d_is_nop;
          q_ea           <= d_ea;
          q_pc           <= eip;

          // int $0x80 halts (program exit); an opcode outside the M1 subset
          // halts LOUDLY (no retire) rather than silently mis-decoding the
          // fetch stream. Neither emits a retire record for itself.
          if (d_halt || d_unknown) begin
            state <= S_HALT;
          end else if (d_mem_read || d_is_pop) begin
            state <= S_LOAD;
          end else begin
            state <= S_EXEC;
          end
        end

        // -------------------------------------------------------------------
        // LOAD: one word read of the memory source (pop -> [ESP]; mem ModR/M).
        S_LOAD: begin
          if (mem_ack) begin
            mem_load_data <= mem_rdata;
            state         <= S_EXEC;
          end
        end

        // -------------------------------------------------------------------
        // EXEC: compute result + flags, then either store to memory or retire.
        S_EXEC: begin
          if (q_mem_write) begin
            state <= S_STORE;
          end else begin
            // commit register / flags / EIP, then retire
            if (q_is_lea) begin
              gpr[q_dst_reg] <= q_ea;
            end else if (q_is_pop) begin
              // pop reg: reg <- mem[ESP]; ESP += 4. When reg IS ESP, the loaded
              // value is the final ESP (the +4 is discarded) — Intel SDM. Issue
              // the ESP bump only for a non-ESP destination so the two NBAs to
              // gpr[ESP] never race (the popped value must win for `pop %esp`).
              gpr[q_dst_reg] <= mem_load_data;
              if (q_dst_reg != R_ESP)
                gpr[R_ESP] <= gpr[R_ESP] + 32'd4;
            end else if (q_writes_reg) begin
              gpr[q_dst_reg] <= alu_out;
            end
            if (q_writes_flags) eflags <= flags_out;

            // EIP update
            if (q_is_branch && q_branch_taken)
              eip <= next_eip + q_rel;
            else
              eip <= next_eip;

            retire_valid <= 1'b1;   // post-commit (regs update this same edge)
            state        <= S_FETCH;
          end
        end

        // -------------------------------------------------------------------
        // STORE: one word write (push -> [ESP-4]; mov [m],r/imm; RMW result).
        S_STORE: begin
          // request (addr/we/wdata) is driven combinationally above.
          if (mem_ack) begin
            // commit side effects
            if (q_is_push) gpr[R_ESP] <= gpr[R_ESP] - 32'd4;
            if (q_writes_flags) eflags <= flags_out;
            eip <= next_eip;
            retire_valid <= 1'b1;
            state        <= S_FETCH;
          end
        end

        // -------------------------------------------------------------------
        S_HALT: begin
          state   <= S_HALT;   // stay halted; TB stops on quiescence
        end

        default: state <= S_HALT;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Keep structurally-recognised-but-unused decode bits from tripping lint.
  // ---------------------------------------------------------------------------
  // verilator lint_off UNUSED
  // q_is_nop / q_halt are latched for symmetry/clarity but the FSM acts on the
  // combinational d_* (halt routing) and the NOP needs no datapath action; b5 /
  // mem_rdata[0] are slices whose siblings are consumed. Sink them explicitly.
  wire _unused = &{1'b0, q_is_nop, q_halt, b5, mem_rdata[0]};
  // verilator lint_on UNUSED

endmodule : intcore
