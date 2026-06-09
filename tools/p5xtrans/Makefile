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

clean:
	rm -f $(TARGET)
.PHONY: clean
