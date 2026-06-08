// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

/*
 * p5trace.c — Ventium Producer B: QEMU TCG cycle-trace plugin.
 *
 * This is the CYCLE-mode .vtrace producer of the differential-testing stack
 * (see docs/trace-format.md §2.3 and PLAN.md §4.1). It rides functional QEMU
 * execution (qemu-i386 -cpu pentium) and, for every RETIRED instruction, emits
 * one JSON-Lines record:
 *
 *     {"n":<seq>, "pc":"0x...", "cyc":<cumulative core cycles>,
 *      "pipe":"U"|"V"|"-", "paired":<bool>, "stall":<int>?, "bytes":"..."?}
 *
 * The first line is the header object:
 *     {"vtrace":1,"producer":"qemu-plugin","mode":"cycle","x87":false,"note":"..."}
 *
 * The cycle model is the SAME in-order, dual-pipe (U/V) Pentium (P5/P54C,
 * non-MMX) estimate as ventium-refs/07-p5-emulation-harness/plugin/p5model.c —
 * pairing classes (AP-500 / Agner Fog), Agner P5 latencies, AGI interlock,
 * 256-entry 4-way BTB w/ 2-bit counters, split 8 KB 2-way L1 I/D caches. The
 * ONLY difference from p5model is the OUTPUT: p5model prints one aggregate JSON
 * blob at exit; we append a per-retired-instruction cycle record as execution
 * proceeds. Records are buffered in memory and flushed at the atexit callback
 * (faster, and avoids interleaving with QEMU's own stderr).
 *
 * `cyc` is CUMULATIVE core-clock count at the instruction's retire, exactly as
 * required by docs/trace-format.md §2.3 (the comparator derives per-insn deltas
 * as cyc[n]-cyc[n-1]). The model is a cycle ESTIMATE for L1-resident user-mode
 * code, not cycle-exact silicon (see the harness README "What it does NOT
 * model" and PLAN.md §8).
 *
 * Pipe attribution per record:
 *   - "U"  the instruction started a fresh issue group (it occupied the U pipe);
 *   - "V"  the instruction paired into the open V slot of the current group;
 *   - "-"  microcoded / non-issued forms (currently unused: every retired insn
 *          maps to either U or V here, but the field is kept for parity with the
 *          RTL producer which can microcode-stall — see docs/trace-format.md).
 *
 * Decoding uses capstone (linked statically). Classification mirrors p5model.c
 * by capstone instruction-id + operand inspection.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <glib.h>

#include <qemu-plugin.h>
#include <capstone/capstone.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

/* ----------------------------- timing constants ------------------------------
 * From the canonical P5 timing data (AP-500 / Agner Fog), as used in p5model.c.
 * Latencies in core clocks.                                                    */
#define P5_AGI_PENALTY        1     /* AP-500: result-reuse address interlock    */
#define P5_MISALIGN_PENALTY   3     /* AP-500: misaligned data access            */
#define P5_MISPREDICT_U       3     /* cond mispredict, branch in U-pipe         */
#define P5_MISPREDICT_V       4     /* cond mispredict, branch in V-pipe         */
#define P5_MISPREDICT_UNCOND  3     /* taken JMP/CALL mispredict                  */
#define P5_FP_ISSUE_OCC       2     /* GAP1/VEN_FP_OVERLAP: U-pipe dispatch slot an
                                       FP op consumes (the integer pipe is held only
                                       this long; the long FP exec window lives on
                                       fp_busy_until so integer ops overlap it).   */

/* L1 geometry (P54C): 8 KB, 2-way, 32-byte line => 128 sets each. */
#define L1_SIZE      8192
#define L1_WAYS      2
#define L1_LINE      32
#define L1_SETS      (L1_SIZE / L1_LINE / L1_WAYS)   /* 128 */

/* BTB: 256 entries, 4-way => 64 sets (Alpert/Avnon). */
#define BTB_WAYS     4
#define BTB_SETS     64

/* GP register bit indices: a c d b sp bp si di */
enum { R_A, R_C, R_D, R_B, R_SP, R_BP, R_SI, R_DI, R_N };
#define GP_NOSP_MASK (0xFFu & ~(1u << R_SP))   /* deps ignore ESP (stack engine) */

/* Pairing class. */
typedef enum { NP=0, UV, PU, PV } pclass_t;

