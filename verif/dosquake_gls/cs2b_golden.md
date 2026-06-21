# DOS-Quake #DE — cs=0x2b divergence golden (from qemu /tmp/qasm.log)

cs=0x2b: base=0x00025930, 16-bit (CS16), the go32 stub PM code.
qemu executes cs=0x2b ONLY at eips (in this order, a ~1.4KB loop):
  0x3b44 0x3e80 0x402e 0x4035 0x403b 0x405a 0x405d 0x4068 0x4082 0x4085 0x408d 0x4094 0x4095
qemu NEVER executes cs=0x2b:0x24e -> the board WILD-JUMPS there (#DE site).
Board #DE: cs=0x2b UNCHANGED -> the wild jump is a NEAR transfer (RET/jmp), not far.

## PRIME SUSPECT: LSS @ cs=0x2b:0x4085  (linear 0x299b5)
  bytes: 66 2e 0f b2 26 9d 40 (..)   = LSS esp, [cs:0x409d]   (opsize+CS-pfx, 0fb2)
  len > 6 ; linear 0x299b5 & 7 = 5  -> straddles the 8-byte fetch-granule boundary
           (0x299b0-7 | 0x299b8-f), bytes split across two granules.
  effect: loads SS:ESP. qemu-correct SS=0x0033 base=0x2b570 across it.
  mis-fetch (fetch-window/granule-straddle bug) -> wrong SS:ESP -> corrupt stack
  -> a later near-RET pops garbage -> wild jump to cs=0x2b:0x24e (cs unchanged).

## cs=0x2b code blocks (linear: OBJD-T bytes), the GLS fixture:
  0x29474:  1e06665666576651061f668bf7b933008ec166bf9823000066b919000000fcf3
  0x2982c:  6664678b06668947206664678b46086689472464678b46048b4f4c89474c6683
  0x29854:  64678b460880e43080fc307418
  0x29861:  64678b46048947506664678b3666897738c606483a016633c08ee08ee80f22d0
  0x299b5:  662e0fb2269d40            <-- LSS @0x4085 (prime suspect)
  0x299c4:  fb                        (STI @0x4094)
  0x299c5:  66ea71e80400a700          (JMP FAR 0x00a7:0x4e871 @0x4095 — ruled out, far)
  far jumps elsewhere: 66ea8d0400008700, 66ea9ce20400a700, ea00007000

## GLS plan: test the synthesized SLOW-PATH fetch (S_FETCH ibuf assembly) of the
## granule-straddling LSS @0x4085 (and the other long insns) vs the qemu golden.
## The icache-module GLS is already clean -> the bug is in the spine ibuf/fetch
## assembly the module GLS doesn't cover.

## UPDATE — divergence is in cs=0x0070, NOT a fetch/far-jump bug
JMP FAR @cs=0x2b:0x3E93 (`ea 00 00 70 00`) FETCHES CORRECT (ibuf0_3=0x700000EA) -> legit
transition to cs=0x0070 (base 0x700, 16-bit). Board then DRIFTS off-by-one there.
qemu cs=0x0070 boundaries: 0x245 -> 0x24f -> 0x255 -> 0x25b -> 0x261 -> 0x267 -> 0x270/0x271.
Block @0x245 (linear 0x945) = `be54062e88261204eb22`:
  0x245: be 54 06            MOV SI, 0x0654        (3B)
  0x248: 2e 88 26 12 04      MOV [cs:0x0412], AH   (5B)  <-- SUSPECT
  0x24d: eb 22               JMP +0x22 -> 0x271    (2B)
Board faults at eip=0x24e = 0x248 + 6  => it decoded the 5-byte MOV as 6 BYTES,
drifting 1 byte into the `eb 22` operand -> garbage decode -> #DE.
The MOV is `2e`(CS-pfx) + `88`(MOV r/m8,r8) + `26`(mod=00,reg=100=AH,rm=110=[disp16]) +
`12 04`(disp16=0x0412). The off-by-one = a 16-bit length mis-decode of this form
(CS-prefix + mod00/rm110 disp16), OR a silicon fetch of an extra byte. Sim renders
Quake (decodes it as 5B) so if it's a pure decode bug it'd be sim-visible -> leans
fetch/synth-context. Comparator (armed cs=0x0070) -> last/prev retired eip pins it;
then capture the MOV's fetched bytes (golden 2e 88 26 12 04) for fetch-vs-decode.
