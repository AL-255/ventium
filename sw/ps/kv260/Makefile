# sw/ps/kv260/Makefile — board deploy helpers.
BOARD ?= ubuntu@10.0.0.4
HERE  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SR    := $(HERE)sysroot

.PHONY: deploy run bitstream sysroot
deploy:    ; $(HERE)deploy.sh
run:       ; $(HERE)deploy.sh --run
bitstream: ; $(HERE)deploy.sh --bitstream

# Re-fetch the aarch64 libdrm cross sysroot from the board (one-time / if lost).
sysroot:
	mkdir -p $(SR)/include $(SR)/lib
	scp -r $(BOARD):/usr/include/libdrm $(SR)/include/
	scp $(BOARD):/usr/include/xf86drm.h $(BOARD):/usr/include/xf86drmMode.h $(SR)/include/
	scp '$(BOARD):/usr/lib/aarch64-linux-gnu/libdrm.so*' $(SR)/lib/
	@echo "sysroot ready at $(SR)"