/* Per-static-instruction decoded info (allocated at translate, never freed). */
typedef struct {
    uint64_t vaddr;
    uint8_t  size;
    pclass_t pclass;
    bool     pairs_first;   /* may be the U member of a pair (something pairs after) */
    bool     pairs_second;  /* may be the V member of a pair */
    uint16_t occ;           /* pipe occupancy (cycles the pipe is held)            */
    uint16_t lat;           /* result latency (when written regs become ready)     */
    uint8_t  reads;         /* GP regs read  (bitmask) */
    uint8_t  writes;        /* GP regs written (bitmask) */
    uint8_t  addr;          /* GP regs used as base/index for addressing (AGI)     */
    bool     has_disp_imm;  /* operand has both displacement AND immediate         */
    uint8_t  prefixes;      /* legacy prefix count (decode penalty)                */
    bool     is_branch;     /* control transfer */
    bool     is_cond;       /* conditional branch */
    bool     is_callret;
    bool     is_mem;
    uint8_t  fp_role;       /* x87 top-of-stack dep: 0 none,1 producer,2 consumer,3 rmw */
    /* raw bytes for the optional "bytes" trace field (lowercase hex emitted later) */
    uint8_t  raw[16];
    uint8_t  rawlen;
} insn_t;

/* ------------------------- emitted cycle record ----------------------------- */
/* One per retired instruction, buffered then flushed as a .vtrace line.        */
typedef struct {
    uint64_t pc;
    uint64_t cyc;       /* cumulative core cycles at retire */
    uint32_t stall;     /* cycles attributed to this instruction (AGI/miss/...)  */
    char     pipe;      /* 'U' / 'V' / '-' */
    bool     paired;
    const insn_t *ii;   /* for the optional bytes field (points at static decode) */
} rec_t;

/* ------------------------------- model state -------------------------------- */
typedef struct { uint32_t tag[L1_WAYS]; bool val[L1_WAYS]; uint8_t lru; } l1set_t;
typedef struct {
    uint32_t tag[BTB_WAYS]; uint8_t ctr[BTB_WAYS]; bool val[BTB_WAYS]; uint8_t rr;
} btbset_t;

static struct {
    /* config */
    FILE    *out;
    char    *outpath;
    uint32_t imiss, dmiss;   /* I/D L1 miss penalties (cycles) — see README       */
    bool     model_cache;
    bool     emit_bytes;     /* include "bytes" field in each record              */
    /* trace buffer (grown as we go; flushed at exit) */
    rec_t   *recs;
    size_t   nrec, caprec;
    uint64_t seq;            /* retire sequence number (the trace's "n")          */
    /* timing accumulators */
    uint64_t cycles;
    /* per-instruction bookkeeping for the current retire (set in the timing core) */
    uint64_t cur_pen;        /* stall cycles attributed to the current insn       */
    /* in-order pipe state */
    uint64_t pipe_free_at;   /* cycle the U pipe is free for a new issue group     */
    uint64_t grp_cycle;      /* issue cycle of current group                       */
    bool     grp_vfree;      /* V slot of current group still open                 */
    insn_t  *grp_u;          /* U-member of current group                          */
    int64_t  reg_ready[R_N]; /* cycle each GP reg value is ready (RAW)             */
    int64_t  reg_wcycle[R_N];/* cycle each GP reg was last written (AGI)           */
    int64_t  fp_ready;       /* cycle x87 top-of-stack result is ready (FP chains) */
    int64_t  fp_busy_until;  /* GAP1: cycle the single x87 exec unit is free again */
    bool     fp_overlap;     /* GAP1/VEN_FP_OVERLAP gate (argv fpovl=1). default 0 */
    bool     fxch_free;      /* GAP2/VEN_FXCH_FREE gate (argv fxchfree=1). default 0 */
    uint64_t pending_mem_pen;/* D-cache penalty from prev insn's mem access        */
    /* deferred branch resolution */
    bool     pend_branch;
    uint64_t pend_fallthru;  /* vaddr of the instruction after the branch          */
    bool     pend_pred_taken;
    bool     pend_in_v;      /* branch issued in V pipe                            */
    bool     pend_cond;
    uint64_t pend_pc;        /* the branch instruction's own vaddr (for BTB update)*/
    /* structures */
    l1set_t  icache[L1_SETS];
    l1set_t  dcache[L1_SETS];
    btbset_t btb[BTB_SETS];
} g;

static csh cs_handle;

/* --------------------------- capstone reg mapping --------------------------- */
static int reg_parent(uint16_t r)
{
    switch (r) {
    case X86_REG_AL: case X86_REG_AH: case X86_REG_AX: case X86_REG_EAX: return R_A;
    case X86_REG_CL: case X86_REG_CH: case X86_REG_CX: case X86_REG_ECX: return R_C;
    case X86_REG_DL: case X86_REG_DH: case X86_REG_DX: case X86_REG_EDX: return R_D;
    case X86_REG_BL: case X86_REG_BH: case X86_REG_BX: case X86_REG_EBX: return R_B;
    case X86_REG_SPL: case X86_REG_SP: case X86_REG_ESP: return R_SP;
    case X86_REG_BPL: case X86_REG_BP: case X86_REG_EBP: return R_BP;
    case X86_REG_SIL: case X86_REG_SI: case X86_REG_ESI: return R_SI;
    case X86_REG_DIL: case X86_REG_DI: case X86_REG_EDI: return R_DI;
    default: return -1;
    }
}

