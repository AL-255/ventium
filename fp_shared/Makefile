REPO ?= $(abspath $(CURDIR)/..)
VERILATOR ?= verilator
# The shared-FP top produces several very large generated C++ translation units.
# A parallel `make test` used to launch one Verilator build per test target, and
# each build in turn requested four compiler jobs.  That multiplicative fan-out
# is enough to exhaust a normal developer workstation.  Keep both layers
# serial by default; a deliberately provisioned runner may explicitly raise
# VL_J for one build at a time.
VL_J ?= 1
CCACHE_DISABLE ?= 1
export CCACHE_DISABLE
BUILD := $(CURDIR)/build
REF_FPPIPE_BUILD := $(BUILD)/reference-fppipe
REF_BCD_BUILD := $(BUILD)/reference-bcd
REF_FBLD_BUILD := $(BUILD)/reference-fbld
REF_SRT_BUILD := $(BUILD)/srt
SRT := $(CURDIR)/fpu_srt_div.sv

PKGS := \
	$(REPO)/rtl/core/ventium_decode_pkg.sv \
	$(REPO)/rtl/fpu/fpu_x87_pkg.sv \
	$(REPO)/rtl/core/ventium_x87_pkg.sv
SRC := ven_fp_state.sv ven_fp_alu.sv ven_fp_misc.sv ven_fp_widemul.sv \
	ven_fp_estdiv.sv ven_fp_trans.sv ven_fp_top.sv
VLFLAGS := --binary -j $(VL_J) --timing -sv -Wall -Wno-fatal -Wno-UNUSED \
	-Wno-PROCASSINIT -I$(REPO)/rtl/fpu

.PHONY: all lint lint-old-ooc test test-state test-alu test-widemul test-estdiv test-srt-sqrt \
	test-trans test-top test-arch reference-bcd reference-fbld \
	reference-srt reference-fppipe synth synth-ooc synth-ooc-old synth-ooc-shared

# Do not let a caller's `make -j` multiply memory-heavy Verilator jobs across
# independent tests.  This applies to every target in this makefile, including
# the OOC A/B, and does not coordinate with or preempt any board flow.
.NOTPARALLEL:

all: test

lint:
	$(VERILATOR) --lint-only -sv -Wall -Wno-fatal -Wno-UNUSED \
		-Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN \
		-Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
		--top-module ven_fp_top +define+VEN_FPREM $(PKGS) \
		$(SRT) $(REPO)/rtl/fpu/ven_bcd.sv \
		$(REPO)/rtl/fpu/ven_bcd_to_fp.sv \
		-I$(REPO)/rtl/fpu $(SRC)

lint-old-ooc:
	$(VERILATOR) --lint-only -sv -Wall -Wno-fatal -Wno-UNUSED \
		-Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN \
		-Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
		--top-module ven_fp_old_ooc +define+VEN_FPREM $(PKGS) \
		$(REPO)/rtl/fpu/fpu_top.sv $(REPO)/rtl/fpu/fpu_fx_ppl.sv \
		$(REPO)/rtl/fpu/fpu_srt_div.sv $(REPO)/rtl/fpu/ven_bcd.sv \
		$(REPO)/rtl/fpu/ven_bcd_to_fp.sv $(REPO)/rtl/fpu/fpu_estdiv.sv \
		$(REPO)/rtl/fpu/fpu_fsincos.sv $(REPO)/rtl/fpu/fpu_f2xm1.sv \
		$(REPO)/rtl/fpu/fpu_fyl2x.sv $(REPO)/rtl/fpu/fpu_fpatan.sv \
		-I$(REPO)/rtl/fpu ven_fp_misc.sv ven_fp_old_ooc.sv

$(BUILD)/state/Vtb_ven_fp_state: ven_fp_state.sv tb/tb_ven_fp_state.sv
	mkdir -p $(BUILD)/state
	CCACHE_DISABLE=1 $(VERILATOR) $(VLFLAGS) --top-module tb_ven_fp_state \
		--Mdir $(BUILD)/state ven_fp_state.sv \
		$(REPO)/rtl/fpu/fpu_top.sv tb/tb_ven_fp_state.sv

