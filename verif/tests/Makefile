# =============================================================================
# Ventium test corpus -- build the smoke + M1 test binaries. (PLAN.md §4 / §7)
#
# Targets:
#   make            (= all) build every program's .elf, ISA-verify it, flatten
#                            -> .flat, and validate manifest.json vs the ELF.
#   make verify     re-run isa_verify on every built ELF.
#   make run        run every ELF under the harness QEMU (each must exit 0).
#   make clean      remove built artifacts (.elf, .flat).
#
# Driven from the repo root:   make -C verif/tests
# Pure host toolchain (no nasm): GNU as/ld via gcc -m32, python3 stdlib.
#
# Corpus:
#   smoke    -- M0 smoke program (do NOT modify; the M1 baseline).
#   t_mem    -- memory load/store via ModR/M disp32/base/disp8/SIB + ALU (AGU).
#   t_loop   -- counted loops: dec/inc + cmp/test + jne/jl, taken & not-taken.
#   t_branch -- Jcc condition-code coverage (je/jne/jl/jge/jg/jb/ja) + jmp +
#               never-taken sentinels.
# Each M1 program is freestanding (.globl _start), ends with
#   mov $1,%eax; xor %ebx,%ebx; int $0x80  (Linux i386 _exit(0) / core halt).
# =============================================================================

# This Makefile's own directory (verif/tests), regardless of -C / cwd.
HERE := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
# Repo root = two levels up (verif/tests -> verif -> root).
ROOT := $(abspath $(HERE)/../..)

# Read-only harness submodule: ISA verifier and golden QEMU.
HARNESS    := $(ROOT)/ventium-refs/07-p5-emulation-harness
ISA_VERIFY := $(HARNESS)/tools/isa_verify.py
QEMU       := $(HARNESS)/build/qemu/build/qemu-i386

PYTHON  ?= python3
CC      ?= gcc

# Fixed load/text address for the whole corpus (also recorded in each manifest).
LOAD_ADDR := 0x08048000

# Toolchain flags. -nostdlib/-static = freestanding; -Ttext pins .text at the
# chosen load address; --build-id=none drops the NOTE segment so the loadable
# image is just headers + code (QEMU's linux-user loader still maps it cleanly,
# unlike an -n/-N omagic layout).
ASFLAGS  := -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=$(LOAD_ADDR)

ELF2FLAT := elf2flat.py

# --- corpus list -------------------------------------------------------------
# Each PROG has PROG/PROG.{s,elf,flat} and PROG/manifest.json.
PROGS := smoke t_mem t_loop t_branch

ELFS  := $(foreach p,$(PROGS),$(p)/$(p).elf)
FLATS := $(foreach p,$(PROGS),$(p)/$(p).flat)

.PHONY: all verify run clean check-manifest
all: $(FLATS) verify
	@echo "[tests] corpus built: $(PROGS)"

# Assemble + link each freestanding ELF.  (Static pattern over the corpus.)
$(ELFS): %.elf: %.s
	$(CC) $(ASFLAGS) -o $@ $<

# Flatten the loadable code into a raw blob based at LOAD_ADDR, and in the same
# pass validate the program's manifest.json against the freshly-built ELF
# (entry/load_addr/keys). elf2flat clips off the sub-LOAD_ADDR headers segment,
# so the blob starts at the entry/code (and spans any .data/.bss page, zero-
# filling the gap). $(@D) = the target's directory (= the program dir), so the
# matching manifest.json is $(@D)/manifest.json.
$(FLATS): %.flat: %.elf $(ELF2FLAT)
	$(PYTHON) $(ELF2FLAT) $< --out $@ --base $(LOAD_ADDR) \
		--check-manifest $(@D)/manifest.json

# Standalone manifest re-validation for every program (no image rebuild).
check-manifest: $(ELFS)
	@set -e; for p in $(PROGS); do \
		$(PYTHON) $(ELF2FLAT) $$p/$$p.elf --out /dev/null --base $(LOAD_ADDR) \
			--check-manifest $$p/manifest.json; \
	done

# Static ISA check: each ELF must be pure original-Pentium (no MMX/SSE/CMOV/...).
verify: $(ELFS)
	@set -e; for p in $(PROGS); do \
		echo "[verify] $$p"; \
		$(PYTHON) $(ISA_VERIFY) $$p/$$p.elf; \
	done

# Smoke-run each ELF under the golden QEMU; exit code must be 0 (Linux _exit(0)).
run: $(ELFS)
	@set -e; for p in $(PROGS); do \
		echo "[run] $$p"; \
		$(QEMU) -cpu pentium ./$$p/$$p.elf; \
		echo "[run] $$p exited 0"; \
	done
	@echo "[tests] all programs ran under QEMU and exited 0"

clean:
	rm -f $(ELFS) $(FLATS)