/* ----------------------------- classification ------------------------------- */
/* Decide pairing class, occupancy and latency from a decoded insn. Condensed
 * from p5model.c classify(): we drop the instruction-mix histogram (which only
 * fed p5model's aggregate report) but keep every timing-relevant decision. */
static void classify(cs_insn *in, insn_t *ii)
{
    cs_detail *d = in->detail;
    cs_x86 *x = &d->x86;
    unsigned id = in->id;

    /* default: single-cycle, non-pairable */
    ii->pclass = NP; ii->occ = 1; ii->lat = 1;
    ii->pairs_first = ii->pairs_second = false;

    /* read/written GP regs (full, incl. implicit) via cs_regs_access */
    cs_regs rr, rw; uint8_t nr=0, nw=0;
    if (cs_regs_access(cs_handle, in, rr, &nr, rw, &nw) == CS_ERR_OK) {
        for (uint8_t i=0;i<nr;i++){ int p=reg_parent(rr[i]); if(p>=0) ii->reads  |= 1u<<p; }
        for (uint8_t i=0;i<nw;i++){ int p=reg_parent(rw[i]); if(p>=0) ii->writes |= 1u<<p; }
    }

    /* memory operand: addressing regs (AGI), load/store, disp+imm */
    bool has_mem=false, mem_is_w=false, has_imm=false, has_disp=false;
    for (int i=0;i<x->op_count;i++){
        cs_x86_op *op=&x->operands[i];
        if (op->type==X86_OP_MEM){
            has_mem=true;
            int b=reg_parent(op->mem.base);  if(b>=0) ii->addr |= 1u<<b;
            int x_=reg_parent(op->mem.index);if(x_>=0)ii->addr |= 1u<<x_;
            if (op->mem.disp) has_disp=true;
            if (op->access & CS_AC_WRITE) mem_is_w=true;
        } else if (op->type==X86_OP_IMM) has_imm=true;
    }
    ii->is_mem = has_mem;
    ii->has_disp_imm = has_disp && has_imm;
    /* count legacy prefixes (lock/rep/seg/opsize/addrsize) */
    for (int i=0;i<4;i++) if (x->prefix[i]) ii->prefixes++;

    switch (id) {
    /* ---- simple integer ALU: UV, 1 cycle (load form 2-cyc latency) ---- */
    case X86_INS_ADD: case X86_INS_SUB: case X86_INS_AND: case X86_INS_OR:
    case X86_INS_XOR: case X86_INS_CMP: case X86_INS_INC: case X86_INS_DEC:
        ii->pclass=UV; ii->pairs_first=ii->pairs_second=true;
        if (has_mem && mem_is_w){ ii->occ=3; ii->lat=3; ii->pairs_second=false; }
        else if (has_mem){ ii->occ=1; ii->lat=2; }
        else { ii->occ=1; ii->lat=1; }
        break;
    case X86_INS_TEST:
        ii->occ=1; ii->lat= has_mem?2:1;
        /* TEST r,r / TEST eax,imm pair (UV); other imm forms NP (AP-500) */
        if (!has_mem && (!has_imm || (ii->reads & (1u<<R_A)))) {
            ii->pclass=UV; ii->pairs_first=ii->pairs_second=true;
        } else ii->pclass=NP;
        break;
    case X86_INS_MOV: case X86_INS_MOVABS:
        ii->pclass=UV; ii->pairs_first=ii->pairs_second=true;
        if (has_mem && mem_is_w){ ii->occ=1; ii->lat=1; }      /* store */
        else if (has_mem){ ii->occ=1; ii->lat=2; }             /* load  */
        else { ii->occ=1; ii->lat=1; }
        break;
    case X86_INS_MOVZX: case X86_INS_MOVSX: case X86_INS_MOVSXD:
        ii->pclass=NP; ii->occ=2; ii->lat=2; break;
    case X86_INS_LEA:
        ii->pclass=UV; ii->pairs_first=ii->pairs_second=true;
        ii->occ=1; ii->lat=1; break;
    case X86_INS_ADC: case X86_INS_SBB:
        ii->pclass=PU; ii->pairs_first=true;
        ii->occ= (has_mem&&mem_is_w)?3:1; ii->lat=ii->occ; break;
    case X86_INS_NEG: case X86_INS_NOT:
        ii->pclass=NP; ii->occ= has_mem?3:1; ii->lat=ii->occ; break;
    /* ---- shifts / rotates ---- */
    case X86_INS_SHL: case X86_INS_SHR: case X86_INS_SAR:
    case X86_INS_ROL: case X86_INS_ROR: case X86_INS_RCL: case X86_INS_RCR:
        /* by imm/1 => PU (U-only pairable); by CL => NP */
        if (ii->reads & (1u<<R_C)) { ii->pclass=NP; ii->occ=1; ii->lat=1; }
        else { ii->pclass=PU; ii->pairs_first=true; ii->occ=1; ii->lat=1; }
        break;
    case X86_INS_SHLD: case X86_INS_SHRD:
    case X86_INS_BT: case X86_INS_BTC: case X86_INS_BTR: case X86_INS_BTS:
    case X86_INS_BSF: case X86_INS_BSR: case X86_INS_SETE:
        ii->pclass=NP; ii->occ=4; ii->lat=4; break;
    /* ---- multiply / divide (microcoded, NP) ---- */
    case X86_INS_MUL: case X86_INS_IMUL:
        ii->pclass=NP; ii->occ=10; ii->lat=10; break;
    case X86_INS_DIV:
        ii->pclass=NP;
        ii->occ = (in->detail->x86.operands[0].size>=4)?41:
                  (in->detail->x86.operands[0].size==2)?25:17; ii->lat=ii->occ; break;
    case X86_INS_IDIV:
        ii->pclass=NP;
        ii->occ = (in->detail->x86.operands[0].size>=4)?46:
                  (in->detail->x86.operands[0].size==2)?30:22; ii->lat=ii->occ; break;
    /* ---- stack ---- */
    case X86_INS_PUSH: case X86_INS_POP:
        ii->pclass= has_mem?NP:UV;
        ii->pairs_first=ii->pairs_second=!has_mem; ii->occ=1; ii->lat=1; break;
    /* ---- branches ---- */
    case X86_INS_JMP:
        ii->is_branch=true; ii->pclass=PV; ii->pairs_second=true;
        ii->occ=1; ii->lat=1; break;
    case X86_INS_CALL:
        ii->is_branch=true; ii->is_callret=true; ii->pclass=PV;
        ii->pairs_second=true; ii->occ=1; ii->lat=1; break;
    case X86_INS_RET: case X86_INS_RETF: case X86_INS_IRET: case X86_INS_IRETD:
        ii->is_branch=true; ii->is_callret=true; ii->pclass=NP;
        ii->occ=2; ii->lat=2; break;
    case X86_INS_LOOP: case X86_INS_LOOPE: case X86_INS_LOOPNE:
    case X86_INS_JECXZ: case X86_INS_JCXZ:
        ii->is_branch=true; ii->is_cond=true; ii->pclass=NP;
        ii->occ=5; ii->lat=5; break;
    /* ---- x87 FPU ---- */
    case X86_INS_FADD: case X86_INS_FIADD:
    case X86_INS_FSUB: case X86_INS_FSUBP: case X86_INS_FSUBR: case X86_INS_FSUBRP:
    case X86_INS_FISUB: case X86_INS_FISUBR:
    case X86_INS_FCHS: case X86_INS_FABS:
        ii->pclass=NP; ii->occ=1; ii->lat=3; ii->fp_role=3; break;
    case X86_INS_FCOM: case X86_INS_FCOMP: case X86_INS_FCOMPP:
    case X86_INS_FUCOM: case X86_INS_FUCOMP: case X86_INS_FUCOMPP: case X86_INS_FTST:
        ii->pclass=NP; ii->occ=1; ii->lat=1; ii->fp_role=2; break;
    case X86_INS_FMUL: case X86_INS_FMULP: case X86_INS_FIMUL:
        ii->pclass=NP; ii->occ=2; ii->lat=3; ii->fp_role=3; break;
    case X86_INS_FDIV: case X86_INS_FDIVP: case X86_INS_FDIVR: case X86_INS_FDIVRP:
    case X86_INS_FIDIV: case X86_INS_FIDIVR:
        ii->pclass=NP; ii->occ=39; ii->lat=39; ii->fp_role=3; break;
    case X86_INS_FSQRT:
        ii->pclass=NP; ii->occ=70; ii->lat=70; ii->fp_role=3; break;
    case X86_INS_FLD: case X86_INS_FILD: case X86_INS_FBLD:
        ii->pclass=NP; ii->occ=1; ii->lat=1; ii->fp_role=1; break;
    case X86_INS_FST: case X86_INS_FSTP: case X86_INS_FIST: case X86_INS_FISTP:
    case X86_INS_FBSTP:
        ii->pclass=NP; ii->occ=1; ii->lat=1; ii->fp_role=2; break;
    case X86_INS_FXCH:
        /* GAP2: the P5 FXCH is a stack-pointer/tag RENAME that executes in parallel
         * with an adjacent FP op (~0 cycles) — the register flexibility Quake leans on.
         * With g.fxch_free, occ=0 so it does not advance pipe_free_at: its retire folds
         * onto the adjacent group's cycle (forward-collapse). fp_role stays 0 (it neither
         * reads nor writes the fp_ready top-of-stack slot). Default keeps occ=1. */
        ii->pclass=NP; ii->occ = g.fxch_free ? 0 : 1; ii->lat=1; ii->fp_role=0; break;
    case X86_INS_FLDZ: case X86_INS_FLD1: case X86_INS_FLDPI:
    case X86_INS_FLDL2E: case X86_INS_FLDL2T: case X86_INS_FLDLG2: case X86_INS_FLDLN2:
        ii->pclass=NP; ii->occ=2; ii->lat=2; ii->fp_role=1; break;
    case X86_INS_FSIN: case X86_INS_FCOS: case X86_INS_FSINCOS: case X86_INS_FPTAN:
    case X86_INS_FPATAN: case X86_INS_FYL2X: case X86_INS_FYL2XP1:
    case X86_INS_F2XM1: case X86_INS_FSCALE: case X86_INS_FPREM: case X86_INS_FPREM1:
        ii->pclass=NP; ii->occ=120; ii->lat=120; ii->fp_role=3; break;
    /* ---- string ---- */
    case X86_INS_MOVSB: case X86_INS_MOVSW: case X86_INS_MOVSD:
    case X86_INS_STOSB: case X86_INS_STOSW: case X86_INS_STOSD:
    case X86_INS_LODSB: case X86_INS_LODSW: case X86_INS_LODSD:
    case X86_INS_CMPSB: case X86_INS_CMPSW: case X86_INS_CMPSD:
    case X86_INS_SCASB: case X86_INS_SCASW: case X86_INS_SCASD:
        ii->pclass=NP; ii->occ=4; ii->lat=4; break;
    case X86_INS_NOP: case X86_INS_FNOP:
        ii->pclass=UV; ii->pairs_first=ii->pairs_second=true;
        ii->occ=1; ii->lat=1; break;
    default:
        /* setcc/cdq/cwde/etc. keep NP defaults; tag conditional branches we missed */
        if (cs_insn_group(cs_handle, in, X86_GRP_JUMP)) {
            ii->is_branch=true; ii->is_cond=true;
            ii->pclass=PV; ii->pairs_second=true; ii->occ=1; ii->lat=1;
        }
        break;
    }
    /* Jcc (conditional) detection: capstone marks them X86_GRP_JUMP and id Jxx */
    if (ii->is_branch && id!=X86_INS_JMP && id!=X86_INS_CALL && !ii->is_callret
        && id!=X86_INS_LOOP && id!=X86_INS_LOOPE && id!=X86_INS_LOOPNE)
        ii->is_cond = true;
}

