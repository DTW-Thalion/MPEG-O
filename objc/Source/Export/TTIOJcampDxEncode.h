#ifndef TTIO_JCAMP_DX_ENCODE_H
#define TTIO_JCAMP_DX_ENCODE_H

#import <Foundation/Foundation.h>
#import "TTIOJcampDxEncoding.h"

/**
 * JCAMP-DX 5.01 compressed-XYDATA encoder (PAC / SQZ / DIF).
 *
 * Byte-for-byte mirror of Python `ttio.exporters._jcamp_encode`
 * and Java `global.thalion.ttio.exporters.JcampDxEncode`. The
 * conformance fixtures under `conformance/jcamp_dx/` are the gate —
 * if this encoder and the Python/Java encoders diverge, one of them
 * is wrong.
 *
 * Private implementation detail of TTIOJcampDxWriter; not part of
 * the public API.
 */

#define TTIO_JCAMP_VALUES_PER_LINE 10

/** Pick a YFACTOR scaling `ys` to ~`sigDigits`-digit integers. */
double TTIOJcampChooseYFactor(const double *ys, NSUInteger n, int sigDigits);

/** Half-away-from-zero rounding (matches Python + Java exactly). */
int64_t TTIOJcampRoundInt(double v);

/** SQZ-encode a signed integer using the `@ABCDEFGHI` / `@abcdefghi` tables. */
NSString *TTIOJcampEncodeSqz(int64_t v);

/** DIF-encode a Y-difference using the `%JKLMNOPQR` / `%jklmnopqr` tables. */
NSString *TTIOJcampEncodeDif(int64_t delta);

/** PAC-encode a Y value with explicit sign (token delimiter per §5.9). */
NSString *TTIOJcampEncodePacY(int64_t v);

/** Python-`%.10g`-equivalent formatter (strips trailing zeros). */
NSString *TTIOJcampFormatG10(double x);

/**
 * Return the body of an `##XYDATA=(X++(Y..Y))` block for a PAC / SQZ
 * / DIF encoding. AFFN is NOT routed through here. Output is
 * newline-separated with a trailing newline.
 */
NSString *TTIOJcampEncodeXYData(const double *ys, NSUInteger n,
                                double firstx, double deltax,
                                double yfactor,
                                TTIOJcampDxEncoding mode);

#endif