$(BUILD)/alu/Vtb_ven_fp_alu: ven_fp_alu.sv tb/tb_ven_fp_alu.sv
	mkdir -p $(BUILD)/alu
	CCACHE_DISABLE=1 $(VERILATOR) $(VLFLAGS) --top-module tb_ven_fp_alu \
		--Mdir $(BUILD)/alu $(REPO)/rtl/fpu/fpu_x87_pkg.sv \
		$(REPO)/rtl/core/ventium_x87_pkg.sv \
		$(REPO)/rtl/fpu/fpu_fx_ppl.sv ven_fp_alu.sv tb/tb_ven_fp_alu.sv

$(BUILD)/widemul/Vtb_ven_fp_widemul: ven_fp_widemul.sv \
		tb/tb_ven_fp_widemul.sv
	mkdir -p $(BUILD)/widemul
	CCACHE_DISABLE=1 $(VERILATOR) $(VLFLAGS) --top-module tb_ven_fp_widemul \
		--Mdir $(BUILD)/widemul ven_fp_widemul.sv tb/tb_ven_fp_widemul.sv

$(BUILD)/estdiv/Vtb_ven_fp_estdiv: ven_fp_estdiv.sv tb/tb_ven_fp_estdiv.sv \
		$(REPO)/rtl/fpu/fpu_estdiv.sv
	mkdir -p $(BUILD)/estdiv
	CCACHE_DISABLE=1 $(VERILATOR) $(VLFLAGS) --top-module tb_ven_fp_estdiv \
		--Mdir $(BUILD)/estdiv $(REPO)/rtl/fpu/fpu_estdiv.sv \
		ven_fp_estdiv.sv tb/tb_ven_fp_estdiv.sv

$(BUILD)/srt-sqrt/Vtb_ven_fp_srt_sqrt: tb/tb_ven_fp_srt_sqrt.sv \
		$(SRT)
	mkdir -p $(BUILD)/srt-sqrt
	CCACHE_DISABLE=1 $(VERILATOR) $(VLFLAGS) --top-module tb_ven_fp_srt_sqrt \
		--Mdir $(BUILD)/srt-sqrt +define+VEN_FPREM \
		$(REPO)/rtl/fpu/fpu_x87_pkg.sv \
		$(SRT) tb/tb_ven_fp_srt_sqrt.sv

$(BUILD)/trans/Vtb_ven_fp_trans: ven_fp_alu.sv ven_fp_widemul.sv ven_fp_estdiv.sv ven_fp_trans.sv \
		tb/tb_ven_fp_trans.sv
	mkdir -p $(BUILD)/trans
	CCACHE_DISABLE=1 $(VERILATOR) $(VLFLAGS) --top-module tb_ven_fp_trans \
		--Mdir $(BUILD)/trans $(PKGS) \
		$(REPO)/rtl/fpu/fpu_estdiv.sv $(REPO)/rtl/fpu/fpu_srt_div.sv \
		$(REPO)/rtl/fpu/fpu_fsincos.sv $(REPO)/rtl/fpu/fpu_f2xm1.sv \
		$(REPO)/rtl/fpu/fpu_fyl2x.sv $(REPO)/rtl/fpu/fpu_fpatan.sv \
		ven_fp_alu.sv ven_fp_widemul.sv ven_fp_estdiv.sv ven_fp_trans.sv tb/tb_ven_fp_trans.sv

$(BUILD)/top/Vtb_ven_fp_top: $(SRT) $(SRC) tb/tb_ven_fp_top.sv
	mkdir -p $(BUILD)/top
	CCACHE_DISABLE=1 $(VERILATOR) $(VLFLAGS) --top-module tb_ven_fp_top \
		+define+VEN_FPREM --Mdir $(BUILD)/top $(PKGS) \
		$(SRT) $(REPO)/rtl/fpu/ven_bcd.sv \
		$(REPO)/rtl/fpu/ven_bcd_to_fp.sv \
		$(REPO)/rtl/fpu/fpu_estdiv.sv \
		$(SRC) tb/tb_ven_fp_top.sv

