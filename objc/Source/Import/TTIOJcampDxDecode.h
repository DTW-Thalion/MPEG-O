#ifndef TTIO_JCAMP_DX_DECODE_H
#define TTIO_JCAMP_DX_DECODE_H

#import <Foundation/Foundation.h>

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Import/TTIOJcampDxDecode.h</p>
 *
 * <p>JCAMP-DX 5.01 compressed-XYDATA decoder
 * (SQZ / DIF / DUP / PAC). Implements §5.9 of JCAMP-DX 5.01. The
 * AFFN dialect is handled directly by
 * <code>TTIOJcampDxReader</code>; this class is consulted only when
 * <code>+hasCompression:</code> reports a compression sentinel.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.importers._jcamp_decode</code><br/>
 * Java: <code>global.thalion.ttio.importers.JcampDxDecode</code></p>
 */
@interface TTIOJcampDxDecode : NSObject

/**
 * @param body XYDATA section text body.
 * @return <code>YES</code> iff <code>body</code> carries any
 *         SQZ / DIF / DUP sentinel character.
 */
+ (BOOL)hasCompression:(NSString *)body;

/**
 * Decodes a compressed XYDATA body.
 *
 * @param lines   Raw text lines of the XYDATA block (no LDR headers,
 *                no terminal <code>##END=</code>).
 * @param firstx  First X value from <code>##FIRSTX=</code>.
 * @param deltax  <code>(LASTX - FIRSTX) / (NPOINTS - 1)</code>.
 * @param xfactor <code>##XFACTOR=</code> scale factor (default 1).
 * @param yfactor <code>##YFACTOR=</code> scale factor (default 1).
 * @param outXs   On success, filled with <code>NSNumber *</code>
 *                doubles.
 * @param outYs   On success, filled with <code>NSNumber *</code>
 *                doubles.
 * @param error   Out-parameter populated on malformed input.
 * @return <code>YES</code> on success, <code>NO</code> on malformed
 *         input.
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