/* ------------------------------- cache model -------------------------------- */
static bool l1_access(l1set_t *cache, uint64_t addr)   /* true=hit */
{
    uint32_t set = (addr / L1_LINE) % L1_SETS;
    uint32_t tag = addr / L1_LINE / L1_SETS;
    l1set_t *s = &cache[set];
    for (int w=0; w<L1_WAYS; w++)
        if (s->val[w] && s->tag[w]==tag){ s->lru = w; return true; }
    int victim = s->lru ^ 1;          /* 2-way LRU: replace the not-MRU way */
    s->val[victim]=true; s->tag[victim]=tag; s->lru=victim;
    return false;
}

/* ------------------------------- BTB model ---------------------------------- */
static bool btb_predict(uint64_t pc)
{
    uint32_t set=pc % BTB_SETS, tag=pc / BTB_SETS;
    btbset_t *s=&g.btb[set];
    for (int w=0;w<BTB_WAYS;w++) if(s->val[w]&&s->tag[w]==tag) return s->ctr[w]>=2;
    return false;   /* BTB miss => predict not-taken */
}
static void btb_update(uint64_t pc, bool taken)
{
    uint32_t set=pc % BTB_SETS, tag=pc / BTB_SETS;
    btbset_t *s=&g.btb[set];
    for (int w=0;w<BTB_WAYS;w++) if(s->val[w]&&s->tag[w]==tag){
        if (taken){ if(s->ctr[w]<3)s->ctr[w]++; } else { if(s->ctr[w]>0)s->ctr[w]--; }
        return;
    }
    if (!taken) return;                 /* not-taken & not in BTB: no allocation */
    int v=s->rr; s->rr=(s->rr+1)&(BTB_WAYS-1);   /* pseudo-random replacement */
    s->val[v]=true; s->tag[v]=tag; s->ctr[v]=3;  /* first-taken => strongly taken */
}