$(BUILD)/arch/Vtb_ven_fp_arch_ab: $(SRT) $(SRC) tb/old_state_e.sv \
		tb/tb_ven_fp_arch_ab.sv
	mkdir -p $(BUILD)/arch
	CCACHE_DISABLE=1 $(VERILATOR) $(VLFLAGS) --top-module tb_ven_fp_arch_ab \
		+define+VTM_NO_DPI +define+VEN_SRT_ITER +define+VEN_BCD_ITER \
		+define+VEN_TRANSCENDENTAL +define+VEN_FPREM +define+VEN_DIV_EXACT \
		--Mdir $(BUILD)/arch \
		$(REPO)/rtl/ventium_pkg.sv \
		$(REPO)/rtl/core/ventium_alu_pkg.sv \
		$(REPO)/rtl/core/ventium_decode_pkg.sv \
		$(REPO)/rtl/fpu/fpu_x87_pkg.sv \
		$(REPO)/rtl/core/ventium_sys_pkg.sv \
		$(REPO)/rtl/core/ventium_x87_pkg.sv \
		tb/old_state_e.sv $(REPO)/rtl/core/fpu_writeback.sv \
		$(REPO)/rtl/fpu/fpu_top.sv \
		$(SRT) $(REPO)/rtl/fpu/ven_bcd.sv \
		$(REPO)/rtl/fpu/ven_bcd_to_fp.sv \
		$(REPO)/rtl/fpu/fpu_estdiv.sv \
		$(SRC) tb/tb_ven_fp_arch_ab.sv

test-state: $(BUILD)/state/Vtb_ven_fp_state
	$<

test-alu: $(BUILD)/alu/Vtb_ven_fp_alu
	$<

test-widemul: $(BUILD)/widemul/Vtb_ven_fp_widemul
	$<

test-estdiv: $(BUILD)/estdiv/Vtb_ven_fp_estdiv
	$<

test-srt-sqrt: $(BUILD)/srt-sqrt/Vtb_ven_fp_srt_sqrt
	$<

test-trans: $(BUILD)/trans/Vtb_ven_fp_trans
	$<

test-top: $(BUILD)/top/Vtb_ven_fp_top
	$<

test-arch: $(BUILD)/arch/Vtb_ven_fp_arch_ab
	$<

$(REF_FPPIPE_BUILD)/Vtb_fppipe: \
		$(REPO)/verif/fppipe/tb_fppipe.sv \
		$(REPO)/rtl/fpu/fpu_x87_pkg.sv
	mkdir -p $(REF_FPPIPE_BUILD)
	$(VERILATOR) --binary -j $(VL_J) --quiet -Wall -Wno-fatal \
		-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED \
		-Wno-DECLFILENAME -Wno-IMPLICITSTATIC +define+FPPIPE_N=1000000 \
		-Mdir $(REF_FPPIPE_BUILD) --top-module tb_fppipe \
		$(REPO)/rtl/ventium_pkg.sv \
		$(REPO)/rtl/core/ventium_alu_pkg.sv \
		$(REPO)/rtl/core/ventium_decode_pkg.sv \
		$(REPO)/rtl/fpu/fpu_x87_pkg.sv \
		$(REPO)/rtl/core/ventium_sys_pkg.sv \
		$(REPO)/rtl/core/ventium_x87_pkg.sv \
		$(REPO)/verif/fppipe/tb_fppipe.sv

reference-fppipe: $(REF_FPPIPE_BUILD)/Vtb_fppipe
	$< > $(REF_FPPIPE_BUILD)/run.log
	rg -q 'FPPIPE-GATE-OK' $(REF_FPPIPE_BUILD)/run.log
	rg 'FPPIPE-GATE-OK' $(REF_FPPIPE_BUILD)/run.log

