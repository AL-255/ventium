/* Private actual-QEMU SoftFloat A/B probe, not a substitute x87 emulator. */
#include "qemu/osdep.h"
#include "fpu/softfloat.h"

int main(void)
{
    unsigned kind, prec, rc;
    uint64_t ah, al, bh, bl;
    while (scanf("%u %u %u %" SCNx64 " %" SCNx64 " %" SCNx64 " %" SCNx64,
                 &kind, &prec, &rc, &ah, &al, &bh, &bl) == 7) {
        float_status status = { 0 };
        uint64_t high = 0, low, quotient = UINT64_MAX;
        assert(kind <= 4 && prec <= 2 && rc <= 3);
        set_float_rounding_mode(rc, &status);
        set_floatx80_rounding_precision(prec, &status);
        if (kind <= 1) {
            assert(ah <= 0xffff && bh <= 0xffff);
            floatx80 result = floatx80_modrem(make_floatx80(ah, al),
                make_floatx80(bh, bl), kind == 1, &quotient, &status);
            high = result.high;
            low = result.low;
        } else if (kind == 2) {
            low = float32_rem(al, bl, &status);
        } else if (kind == 3) {
            low = float64_rem(al, bl, &status);
        } else {
            float128 a = { .high = ah, .low = al };
            float128 b = { .high = bh, .low = bl };
            float128 result = float128_rem(a, b, &status);
            high = result.high;
            low = result.low;
        }
        printf("%016" PRIx64 " %016" PRIx64 " %04x %016" PRIx64 "\n",
               high, low, get_float_exception_flags(&status), quotient);
    }
    return ferror(stdin) ? 1 : 0;
}