/* ------------------------- pairing decision --------------------------------- */
static bool can_pair(insn_t *u, insn_t *v)
{
    if (!u || !u->pairs_first || !v->pairs_second) return false;
    if (u->has_disp_imm || v->has_disp_imm) return false;
    if (u->prefixes || v->prefixes) return false;     /* prefixed => U-only */
    uint8_t wU = u->writes & GP_NOSP_MASK;             /* deps ignore ESP, flags */
    if ((v->reads & wU) || (v->writes & wU)) return false; /* RAW / WAW */
    return true;
}

/* --------------------------- record buffer ---------------------------------- */
static void emit_record(uint64_t pc, uint64_t cyc, char pipe, bool paired,
                        uint32_t stall, const insn_t *ii)
{
    if (g.nrec == g.caprec) {
        g.caprec = g.caprec ? g.caprec*2 : 4096;
        g.recs = (rec_t *)realloc(g.recs, g.caprec * sizeof(rec_t));
    }
    rec_t *r = &g.recs[g.nrec++];
    r->pc = pc; r->cyc = cyc; r->pipe = pipe; r->paired = paired;
    r->stall = stall; r->ii = ii;
}

/* --------------------------- the timing core -------------------------------- */
static void resolve_pending_branch(uint64_t this_vaddr)
{
    if (!g.pend_branch) return;
    bool taken = (this_vaddr != g.pend_fallthru);
    if (taken != g.pend_pred_taken) {
        uint64_t pen = !g.pend_cond ? P5_MISPREDICT_UNCOND
                     : (g.pend_in_v ? P5_MISPREDICT_V : P5_MISPREDICT_U);
        g.pipe_free_at += pen;          /* flush: target delayed */
        if (g.grp_cycle < g.pipe_free_at) g.grp_cycle = g.pipe_free_at;
        /* attribute the mispredict bubble to THIS (the redirected) instruction */
        g.cur_pen += pen;
    }
    btb_update(g.pend_pc, taken);
    g.pend_branch = false;
}

