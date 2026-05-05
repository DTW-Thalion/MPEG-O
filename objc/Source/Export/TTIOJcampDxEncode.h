#ifndef TTIO_JCAMP_DX_ENCODE_H
#define TTIO_JCAMP_DX_ENCODE_H

#import <Foundation/Foundation.h>
#import "TTIOJcampDxEncoding.h"

/**
 * <p><em>Declared In:</em> Export/TTIOJcampDxEncode.h</p>
 *
 * <p>JCAMP-DX 5.01 compressed-XYDATA encoder
 * (PAC / SQZ / DIF). Byte-for-byte mirror of Python
 * <code>ttio.exporters._jcamp_encode</code> and Java
 * <code>global.thalion.ttio.exporters.JcampDxEncode</code>. The
 * conformance fixtures under <code>conformance/jcamp_dx/</code> are
 * the gate &#8212; if this encoder and the Python / Java encoders
 * diverge, one of them is wrong.</p>
 *
 * <p>Private implementation detail of
 * <code>TTIOJcampDxWriter</code>; not part of the public API.</p>
 */

#define TTIO_JCAMP_VALUES_PER_LINE 10

/**
 * Picks a YFACTOR scaling <code>ys</code> to ~<code>sigDigits</code>
 * digit integers.
 *
 * @param ys        Sample values.
 * @param n         Length of <code>ys</code>.
 * @param sigDigits Target significant digits after integer scaling.
 * @return The chosen YFACTOR.
 */
double TTIOJcampChooseYFactor(const double *ys, NSUInteger n, int sigDigits);

/**
 * Half-away-from-zero rounding (matches Python and Java exactly).
 *
 * @param v Input value.
 * @return The rounded integer.
 */
int64_t TTIOJcampRoundInt(double v);

/**
 * SQZ-encodes a signed integer using the
 * <code>@ABCDEFGHI</code> / <code>@abcdefghi</code> tables.
 *
 * @param v Integer to encode.
 * @return The SQZ token.
 */
NSString *TTIOJcampEncodeSqz(int64_t v);

/**
 * DIF-encodes a Y-difference using the
 * <code>%JKLMNOPQR</code> / <code>%jklmnopqr</code> tables.
 *
 * @param delta Y difference.
 * @return The DIF token.
 */
NSString *TTIOJcampEncodeDif(int64_t delta);

/**
 * PAC-encodes a Y value with explicit sign (token delimiter per
 * §5.9).
 *
 * @param v Y value.
 * @return The PAC token.
 */
NSString *TTIOJcampEncodePacY(int64_t v);

/**
 * Python-<code>%.10g</code>-equivalent formatter (strips trailing
 * zeros).
 *
 * @param x Input value.
 * @return The formatted string.
 */
NSString *TTIOJcampFormatG10(double x);

/**
 * Returns the body of an <code>##XYDATA=(X++(Y..Y))</code> block for
 * a PAC / SQZ / DIF encoding. AFFN is NOT routed through here.
 * Output is newline-separated with a trailing newline.
 *
 * @param ys      Sample Y values.
 * @param n       Length of <code>ys</code>.
 * @param firstx  First X value.
 * @param deltax  X step.
 * @param yfactor Shared YFACTOR.
 * @param mode    Encoding mode (must be PAC, SQZ, or DIF).
 * @return The block body string.
 */
NSString *TTIOJcampEncodeXYData(const double *ys, NSUInteger n,
                                double firstx, double deltax,
                                double yfactor,
                                TTIOJcampDxEncoding mode);

#endif