$(REF_BCD_BUILD)/Vtb_bcd: $(REPO)/verif/bcd/tb_bcd.sv \
		$(REPO)/rtl/fpu/ven_bcd.sv
	mkdir -p $(REF_BCD_BUILD)
	$(VERILATOR) --binary -j $(VL_J) --timing --quiet -Wall -Wno-fatal \
		-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED \
		-Wno-DECLFILENAME -Wno-IMPLICITSTATIC +define+BCD_N=40000 \
		-Mdir $(REF_BCD_BUILD) --top-module tb_bcd \
		$(REPO)/rtl/fpu/fpu_x87_pkg.sv $(REPO)/rtl/fpu/ven_bcd.sv \
		$(REPO)/verif/bcd/tb_bcd.sv

reference-bcd: $(REF_BCD_BUILD)/Vtb_bcd
	$< > $(REF_BCD_BUILD)/run.log
	rg -q 'BCD-GATE-OK' $(REF_BCD_BUILD)/run.log
	rg 'BCD-GATE-OK' $(REF_BCD_BUILD)/run.log

$(REF_FBLD_BUILD)/Vtb_bcd_to_fp: $(REPO)/verif/fbld/tb_bcd_to_fp.sv \
		$(REPO)/rtl/fpu/ven_bcd_to_fp.sv
	mkdir -p $(REF_FBLD_BUILD)
	$(VERILATOR) --binary -j $(VL_J) --timing --quiet -Wall -Wno-fatal \
		-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED \
		-Wno-DECLFILENAME -Wno-IMPLICITSTATIC +define+FBLD_N=40000 \
		-Mdir $(REF_FBLD_BUILD) --top-module tb_bcd_to_fp \
		$(REPO)/rtl/fpu/fpu_x87_pkg.sv $(REPO)/rtl/fpu/ven_bcd_to_fp.sv \
		$(REPO)/verif/fbld/tb_bcd_to_fp.sv

reference-fbld: $(REF_FBLD_BUILD)/Vtb_bcd_to_fp
	$< > $(REF_FBLD_BUILD)/run.log
	rg -q 'FBLD-GATE-OK' $(REF_FBLD_BUILD)/run.log
	rg 'FBLD-GATE-OK' $(REF_FBLD_BUILD)/run.log

$(REF_SRT_BUILD)/vec_a.hex: $(REPO)/verif/srt/gen_vectors.py \
		$(REPO)/tools/srt/srt_model.py
	python3 $(REPO)/verif/srt/gen_vectors.py $(REF_SRT_BUILD)

$(REF_SRT_BUILD)/obj_iter/Vtb_srt_iter: $(REF_SRT_BUILD)/vec_a.hex \
		$(REPO)/verif/srt/tb_srt_iter.sv $(SRT)
	mkdir -p $(REF_SRT_BUILD)/obj_iter
	$(VERILATOR) --binary -j $(VL_J) --timing --quiet -Wall -Wno-fatal \
		-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME \
		+define+SRT_N=609 -Mdir $(REF_SRT_BUILD)/obj_iter \
		--top-module tb_srt_iter $(REPO)/rtl/fpu/fpu_x87_pkg.sv \
		$(SRT) $(REPO)/verif/srt/tb_srt_iter.sv

reference-srt: $(REF_SRT_BUILD)/obj_iter/Vtb_srt_iter
	$< > $(REF_SRT_BUILD)/run-iter.log
	rg -q 'SRT-ITER-GATE-OK' $(REF_SRT_BUILD)/run-iter.log
	rg 'SRT-ITER-GATE-OK' $(REF_SRT_BUILD)/run-iter.log

test: lint lint-old-ooc test-state test-alu test-widemul test-estdiv test-srt-sqrt test-trans test-top \
	test-arch reference-bcd reference-fbld reference-srt reference-fppipe

synth: synth-ooc

synth-ooc: synth-ooc-old synth-ooc-shared

synth-ooc-old: lint-old-ooc
	bash ./run_ooc_vivado.sh old

synth-ooc-shared: lint
	bash ./run_ooc_vivado.sh shared
