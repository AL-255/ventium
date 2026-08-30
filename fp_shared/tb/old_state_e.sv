// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// The proven fpu_writeback module consumes the core's compilation-unit FSM
// type.  This focused harness needs only the states referenced by writeback;
// their numeric encodings are irrelevant because no CPU FSM is instantiated.

typedef enum logic [3:0] {
  S_FEXEC,
  S_FSTORE,
  S_FP_BUSY,
  S_BCD_BUSY,
  S_FBLD_BUSY,
  S_TRSC_BUSY,
  S_FPREM_BUSY,
  S_FENV_ST,
  S_FENV_LD,
  S_PIPE
} state_e;
