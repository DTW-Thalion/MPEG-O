#ifndef TTIO_JCAMP_DX_DECODE_H
#define TTIO_JCAMP_DX_DECODE_H

#import <Foundation/Foundation.h>

/**
 * JCAMP-DX 5.01 compressed-XYDATA decoder (SQZ / DIF / DUP / PAC).
 *
 * Implements §5.9 of JCAMP-DX 5.01. The AFFN dialect is handled
 * directly by TTIOJcampDxReader; this class is consulted only when
 * `hasCompression:` reports a compression sentinel.
 *
 * Cross-language equivalents:
 *   Java:   com.dtwthalion.ttio.importers.JcampDxDecode
 *   Python: ttio.importers._jcamp_decode
 */
@interface TTIOJcampDxDecode : NSObject

/** Returns YES iff `body` carries any SQZ/DIF/DUP sentinel. */
+ (BOOL)hasCompression:(NSString *)body;

/**
 * Decode a compressed XYDATA body.
 *
 * @param lines   Raw text lines of the XYDATA block (no LDR headers,
 *                no terminal `##END=`).
 * @param firstx  First X value from `##FIRSTX=`.
 * @param deltax  `(LASTX - FIRSTX) / (NPOINTS - 1)`.
 * @param xfactor `##XFACTOR=` scale factor (default 1).
 * @param yfactor `##YFACTOR=` scale factor (default 1).
 * @param outXs   On success, filled with `NSNumber *` doubles.
 * @param outYs   On success, filled with `NSNumber *` doubles.
 * @return YES on success, NO on malformed input (populates error).
 */
+ (BOOL)decodeLines:(NSArray<NSString *> *)lines
             firstx:(double)firstx
             deltax:(double)deltax
            xfactor:(double)xfactor
            yfactor:(double)yfactor
            outXs:(NSMutableArray<NSNumber *> *)outXs
            outYs:(NSMutableArray<NSNumber *> *)outYs
            error:(NSError **)error;

@end

#endif