static void p5_insn_exec(unsigned int cpu, void *ud)
{
    insn_t *ii = (insn_t *)ud;
    uint64_t cyc_before = g.cycles;
    g.cur_pen = 0;

    /* fold in the previous instruction's data-cache stall, then resolve branch */
    g.pipe_free_at += g.pending_mem_pen;
    g.cur_pen += g.pending_mem_pen;   /* attribute prev mem stall to this retire */
    g.pending_mem_pen = 0;
    resolve_pending_branch(ii->vaddr);

    /* I-cache fetch (instruction may straddle a line) */
    if (g.model_cache) {
        if (!l1_access(g.icache, ii->vaddr)) { g.pipe_free_at += g.imiss; g.cur_pen += g.imiss; }
        if ((ii->vaddr & (L1_LINE-1)) + ii->size > L1_LINE) {
            if (!l1_access(g.icache, ii->vaddr + L1_LINE)) { g.pipe_free_at += g.imiss; g.cur_pen += g.imiss; }
        }
    }

    /* operand readiness (RAW) */
    int64_t ready = 0;
    bool is_fp = (ii->fp_role >= 1);   /* any x87 producer/consumer/rmw (NOT FXCH=0) */
    for (int r=0;r<R_N;r++) if ((ii->reads>>r)&1) if (g.reg_ready[r]>ready) ready=g.reg_ready[r];
    if (ii->fp_role>=2 && g.fp_ready>ready) ready=g.fp_ready;  /* x87 top-of-stack dep */
    /* GAP1: a FOLLOWING FP op waits until the single x87 exec unit is free (the FDIV
       shadow). Integer ops never enter this branch, so they overlap the shadow. */
    if (g.fp_overlap && is_fp && g.fp_busy_until>ready) ready=g.fp_busy_until;

    /* try to pair into the current group's V slot */
    bool paired = false;
    if (g.grp_vfree && can_pair(g.grp_u, ii) && ready <= (int64_t)g.grp_cycle) {
        /* AGI check at grp_cycle */
        bool agi=false;
        for (int r=0;r<R_N;r++) if((ii->addr>>r)&1) if(g.reg_wcycle[r]==(int64_t)g.grp_cycle-1) agi=true;
        if (!agi) {
            paired = true;
            g.grp_vfree = false;
            uint64_t done = g.grp_cycle + ii->occ;
            if (done > g.pipe_free_at) g.pipe_free_at = done;
            for (int r=0;r<R_N;r++) if((ii->writes>>r)&1){
                g.reg_ready[r]=g.grp_cycle+ii->lat; g.reg_wcycle[r]=g.grp_cycle;
            }
        }
    }

    if (!paired) {
        /* start a new issue group */
        uint64_t issue = g.pipe_free_at;
        if (ready > (int64_t)issue) issue = ready;
        /* AGI */
        for (int r=0;r<R_N;r++) if((ii->addr>>r)&1) if(g.reg_wcycle[r]==(int64_t)issue-1){
            issue += P5_AGI_PENALTY; g.cur_pen += P5_AGI_PENALTY; break;
        }
        issue += ii->prefixes;                  /* prefix decode penalty */
        g.cur_pen += ii->prefixes;
        g.grp_cycle = issue;
        g.grp_u = ii;
        g.grp_vfree = ii->pairs_first;
        if (g.fp_overlap && is_fp) {
            /* GAP1 SPLIT: the integer pipe is freed after only the short dispatch
               slot (min(occ, P5_FP_ISSUE_OCC) — short FP ops like fld/fst occ<=2 are
               unchanged; only the long FDIV/FSQRT cap to the +2 dispatch), while the
               full occ-long exec window lives on fp_busy_until -> the following
               INTEGER groups issue in the FDIV shadow. (x87 ops are NP, so this
               new-group path is the only place fp_busy_until is written.) */
            int64_t isl = (ii->occ < (uint32_t)P5_FP_ISSUE_OCC) ? (int64_t)ii->occ
                                                                : (int64_t)P5_FP_ISSUE_OCC;
            g.fp_busy_until = (int64_t)issue + ii->occ;      /* exec window (39 for fdiv) */
            g.pipe_free_at  = issue + isl;                   /* integer pipe free at +min */
        } else {
            g.pipe_free_at = issue + ii->occ;                /* UNCHANGED default path    */
        }
        for (int r=0;r<R_N;r++) if((ii->writes>>r)&1){
            g.reg_ready[r]=issue+ii->lat; g.reg_wcycle[r]=issue;
        }
    }

    if (ii->fp_role==1 || ii->fp_role==3) g.fp_ready = (int64_t)g.grp_cycle + ii->lat;

    g.cycles = g.pipe_free_at;

    /* set up deferred branch resolution */
    if (ii->is_branch) {
        g.pend_branch = true;
        g.pend_fallthru = ii->vaddr + ii->size;
        g.pend_pred_taken = btb_predict(ii->vaddr);
        g.pend_in_v = paired;
        g.pend_cond = ii->is_cond;
        g.pend_pc = ii->vaddr;   /* resolved & used to update the BTB on next insn */
    }

    /* Emit the per-retired-instruction cycle record (docs/trace-format.md §2.3).
     * pipe: 'V' if it paired into the open V slot, else 'U' (it held the U pipe).
     * `cyc` is CUMULATIVE; the buffered stall is whatever penalties we attributed
     * to this retire above (and is also reflected as a larger cyc delta). */
    char pipe = paired ? 'V' : 'U';
    uint64_t stall = g.cur_pen;
    (void)cyc_before;
    emit_record(ii->vaddr, g.cycles, pipe, paired, (uint32_t)stall, ii);
    g.seq++;
}

