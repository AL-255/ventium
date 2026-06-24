# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# =============================================================================
# verif/fpu87/Makefile — builds the SoftFloat reference + the x87 oracle.
#
#   make            -> build/softfloat/softfloat.a  +  build/ven_fpu_oracle
#   make oracle     -> just the oracle (rebuilds softfloat if missing)
#   make qref       -> build the transcendental oracle (tools/p5xtrans/qref)
#   make clean      -> remove build/ (submodules + repo stay untouched)
#
# The Berkeley SoftFloat-3e submodule is built OUT OF TREE (objects land under
# build/softfloat/, never inside the submodule) so the submodule working tree
# stays pristine. We use the stock Linux-x86_64-GCC build Makefile but override
# SPECIALIZE_TYPE; see README.md for why 8086-SSE is x87-faithful for extF80.
# =============================================================================
HERE        := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SF          := $(HERE)/extern/berkeley-softfloat-3
SF_SRC      := $(SF)/source
SF_BUILDDIR := $(SF)/build/Linux-x86_64-GCC
TF          := $(HERE)/extern/berkeley-testfloat-3
TF_BUILDDIR := $(TF)/build/Linux-x86_64-GCC
BUILD       := $(HERE)/build
SF_OBJDIR   := $(BUILD)/softfloat
SF_LIB      := $(SF_OBJDIR)/softfloat.a
TF_OBJDIR   := $(BUILD)/testfloat
TF_GEN      := $(TF_OBJDIR)/testfloat_gen
ORACLE      := $(BUILD)/ven_fpu_oracle
FIST_ORACLE := $(BUILD)/fist_oracle
CONV_ORACLE := $(BUILD)/conv_oracle

# extF80 results are identical across the 8086 / 8086-SSE specializations
# (s_propagateNaNExtF80UI.c is byte-identical; conversions use the shared
# commonNaN path). 8086-SSE compiles cleanly (the 8086 spec omits two bf16
# helpers the stock Makefile's object list references), so we build it.
SPECIALIZE  := 8086-SSE

# Callers MUST match the library's struct layout: SOFTFLOAT_FAST_INT64 selects
# the by-value extF80 API and LITTLEENDIAN fixes the extFloat80M field order.
SF_CFLAGS   := -DSOFTFLOAT_FAST_INT64 -DLITTLEENDIAN=1 -I$(SF_SRC)/include

CC          ?= gcc
CFLAGS      ?= -O2 -Wall -Wextra -std=c11

.PHONY: all oracle fist conv qref testfloat clean
all: $(ORACLE)

# Standalone x87 FIST (floatx80 -> signed int) golden for the OOC fist gate.
fist: $(FIST_ORACLE)
$(FIST_ORACLE): oracle/fist_oracle.c $(SF_LIB)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(SF_CFLAGS) -o $@ $< $(SF_LIB)

# Standalone x87 f32/f64 <-> floatx80 conversion golden for the OOC conv gate.
conv: $(CONV_ORACLE)
$(CONV_ORACLE): oracle/conv_oracle.c $(SF_LIB)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(SF_CFLAGS) -o $@ $< $(SF_LIB)

$(SF_LIB):
	@mkdir -p $(SF_OBJDIR)
	@cp -f $(SF_BUILDDIR)/platform.h $(SF_OBJDIR)/platform.h
	$(MAKE) -C $(SF_OBJDIR) -f $(SF_BUILDDIR)/Makefile \
		SOURCE_DIR=$(SF_SRC) SPECIALIZE_TYPE=$(SPECIALIZE)

oracle: $(ORACLE)
$(ORACLE): oracle/ven_fpu_oracle.c $(SF_LIB)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(SF_CFLAGS) -o $@ $< $(SF_LIB)

# Berkeley TestFloat's input-vector generator (links our SoftFloat library).
# Optional: gen_fpu87.py --testfloat-gen ingests its corner-case operands.
testfloat: $(TF_GEN)
$(TF_GEN): $(SF_LIB)
	@mkdir -p $(TF_OBJDIR)
	@cp -f $(TF_BUILDDIR)/platform.h $(TF_OBJDIR)/platform.h
	$(MAKE) -C $(TF_OBJDIR) -f $(TF_BUILDDIR)/Makefile \
		SOURCE_DIR=$(TF)/source SUBJ_SOURCE_DIR=$(TF)/source/subj-C \
		SOFTFLOAT_DIR=$(SF) SOFTFLOAT_LIB=$(SF_LIB) SPECIALIZE_TYPE=$(SPECIALIZE) \
		testfloat_gen

# The transcendental oracle (F2XM1/FPATAN/FYL2X/FYL2XP1) lives in tools/p5xtrans.
qref:
	$(MAKE) -C $(HERE)/../../tools/p5xtrans qref

clean:
	rm -rf $(BUILD)
