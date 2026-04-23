#import "MPGOJcampDxEncode.h"
#import <math.h>
#import <stdlib.h>
#import <string.h>

static const char *const SQZ_POS = "@ABCDEFGHI"; // 0..9 positive
static const char *const SQZ_NEG = "@abcdefghi"; // 0..9 negative (reuses '@' for 0)
static const char *const DIF_POS = "%JKLMNOPQR"; // 0..9 positive
static const char *const DIF_NEG = "%jklmnopqr"; // 0..9 negative (reuses '%' for 0)

double MPGOJcampChooseYFactor(const double *ys, NSUInteger n, int sigDigits)
{
    if (n == 0) return 1.0;
    double maxAbs = 0.0;
    for (NSUInteger i = 0; i < n; i++) {
        double a = fabs(ys[i]);
        if (a > maxAbs) maxAbs = a;
    }
    if (maxAbs == 0.0) return 1.0;
    double exp = ceil(log10(maxAbs));
    return pow(10.0, exp - sigDigits);
}

int64_t MPGOJcampRoundInt(double v)
{
    // Explicit half-away-from-zero; (int64_t)double truncates toward
    // zero in C, so the ±0.5 nudge gives the rounding we need.
    return (int64_t)(v + (v >= 0.0 ? 0.5 : -0.5));
}

static NSString *encodeWithTables(int64_t v,
                                  const char *posTable,
                                  const char *negTable,
                                  char zeroChar)
{
    if (v == 0) {
        return [NSString stringWithFormat:@"%c", zeroChar];
    }
    BOOL negative = (v < 0);
    // abs() on INT64_MIN is UB; llabs handles it the same way as Python
    // abs() here — that input is out of range for our rounded-integer
    // scale anyway, so don't guard it beyond what C does naturally.
    int64_t mag = negative ? -v : v;
    char buf[32];
    snprintf(buf, sizeof buf, "%lld", (long long)mag);
    int lead = buf[0] - '0';
    const char *table = negative ? negTable : posTable;
    NSMutableString *out = [NSMutableString stringWithCapacity:strlen(buf)];
    [out appendFormat:@"%c", table[lead]];
    if (buf[1] != '\0') {
        [out appendFormat:@"%s", buf + 1];
    }
    return out;
}

NSString *MPGOJcampEncodeSqz(int64_t v)
{
    return encodeWithTables(v, SQZ_POS, SQZ_NEG, '@');
}

NSString *MPGOJcampEncodeDif(int64_t delta)
{
    return encodeWithTables(delta, DIF_POS, DIF_NEG, '%');
}

NSString *MPGOJcampEncodePacY(int64_t v)
{
    // Matches Python f"{v:+d}" and Java String.format("%+d", v):
    // explicit + for non-negatives, - otherwise. + also acts as the
    // JCAMP-DX §5.9 token delimiter, so consecutive PAC values abut
    // without whitespace.
    return [NSString stringWithFormat:@"%+lld", (long long)v];
}

NSString *MPGOJcampFormatG10(double x)
{
    if (isnan(x)) return @"nan";
    if (isinf(x)) return x > 0 ? @"inf" : @"-inf";

    // `%.10g` strips trailing zeros on GNU libc + the Apple CRT the
    // same way Python does. In the rare case a printf dialect pads
    // trailing zeros (not observed on our supported libc), the
    // post-process below is a no-op, so we can lean on it first and
    // normalize defensively afterwards.
    NSString *raw = [NSString stringWithFormat:@"%.10g", x];

    NSRange eRange = [raw rangeOfString:@"e" options:NSCaseInsensitiveSearch];
    NSString *mantissa;
    NSString *exponent;
    if (eRange.location != NSNotFound) {
        mantissa = [raw substringToIndex:eRange.location];
        exponent = [raw substringFromIndex:eRange.location];
    } else {
        mantissa = raw;
        exponent = @"";
    }

    if ([mantissa rangeOfString:@"."].location != NSNotFound) {
        NSUInteger end = mantissa.length;
        while (end > 0 && [mantissa characterAtIndex:end - 1] == '0') end--;
        if (end > 0 && [mantissa characterAtIndex:end - 1] == '.') end--;
        mantissa = [mantissa substringToIndex:end];
    }
    return [mantissa stringByAppendingString:exponent];
}

static NSString *formatAnchor(double x)
{
    return MPGOJcampFormatG10(x);
}

NSString *MPGOJcampEncodeXYData(const double *ys, NSUInteger n,
                                double firstx, double deltax,
                                double yfactor,
                                MPGOJcampDxEncoding mode)
{
    NSCParameterAssert(mode != MPGOJcampDxEncodingAFFN);
    if (n == 0) return @"";

    int64_t *yInt = (int64_t *)malloc(n * sizeof(int64_t));
    for (NSUInteger i = 0; i < n; i++) {
        yInt[i] = MPGOJcampRoundInt(ys[i] / yfactor);
    }

    NSMutableString *out = [NSMutableString stringWithCapacity:32 + n * 8];
    NSUInteger i = 0;
    BOOL havePrev = NO;
    int64_t prevLast = 0;

    while (i < n) {
        NSUInteger j = i + MPGO_JCAMP_VALUES_PER_LINE;
        if (j > n) j = n;
        NSString *anchor = formatAnchor(firstx + (double)i * deltax);

        if (mode == MPGOJcampDxEncodingPAC) {
            [out appendString:anchor];
            [out appendString:@" "];
            if (havePrev) {
                // Explicit Y-check — the decoder drops line-start
                // values matching prev_last unconditionally, so a
                // plateau at the line boundary would silently steal a
                // data point without this sentinel.
                [out appendString:MPGOJcampEncodePacY(prevLast)];
            }
            for (NSUInteger k = i; k < j; k++) {
                [out appendString:MPGOJcampEncodePacY(yInt[k])];
            }
            [out appendString:@"\n"];
            prevLast = yInt[j - 1];
            havePrev = YES;
            i = j;
            continue;
        }

        if (mode == MPGOJcampDxEncodingSQZ) {
            [out appendString:anchor];
            if (havePrev) {
                [out appendString:@" "];
                [out appendString:MPGOJcampEncodeSqz(prevLast)]; // Y-check
            }
            for (NSUInteger k = i; k < j; k++) {
                [out appendString:@" "];
                [out appendString:MPGOJcampEncodeSqz(yInt[k])];
            }
            [out appendString:@"\n"];
            prevLast = yInt[j - 1];
            havePrev = YES;
            i = j;
            continue;
        }

        // DIF — every line starts with an SQZ absolute (y[0] on line
        // 0, prev_last elsewhere). DIF tokens in the body encode the
        // delta from the running value.
        [out appendString:anchor];
        int64_t running;
        NSUInteger start;
        if (!havePrev) {
            [out appendString:@" "];
            [out appendString:MPGOJcampEncodeSqz(yInt[i])];
            running = yInt[i];
            start = i + 1;
        } else {
            [out appendString:@" "];
            [out appendString:MPGOJcampEncodeSqz(prevLast)];
            running = prevLast;
            start = i;
        }
        for (NSUInteger k = start; k < j; k++) {
            int64_t delta = yInt[k] - running;
            [out appendString:@" "];
            [out appendString:MPGOJcampEncodeDif(delta)];
            running = yInt[k];
        }
        [out appendString:@"\n"];
        prevLast = yInt[j - 1];
        havePrev = YES;
        i = j;
    }

    free(yInt);
    return out;
}