/* ------------------------------ memory cb ----------------------------------- */
static void p5_mem(unsigned int cpu, qemu_plugin_meminfo_t info,
                   uint64_t vaddr, void *ud)
{
    if (!g.model_cache) return;
    unsigned shift = qemu_plugin_mem_size_shift(info);
    unsigned size = 1u << shift;
    bool store = qemu_plugin_mem_is_store(info);
    bool hit = l1_access(g.dcache, vaddr);
    if (!hit && !store) { g.pending_mem_pen += g.dmiss; }  /* read-allocate */
    if (vaddr & (size-1)) { g.pending_mem_pen += P5_MISALIGN_PENALTY; }  /* misaligned */
}

/* ------------------------------ translate cb -------------------------------- */
static void vcpu_tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    size_t n = qemu_plugin_tb_n_insns(tb);
    for (size_t i=0;i<n;i++){
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        const uint8_t *data = qemu_plugin_insn_data(insn);
        size_t sz = qemu_plugin_insn_size(insn);
        uint64_t va = qemu_plugin_insn_vaddr(insn);

        insn_t *ii = g_new0(insn_t, 1);
        ii->vaddr = va; ii->size = sz>255?255:sz;
        /* stash raw bytes for the optional "bytes" trace field */
        ii->rawlen = sz>sizeof(ii->raw) ? sizeof(ii->raw) : (uint8_t)sz;
        memcpy(ii->raw, data, ii->rawlen);

        cs_insn *ci = NULL;
        size_t cnt = cs_disasm(cs_handle, data, sz, va, 1, &ci);
        if (cnt==1){ classify(ci, ii); cs_free(ci, cnt); }
        else { ii->pclass=NP; ii->occ=1; ii->lat=1; }

        qemu_plugin_register_vcpu_insn_exec_cb(insn, p5_insn_exec,
                                               QEMU_PLUGIN_CB_NO_REGS, ii);
        if (ii->is_mem)
            qemu_plugin_register_vcpu_mem_cb(insn, p5_mem, QEMU_PLUGIN_CB_NO_REGS,
                                             QEMU_PLUGIN_MEM_RW, ii);
    }
}

