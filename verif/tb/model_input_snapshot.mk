# Additional generated-model makefile, enabled only by VL_INPUT_SNAPSHOT=1.
VENTIUM_SNAPSHOT_GENERATOR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../tools/gen_model_input_snapshot.py)

model_input_snapshot.h: Vventium_top.h $(VENTIUM_SNAPSHOT_GENERATOR)
	$(PYTHON3) $(VENTIUM_SNAPSHOT_GENERATOR) --model-header Vventium_top.h --output $@

tb_main.o: model_input_snapshot.h
