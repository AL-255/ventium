# Optional plain MOV source-ACK retirement

`VEN_P54_MOV_ACK_RETIRE` removes the redundant `S_EXEC` edge following a
complete plain MOV source read. Intel Volume 3, instruction MOV and Appendix F,
specify one EX clock for ordinary byte/word/dword MOV memory operands. CMP and
TEST memory forms specify **two** clocks and are deliberately not admitted.
A single ordinary prefix still costs D1; no frontend clock is credited to EX.

The initial option admits flat user mode only, at most one ordinary prefix,
ordinary `K_ALU/ALU_MOV` register destinations, and no flags/stack/segment/
system/LOCK/FP/control effects. Debug, folded syscall ownership, and older
pending FP results keep the existing conservative path. This is generic ISA
logic, not a CoreMark or Quake address/opcode-sequence special case.

Safety ownership:

- `mem_ack` is the existing FSM-visible fragment-completed ACK. `xp_cross`
  blocks the first legacy page fragment; the final fragment is merged once and
  feeds both the normal source latch and the sole GPR writeback driver.
- `fsm_case_enabled` fences translation, permission, segment, and execution
  diversions. No architectural write or retirement occurs before validation.
- `core_int_retire.svh` is the shared original normal integer retirement/#DB
  authority, also used by `S_EXEC`; flags and debug priorities are not copied
  into a second independently-maintained commit implementation.
- `ibuf` belongs to the captured `q_pc` while `S_LOAD` runs. Ordinary
  `S_DECODE` consumes the previously fetched buffer. Direct `S_PIPE` reference
  dispatch copies the **same** live decoder bytes on its q-capture edge; SHORT
  zeros only suffix bytes beyond the proved instruction length. EX_CHAIN also
  copies its explicit-PC window and excludes incoming MOV. Manual fast shared
  FP captures set `q_is_x87` or disable the integer memory read. Neither
  `S_LOAD` nor its `S_WALK` detour writes `ibuf`.
- Existing D-cache touch, read-miss, misalignment, and fragment accounting stay
  at the source ACK. The option does not alter ISA data, cache geometry, or
  the two-clock service of memory ALU/compare instructions.

Focused tests:

```sh
bash verif/issue_uv/run-p54-mov-ack-leaf.sh
TB_BIN=/path/to/frozen/tb_ventium bash verif/issue_uv/run-mov-ack-retire.sh
```

The real-helper leaf covers admission, merge, WB lanes, exclusion inputs, and
the shared normal retire/#DB task. The prebuilt whole-core/QEMU runner covers
all 24 byte/word/dword destination encodings, all low address-bank positions,
line/page crossings, zero/high-bit data, immediate dependent consumers,
multi-prefix exclusion, and unchanged CMP/TEST execution floors. It has a
540-second global deadline and never builds RTL or boots a full-system guest.
These focused witnesses do not replace the standard acceptance suite.

## Focused qualification, 2026-09-29

The real-helper leaf passed **30,755 checks**; artifacts:
`/tmp/ventium-mov-ack-leaf.r5spzU`.

The frozen combined normal binary
`/tmp/obj_dir_cm_p54_combo_sep29/tb_ventium`, SHA-256
`0c1f589262b397b4ce21256e9ae541a075ce4cd272aae2cd79fc13c071fd8d01`,
passed all **152** pinned-QEMU architectural-state/PC-stream cases in cycle and
cycle-func modes. The gate used 24 workers inside one shared 16 GiB/128-task
scope, with a 540-second global deadline; artifacts:
`/tmp/ventium-mov-ack.AS0HGL`.

Representative warm result-retire spacing from the immediately preceding STC:

| Source instruction | Observed clocks |
| --- | ---: |
| Aligned ordinary word MOV | 2 (66 D1 + one source EX) |
| Word MOV crossing a page | 3 (66 D1 + two complete source beats) |
| Word MOV with two ordinary prefixes, excluded | 4 |
| Word memory CMP, unchanged | 3 (66 D1 + two EX) |

Fault/debug/system exclusion inputs are exercised by the leaf, not claimed as
new full-system qualification. Standard-suite acceptance remains separate.
