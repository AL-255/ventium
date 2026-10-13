/* Private format-rounding probe, not an architectural x87 emulator. */
#include "qemu/osdep.h"
#include "fpu/softfloat.h"

int main(void)
{
    unsigned kind, prec, rc, high, other_high;
    uint64_t low, other_low;
    while (scanf("%u %u %u %x %" SCNx64 " %x %" SCNx64,
                 &kind, &prec, &rc, &high, &low, &other_high, &other_low) == 7) {
        float_status status = { 0 };
        floatx80 input = make_floatx80(high, low);
        floatx80 other = make_floatx80(other_high, other_low);
        uint64_t result_low;
        unsigned result_high = 0;
        assert(kind <= 7 && prec <= 2 && rc <= 3 && high <= 0xffff && other_high <= 0xffff);
        set_float_rounding_mode(rc, &status);
        set_floatx80_rounding_precision(prec, &status);
#ifdef VTM_ROUND_EVENT
        /* Poison each new call to detect missing resets, even on exact input. */
        status.float_round_increment = true;
#endif
        if (kind == 0) {
            result_low = floatx80_to_float32(input, &status);
        } else if (kind == 1) {
            result_low = floatx80_to_float64(input, &status);
        } else {
            floatx80 result;
            switch (kind) {
            case 2: result = floatx80_add(input, make_floatx80(0, 0), &status); break;
            case 3: result = floatx80_add(input, other, &status); break;
            case 4: result = floatx80_sub(input, other, &status); break;
            case 5: result = floatx80_mul(input, other, &status); break;
            case 6: result = floatx80_div(input, other, &status); break;
            case 7: result = floatx80_sqrt(input, &status); break;
            default: abort();
            }
            result_low = result.low;
            result_high = result.high;
        }
        printf("%04x %016" PRIx64 " %04x ", result_high, result_low,
               get_float_exception_flags(&status));
#ifdef VTM_ROUND_EVENT
        printf("%u\n", status.float_round_increment);
#else
        puts("-1");
#endif
    }
    return ferror(stdin) ? 1 : 0;
}
