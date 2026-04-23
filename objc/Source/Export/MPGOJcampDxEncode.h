#ifndef MPGO_JCAMP_DX_ENCODE_H
#define MPGO_JCAMP_DX_ENCODE_H

#import <Foundation/Foundation.h>
#import "MPGOJcampDxEncoding.h"

/**
 * JCAMP-DX 5.01 compressed-XYDATA encoder (PAC / SQZ / DIF).
 *
 * Byte-for-byte mirror of Python `mpeg_o.exporters._jcamp_encode`
 * and Java `com.dtwthalion.mpgo.exporters.JcampDxEncode`. The
 * conformance fixtures under `conformance/jcamp_dx/` are the gate —
 * if this encoder and the Python/Java encoders diverge, one of them
 * is wrong.
 *
 * Private implementation detail of MPGOJcampDxWriter; not part of
 * the public API.
 */

#define MPGO_JCAMP_VALUES_PER_LINE 10

/** Pick a YFACTOR scaling `ys` to ~`sigDigits`-digit integers. */
double MPGOJcampChooseYFactor(const double *ys, NSUInteger n, int sigDigits);

/** Half-away-from-zero rounding (matches Python + Java exactly). */
int64_t MPGOJcampRoundInt(double v);

/** SQZ-encode a signed integer using the `@ABCDEFGHI` / `@abcdefghi` tables. */
NSString *MPGOJcampEncodeSqz(int64_t v);

/** DIF-encode a Y-difference using the `%JKLMNOPQR` / `%jklmnopqr` tables. */
NSString *MPGOJcampEncodeDif(int64_t delta);

/** PAC-encode a Y value with explicit sign (token delimiter per §5.9). */
NSString *MPGOJcampEncodePacY(int64_t v);

/** Python-`%.10g`-equivalent formatter (strips trailing zeros). */
NSString *MPGOJcampFormatG10(double x);

/**
 * Return the body of an `##XYDATA=(X++(Y..Y))` block for a PAC / SQZ
 * / DIF encoding. AFFN is NOT routed through here. Output is
 * newline-separated with a trailing newline.
 */
NSString *MPGOJcampEncodeXYData(const double *ys, NSUInteger n,
                                double firstx, double deltax,
                                double yfactor,
                                MPGOJcampDxEncoding mode);

#endif
