# tools/p5xtrans/Makefile — the executable silicon spec for the x87 transcendentals (#11).
# The C reference model the silicon-mode RTL must match bit-exact (docs/m11-transcendental-spec.md).
CC     ?= gcc
CFLAGS := -O2 -Wall -Wextra -std=c11
LIBS   := -lquadmath -lm
TARGET := p5xtrans

$(TARGET): p5xtrans.c
	$(CC) $(CFLAGS) -o $@ p5xtrans.c $(LIBS)

# accuracy-validate the model vs quad-precision truth (the P5 ~1 ulp envelope).
.PHONY: validate
validate: $(TARGET)
	./$(TARGET) --validate

# --- QEMU-mode bit-exact reference (the `make verify` x87 gate target) --------
# qref.c reproduces qemu-8.2 helper_f2xm1 bit-for-bit; qref-validate closes the
# loop to the actual pinned qemu-i386 (QREF-F2XM1-QEMU-OK).
qref: qref.c qref_f2xm1_table.inc
	$(CC) $(CFLAGS) -o $@ qref.c -lquadmath -lm

.PHONY: qref-validate
qref-validate: qref
	python3 qref_validate.py

clean:
	rm -f $(TARGET) qref
.PHONY: clean
