# Additional generated-model makefile, enabled only by VL_INPUT_SNAPSHOT=1.
VENTIUM_SNAPSHOT_GENERATOR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../tools/gen_model_input_snapshot.py)

model_input_snapshot.h: Vventium_top.h $(VENTIUM_SNAPSHOT_GENERATOR)
	$(PYTHON3) $(VENTIUM_SNAPSHOT_GENERATOR) --model-header Vventium_top.h --output $@

# Verilator derives these names from --exe inputs. Isolated variant builds use
# private harness basenames to prevent VPATH from reusing an unrelated object;
# a dependency on tb_main.o alone races header generation in those builds.
$(addsuffix .o,$(VM_USER_CLASSES)): model_input_snapshot.h