/* -------------------------------- flush ------------------------------------- */
/* Write the header + all buffered records as JSON Lines (docs/trace-format.md
 * §1). Field names/formatting MUST match tracefmt.py exactly — pc is a 32-bit
 * zero-padded lowercase hex string ("0x%08x"), bytes is lowercase hex no 0x. */
static void p5_exit(qemu_plugin_id_t id, void *p)
{
    FILE *o = g.out ? g.out : stderr;

    /* Header line (cycle mode, no x87 fields). */
    fprintf(o, "{\"vtrace\":1,\"producer\":\"qemu-plugin\",\"mode\":\"cycle\","
               "\"x87\":false,\"note\":\"p5trace: P5/P54C in-order U+V cycle estimate"
               " (imiss=%u,dmiss=%u,cache=%d)\"}\n",
            g.imiss, g.dmiss, g.model_cache ? 1 : 0);

    for (size_t i=0;i<g.nrec;i++){
        rec_t *r=&g.recs[i];
        const char *pipe = r->pipe=='U' ? "U" : r->pipe=='V' ? "V" : "-";
        uint64_t pc32 = (uint64_t)(uint32_t)r->pc;   /* trace pc is 32-bit */
        fprintf(o, "{\"n\":%zu,\"pc\":\"0x%08" PRIx64 "\",\"cyc\":%" PRIu64
                   ",\"pipe\":\"%s\",\"paired\":%s,\"stall\":%u",
                i, pc32, r->cyc, pipe,
                r->paired ? "true" : "false", r->stall);
        if (g.emit_bytes && r->ii && r->ii->rawlen) {
            fputs(",\"bytes\":\"", o);
            for (uint8_t b=0;b<r->ii->rawlen;b++) fprintf(o, "%02x", r->ii->raw[b]);
            fputc('"', o);
        }
        fputs("}\n", o);
    }

    if (g.out && g.out!=stderr && g.out!=stdout) fclose(g.out);
    free(g.recs);
}

/* -------------------------------- install ----------------------------------- */
QEMU_PLUGIN_EXPORT
int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info,
                        int argc, char **argv)
{
    g.imiss = 8; g.dmiss = 8; g.model_cache = true;  /* defaults (see README) */
    g.emit_bytes = true;                             /* default: include bytes */
    const char *outpath = NULL;
    for (int i=0;i<argc;i++){
        char *a = argv[i];
        if (!strncmp(a,"out=",4)) outpath = a+4;
        else if (!strncmp(a,"imiss=",6)) g.imiss = atoi(a+6);
        else if (!strncmp(a,"dmiss=",6)) g.dmiss = atoi(a+6);
        else if (!strncmp(a,"cache=",6)) g.model_cache = atoi(a+6);
        else if (!strncmp(a,"bytes=",6)) g.emit_bytes = atoi(a+6);
        else if (!strncmp(a,"fpovl=",6)) g.fp_overlap = atoi(a+6);
        else if (!strncmp(a,"fxchfree=",9)) g.fxch_free = atoi(a+9);
    }
    g.out = outpath ? fopen(outpath,"w") : stderr;
    if (!g.out) { fprintf(stderr,"p5trace: cannot open out=%s\n", outpath?outpath:""); g.out = stderr; }

    if (cs_open(CS_ARCH_X86, CS_MODE_32, &cs_handle)!=CS_ERR_OK) {
        fprintf(stderr,"p5trace: capstone init failed\n"); return -1;
    }
    cs_option(cs_handle, CS_OPT_DETAIL, CS_OPT_ON);

    qemu_plugin_register_vcpu_tb_trans_cb(id, vcpu_tb_trans);
    qemu_plugin_register_atexit_cb(id, p5_exit, NULL);
    return 0;
}
